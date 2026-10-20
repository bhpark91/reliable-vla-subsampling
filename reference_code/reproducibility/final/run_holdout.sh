#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
REPO=${REPO:-"$REPO_ROOT"}
CAL_MATRIX=${CAL_MATRIX:-"$REPO/data/calibration/calibration_wide_500x11.csv"}
CAL_LONG=${CAL_LONG:-"$REPO/data/calibration/calibration_long_5500.csv"}
HOLD_WIDE=${HOLD_WIDE:-"$REPO/data/holdout/holdout_wide_500x3.csv"}
HOLD_LONG=${HOLD_LONG:-"$REPO/data/holdout/holdout_long_1500.csv"}
HOLD_AUDIT=${HOLD_AUDIT:-"$REPO/data/holdout/audit_report.json"}
OUT=${OUT:-"$REPO/reproducibility/reproduced/final/prospective_corrected_v2"}
PYTHON=${PYTHON:-python3}
mkdir -p "$OUT"

test -s "$CAL_MATRIX" || { echo "ERROR=CAL_MATRIX_MISSING:$CAL_MATRIX"; exit 2; }
test -s "$CAL_LONG" || { echo "ERROR=CAL_LONG_MISSING:$CAL_LONG"; exit 3; }
test -d "$REPO/data" || { echo "ERROR=CAL_REPO_MISSING:$REPO"; exit 4; }
test -s "$HOLD_WIDE" || { echo "ERROR=HOLD_WIDE_MISSING:$HOLD_WIDE"; exit 6; }
test -s "$HOLD_LONG" || { echo "ERROR=HOLD_LONG_MISSING:$HOLD_LONG"; exit 7; }
test -s "$HOLD_AUDIT" || { echo "ERROR=HOLD_AUDIT_MISSING:$HOLD_AUDIT"; exit 8; }

echo "============================================================"
echo " FROZEN PROSPECTIVE UNSEEN-FAMILY D500 COMPARISON"
echo "============================================================"
echo "Calibration: 11 systems / 9 families / 5500 responses"
echo "Holdout:     3 systems / 2 unseen families / 1500 responses"
echo "Budgets:     80,160,320"
echo "Methods:     SRS, STRAT_PROP, STRAT_BAL, STRAT_NEYMAN_CAL,"
echo "             STRAT_REG, ADAPT20_REG"
echo "Replicates:  5000"
echo "GPU jobs:    0"
echo "Leakage:     calibration frozen before holdout; no refit/tuning"
echo "============================================================"

echo
echo "===== INPUT SHA256 ====="
sha256sum "$CAL_MATRIX" "$CAL_LONG" "$HOLD_WIDE" "$HOLD_LONG" "$HOLD_AUDIT" \
  | tee "$OUT/input_SHA256SUMS.txt"

echo
echo "===== RUN PROSPECTIVE ANALYSIS ====="

"$PYTHON" - "$CAL_MATRIX" "$CAL_LONG" "$REPO" "$HOLD_WIDE" "$HOLD_LONG" "$HOLD_AUDIT" "$OUT" <<'PY'
from __future__ import annotations

import csv
import gzip
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
from scipy.optimize import minimize

cal_matrix = Path(sys.argv[1])
cal_long = Path(sys.argv[2])
repo = Path(sys.argv[3])
hold_wide = Path(sys.argv[4])
hold_long = Path(sys.argv[5])
hold_audit = Path(sys.argv[6])
out = Path(sys.argv[7])
out.mkdir(parents=True, exist_ok=True)

SEED_CLASSICAL = 20260829
SEED_FROZEN = 20260824
REPS = 5000
BUDGETS = (80, 160, 320)
RIDGE = 1/9
ANCHOR = 80
ADAPT_N = 8
EXPLORE_N = 32
HOLD_SYSTEMS = ("pi05", "pi0_fast", "vlanext")
HOLD_FAMILY = {
    "pi05": "pi_openpi",
    "pi0_fast": "pi_openpi",
    "vlanext": "vlanext",
}

def read_csv(p):
    with Path(p).open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))

# ------------------------------------------------------------------
# 1. Load frozen calibration only.
# ------------------------------------------------------------------

cw = read_csv(cal_matrix)
assert len(cw) == 500
base_cols = ["item_index", "language", "registry_name", "suite"]
cal_systems = [c for c in cw[0].keys() if c not in base_cols]
assert len(cal_systems) == 11, cal_systems

item_index = np.array([int(r["item_index"]) for r in cw], dtype=int)
assert np.array_equal(item_index, np.arange(500))

# items x systems, matching the frozen clean-room implementation
Ycal = np.array([[int(r[s]) for s in cal_systems] for r in cw], dtype=float)
assert Ycal.shape == (500, 11)
assert np.isin(Ycal, [0, 1]).all()

cl = read_csv(cal_long)
assert len(cl) == 5500
cal_family = {}
for r in cl:
    s, f = r["system"], r["family"]
    if s in cal_family:
        assert cal_family[s] == f
    cal_family[s] = f
assert set(cal_family) == set(cal_systems)
assert len(set(cal_family.values())) == 9

# ------------------------------------------------------------------
# 2. Load audited holdout gold matrix.
# ------------------------------------------------------------------

audit = json.load(open(hold_audit))
assert audit["gate"] == "PASS"
assert audit["observed_rows"] == 1500
assert audit["engineering_errors"] == 0

hw = read_csv(hold_wide)
assert len(hw) == 500
assert all(s in hw[0] for s in HOLD_SYSTEMS)
hold_idx = np.array([int(r["discovery_index"]) for r in hw], dtype=int)
order = np.argsort(hold_idx)
hw = [hw[i] for i in order]
hold_idx = np.array([int(r["discovery_index"]) for r in hw], dtype=int)
assert np.array_equal(hold_idx, np.arange(500))

Yhold = {
    s: np.array([int(r[s]) for r in hw], dtype=float)
    for s in HOLD_SYSTEMS
}
for s in HOLD_SYSTEMS:
    assert np.isin(Yhold[s], [0, 1]).all()
    assert len(Yhold[s]) == 500

# ------------------------------------------------------------------
# 3. Hard leakage guards.
# ------------------------------------------------------------------

assert not (set(HOLD_SYSTEMS) & set(cal_systems))
assert not (set(HOLD_FAMILY.values()) & set(cal_family.values())), (
    set(HOLD_FAMILY.values()) & set(cal_family.values())
)

# The only arrays used for calibration-side quantities below are Ycal.
# Yhold is accessed only by the evaluation/sampling routines after all frozen
# calibration quantities are built.

# ------------------------------------------------------------------
# 4. Canonical D500 metadata.
# ------------------------------------------------------------------

manifest_path = repo / "data/bank/discovery_500_primary.json"
manifest = json.loads(manifest_path.read_text())
items = manifest["items"]
assert len(items) == 500
items_by_idx = {int(x["discovery_index"]): x for x in items}
assert set(items_by_idx) == set(range(500))
items = [items_by_idx[i] for i in range(500)]

for r in cw:
    i = int(r["item_index"])
    x = items[i]
    assert r["language"] == x["language"]
    assert r["registry_name"] == x["registry_name"]
    assert r["suite"] == x["suite"]

for r in hw:
    i = int(r["discovery_index"])
    assert r["suite"] == items[i]["suite"]

def clean_meta(v):
    if v is None or v == "":
        return "NA"
    return str(v)

# Frozen classical hierarchy = suite x category, 24 strata.
strata_keys = [
    (
        clean_meta(x.get("suite")),
        clean_meta(x.get("category")),
    )
    for x in items
]
unique_strata = sorted(set(strata_keys), key=lambda z: tuple(map(str, z)))
assert len(unique_strata) == 24
stratum_id = {k: h for h, k in enumerate(unique_strata)}
item_stratum = np.array([stratum_id[k] for k in strata_keys], dtype=int)
H = len(unique_strata)
strata_items = [np.where(item_stratum == h)[0] for h in range(H)]
Nh = np.array([len(ix) for ix in strata_items], dtype=int)
Wh = Nh / 500.0
assert Nh.sum() == 500
assert Nh.min() == 20
assert Nh.max() == 21

# Frozen IRT/CAT stratification = suite only.
suite = np.array([x["suite"] for x in items], dtype=object)
suite_names = sorted(set(suite))
suite_groups = {s: np.where(suite == s)[0] for s in suite_names}
assert len(suite_names) == 4

# ------------------------------------------------------------------
# 5. Exact frozen clean-room Rasch (ridge 1/9), fit to calibration only.
# ------------------------------------------------------------------

def expit(x):
    x = np.asarray(x, dtype=float)
    o = np.empty_like(x)
    p = x >= 0
    o[p] = 1 / (1 + np.exp(-x[p]))
    z = np.exp(x[~p])
    o[~p] = z / (1 + z)
    return o

def fit_rasch(Y):
    # Y is items x systems, exact orientation of frozen clean-room code.
    ni, ns = Y.shape
    sr = (Y.sum(0) + .5) / (ni + 1)
    th0 = np.log(sr / (1 - sr))
    ir = (Y.sum(1) + .5) / (ns + 1)
    b0 = -np.log(ir / (1 - ir))
    x0 = np.r_[th0, b0]

    def fg(x):
        th = x[:ns]
        b = x[ns:]
        eta = th[None, :] - b[:, None]
        p = expit(eta)
        nll = np.logaddexp(0, eta).sum() - (Y * eta).sum()
        obj = nll + .5 * RIDGE * (th @ th + b @ b)
        grad = np.r_[
            (p - Y).sum(0) + RIDGE * th,
            (Y - p).sum(1) + RIDGE * b,
        ]
        return float(obj), grad

    r = minimize(
        lambda x: fg(x)[0],
        x0,
        jac=lambda x: fg(x)[1],
        method="L-BFGS-B",
        options={"maxiter":10000, "ftol":1e-15, "gtol":1e-10, "maxls":80},
    )
    th = r.x[:ns]
    b = r.x[ns:]
    shift = float(th.mean())
    th -= shift
    b -= shift
    return {"success": bool(r.success), "theta": th, "b": b}

rasch = fit_rasch(Ycal)
assert rasch["success"]
b_frozen = np.asarray(rasch["b"], float)

# Eligibility is calibration-only variability; no holdout response inspected.
elig_frozen = (Ycal.sum(1) > 0) & (Ycal.sum(1) < Ycal.shape[1])

# ------------------------------------------------------------------
# 6. Exact integer allocation helpers.
# ------------------------------------------------------------------

def allocate_integer(weights, budget, capacities, min_each=1):
    weights = np.asarray(weights, dtype=float)
    capacities = np.asarray(capacities, dtype=int)
    Hloc = len(weights)

    if budget > int(capacities.sum()):
        raise ValueError("budget exceeds population")
    if min_each * Hloc > budget:
        raise ValueError("budget too small for min_each")
    if np.any(capacities < min_each):
        raise ValueError("capacity below min_each")

    n = np.full(Hloc, min_each, dtype=int)
    remaining = budget - int(n.sum())
    cap_left = capacities - n
    if remaining == 0:
        return n

    w = np.maximum(weights, 0.0)
    if w.sum() <= 0:
        w = cap_left.astype(float)
    else:
        w = w.copy()

    while remaining > 0:
        active = cap_left > 0
        if not active.any():
            raise RuntimeError("no capacity left")
        wa = w.copy()
        wa[~active] = 0.0
        if wa.sum() <= 0:
            wa = cap_left.astype(float)
        quota = remaining * wa / wa.sum()
        floor = np.minimum(np.floor(quota).astype(int), cap_left)
        add_floor = int(floor.sum())

        if add_floor > 0:
            n += floor
            cap_left -= floor
            remaining -= add_floor
            if remaining == 0:
                break

        active = cap_left > 0
        if not active.any():
            break
        remainder = quota - np.floor(quota)
        order = np.argsort(-remainder, kind="mergesort")
        progressed = False
        for h in order:
            if remaining == 0:
                break
            if cap_left[h] <= 0:
                continue
            n[h] += 1
            cap_left[h] -= 1
            remaining -= 1
            progressed = True

        if not progressed:
            order = np.argsort(-cap_left, kind="mergesort")
            for h in order:
                if remaining == 0:
                    break
                if cap_left[h] > 0:
                    n[h] += 1
                    cap_left[h] -= 1
                    remaining -= 1

    assert n.sum() == budget
    assert np.all(n >= min_each)
    assert np.all(n <= capacities)
    return n

def alloc_prop(B):
    return allocate_integer(Nh.astype(float), B, Nh, min_each=1)

def alloc_bal(B):
    return allocate_integer(np.ones(H), B, Nh, min_each=1)

# Exact inference from frozen producer:
# training_S_h = sqrt(mean across calibration systems of within-stratum
# unbiased sample variance). This uses calibration outcomes only.
def calibration_neyman_sd():
    # Ycal is items x systems; transpose to systems x items.
    tr = Ycal.T
    S = np.zeros(H, dtype=float)
    for h, ix in enumerate(strata_items):
        # binary sample variance within each calibration system/stratum
        v = np.var(tr[:, ix], axis=1, ddof=1)
        S[h] = float(np.sqrt(np.mean(v)))
    return S

S_cal = calibration_neyman_sd()

def alloc_neyman(B):
    return allocate_integer(Nh.astype(float) * S_cal, B, Nh, min_each=1)

# Save prospective frozen allocations.
with (out / "classical_allocations.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow([
        "budget","stratum_id","stratum_key","N_h",
        "prop_n","bal_n","neyman_cal_n","training_S_h"
    ])
    for B in BUDGETS:
        ap, ab, an = alloc_prop(B), alloc_bal(B), alloc_neyman(B)
        for h, key in enumerate(unique_strata):
            w.writerow([
                B,h,json.dumps(key),int(Nh[h]),
                int(ap[h]),int(ab[h]),int(an[h]),float(S_cal[h])
            ])

# ------------------------------------------------------------------
# 7. Classical estimators.
# ------------------------------------------------------------------

def draw_stratified(rng, allocation):
    out_ix = []
    by_h = {}
    for h, n in enumerate(allocation):
        ix = rng.choice(strata_items[h], size=int(n), replace=False)
        by_h[h] = np.asarray(ix, int)
        out_ix.extend(ix.tolist())
    return np.asarray(out_ix, int), by_h

def strat_est(y, by_h):
    return float(sum(Wh[h] * float(np.mean(y[ix])) for h, ix in by_h.items()))

# results[method][B][system] = list of prediction errors / predictions
preds = {
    m: {B:{s:[] for s in HOLD_SYSTEMS} for B in BUDGETS}
    for m in (
        "SRS","STRAT_PROP","STRAT_BAL","STRAT_NEYMAN_CAL",
        "STRAT_REG","ADAPT20_REG"
    )
}

# SRS common-random sample across systems, deterministic frozen seed.
rng = np.random.default_rng(SEED_CLASSICAL)
for rep in range(REPS):
    perm = rng.permutation(500)
    for B in BUDGETS:
        ix = perm[:B]
        for s in HOLD_SYSTEMS:
            preds["SRS"][B][s].append(float(np.mean(Yhold[s][ix])))

# Three strict classical stratified designs.
for method, afn, offset in (
    ("STRAT_PROP", alloc_prop, 1000),
    ("STRAT_BAL", alloc_bal, 2000),
    ("STRAT_NEYMAN_CAL", alloc_neyman, 3000),
):
    rng = np.random.default_rng(SEED_CLASSICAL + offset)
    allocations = {B:afn(B) for B in BUDGETS}
    for rep in range(REPS):
        # Nested by stratum via one permutation/stratum, analogous to frozen
        # sampling design; allocation differs by B.
        perms = {h:rng.permutation(strata_items[h]) for h in range(H)}
        for B in BUDGETS:
            by_h = {
                h:perms[h][:int(allocations[B][h])]
                for h in range(H)
            }
            for s in HOLD_SYSTEMS:
                preds[method][B][s].append(strat_est(Yhold[s], by_h))

# ------------------------------------------------------------------
# 8. Frozen STRAT_REG / ADAPT20_REG.
# ------------------------------------------------------------------

def alloc_suite(caps, total):
    keys = list(caps)
    sz = np.array([caps[k] for k in keys], float)
    ideal = total * sz / sz.sum()
    n = np.floor(ideal).astype(int)
    rem = total - int(n.sum())
    for q in sorted(range(len(keys)), key=lambda q:(-(ideal-n)[q], keys[q])):
        if rem <= 0:
            break
        if n[q] < sz[q]:
            n[q] += 1
            rem -= 1
    return {k:int(n[q]) for q,k in enumerate(keys)}

def theta_est(y, b):
    r = (y.sum() + .5) / (len(y) + 1)
    th = float(np.log(r / (1-r)))
    for _ in range(60):
        p = expit(th-b)
        sc = float((y-p).sum() - RIDGE*th)
        inf = float((p*(1-p)).sum() + RIDGE)
        th2 = float(np.clip(th + sc/inf, -12, 12))
        if abs(th2-th) < 1e-12:
            th = th2
            break
        th = th2
    return th

def rs_suite(rng, av, n):
    al = alloc_suite(
        {s:int(np.sum(av[suite_groups[s]])) for s in suite_names},
        n,
    )
    o = []
    for s in suite_names:
        pool = suite_groups[s][av[suite_groups[s]]]
        if al[s]:
            o.extend(rng.choice(pool, size=al[s], replace=False).tolist())
    return np.array(o, int)

def info_select(th, b, av, n, elig):
    mask = av & elig
    pools = {s:suite_groups[s][mask[suite_groups[s]]] for s in suite_names}
    al = alloc_suite({s:len(pools[s]) for s in suite_names}, n)
    o = []
    for s in suite_names:
        pool = pools[s]
        if not al[s]:
            continue
        p = expit(th-b[pool])
        inf = p*(1-p)
        order = np.lexsort((pool, -inf))
        o.extend(pool[order[:al[s]]].tolist())
    return np.array(o, int)

def irt_pred(y, b, theta_mask, random_mask):
    ii = np.where(theta_mask)[0]
    th = theta_est(y[ii], b[ii])
    pall = expit(th-b)
    corr = 0.0
    for s in suite_names:
        g = suite_groups[s]
        take = g[random_mask[g]]
        if len(take):
            corr += (len(g)/500.0) * float(np.mean(y[take] - pall[take]))
    return float(np.clip(float(pall.mean()) + corr, 0, 1)), th

# STRAT_REG exact frozen RNG scheme: one suite permutation/rep, common targets.
rng = np.random.default_rng(SEED_FROZEN)
for rep in range(REPS):
    perms = {s:rng.permutation(suite_groups[s]) for s in suite_names}
    samples = {}
    for B in BUDGETS:
        al = alloc_suite({s:len(suite_groups[s]) for s in suite_names}, B)
        samples[B] = np.concatenate([perms[s][:al[s]] for s in suite_names])

    for system in HOLD_SYSTEMS:
        y = Yhold[system]
        for B in BUDGETS:
            mask = np.zeros(500, bool)
            mask[samples[B]] = True
            pr, _ = irt_pred(y, b_frozen, mask, mask)
            preds["STRAT_REG"][B][system].append(pr)

# ADAPT20 exact frozen acquisition, with unseen systems deterministically
# appended after the 11 calibration systems. This index assignment is
# outcome-independent and frozen in this prospective script.
prospective_j = {
    "pi05": 11,
    "pi0_fast": 12,
    "vlanext": 13,
}
for rep in range(REPS):
    for system in HOLD_SYSTEMS:
        y = Yhold[system]
        j = prospective_j[system]
        sr = (SEED_FROZEN*1000003 + rep*1009 + (j+1)*9176) % (2**63-1)
        rng = np.random.default_rng(sr)

        av = np.ones(500, bool)
        a = rs_suite(rng, av, ANCHOR)
        av[a] = False

        sel = np.zeros(500, bool)
        sel[a] = True
        rnd = sel.copy()

        pr, th = irt_pred(y, b_frozen, sel, rnd)
        preds["ADAPT20_REG"][80][system].append(pr)

        while sel.sum() < 320:
            ad = info_select(th, b_frozen, av, ADAPT_N, elig_frozen)
            av[ad] = False
            ex = rs_suite(rng, av, EXPLORE_N)
            av[ex] = False
            sel[ad] = True
            sel[ex] = True
            rnd[ex] = True
            pr, th = irt_pred(y, b_frozen, sel, rnd)
            B = int(sel.sum())
            if B in (160, 320):
                preds["ADAPT20_REG"][B][system].append(pr)

# ------------------------------------------------------------------
# 9. Summaries.
# ------------------------------------------------------------------

methods = tuple(preds)
truth = {s:float(np.mean(Yhold[s])) for s in HOLD_SYSTEMS}

system_rows = []
family_rows = []
overall_rows = []
rep_rows = []

for method in methods:
    for B in BUDGETS:
        system_metrics = {}
        for s in HOLD_SYSTEMS:
            pr = np.asarray(preds[method][B][s], float)
            assert len(pr) == REPS, (method,B,s,len(pr))
            err_pp = (pr - truth[s]) * 100.0
            abs_pp = np.abs(err_pp)

            m = {
                "method":method,
                "budget":B,
                "system":s,
                "family":HOLD_FAMILY[s],
                "truth":truth[s],
                "mean_estimate":float(pr.mean()),
                "mae_pp":float(abs_pp.mean()),
                "rmse_pp":float(np.sqrt(np.mean(err_pp**2))),
                "bias_pp":float(err_pp.mean()),
                "abs_bias_pp":float(abs(err_pp.mean())),
                "p90_abs_pp":float(np.quantile(abs_pp,.9)),
                "gt5_rate":float(np.mean(abs_pp>5.0)),
                "replicates":REPS,
            }
            system_rows.append(m)
            system_metrics[s] = m

            for rep, (p,e,a) in enumerate(zip(pr,err_pp,abs_pp)):
                rep_rows.append({
                    "method":method,"budget":B,"system":s,
                    "family":HOLD_FAMILY[s],"replicate":rep,
                    "truth":truth[s],"estimate":float(p),
                    "error_pp":float(e),"abs_error_pp":float(a),
                })

        fam_metrics = {}
        for fam in ("pi_openpi","vlanext"):
            ss = [s for s in HOLD_SYSTEMS if HOLD_FAMILY[s] == fam]
            fm = {
                "method":method,
                "budget":B,
                "family":fam,
                "n_systems":len(ss),
            }
            for metric in (
                "mae_pp","rmse_pp","abs_bias_pp","p90_abs_pp","gt5_rate"
            ):
                fm[metric] = float(np.mean([system_metrics[s][metric] for s in ss]))
            family_rows.append(fm)
            fam_metrics[fam] = fm

        overall = {
            "method":method,
            "budget":B,
            "family_balanced_mae_pp":float(np.mean([
                fam_metrics["pi_openpi"]["mae_pp"],
                fam_metrics["vlanext"]["mae_pp"],
            ])),
            "family_balanced_rmse_pp":float(np.mean([
                fam_metrics["pi_openpi"]["rmse_pp"],
                fam_metrics["vlanext"]["rmse_pp"],
            ])),
            "family_balanced_abs_bias_pp":float(np.mean([
                fam_metrics["pi_openpi"]["abs_bias_pp"],
                fam_metrics["vlanext"]["abs_bias_pp"],
            ])),
            "family_balanced_p90_abs_pp":float(np.mean([
                fam_metrics["pi_openpi"]["p90_abs_pp"],
                fam_metrics["vlanext"]["p90_abs_pp"],
            ])),
            "family_balanced_gt5_rate":float(np.mean([
                fam_metrics["pi_openpi"]["gt5_rate"],
                fam_metrics["vlanext"]["gt5_rate"],
            ])),
        }
        overall_rows.append(overall)

# Rank by family-balanced MAE within budget.
for B in BUDGETS:
    rows = [r for r in overall_rows if r["budget"] == B]
    for rank, r in enumerate(sorted(rows,key=lambda x:x["family_balanced_mae_pp"]),1):
        r["rank"] = rank

# Key deltas, descriptive (2 unseen families only).
lookup = {(r["method"],r["budget"]):r for r in overall_rows}
key_deltas = []
for B in BUDGETS:
    for a,b in (
        ("STRAT_REG","STRAT_NEYMAN_CAL"),
        ("ADAPT20_REG","STRAT_NEYMAN_CAL"),
        ("ADAPT20_REG","STRAT_REG"),
    ):
        key_deltas.append({
            "budget":B,
            "method_a":a,
            "method_b":b,
            "delta_family_balanced_mae_pp_a_minus_b":
                lookup[(a,B)]["family_balanced_mae_pp"]
                - lookup[(b,B)]["family_balanced_mae_pp"],
        })

def write_dict_csv(path, rows):
    fields = list(rows[0].keys())
    with Path(path).open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)

write_dict_csv(out/"prospective_system_summary.csv", system_rows)
write_dict_csv(out/"prospective_family_summary.csv", family_rows)
write_dict_csv(out/"prospective_overall_summary.csv", overall_rows)
write_dict_csv(out/"prospective_key_deltas.csv", key_deltas)

with gzip.open(out/"prospective_replicate_errors.csv.gz","wt",newline="",encoding="utf-8") as f:
    fields = list(rep_rows[0].keys())
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rep_rows)

# Human-readable table.
lines = []
lines.append("# Prospective unseen-family D500 validation")
lines.append("")
lines.append("Frozen before holdout: 11 calibration systems / 9 families.")
lines.append("Targets: pi05, pi0_fast (pi_openpi), vlanext (vlanext).")
lines.append("No holdout outcomes used to fit Rasch difficulty, eligibility, strata, or Neyman variance.")
lines.append("")
lines.append("## Full D500 target scores")
lines.append("")
for s in HOLD_SYSTEMS:
    lines.append(f"- {s}: {truth[s]*100:.1f}%")
lines.append("")
for B in BUDGETS:
    lines.append(f"## Budget {B}")
    lines.append("")
    lines.append("| Rank | Method | Family-balanced MAE (pp) | RMSE (pp) | >5pp rate |")
    lines.append("|---:|---|---:|---:|---:|")
    rows = sorted([r for r in overall_rows if r["budget"]==B], key=lambda x:x["rank"])
    for r in rows:
        lines.append(
            f"| {r['rank']} | {r['method']} | "
            f"{r['family_balanced_mae_pp']:.4f} | "
            f"{r['family_balanced_rmse_pp']:.4f} | "
            f"{100*r['family_balanced_gt5_rate']:.2f}% |"
        )
    lines.append("")

lines.append("## Key deltas")
lines.append("")
for r in key_deltas:
    lines.append(
        f"- B={r['budget']} {r['method_a']} - {r['method_b']}: "
        f"{r['delta_family_balanced_mae_pp_a_minus_b']:+.4f} pp"
    )
lines.append("")
lines.append("Inference note: only 2 unseen families are available; treat family-balanced holdout comparisons as prospective descriptive validation rather than strong family-level inferential evidence.")
(out/"README.md").write_text("\n".join(lines)+"\n", encoding="utf-8")

summary = {
    "schema_version":"prospective_unseen_family_d500_v1",
    "calibration":{
        "systems":11,
        "families":9,
        "responses":5500,
        "used_holdout_outcomes":False,
        "rasch_ridge":RIDGE,
    },
    "holdout":{
        "systems":list(HOLD_SYSTEMS),
        "families":["pi_openpi","vlanext"],
        "responses":1500,
        "truth":truth,
    },
    "design":{
        "budgets":list(BUDGETS),
        "replicates":REPS,
        "classical_seed":SEED_CLASSICAL,
        "frozen_irt_seed":SEED_FROZEN,
        "classical_strata":"suite_category",
        "classical_nonempty_strata":H,
        "neyman_variance_source":"all 11 calibration systems only",
        "neyman_training_S_h":"sqrt(mean_system(within_stratum_sample_variance_ddof1))",
        "strat_reg":"frozen clean-room suite-stratified random sampling + Rasch residual correction",
        "adapt20_reg":{
            "anchor":ANCHOR,
            "batch":ADAPT_N+EXPLORE_N,
            "adaptive_per_batch":ADAPT_N,
            "random_explore_per_batch":EXPLORE_N,
            "eligibility_source":"calibration-only variable items",
            "difficulty_source":"Rasch fit on all 11 calibration systems only",
            "prospective_rng_system_indices":prospective_j,
        },
    },
    "overall":overall_rows,
    "system":system_rows,
    "family":family_rows,
    "key_deltas":key_deltas,
    "inference_note":"Only two unseen families; family-balanced prospective results are primarily descriptive.",
}
json.dump(summary,open(out/"prospective_summary.json","w"),indent=2,ensure_ascii=False)

# Print compact final result.
print("LEAKAGE_GUARD=PASS")
print("CALIBRATION_SYSTEMS=11")
print("CALIBRATION_FAMILIES=9")
print("HOLDOUT_SYSTEMS=3")
print("UNSEEN_FAMILIES=2")
print("HOLDOUT_OUTCOMES_USED_FOR_CALIBRATION=NO")
for s in HOLD_SYSTEMS:
    print(f"FULL_SCORE_{s.upper()}={truth[s]:.6f}")

for B in BUDGETS:
    print(f"===== BUDGET={B} =====")
    for r in sorted([x for x in overall_rows if x["budget"]==B], key=lambda x:x["rank"]):
        print(
            f"RANK={r['rank']} METHOD={r['method']} "
            f"FAM_MAE_PP={r['family_balanced_mae_pp']:.6f} "
            f"RMSE_PP={r['family_balanced_rmse_pp']:.6f} "
            f"GT5={r['family_balanced_gt5_rate']:.6f}"
        )
for r in key_deltas:
    if r["budget"] == 320:
        print(
            f"B320_DELTA {r['method_a']}-{r['method_b']}="
            f"{r['delta_family_balanced_mae_pp_a_minus_b']:+.6f}pp"
        )
PY

echo
echo "===== OUTPUT SHA256 ====="
(
  cd "$OUT"
  sha256sum \
    README.md \
    prospective_summary.json \
    prospective_system_summary.csv \
    prospective_family_summary.csv \
    prospective_overall_summary.csv \
    prospective_key_deltas.csv \
    prospective_replicate_errors.csv.gz \
    classical_allocations.csv \
    input_SHA256SUMS.txt
) | tee "$OUT/SHA256SUMS.txt"

echo
echo "===== COMPACT RESULTS ====="
"$PYTHON" - "$OUT/prospective_summary.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
for B in (80,160,320):
    rows=sorted(
        [r for r in x["overall"] if r["budget"]==B],
        key=lambda r:r["rank"]
    )
    print(f"B={B}")
    for r in rows:
        print(f"  {r['rank']}. {r['method']}: {r['family_balanced_mae_pp']:.4f} pp")
print("B320 key deltas:")
for r in x["key_deltas"]:
    if r["budget"]==320:
        print(
            f"  {r['method_a']} - {r['method_b']}: "
            f"{r['delta_family_balanced_mae_pp_a_minus_b']:+.4f} pp"
        )
PY

SCORE_LINES="$(
"$PYTHON" - "$OUT/prospective_summary.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
for B in (80,160,320):
    rows=sorted([r for r in x["overall"] if r["budget"]==B],key=lambda r:r["rank"])
    best=rows[0]
    print(f"B{B}_BEST={best['method']}:{best['family_balanced_mae_pp']:.6f}pp")
for r in x["key_deltas"]:
    if r["budget"]==320:
        print(
            f"B320_{r['method_a']}_MINUS_{r['method_b']}="
            f"{r['delta_family_balanced_mae_pp_a_minus_b']:+.6f}pp"
        )
PY
)"

SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=RUN_FROZEN_PROSPECTIVE_UNSEEN_FAMILY_D500
GATE=PASS
CALIBRATION=11_SYSTEMS_9_FAMILIES_5500_RESPONSES
HOLDOUT=3_SYSTEMS_2_UNSEEN_FAMILIES_1500_RESPONSES
FULL_PI05=0.876000
FULL_PI0_FAST=0.078000
FULL_VLANEXT=0.788000
LEAKAGE_GUARD=PASS
REPS=5000
BUDGETS=80,160,320
$SCORE_LINES
OUTPUT=$OUT
GPU_JOBS_CREATED=0
NEXT=REVIEW_REGENERATED_CORRECTED_HOLDOUT_OUTPUTS
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
