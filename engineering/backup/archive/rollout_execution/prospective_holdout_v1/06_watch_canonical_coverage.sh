#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

HERE="/mnt/c/Users/YOUR_USER/Downloads"
ORIG="$HERE/d500-holdout-prod-v2-20260829-jobs.tsv"
REP="$HERE/d500-holdout-prod-v2-repair1-20260829-jobs.tsv"
OUT="$HERE/d500-holdout-prod-v2-combined-watch-20260829"
mkdir -p "$OUT"

test -s "$ORIG" || { echo "ERROR=ORIG_JOBS_MISSING:$ORIG"; exit 2; }
test -s "$REP"  || { echo "ERROR=REPAIR_JOBS_MISSING:$REP"; exit 3; }

ORIG_N="$(wc -l < "$ORIG")"
REP_N="$(wc -l < "$REP")"
test "$ORIG_N" -eq 60 || { echo "ERROR=ORIG_EXPECTED_60_FOUND_$ORIG_N"; exit 4; }

INTERVAL="${INTERVAL:-90}"

echo "============================================================"
echo " COMBINED HOLDOUT WATCH — ORIGINAL + REPAIR1"
echo "============================================================"
echo "Original jobs: $ORIG_N"
echo "Repair1 jobs:  $REP_N"
echo "Canonical:     60 shards"
echo "GPU submit:    0"
echo "Poll:          ${INTERVAL}s"
echo "Ctrl+C:        safe; rerun anytime"
echo "============================================================"

state_of () {
  local job="$1"
  local out=""
  out="$(vesslctl job show "$job" 2>/dev/null || true)"
  printf '%s\n' "$out" |
    awk -F: '/^State:/{
      sub(/^[^:]*:[ \t]*/, "");
      print tolower($0);
      exit
    }' || true
}

is_terminal () {
  case "$1" in
    succeeded|failed|cancelled|canceled) return 0 ;;
    *) return 1 ;;
  esac
}

declare -A PREV
round=0

while :; do
  round=$((round+1))
  NOW="$(date '+%Y-%m-%d %H:%M:%S %z')"

  ORUN=0; OSUCC=0; OFAIL=0; OOTHER=0; OTERM=0
  RRUN=0; RSUCC=0; RFAIL=0; ROTHER=0; RTERM=0

  : > "$OUT/original-current.tsv"
  : > "$OUT/repair-current.tsv"

  # Original: SYSTEM SUITE SHARD JOB NAME BRANCH
  while IFS=$'\t' read -r SYSTEM SUITE SHARD JOB NAME BRANCH; do
    ST="$(state_of "$JOB")"
    ST="${ST:-unknown}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SYSTEM" "$SUITE" "$SHARD" "$JOB" "$NAME" "$BRANCH" "$ST" \
      >> "$OUT/original-current.tsv"

    case "$ST" in
      running) ORUN=$((ORUN+1)) ;;
      succeeded) OSUCC=$((OSUCC+1)); OTERM=$((OTERM+1)) ;;
      failed|cancelled|canceled) OFAIL=$((OFAIL+1)); OTERM=$((OTERM+1)) ;;
      *) OOTHER=$((OOTHER+1)) ;;
    esac

    KEY="O:$JOB"
    if [ "${PREV[$KEY]:-}" != "$ST" ]; then
      printf '[%s] ORIG   %-9s %-15s s%d %-18s -> %s\n' \
        "$NOW" "$SYSTEM" "$SUITE" "$SHARD" "$JOB" "$ST"
      PREV[$KEY]="$ST"
    fi
  done < "$ORIG"

  # Repair: SYSTEM SUITE SHARD OLDJOB NEWJOB NAME BRANCH
  while IFS=$'\t' read -r SYSTEM SUITE SHARD OLDJOB JOB NAME BRANCH; do
    ST="$(state_of "$JOB")"
    ST="${ST:-unknown}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SYSTEM" "$SUITE" "$SHARD" "$OLDJOB" "$JOB" "$NAME" "$BRANCH" "$ST" \
      >> "$OUT/repair-current.tsv"

    case "$ST" in
      running) RRUN=$((RRUN+1)) ;;
      succeeded) RSUCC=$((RSUCC+1)); RTERM=$((RTERM+1)) ;;
      failed|cancelled|canceled) RFAIL=$((RFAIL+1)); RTERM=$((RTERM+1)) ;;
      *) ROTHER=$((ROTHER+1)) ;;
    esac

    KEY="R:$JOB"
    if [ "${PREV[$KEY]:-}" != "$ST" ]; then
      printf '[%s] REPAIR %-9s %-15s s%d %-18s -> %s\n' \
        "$NOW" "$SYSTEM" "$SUITE" "$SHARD" "$JOB" "$ST"
      PREV[$KEY]="$ST"
    fi
  done < "$REP"

  # Compute canonical coverage as of now.
  python3 - "$OUT/original-current.tsv" "$OUT/repair-current.tsv" \
    "$OUT/canonical-current.tsv" "$OUT/uncovered-current.tsv" <<'PY'
import csv,sys
orig,rep,out,uncovered=sys.argv[1:]
O={}
with open(orig,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        key=(r[0],r[1],r[2])
        O[key]={"job":r[3],"state":r[6]}
R={}
with open(rep,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        key=(r[0],r[1],r[2])
        R[key]={"oldjob":r[3],"job":r[4],"state":r[7]}

rows=[]
bad=[]
for key in sorted(O):
    o=O[key]
    rr=R.get(key)
    covered = o["state"]=="succeeded" or (rr is not None and rr["state"]=="succeeded")
    source = "original" if o["state"]=="succeeded" else ("repair1" if rr and rr["state"]=="succeeded" else "")
    row=list(key)+[
        o["job"],o["state"],
        rr["job"] if rr else "",
        rr["state"] if rr else "",
        "covered" if covered else "uncovered",
        source
    ]
    rows.append(row)
    if not covered:
        bad.append(row)

with open(out,"w",newline='') as f:
    w=csv.writer(f,delimiter='\t',lineterminator='\n')
    w.writerows(rows)
with open(uncovered,"w",newline='') as f:
    w=csv.writer(f,delimiter='\t',lineterminator='\n')
    w.writerows(bad)

print(f"CANONICAL_COVERED={len(rows)-len(bad)}")
print(f"CANONICAL_UNCOVERED={len(bad)}")
PY

  COVERED="$(awk -F'\t' '$8=="covered"{n++} END{print n+0}' "$OUT/canonical-current.tsv")"
  UNCOVERED=$((60-COVERED))

  echo
  echo "[$NOW] ROUND=$round"
  echo "ORIGINAL: terminal=$OTERM/60 succeeded=$OSUCC failed=$OFAIL running=$ORUN other=$OOTHER"
  echo "REPAIR1:  terminal=$RTERM/$REP_N succeeded=$RSUCC failed=$RFAIL running=$RRUN other=$ROTHER"
  echo "CANONICAL: covered=$COVERED/60 uncovered=$UNCOVERED"
  echo

  if [ "$OTERM" -eq 60 ] && [ "$RTERM" -eq "$REP_N" ]; then
    break
  fi

  sleep "$INTERVAL"
done

cp "$OUT/original-current.tsv" "$OUT/original-final.tsv"
cp "$OUT/repair-current.tsv" "$OUT/repair-final.tsv"
cp "$OUT/canonical-current.tsv" "$OUT/canonical-final.tsv"
cp "$OUT/uncovered-current.tsv" "$OUT/uncovered-final.tsv"

COVERED="$(awk -F'\t' '$8=="covered"{n++} END{print n+0}' "$OUT/canonical-final.tsv")"
UNCOVERED=$((60-COVERED))
OSUCC="$(awk -F'\t' '$7=="succeeded"{n++} END{print n+0}' "$OUT/original-final.tsv")"
OFAIL="$(awk -F'\t' '$7=="failed" || $7=="cancelled" || $7=="canceled"{n++} END{print n+0}' "$OUT/original-final.tsv")"
RSUCC="$(awk -F'\t' '$8=="succeeded"{n++} END{print n+0}' "$OUT/repair-final.tsv")"
RFAIL="$(awk -F'\t' '$8=="failed" || $8=="cancelled" || $8=="canceled"{n++} END{print n+0}' "$OUT/repair-final.tsv")"

# Build repair2 targets only for canonical shards still uncovered.
# Columns: SYSTEM SUITE SHARD ORIG_JOB ORIG_STATE REPAIR1_JOB REPAIR1_STATE
cp "$OUT/uncovered-final.tsv" "$OUT/repair2-targets.tsv"

echo "===== FINAL CANONICAL COVERAGE ====="
echo "ORIGINAL_SUCCEEDED=$OSUCC"
echo "ORIGINAL_FAILED=$OFAIL"
echo "REPAIR1_SUCCEEDED=$RSUCC"
echo "REPAIR1_FAILED=$RFAIL"
echo "CANONICAL_COVERED=$COVERED/60"
echo "CANONICAL_UNCOVERED=$UNCOVERED"

if [ "$UNCOVERED" -gt 0 ]; then
  echo
  echo "===== REPAIR2 TARGETS ====="
  column -t -s $'\t' "$OUT/repair2-targets.tsv" 2>/dev/null || cat "$OUT/repair2-targets.tsv"
  GATE="NEEDS_REPAIR2"
  NEXT="LAUNCH_ONLY_CANONICAL_UNCOVERED_SHARDS_WITH_ISOLATED_UV"
else
  GATE="PASS"
  NEXT="AUDIT_SHARED_DATA_AND_COLLECT_1500_RESPONSES"
fi

SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=WATCH_ORIGINAL_PLUS_REPAIR1_HOLDOUT_D500
GATE=$GATE
ORIGINAL_TOTAL=60
ORIGINAL_SUCCEEDED=$OSUCC
ORIGINAL_FAILED=$OFAIL
REPAIR1_TOTAL=$REP_N
REPAIR1_SUCCEEDED=$RSUCC
REPAIR1_FAILED=$RFAIL
CANONICAL_COVERED=$COVERED
CANONICAL_UNCOVERED=$UNCOVERED
GPU_JOBS_CREATED=0
REPAIR2_TARGETS=$OUT/repair2-targets.tsv
CANONICAL_STATUS=$OUT/canonical-final.tsv
NEXT=$NEXT
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
