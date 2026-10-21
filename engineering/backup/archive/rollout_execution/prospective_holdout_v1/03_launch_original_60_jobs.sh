#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

HERE="/mnt/c/Users/YOUR_USER/Downloads"
WORKER="$HERE/d500_holdout_production_worker_v2_20260829.sh"

WS="wsp-REDACTED000001"
IMAGE="ghcr.io/allenai/vla-evaluation-harness/libero@sha256:2a4566009395888ae3904bde87cffceea7526e2e0f0667b933cae0e8e6134413"
VOL="clustervol-REDACTED000001"
RESOURCE="resourcespec-a100x1"

RUN_TAG="d500-holdout-prod-v2-20260829"
SHARDS=5
COUNT=$((3 * 4 * SHARDS))
RATE=1.55
JOB_HARD_CAP_H=5
MAX_BURN="$(python3 - <<PY
print(f"{${COUNT} * ${JOB_HARD_CAP_H} * ${RATE}:.2f}")
PY
)"
JOBS="$HERE/${RUN_TAG}-jobs.tsv"

test -s "$WORKER" || { echo "ERROR=WORKER_NOT_FOUND:$WORKER"; exit 2; }

echo "============================================================"
echo " D500 PROSPECTIVE HOLDOUT PRODUCTION V2"
echo "============================================================"
echo "Systems:        pi05, pi0_fast, vlanext"
echo "Unseen family:  pi/OpenPI + VLANeXt"
echo "Suites/system:  4"
echo "Shards/suite:   $SHARDS"
echo "Total jobs:     $COUNT"
echo "GPU/job:        A100 SXM x1"
echo "Rate/job:       \$$RATE/hr"
echo "Hard cap/job:   ${JOB_HARD_CAP_H}h"
echo "Absolute max:   ~\$$MAX_BURN"
echo "Runtime:        qualified persistent /data"
echo "Fresh runtime clone: NO"
echo "Per-job restore: Python 3.8 + headless OS libs"
echo "Persistence:    shared /data first, Git branch second"
echo "============================================================"

echo
echo "===== DUPLICATE V2 GUARD ====="
if [ -s "$JOBS" ]; then
  echo "ERROR=V2_JOBS_FILE_ALREADY_EXISTS:$JOBS"
  cat "$JOBS"
  exit 19
fi

EXISTING="$(
  vesslctl job list 2>/dev/null |
  grep -E 'd500h2-(p05|pf|vx)-(sp|ob|go|l10)-s[0-9]+of5' || true
)"
if [ -n "$EXISTING" ]; then
  echo "ERROR=V2_JOBS_ALREADY_EXIST"
  printf '%s\n' "$EXISTING"
  exit 19
fi
echo "DUPLICATE_V2_JOBS=NO"

echo
echo "===== DEBUG WORKSPACE STATE ====="
WS_STATE="$(
  vesslctl workspace show "$WS" 2>/dev/null |
  awk -F: '/^State:/ {sub(/^[^:]*:[ \t]*/,""); print tolower($0); exit}'
)"
echo "DEBUG_WORKSPACE_STATE=${WS_STATE:-unknown}"

echo
echo "Target: $COUNT A100 jobs; theoretical maximum burn ~\$$MAX_BURN."
echo "The clean 3-way 1-item qualification has PASSed."
read -rp "Proceed? [y/N] " OK
[[ "${OK,,}" == "y" ]] || { echo "ABORTED"; exit 0; }

echo
echo "===== STOP PERSISTENT DEBUG A100 BEFORE BATCH ====="
if [ "${WS_STATE:-}" = "running" ]; then
  vesslctl workspace pause "$WS"
fi

STOPPED=0
for i in $(seq 1 120); do
  WS_STATE="$(
    vesslctl workspace show "$WS" 2>/dev/null |
    awk -F: '/^State:/ {sub(/^[^:]*:[ \t]*/,""); print tolower($0); exit}'
  )"
  printf '\rDEBUG_WORKSPACE=%s state=%-12s' "$WS" "${WS_STATE:-unknown}"
  case "${WS_STATE:-}" in
    stopped|paused|standby) STOPPED=1; break ;;
  esac
  sleep 3
done
echo
test "$STOPPED" = "1" || {
  echo "ERROR=DEBUG_WORKSPACE_STOP_NOT_CONFIRMED"
  echo "NO_BATCH_JOBS_SUBMITTED=YES"
  exit 22
}
echo "DEBUG_A100_STOP=PASS"

PAYLOAD="$(base64 -w0 "$WORKER")"
: > "$JOBS"

declare -A SHORT_SYS=(
  [pi05]="p05"
  [pi0_fast]="pf"
  [vlanext]="vx"
)
declare -A SHORT_SUITE=(
  [libero_spatial]="sp"
  [libero_object]="ob"
  [libero_goal]="go"
  [libero_10]="l10"
)

SYSTEMS=(pi05 pi0_fast vlanext)
SUITES=(libero_spatial libero_object libero_goal libero_10)

echo
echo "===== SUBMIT $COUNT V2 JOBS ====="

SUBMITTED=0
FAILED_SUBMITS=0

for SYSTEM in "${SYSTEMS[@]}"; do
  for SUITE in "${SUITES[@]}"; do
    for SHARD_ID in $(seq 0 $((SHARDS-1))); do
      NAME="d500h2-${SHORT_SYS[$SYSTEM]}-${SHORT_SUITE[$SUITE]}-s${SHARD_ID}of${SHARDS}"
      BRANCH="results/${RUN_TAG}/${SYSTEM}/${SUITE}/s${SHARD_ID}of${SHARDS}"

      CMD="echo '$PAYLOAD' | base64 -d > /tmp/d500_holdout_worker_v2.sh && chmod 700 /tmp/d500_holdout_worker_v2.sh && timeout --signal=TERM --kill-after=120 18000 bash /tmp/d500_holdout_worker_v2.sh"

      set +e
      OUT="$(
        vesslctl job create \
          --name "$NAME" \
          --image "$IMAGE" \
          --resource-spec "$RESOURCE" \
          --cluster-volume "$VOL:/data" \
          --secret GIT_TOKEN \
          --secret HF_TOKEN \
          --env "SYSTEM=$SYSTEM" \
          --env "SUITE=$SUITE" \
          --env "SHARD_ID=$SHARD_ID" \
          --env "SHARD_COUNT=$SHARDS" \
          --env "RESULT_BRANCH=$BRANCH" \
          --env "RUN_TAG=$RUN_TAG" \
          --cmd "$CMD" \
          2>&1
      )"
      RC=$?
      set -e

      JOB="$(printf '%s\n' "$OUT" | grep -oE 'job-[a-z0-9]+' | tail -1)"

      if [ "$RC" -eq 0 ] && [ -n "$JOB" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$SYSTEM" "$SUITE" "$SHARD_ID" "$JOB" "$NAME" "$BRANCH" >> "$JOBS"
        SUBMITTED=$((SUBMITTED+1))
        printf 'SUBMIT=%02d/%02d PASS %-9s %-15s s%d job=%s\n' \
          "$SUBMITTED" "$COUNT" "$SYSTEM" "$SUITE" "$SHARD_ID" "$JOB"
      else
        FAILED_SUBMITS=$((FAILED_SUBMITS+1))
        echo "SUBMIT_FAIL SYSTEM=$SYSTEM SUITE=$SUITE SHARD=$SHARD_ID RC=$RC"
        printf '%s\n' "$OUT" | tail -25
      fi
    done
  done
done

echo
echo "===== SUBMISSION SUMMARY ====="
echo "SUBMITTED=$SUBMITTED"
echo "FAILED_SUBMITS=$FAILED_SUBMITS"
echo "JOBS_FILE=$JOBS"

if [ "$SUBMITTED" -ne "$COUNT" ]; then
  echo "GATE=PARTIAL_SUBMISSION"
  echo "NEXT=RETRY_ONLY_FAILED_V2_SUBMISSIONS"
  exit 21
fi

SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=LAUNCH_FULL_PROSPECTIVE_HOLDOUT_D500_V2
GATE=PASS
DEBUG_A100_STATE=${WS_STATE:-stopped}
TOTAL_JOBS=$COUNT
SUBMITTED=$SUBMITTED
FAILED_SUBMITS=0
SYSTEMS=3
UNSEEN_FAMILIES=2
SUITES_PER_SYSTEM=4
SHARDS_PER_SUITE=$SHARDS
GPU_PER_JOB=A100x1
MAX_THEORETICAL_BURN_USD=$MAX_BURN
RUNTIME_SOURCE=PERSISTENT_/data
FRESH_RUNTIME_CLONE=NO
SHARED_DATA_PERSIST_FIRST=YES
JOBS_FILE=$JOBS
NEXT=WATCH_V2_60_JOBS_AND_REPAIR_ONLY_ENGINEERING_FAILURES
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
