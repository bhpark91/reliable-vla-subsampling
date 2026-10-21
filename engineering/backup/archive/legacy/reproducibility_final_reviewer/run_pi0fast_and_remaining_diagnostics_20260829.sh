#!/usr/bin/env bash
set -Eeuo pipefail
export PYTHONUNBUFFERED=1

: "${VLA_IRT_ARTIFACT_ROOT:?Set VLA_IRT_ARTIFACT_ROOT to the directory containing d500-holdout-corrected-pi0fast-zscore-20260829}"
HERE="$VLA_IRT_ARTIFACT_ROOT"
export VLA_IRT_ARTIFACT_ROOT
HOLD="$HERE/d500-holdout-corrected-pi0fast-zscore-20260829"
OFF="$HOLD/reviewer_response_offline_v1"
CALROOT="$HERE/d500-critical3-collected-20260829"

HW="$HOLD/holdout_wide_500x3.csv"
OUT="$HOLD/pi0fast_existing_diagnostics_v1"

test -s "$HW" || { echo "ERROR=MISSING:$HW"; exit 2; }
for f in \
  "$OFF/prospective_tail_risk_all_methods.csv" \
  "$OFF/aggregation_weighting_sensitivity.csv" \
  "$OFF/selection_concentration_diagnostics.csv" \
  "$OFF/adaptive_fraction_sweep_prospective.csv" \
  "$OFF/residual_sample_size_control.csv" \
  "$OFF/overlap_excluded_calibration_sensitivity.csv" \
  "$OFF/l2fo_rasch_stability.csv" \
  "$OFF/ridge_sensitivity.csv"
do
  test -s "$f" || { echo "ERROR=MISSING:$f"; exit 3; }
done

rm -rf "$OUT"
mkdir -p "$OUT"

python3 - "$HW" "$OFF" "$OUT" <<'PY'
import csv, json, math, sys
from pathlib import Path
from collections import defaultdict

hw=Path(sys.argv[1])
off=Path(sys.argv[2])
out=Path(sys.argv[3])

def read(p):
    with Path(p).open(newline="",encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

def write(p,rows):
    if not rows: return
    with Path(p).open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)

rows=read(hw)
assert len(rows)==500
assert sum(int(r["pi0_fast"]) for r in rows)==39

def wilson(k,n,z=1.959963984540054):
    p=k/n
    den=1+z*z/n
    c=(p+z*z/(2*n))/den
    h=z*math.sqrt(p*(1-p)/n+z*z/(4*n*n))/den
    return c-h,c+h

# ---------- π0-FAST breakdown ----------
dims=[
    ("difficulty_level","difficulty"),
    ("suite","suite"),
    ("category","category"),
]
all_diag=[]
for col,label in dims:
    groups=defaultdict(list)
    for r in rows:
        groups[r[col]].append(int(r["pi0_fast"]))
    print()
    print(f"===== PI0FAST BY {label.upper()} =====")
    print("group\tn\tsuccesses\trate")
    for g in sorted(groups, key=lambda x:(str(x))):
        vals=groups[g]; k=sum(vals); n=len(vals)
        lo,hi=wilson(k,n)
        print(f"{g}\t{n}\t{k}\t{k/n:.4f}")
        all_diag.append({
            "dimension":label,"group":g,"n":n,"successes":k,
            "success_rate":k/n,"wilson95_lo":lo,"wilson95_hi":hi,
        })

write(out/"pi0fast_breakdown.csv",all_diag)

# difficulty × category
cross=[]
for cat in sorted(set(r["category"] for r in rows)):
    for d in sorted(set(r["difficulty_level"] for r in rows),key=str):
        ss=[int(r["pi0_fast"]) for r in rows
            if r["category"]==cat and r["difficulty_level"]==d]
        if not ss: continue
        cross.append({
            "category":cat,"difficulty_level":d,"n":len(ss),
            "successes":sum(ss),"success_rate":sum(ss)/len(ss)
        })
write(out/"pi0fast_category_x_difficulty.csv",cross)

# ---------- canary uncertainty ----------
lo,hi=wilson(6,10)
print()
print("===== OFFICIAL STANDARD-LIBERO ENGINEERING CANARY =====")
print("episodes=10")
print("successes=6")
print("rate=0.6000")
print(f"wilson95=[{lo:.4f},{hi:.4f}]")
print("INTERPRETATION=PIPELINE_SANITY_ONLY_NOT_PUBLISHED_PERFORMANCE_REPRODUCTION")

# ---------- remaining reviewer-response outputs ----------
def print_csv(title,path,cols=None,where=None,sort=None):
    rr=read(path)
    if where: rr=[r for r in rr if where(r)]
    if sort: rr=sorted(rr,key=sort)
    print()
    print(f"===== {title} =====")
    if not rr:
        print("NO_ROWS"); return
    if cols is None: cols=list(rr[0])
    print("\t".join(cols))
    for r in rr:
        print("\t".join(str(r.get(c,"")) for c in cols))

print_csv(
    "TAIL RISK ALL METHODS B320",
    off/"prospective_tail_risk_all_methods.csv",
    ["method","budget","mae_pp","rmse_pp","signed_bias_pp","p90_abs_pp","gt5_rate"],
    where=lambda r:int(r["budget"])==320,
    sort=lambda r:float(r["mae_pp"]),
)

print_csv(
    "AGGREGATION WEIGHTING SENSITIVITY B320",
    off/"aggregation_weighting_sensitivity.csv",
    ["method","budget","family_balanced_mae_pp","system_balanced_mae_pp","difference_pp"],
    where=lambda r:int(r["budget"])==320,
    sort=lambda r:float(r["family_balanced_mae_pp"]),
)

print_csv(
    "SELECTION CONCENTRATION B320",
    off/"selection_concentration_diagnostics.csv",
    None,
    where=lambda r:int(r["budget"])==320,
)

# ---------- interpretable decomposition ----------
sweep=read(off/"adaptive_fraction_sweep_prospective.csv")
resid=read(off/"residual_sample_size_control.csv")
content=read(off/"content_constrained_cat.csv")

def one(rr, **conds):
    q=[]
    for r in rr:
        ok=True
        for k,v in conds.items():
            if str(r[k])!=str(v): ok=False
        if ok:q.append(r)
    assert len(q)==1,(conds,len(q))
    return q[0]

base0=float(one(sweep,alpha="0.0",budget="320")["fb_mae"])
a20=float(one(sweep,alpha="0.2",budget="320")["fb_mae"])
a100=float(one(sweep,alpha="1.0",budget="320")["fb_mae"])
rm=float(one(resid,method="STATIC_MATCHED_RESIDUAL",budget="320")["fb_mae"])
ca20=float(one(content,method="CONTENT_ADAPT20_REG",budget="320")["fb_mae"])
ca100=float(one(content,method="CONTENT_ADAPT100_REG",budget="320")["fb_mae"])

print()
print("===== ADAPTIVE LOSS DECOMPOSITION B320 =====")
print(f"STATIC_ALPHA0={base0:.6f}")
print(f"STATIC_MATCHED_RESIDUAL272={rm:.6f}")
print(f"CONTENT_ADAPT20={ca20:.6f}")
print(f"UNCONSTRAINED_ADAPT20={a20:.6f}")
print(f"CONTENT_ADAPT100={ca100:.6f}")
print(f"UNCONSTRAINED_ADAPT100={a100:.6f}")
print(f"RESIDUAL_COVERAGE_PENALTY_APPROX={rm-base0:+.6f}")
print(f"UNCONSTRAINED_SELECTION_EXTRA_PENALTY_OVER_MATCHED={a20-rm:+.6f}")
print(f"CONTENT_CONSTRAINT_EXTRA_PENALTY_OVER_MATCHED={ca20-rm:+.6f}")

# ---------- strict non-overlap / pi0fast exclusion ----------
# Known canonical per-system B320 values from corrected frozen analysis.
sys=read((Path(__import__("os").environ["VLA_IRT_ARTIFACT_ROOT"]) / "d500-holdout-corrected-pi0fast-zscore-20260829/prospective_frozen_methods_v1/prospective_system_summary.csv"))
def mae(method,system):
    q=[r for r in sys if r["method"]==method and int(r["budget"])==320 and r["system"]==system]
    assert len(q)==1
    return float(q[0]["mae_pp"])

methods=["STRAT_NEYMAN_CAL","STRAT_REG","ADAPT20_REG"]
print()
print("===== STRICT NON-OVERLAP HOLDOUT: VLANEXT ONLY, B320 =====")
for m in methods:
    print(f"{m}={mae(m,'vlanext'):.6f}")

print()
print("===== EXCLUDING PI0-FAST: PI0.5 + VLANEXT, B320 =====")
for m in methods:
    v=(mae(m,"pi05")+mae(m,"vlanext"))/2
    print(f"{m}={v:.6f}")

# ---------- provenance logic ----------
print()
print("===== BENCHMARK REFERENCE-OUTCOME AGREEMENT =====")
print("STATUS=NOT_IDENTIFIABLE_FROM_L1_L5_LABEL_ALONE")
print("REASON=L1_L5_ENCODES_AGGREGATE_REFERENCE_MODEL_SUCCESS_COUNT_NOT_PI0FAST_SPECIFIC_BINARY_OUTCOME")
print("ACTION=DO_NOT_REPORT_A_FABRICATED_PI0FAST_AGREEMENT_RATE")

# Save summary
summary={
    "pi0fast_d500":{"successes":39,"n":500,"rate":39/500},
    "canary":{"successes":6,"n":10,"rate":.6,"wilson95":[lo,hi],
              "interpretation":"pipeline sanity only; not reproduction of published pi0-fast performance"},
    "adaptive_decomposition_B320":{
        "static_alpha0":base0,
        "static_matched_residual272":rm,
        "content_adapt20":ca20,
        "unconstrained_adapt20":a20,
        "content_adapt100":ca100,
        "unconstrained_adapt100":a100,
        "residual_coverage_penalty_approx":rm-base0,
        "unconstrained_selection_extra_penalty_over_matched":a20-rm,
        "content_constraint_extra_penalty_over_matched":ca20-rm,
    },
    "reference_outcome_agreement":{
        "status":"not_identifiable_from_L1_L5_label_alone",
        "reason":"difficulty label is aggregate across reference models, not a per-pi0-fast binary label"
    }
}
json.dump(summary,open(out/"diagnostic_summary.json","w"),indent=2)

print()
print("OUTPUT="+str(out))
print("GATE=PASS")
PY

(
  cd "$OUT"
  sha256sum pi0fast_breakdown.csv pi0fast_category_x_difficulty.csv diagnostic_summary.json > SHA256SUMS.txt
)

echo
echo "===== CHATGPT_SUMMARY ====="
echo "TASK=PI0FAST_AND_REMAINING_OFFLINE_DIAGNOSTICS"
echo "GATE=PASS"
echo "GPU_JOBS=0"
echo "NEW_ROLLOUTS=0"
echo "WORKSPACE=UNTOUCHED"
echo "GITHUB=UNTOUCHED"
echo "OUTPUT=$OUT"
echo "NEXT=PASTE_FROM_PI0FAST_BY_DIFFICULTY_THROUGH_ADAPTIVE_LOSS_DECOMPOSITION"
echo "==========================="
