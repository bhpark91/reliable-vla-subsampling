#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
REPO=${REPO:-"$REPO_ROOT"}
MATRIX=${MATRIX:-"$REPO/data/calibration/calibration_wide_500x11.csv"}
LONG=${LONG:-"$REPO/data/calibration/calibration_long_5500.csv"}
OUT=${OUT:-"$REPO/reproducibility/reproduced/final/expanded_rasch"}
PYTHON=${PYTHON:-python3}

test -s "$MATRIX" || { echo "ERROR=MATRIX_MISSING:$MATRIX"; exit 2; }
test -s "$LONG" || { echo "ERROR=LONG_MISSING:$LONG"; exit 3; }
test -d "$REPO/data" || { echo "ERROR=REPO_MISSING:$REPO"; exit 4; }

mkdir -p "$OUT"

echo "============================================================"
echo " EXPANDED RASCH/LOFO + STRICT CLASSICAL STRATIFIED BASELINES"
echo "============================================================"
echo "Matrix:        500 items x 11 systems = 5500 responses"
echo "Families:      9"
echo "Budgets:       80,160,320"
echo "Pure methods:  SRS, STRAT_PROP, STRAT_BAL, STRAT_NEYMAN_LOFO"
echo "Strata:        richest frozen metadata hierarchy feasible at B=80"
echo "Estimator:     design-based population-weighted stratum mean"
echo "Neyman:        training families only; held-out family outcomes excluded"
echo "Replicates:    5000 per held-out system/method/budget"
echo "GPU jobs:      0"
echo "Output:        $OUT"
echo "============================================================"

echo
echo "===== RUN ANALYSIS ====="

"$PYTHON" - "$MATRIX" "$LONG" "$REPO" "$OUT" <<'PY'
from __future__ import annotations

import csv
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
from scipy.optimize import minimize
from scipy.special import expit
from scipy.stats import pearsonr, spearmanr

matrix_path = Path(sys.argv[1])
long_path = Path(sys.argv[2])
repo = Path(sys.argv[3])
out = Path(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)

SEED = 20260829
BUDGETS = [80, 160, 320]
REPS = 5000

# ------------------------------------------------------------------
# Load matrices and family mapping
# ------------------------------------------------------------------

with matrix_path.open(newline="") as f:
    wide_rows = list(csv.DictReader(f))

assert len(wide_rows) == 500
base_cols = ["item_index", "language", "registry_name", "suite"]
systems = [c for c in wide_rows[0].keys() if c not in base_cols]
assert len(systems) == 11, systems

item_index = np.array([int(r["item_index"]) for r in wide_rows], dtype=int)
assert np.array_equal(item_index, np.arange(500))

Y_items_systems = np.array(
    [[int(r[s]) for s in systems] for r in wide_rows],
    dtype=float,
)
Y = Y_items_systems.T  # systems x items
assert Y.shape == (11, 500)
assert np.isin(Y, [0, 1]).all()

with long_path.open(newline="") as f:
    long_rows = list(csv.DictReader(f))
assert len(long_rows) == 5500

family_by_system = {}
for r in long_rows:
    s = r["system"]
    fam = r["family"]
    if s in family_by_system:
        assert family_by_system[s] == fam
    family_by_system[s] = fam

assert set(family_by_system) == set(systems)
families = sorted(set(family_by_system.values()))
assert len(families) == 9, families

system_idx = {s: i for i, s in enumerate(systems)}
family_systems = {
    fam: [s for s in systems if family_by_system[s] == fam]
    for fam in families
}

# ------------------------------------------------------------------
# Canonical metadata
# ------------------------------------------------------------------

manifest_path = repo / "data/bank/discovery_500_primary.json"
manifest = json.loads(manifest_path.read_text())
items = manifest["items"]
assert len(items) == 500
items_by_idx = {int(x["discovery_index"]): x for x in items}
assert set(items_by_idx) == set(range(500))

# Verify matrix metadata against manifest.
for r in wide_rows:
    idx = int(r["item_index"])
    x = items_by_idx[idx]
    assert r["language"] == x["language"]
    assert r["registry_name"] == x["registry_name"]
    assert r["suite"] == x["suite"]

def clean_meta(v):
    if v is None or v == "":
        return "NA"
    return str(v)

# Fixed hierarchy, chosen using metadata only, never outcomes.
candidate_strata = [
    (
        "suite_category_difficulty",
        lambda x: (
            clean_meta(x.get("suite")),
            clean_meta(x.get("category")),
            clean_meta(x.get("difficulty")),
        ),
    ),
    (
        "suite_category",
        lambda x: (
            clean_meta(x.get("suite")),
            clean_meta(x.get("category")),
        ),
    ),
    (
        "suite_difficulty",
        lambda x: (
            clean_meta(x.get("suite")),
            clean_meta(x.get("difficulty")),
        ),
    ),
    (
        "suite",
        lambda x: (clean_meta(x.get("suite")),),
    ),
]

# Use the richest hierarchy that can guarantee >=1 draw/stratum at smallest budget.
chosen_name = None
chosen_keys = None
strata_candidates_report = []
for name, fn in candidate_strata:
    keys = [fn(items_by_idx[i]) for i in range(500)]
    H = len(set(keys))
    min_n = min(Counter(keys).values())
    strata_candidates_report.append((name, H, min_n))
    if chosen_name is None and H <= min(BUDGETS):
        chosen_name = name
        chosen_keys = keys

assert chosen_name is not None
keys = chosen_keys
unique_strata = sorted(set(keys), key=lambda z: tuple(map(str, z)))
stratum_id = {k: h for h, k in enumerate(unique_strata)}
item_stratum = np.array([stratum_id[k] for k in keys], dtype=int)
H = len(unique_strata)
strata_items = [np.where(item_stratum == h)[0] for h in range(H)]
Nh = np.array([len(ix) for ix in strata_items], dtype=int)
Wh = Nh / 500.0

assert H <= 80
assert Nh.sum() == 500

# ------------------------------------------------------------------
# Historical calibration diagnostics
# ------------------------------------------------------------------

def rasch_fit(Yfit, maxiter=2500):
    """Unregularized bounded JML used by archived calibration diagnostics.

    This is intentionally distinct from the ridge=1/9 Rasch estimator used by
    the frozen sampling/holdout policy. See RECOVERY_LIMITATIONS.md.
    """
    Yfit = np.asarray(Yfit, dtype=float)
    n, m = Yfit.shape
    assert m == 500

    # Empirical-logit starts.
    person_p = (Yfit.sum(axis=1) + 0.5) / (m + 1.0)
    theta0 = np.log(person_p / (1 - person_p))
    theta0 = theta0 - theta0[0]

    item_p = (Yfit.sum(axis=0) + 0.5) / (n + 1.0)
    b0 = -np.log(item_p / (1 - item_p))

    x0 = np.concatenate([theta0[1:], b0])

    def unpack(x):
        theta = np.concatenate([[0.0], x[: n - 1]])
        b = x[n - 1 :]
        return theta, b

    def fun_grad(x):
        theta, b = unpack(x)
        eta = theta[:, None] - b[None, :]
        # sum log(1+exp(eta)) - y*eta
        nll = np.logaddexp(0.0, eta).sum() - (Yfit * eta).sum()
        p = expit(eta)
        resid = p - Yfit
        gtheta = resid.sum(axis=1)
        gb = -resid.sum(axis=0)
        grad = np.concatenate([gtheta[1:], gb])
        return float(nll), grad

    bounds = [(-10, 10)] * len(x0)
    res = minimize(
        lambda x: fun_grad(x),
        x0,
        jac=True,
        method="L-BFGS-B",
        bounds=bounds,
        options={"maxiter": maxiter, "ftol": 1e-11, "gtol": 1e-7},
    )
    theta, b = unpack(res.x)

    # Recenter theta to mean zero and shift b by the same constant.
    c = float(theta.mean())
    theta = theta - c
    b = b - c

    eta = theta[:, None] - b[None, :]
    p = expit(eta)
    eps = 1e-12
    logloss = -np.mean(Yfit * np.log(np.clip(p, eps, 1-eps)) +
                       (1-Yfit) * np.log(np.clip(1-p, eps, 1-eps)))

    info_person = np.sum(p * (1-p), axis=1)
    person_se = 1.0 / np.sqrt(np.maximum(info_person, 1e-12))
    theta_var = float(np.var(theta, ddof=1)) if n > 1 else 0.0
    reliability = theta_var / (theta_var + float(np.mean(person_se**2))) if theta_var > 0 else 0.0

    info_item = np.sum(p * (1-p), axis=0)
    item_se = 1.0 / np.sqrt(np.maximum(info_item, 1e-12))

    observed_score = Yfit.mean(axis=1)
    predicted_score = p.mean(axis=1)
    score_mae_pp = float(np.mean(np.abs(observed_score - predicted_score)) * 100)

    # Basic Rasch item fit diagnostics.
    resid = Yfit - p
    var = np.maximum(p*(1-p), 1e-12)
    outfit = np.mean((resid**2)/var, axis=0)
    infit = np.sum(resid**2, axis=0) / np.sum(var, axis=0)
    fit_flag = (infit < 0.5) | (infit > 1.5) | (outfit < 0.5) | (outfit > 1.5)

    return {
        "success": bool(res.success),
        "message": str(res.message),
        "theta": theta,
        "b": b,
        "p": p,
        "logloss": float(logloss),
        "person_se": person_se,
        "item_se": item_se,
        "reliability": float(reliability),
        "score_mae_pp": score_mae_pp,
        "infit": infit,
        "outfit": outfit,
        "fit_flag": fit_flag,
    }

full_fit = rasch_fit(Y)

variable_full = (Y.sum(axis=0) > 0) & (Y.sum(axis=0) < Y.shape[0])

lofo_rows = []
for fam in families:
    train_systems = [s for s in systems if family_by_system[s] != fam]
    train_ix = [system_idx[s] for s in train_systems]
    Ytr = Y[train_ix]
    fit = rasch_fit(Ytr)

    variable_tr = (Ytr.sum(axis=0) > 0) & (Ytr.sum(axis=0) < Ytr.shape[0])
    shared = variable_full & variable_tr
    assert shared.sum() >= 2

    bf = full_fit["b"][shared]
    bt = fit["b"][shared]

    # LOFO calibration changes latent location. Align by median shift.
    shift = float(np.median(bt - bf))
    bt_aligned = bt - shift

    pr = float(pearsonr(bf, bt_aligned).statistic)
    sr = float(spearmanr(bf, bt_aligned).statistic)
    mae = float(np.mean(np.abs(bf - bt_aligned)))

    lofo_rows.append({
        "heldout_family": fam,
        "heldout_systems": len(family_systems[fam]),
        "train_systems": len(train_systems),
        "shared_variable_items": int(shared.sum()),
        "pearson_b": pr,
        "spearman_b": sr,
        "aligned_b_mae": mae,
        "fit_success": int(fit["success"]),
    })

# ------------------------------------------------------------------
# Exact integer allocations
# ------------------------------------------------------------------

def allocate_integer(weights, budget, capacities, min_each=1):
    """Largest-remainder allocation under lower and upper bounds."""
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

    # Iteratively assign quotas to non-saturated strata.
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

        # Largest remainder one-by-one for residual.
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
            # deterministic fallback: largest remaining capacity
            order = np.argsort(-cap_left, kind="mergesort")
            for h in order:
                if remaining == 0:
                    break
                if cap_left[h] > 0:
                    n[h] += 1
                    cap_left[h] -= 1
                    remaining -= 1

    assert n.sum() == budget, (n.sum(), budget)
    assert np.all(n >= min_each)
    assert np.all(n <= capacities)
    return n

def alloc_prop(budget):
    return allocate_integer(Nh.astype(float), budget, Nh, min_each=1)

def alloc_bal(budget):
    return allocate_integer(np.ones(H), budget, Nh, min_each=1)

def train_neyman_sd(train_systems):
    tr = Y[[system_idx[s] for s in train_systems]]
    S = np.zeros(H, dtype=float)
    for h, ix in enumerate(strata_items):
        # Estimate expected target within-stratum variance only from training systems.
        # Binary finite-pop variance per calibration system.
        vars_ = []
        for row in tr:
            vals = row[ix]
            if len(vals) <= 1:
                vars_.append(0.0)
            else:
                vars_.append(float(np.var(vals, ddof=1)))
        S[h] = math.sqrt(max(float(np.mean(vars_)), 0.0))
    return S

def alloc_neyman(budget, train_systems):
    S = train_neyman_sd(train_systems)
    return allocate_integer(Nh * S, budget, Nh, min_each=1)

# ------------------------------------------------------------------
# Sampling simulation
# ------------------------------------------------------------------

def estimate_srs(y, budget, rng):
    ix = rng.choice(500, size=budget, replace=False)
    return float(np.mean(y[ix]))

def estimate_strat(y, alloc, rng):
    est = 0.0
    for h, ix in enumerate(strata_items):
        nh = int(alloc[h])
        if nh == len(ix):
            vals = y[ix]
        else:
            sel = rng.choice(ix, size=nh, replace=False)
            vals = y[sel]
        est += Wh[h] * float(np.mean(vals))
    return float(est)

methods = ["SRS", "STRAT_PROP", "STRAT_BAL", "STRAT_NEYMAN_LOFO"]

rep_rows = []
system_summary_rows = []
family_summary_rows = []

# Cache allocations.
prop_allocs = {B: alloc_prop(B) for B in BUDGETS}
bal_allocs = {B: alloc_bal(B) for B in BUDGETS}
neyman_allocs = {}
for fam in families:
    train_systems = [s for s in systems if family_by_system[s] != fam]
    for B in BUDGETS:
        neyman_allocs[(fam, B)] = alloc_neyman(B, train_systems)

# Save allocation tables.
allocation_rows = []
for B in BUDGETS:
    for h, key in enumerate(unique_strata):
        allocation_rows.append({
            "budget": B,
            "stratum_id": h,
            "stratum_key": json.dumps(key, ensure_ascii=False),
            "N_h": int(Nh[h]),
            "prop_n": int(prop_allocs[B][h]),
            "bal_n": int(bal_allocs[B][h]),
        })
for fam in families:
    for B in BUDGETS:
        a = neyman_allocs[(fam, B)]
        S = train_neyman_sd([s for s in systems if family_by_system[s] != fam])
        for h, key in enumerate(unique_strata):
            allocation_rows.append({
                "budget": B,
                "stratum_id": h,
                "stratum_key": json.dumps(key, ensure_ascii=False),
                "N_h": int(Nh[h]),
                "heldout_family": fam,
                "neyman_n": int(a[h]),
                "training_S_h": float(S[h]),
            })

for s in systems:
    fam = family_by_system[s]
    y = Y[system_idx[s]]
    truth = float(y.mean())

    for B in BUDGETS:
        for method in methods:
            # Stable method/system/budget-specific generator.
            seed = (
                SEED
                + 1000003 * systems.index(s)
                + 10007 * B
                + 97 * methods.index(method)
            ) % (2**32 - 1)
            rng = np.random.default_rng(seed)

            ests = np.empty(REPS, dtype=float)
            if method == "SRS":
                for r in range(REPS):
                    ests[r] = estimate_srs(y, B, rng)
            else:
                if method == "STRAT_PROP":
                    alloc = prop_allocs[B]
                elif method == "STRAT_BAL":
                    alloc = bal_allocs[B]
                elif method == "STRAT_NEYMAN_LOFO":
                    alloc = neyman_allocs[(fam, B)]
                else:
                    raise AssertionError(method)

                for r in range(REPS):
                    ests[r] = estimate_strat(y, alloc, rng)

            err = ests - truth
            abs_err = np.abs(err)

            sysrow = {
                "system": s,
                "family": fam,
                "budget": B,
                "method": method,
                "truth": truth,
                "mean_estimate": float(ests.mean()),
                "bias_pp": float(err.mean() * 100),
                "mae_pp": float(abs_err.mean() * 100),
                "rmse_pp": float(np.sqrt(np.mean(err**2)) * 100),
                "p90_abs_pp": float(np.quantile(abs_err, 0.90) * 100),
                "p95_abs_pp": float(np.quantile(abs_err, 0.95) * 100),
                "catastrophic_gt5pp_rate": float(np.mean(abs_err > 0.05)),
                "replicates": REPS,
            }
            system_summary_rows.append(sysrow)

            # Store replicate errors compactly for pairwise statistical comparisons.
            for r in range(REPS):
                rep_rows.append({
                    "system": s,
                    "family": fam,
                    "budget": B,
                    "method": method,
                    "replicate": r,
                    "error_pp": float(err[r] * 100),
                    "abs_error_pp": float(abs_err[r] * 100),
                })

# Family summaries: equal weight to systems inside a family.
for fam in families:
    fam_systems = family_systems[fam]
    for B in BUDGETS:
        for method in methods:
            rows = [
                r for r in system_summary_rows
                if r["family"] == fam and r["budget"] == B and r["method"] == method
            ]
            assert len(rows) == len(fam_systems)
            family_summary_rows.append({
                "family": fam,
                "n_systems": len(rows),
                "budget": B,
                "method": method,
                "mae_pp": float(np.mean([r["mae_pp"] for r in rows])),
                "rmse_pp": float(np.mean([r["rmse_pp"] for r in rows])),
                "bias_pp": float(np.mean([r["bias_pp"] for r in rows])),
                "p90_abs_pp": float(np.mean([r["p90_abs_pp"] for r in rows])),
                "gt5_rate": float(np.mean([r["catastrophic_gt5pp_rate"] for r in rows])),
            })

# Overall family-balanced summaries.
overall_rows = []
for B in BUDGETS:
    for method in methods:
        rows = [
            r for r in family_summary_rows
            if r["budget"] == B and r["method"] == method
        ]
        assert len(rows) == len(families)
        overall_rows.append({
            "budget": B,
            "method": method,
            "family_balanced_mae_pp": float(np.mean([r["mae_pp"] for r in rows])),
            "family_balanced_rmse_pp": float(np.mean([r["rmse_pp"] for r in rows])),
            "family_balanced_abs_bias_pp": float(np.mean([abs(r["bias_pp"]) for r in rows])),
            "family_balanced_p90_abs_pp": float(np.mean([r["p90_abs_pp"] for r in rows])),
            "family_balanced_gt5_rate": float(np.mean([r["gt5_rate"] for r in rows])),
        })

# Bootstrap families for method deltas vs SRS and vs best non-SRS pure-strat method.
rng_boot = np.random.default_rng(SEED + 777)
BOOT = 10000
pairwise_rows = []

fam_lookup = {
    (r["family"], r["budget"], r["method"]): r["mae_pp"]
    for r in family_summary_rows
}

for B in BUDGETS:
    # identify best pure strat method by family-balanced point estimate,
    # but do not use it as a preregistered primary; label descriptive only.
    pure_methods = ["STRAT_PROP", "STRAT_BAL", "STRAT_NEYMAN_LOFO"]
    best_pure = min(
        pure_methods,
        key=lambda m: next(
            r["family_balanced_mae_pp"]
            for r in overall_rows if r["budget"] == B and r["method"] == m
        )
    )

    for method in methods:
        for comparator in ["SRS"] + ([best_pure] if method != best_pure else []):
            if method == comparator:
                continue
            diffs = np.array([
                fam_lookup[(fam, B, method)] - fam_lookup[(fam, B, comparator)]
                for fam in families
            ])
            boot = np.empty(BOOT)
            for k in range(BOOT):
                ix = rng_boot.integers(0, len(families), size=len(families))
                boot[k] = diffs[ix].mean()
            pairwise_rows.append({
                "budget": B,
                "method": method,
                "comparator": comparator,
                "delta_mae_pp_method_minus_comparator": float(diffs.mean()),
                "bootstrap95_lo": float(np.quantile(boot, 0.025)),
                "bootstrap95_hi": float(np.quantile(boot, 0.975)),
                "families": len(families),
                "best_pure_at_budget_descriptive": best_pure,
            })

# ------------------------------------------------------------------
# Write outputs
# ------------------------------------------------------------------

def write_csv(path, rows):
    rows = list(rows)
    if not rows:
        return
    # Some audit tables intentionally contain heterogeneous row schemas
    # (e.g. fixed PROP/BAL allocations vs held-out-family Neyman allocations).
    # Preserve every field across all rows instead of assuming row 0 is exhaustive.
    fields = []
    seen = set()
    for row in rows:
        for key in row.keys():
            if key not in seen:
                seen.add(key)
                fields.append(key)
    with Path(path).open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="raise")
        w.writeheader()
        w.writerows(rows)

rasch_system_rows = []
for i, s in enumerate(systems):
    rasch_system_rows.append({
        "system": s,
        "family": family_by_system[s],
        "observed_score": float(Y[i].mean()),
        "theta": float(full_fit["theta"][i]),
        "theta_se_approx": float(full_fit["person_se"][i]),
        "predicted_score": float(full_fit["p"][i].mean()),
    })

rasch_item_rows = []
for j in range(500):
    x = items_by_idx[j]
    rasch_item_rows.append({
        "item_index": j,
        "suite": x["suite"],
        "category": clean_meta(x.get("category")),
        "difficulty_level": clean_meta(x.get("difficulty")),
        "b": float(full_fit["b"][j]),
        "item_se_approx": float(full_fit["item_se"][j]),
        "infit": float(full_fit["infit"][j]),
        "outfit": float(full_fit["outfit"][j]),
        "fit_flag": int(full_fit["fit_flag"][j]),
        "successes": int(Y[:,j].sum()),
        "systems": Y.shape[0],
    })

write_csv(out/"rasch_systems_11.csv", rasch_system_rows)
write_csv(out/"rasch_items_500.csv", rasch_item_rows)
write_csv(out/"rasch_lofo_9families.csv", lofo_rows)
write_csv(out/"stratified_system_summary.csv", system_summary_rows)
write_csv(out/"stratified_family_summary.csv", family_summary_rows)
write_csv(out/"stratified_family_balanced_summary.csv", overall_rows)
write_csv(out/"stratified_pairwise_family_bootstrap.csv", pairwise_rows)
write_csv(out/"stratified_allocations.csv", allocation_rows)

# Replicate-level file is large but still manageable (~660k rows).
write_csv(out/"stratified_replicate_errors.csv", rep_rows)

rasch_summary = {
    "fit_estimator": "historical_unregularized_bounded_joint_ml",
    "systems": len(systems),
    "families": len(families),
    "items": 500,
    "variable_items": int(variable_full.sum()),
    "optimizer_success": full_fit["success"],
    "optimizer_message": full_fit["message"],
    "logloss": full_fit["logloss"],
    "person_reliability_approx": full_fit["reliability"],
    "score_mae_pp": full_fit["score_mae_pp"],
    "theta_min": float(full_fit["theta"].min()),
    "theta_max": float(full_fit["theta"].max()),
    "item_b_min": float(full_fit["b"].min()),
    "item_b_max": float(full_fit["b"].max()),
    "median_item_se": float(np.median(full_fit["item_se"])),
    "median_person_se": float(np.median(full_fit["person_se"])),
    "item_fit_flag_count": int(full_fit["fit_flag"].sum()),
    "item_fit_flag_rate": float(full_fit["fit_flag"].mean()),
    "lofo_spearman_min": float(min(r["spearman_b"] for r in lofo_rows)),
    "lofo_spearman_median": float(np.median([r["spearman_b"] for r in lofo_rows])),
}
(out/"rasch_summary.json").write_text(json.dumps(rasch_summary, indent=2))

strat_summary = {
    "seed": SEED,
    "replicates": REPS,
    "budgets": BUDGETS,
    "stratum_hierarchy_candidates": [
        {"name": n, "nonempty_strata": Hc, "min_stratum_size": mn}
        for n,Hc,mn in strata_candidates_report
    ],
    "chosen_stratification": chosen_name,
    "chosen_nonempty_strata": H,
    "methods": methods,
    "neyman_leakage_control": "leave-one-family-out; allocation variance uses training families only",
    "estimator": "design-based weighted stratum sample mean, weights N_h/500",
    "overall": overall_rows,
}
(out/"strict_stratified_summary.json").write_text(json.dumps(strat_summary, indent=2))

# Human-readable summary.
with (out/"SUMMARY.txt").open("w") as f:
    f.write("EXPANDED_RASCH\n")
    for k,v in rasch_summary.items():
        f.write(f"{k}={v}\n")
    f.write("\nSTRATIFICATION\n")
    f.write(f"chosen={chosen_name}\n")
    f.write(f"strata={H}\n")
    f.write("candidate_hierarchy=\n")
    for n,Hc,mn in strata_candidates_report:
        f.write(f"  {n}: strata={Hc} minN={mn}\n")
    f.write("\nFAMILY_BALANCED_METHODS\n")
    for r in sorted(overall_rows, key=lambda z:(z["budget"], z["family_balanced_mae_pp"])):
        f.write(
            f"B={r['budget']} {r['method']} "
            f"MAE={r['family_balanced_mae_pp']:.4f}pp "
            f"RMSE={r['family_balanced_rmse_pp']:.4f}pp "
            f"P90={r['family_balanced_p90_abs_pp']:.4f}pp "
            f"GT5={r['family_balanced_gt5_rate']:.6f}\n"
        )

# ------------------------------------------------------------------
# Console report
# ------------------------------------------------------------------

print("===== EXPANDED RASCH =====")
print(f"SYSTEMS={len(systems)}")
print(f"FAMILIES={len(families)}")
print("ITEMS=500")
print(f"VARIABLE_ITEMS={int(variable_full.sum())}")
print(f"OPTIMIZER_SUCCESS={full_fit['success']}")
print(f"LOGLOSS={full_fit['logloss']:.6f}")
print(f"PERSON_RELIABILITY_APPROX={full_fit['reliability']:.6f}")
print(f"SCORE_MAE_PP={full_fit['score_mae_pp']:.4f}")
print(f"ITEM_FIT_FLAGS={int(full_fit['fit_flag'].sum())}/500")
print(f"LOFO_SPEARMAN_MIN={min(r['spearman_b'] for r in lofo_rows):.6f}")
print(f"LOFO_SPEARMAN_MEDIAN={np.median([r['spearman_b'] for r in lofo_rows]):.6f}")

print()
print("===== LOFO BY FAMILY =====")
for r in sorted(lofo_rows, key=lambda z:z["heldout_family"]):
    print(
        f"{r['heldout_family']:22s} "
        f"train={r['train_systems']:2d} shared={r['shared_variable_items']:3d} "
        f"spearman={r['spearman_b']:.4f} "
        f"aligned_mae={r['aligned_b_mae']:.4f}"
    )

print()
print("===== STRICT STRATIFICATION DESIGN =====")
for n,Hc,mn in strata_candidates_report:
    tag = "CHOSEN" if n == chosen_name else ""
    print(f"{n:28s} strata={Hc:3d} minN={mn:2d} {tag}")
print(f"PRIMARY_METADATA_STRATA={chosen_name}")
print(f"NONEMPTY_STRATA={H}")
print("ESTIMATOR=DESIGN_BASED_NH_OVER_N_WEIGHTED")
print("NEYMAN_HELDOUT_LEAKAGE=NO")

print()
print("===== FAMILY-BALANCED MAE RANKING =====")
for B in BUDGETS:
    print(f"--- B={B} ---")
    rr = sorted(
        [r for r in overall_rows if r["budget"] == B],
        key=lambda z:z["family_balanced_mae_pp"]
    )
    for rank,r in enumerate(rr,1):
        print(
            f"{rank}. {r['method']:20s} "
            f"MAE={r['family_balanced_mae_pp']:.4f}pp "
            f"RMSE={r['family_balanced_rmse_pp']:.4f}pp "
            f"P90={r['family_balanced_p90_abs_pp']:.4f}pp "
            f"GT5={100*r['family_balanced_gt5_rate']:.2f}%"
        )

print()
print("===== PAIRWISE MAE DELTAS =====")
for r in pairwise_rows:
    if r["comparator"] == "SRS" or r["method"] == "STRAT_NEYMAN_LOFO":
        print(
            f"B={r['budget']} {r['method']} - {r['comparator']}: "
            f"{r['delta_mae_pp_method_minus_comparator']:+.4f}pp "
            f"95%family-bootstrap=[{r['bootstrap95_lo']:+.4f},"
            f"{r['bootstrap95_hi']:+.4f}]"
        )

print()
print("===== CHATGPT_SUMMARY =====")
print("TASK=EXPANDED_RASCH_LOFO_STRICT_STRATIFIED")
print("GATE=PASS")
print("SYSTEMS=11")
print("FAMILIES=9")
print("RESPONSES=5500")
print(f"RASCH_LOGLOSS={full_fit['logloss']:.6f}")
print(f"RASCH_RELIABILITY={full_fit['reliability']:.6f}")
print(f"LOFO_SPEARMAN_MIN={min(r['spearman_b'] for r in lofo_rows):.6f}")
print(f"LOFO_SPEARMAN_MEDIAN={np.median([r['spearman_b'] for r in lofo_rows]):.6f}")
print(f"STRATA={chosen_name}")
for B in BUDGETS:
    rr = sorted(
        [r for r in overall_rows if r["budget"] == B],
        key=lambda z:z["family_balanced_mae_pp"]
    )
    best = rr[0]
    print(f"B{B}_BEST_PURE={best['method']}")
    print(f"B{B}_BEST_PURE_MAE_PP={best['family_balanced_mae_pp']:.6f}")
print(f"OUTPUT={out}")
print("NEXT=RUN_FROZEN_STRAT_REG_ADAPT20_REG_ON_EXPANDED_MATRIX_AND_HEAD_TO_HEAD")
print("===========================")
PY

echo
echo "===== OUTPUT FILES ====="
ls -lh "$OUT" | sed -n '1,40p'
