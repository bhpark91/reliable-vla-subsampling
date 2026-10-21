#!/usr/bin/env bash
set -Eeuo pipefail

: "${VLA_IRT_ARTIFACT_ROOT:?Set VLA_IRT_ARTIFACT_ROOT to the directory that contains the archived D500 artifact directories}"
HERE="$VLA_IRT_ARTIFACT_ROOT"
HOLD="$HERE/d500-holdout-corrected-pi0fast-zscore-20260829"
SRC="$HOLD/run_frozen_prospective_analysis_corrected.sh"
RUN="$HOLD/run_posthoc_adapt100_sensitivity.sh"
OUT="$HOLD/prospective_adapt100_sensitivity_v1"
BASE="$HOLD/prospective_frozen_methods_v1"

echo "============================================================"
echo " POST-HOC 100% ADAPTIVE SENSITIVITY — CPU ONLY"
echo "============================================================"
echo "New GPU jobs:          0"
echo "New rollouts:          0"
echo "Workspace touched:     0"
echo "Corrected D500 reused: yes"
echo "Calibration quantities: frozen 11-system Rasch"
echo "Status:                POST-HOC / EXPLORATORY"
echo
echo "Definition:"
echo "  anchor = 80 suite-stratified random items"
echo "  after anchor, each 40-item batch = 40 Fisher-selected items"
echo "  random exploration after anchor = 0"
echo "  estimator = same Rasch population prediction + residual correction"
echo "              (residual correction uses random anchor only)"
echo
echo "This does NOT replace the preregistered/frozen ADAPT20 result."
echo "It tests whether the negative result was caused by using only 20% adaptivity."
echo "============================================================"

test -s "$SRC" || { echo "ERROR=CORRECTED_ANALYSIS_SCRIPT_MISSING:$SRC"; exit 2; }
test -s "$BASE/prospective_overall_summary.csv" || { echo "ERROR=BASE_RESULTS_MISSING"; exit 3; }

cp "$SRC" "$RUN"

python3 - "$RUN" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

repls = [
    ('OUT="$HOLDROOT/prospective_frozen_methods_v1"',
     'OUT="$HOLDROOT/prospective_adapt100_sensitivity_v1"'),
    ('ADAPT_N = 8', 'ADAPT_N = 40'),
    ('EXPLORE_N = 32', 'EXPLORE_N = 0'),
    ('ADAPT20_REG', 'ADAPT100_REG'),
    ('adapt20_reg', 'adapt100_reg'),
    ('FROZEN PROSPECTIVE UNSEEN-FAMILY D500 COMPARISON',
     'POST-HOC ADAPT100 SENSITIVITY ON CORRECTED HOLDOUT'),
    ('FULL_PI0_FAST=0.030000', 'FULL_PI0_FAST=0.078000'),
    ('TASK=RUN_FROZEN_PROSPECTIVE_UNSEEN_FAMILY_D500',
     'TASK=RUN_POSTHOC_ADAPT100_SENSITIVITY'),
    ('NEXT=INTERPRET_PROSPECTIVE_RESULT_AND_PUBLISH_HOLDOUT_BUNDLE_TO_GITHUB',
     'NEXT=COMPARE_ADAPT20_VS_ADAPT100_AND_DECIDE_PAPER_SENSITIVITY'),
]

for old,new in repls:
    if old not in s:
        raise SystemExit(f"PATCH_TARGET_MISSING: {old}")
    s=s.replace(old,new)

# Make status explicit anywhere the generated README otherwise says "Frozen before holdout".
s=s.replace(
    'lines.append("Frozen before holdout: 11 calibration systems / 9 families.")',
    'lines.append("Calibration quantities were frozen before holdout: 11 systems / 9 families. ADAPT100 acquisition fraction is post-hoc exploratory.")'
)

# Change schema marker so it cannot be confused with the confirmatory output.
s=s.replace(
    '"schema_version":"prospective_unseen_family_d500_v1"',
    '"schema_version":"posthoc_adapt100_sensitivity_v1"'
)

p.write_text(s)
print("PATCH_ADAPT100_SCRIPT=PASS")
PY

chmod +x "$RUN"
rm -rf "$OUT"

echo
echo "===== RUN ADAPT100 SENSITIVITY ====="
bash "$RUN" | tee "$HOLD/adapt100_sensitivity_run.log"

echo
echo "===== COMPARE ADAPT20 vs ADAPT100 ====="
python3 - \
  "$BASE/prospective_overall_summary.csv" \
  "$OUT/prospective_overall_summary.csv" \
  "$BASE/prospective_system_summary.csv" \
  "$OUT/prospective_system_summary.csv" <<'PY'
import csv,sys
from collections import defaultdict

base_over, a100_over, base_sys, a100_sys = sys.argv[1:]

def read(p):
    with open(p,newline="",encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

bo=read(base_over)
ao=read(a100_over)
bs=read(base_sys)
as_=read(a100_sys)

def get(rows, method, B, key):
    r=[x for x in rows if x["method"]==method and int(x["budget"])==B]
    assert len(r)==1,(method,B,len(r))
    return float(r[0][key])

print("IMPORTANT: B80 method differences are NOT interpreted; all adaptive variants begin from the same 80-item procedure conceptually.")
print()
print("FAMILY_BALANCED_MAE_PP")
print("budget\tSTRAT_REG\tADAPT20_REG\tADAPT100_REG\tA100-STRAT\tA100-A20")
for B in (80,160,320):
    sr=get(bo,"STRAT_REG",B,"family_balanced_mae_pp")
    a20=get(bo,"ADAPT20_REG",B,"family_balanced_mae_pp")
    a100=get(ao,"ADAPT100_REG",B,"family_balanced_mae_pp")
    print(f"{B}\t{sr:.4f}\t{a20:.4f}\t{a100:.4f}\t{a100-sr:+.4f}\t{a100-a20:+.4f}")

print()
print("ADAPT100_B320_PER_SYSTEM")
for system in ("pi05","pi0_fast","vlanext"):
    r=[x for x in as_ if x["method"]=="ADAPT100_REG" and int(x["budget"])==320 and x["system"]==system]
    assert len(r)==1
    x=r[0]
    print(f"{system:10s} MAE={float(x['mae_pp']):.4f} P90={float(x['p90_abs_pp']):.4f} GT5={float(x['gt5_rate']):.5f}")

a100_160=get(ao,"ADAPT100_REG",160,"family_balanced_mae_pp")
a100_320=get(ao,"ADAPT100_REG",320,"family_balanced_mae_pp")
sr_160=get(bo,"STRAT_REG",160,"family_balanced_mae_pp")
sr_320=get(bo,"STRAT_REG",320,"family_balanced_mae_pp")

if a100_160 < sr_160 or a100_320 < sr_320:
    verdict="ADAPT100_CHANGES_INTERPRETATION_REVIEW_REQUIRED"
else:
    verdict="ADAPT100_DOES_NOT_BEAT_STATIC_AT_B160_OR_B320"

print()
print("POSTHOC_VERDICT="+verdict)
print("POSTHOC_STATUS=EXPLORATORY_NOT_FROZEN_BEFORE_HOLDOUT")
PY

echo
echo "===== CHATGPT_SUMMARY ====="
echo "TASK=POSTHOC_ADAPT100_SENSITIVITY"
echo "GPU_JOBS=0"
echo "NEW_ROLLOUTS=0"
echo "STATUS=EXPLORATORY_NOT_FROZEN_BEFORE_HOLDOUT"
echo "OUTPUT=$OUT"
echo "NEXT=PASTE_COMPARE_OUTPUT"
echo "==========================="
