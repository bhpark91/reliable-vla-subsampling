#!/usr/bin/env bash
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

HERE="/mnt/c/Users/YOUR_USER/Downloads"
ORIG="$HERE/d500-holdout-prod-v2-20260829-jobs.tsv"
WORKER="$HERE/d500_holdout_repair_worker_v3_isolated_uv_20260829.sh"

IMAGE="ghcr.io/allenai/vla-evaluation-harness/libero@sha256:2a4566009395888ae3904bde87cffceea7526e2e0f0667b933cae0e8e6134413"
VOL="clustervol-REDACTED000001"
RESOURCE="resourcespec-a100x1"

RUN_TAG="d500-holdout-prod-v2-repair1-20260829"
CANONICAL_RUN_TAG="d500-holdout-prod-v2-20260829"
RATE=1.55
HARD_CAP_H=5

TARGETS="$HERE/${RUN_TAG}-targets.tsv"
JOBS="$HERE/${RUN_TAG}-jobs.tsv"

test -s "$ORIG" || { echo "ERROR=ORIGINAL_JOBS_FILE_MISSING:$ORIG"; exit 2; }
test -s "$WORKER" || { echo "ERROR=WORKER_MISSING:$WORKER"; exit 3; }

if [ -s "$JOBS" ]; then
  echo "ERROR=REPAIR1_ALREADY_SUBMITTED:$JOBS"
  cat "$JOBS"
  exit 19
fi

state_of () {
  local job="$1"
  vesslctl job show "$job" 2>/dev/null |
    awk -F: '/^State:/{
      sub(/^[^:]*:[ \t]*/, "");
      print tolower($0);
      exit
    }'
}

: > "$TARGETS"
while IFS=$'\t' read -r SYSTEM SUITE SHARD OLDJOB OLDNAME OLDBRANCH; do
  ST="$(state_of "$OLDJOB")"
  if [ "$ST" = "failed" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SYSTEM" "$SUITE" "$SHARD" "$OLDJOB" "$OLDNAME" "$OLDBRANCH" >> "$TARGETS"
  fi
done < "$ORIG"

COUNT="$(wc -l < "$TARGETS")"
if [ "$COUNT" -eq 0 ]; then
  echo "NO_FAILED_JOBS_TO_REPAIR=YES"
  exit 0
fi

MAX_BURN="$(python3 - <<PY
print(f"{${COUNT} * ${HARD_CAP_H} * ${RATE}:.2f}")
PY
)"

echo "============================================================"
echo " D500 HOLDOUT REPAIR1 — ISOLATED UV CACHE"
echo "============================================================"
echo "Failed shards now: $COUNT"
echo "New jobs:          $COUNT"
echo "GPU/job:           A100 x1"
echo "Rate/job:          \$$RATE/hr"
echo "Hard cap/job:      ${HARD_CAP_H}h"
echo "Max theoretical:   ~\$$MAX_BURN"
echo "Existing running:  untouched"
echo "Mutable UV cache:  /scratch per job"
echo "Shared /data:      frozen inputs/model caches/results only"
echo "============================================================"
echo
column -t -s $'\t' "$TARGETS" 2>/dev/null || cat "$TARGETS"
echo
read -rp "Proceed with these $COUNT repair jobs? [y/N] " OK
[[ "${OK,,}" == "y" ]] || { echo "ABORTED"; exit 0; }

PAYLOAD="$(base64 -w0 "$WORKER")"
: > "$JOBS"

declare -A SHORT_SYS=([pi05]="p05" [pi0_fast]="pf" [vlanext]="vx")
declare -A SHORT_SUITE=([libero_spatial]="sp" [libero_object]="ob" [libero_goal]="go" [libero_10]="l10")

SUBMITTED=0
FAILED_SUBMITS=0

while IFS=$'\t' read -r SYSTEM SUITE SHARD OLDJOB OLDNAME OLDBRANCH; do
  NAME="d500h3r-${SHORT_SYS[$SYSTEM]}-${SHORT_SUITE[$SUITE]}-s${SHARD}of5"
  BRANCH="results/${RUN_TAG}/${SYSTEM}/${SUITE}/s${SHARD}of5"

  CMD="echo '$PAYLOAD' | base64 -d > /tmp/d500_repair_worker_v3.sh && chmod 700 /tmp/d500_repair_worker_v3.sh && timeout --signal=TERM --kill-after=120 18000 bash /tmp/d500_repair_worker_v3.sh"

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
      --env "SHARD_ID=$SHARD" \
      --env "SHARD_COUNT=5" \
      --env "RESULT_BRANCH=$BRANCH" \
      --env "RUN_TAG=$RUN_TAG" \
      --env "CANONICAL_RUN_TAG=$CANONICAL_RUN_TAG" \
      --cmd "$CMD" \
      2>&1
  )"
  RC=$?
  set -e

  NEWJOB="$(printf '%s\n' "$OUT" | grep -oE 'job-[a-z0-9]+' | tail -1)"

  if [ "$RC" -eq 0 ] && [ -n "$NEWJOB" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SYSTEM" "$SUITE" "$SHARD" "$OLDJOB" "$NEWJOB" "$NAME" "$BRANCH" >> "$JOBS"
    SUBMITTED=$((SUBMITTED+1))
    printf 'REPAIR_SUBMIT=%02d/%02d PASS %-9s %-15s s%d old=%s new=%s\n' \
      "$SUBMITTED" "$COUNT" "$SYSTEM" "$SUITE" "$SHARD" "$OLDJOB" "$NEWJOB"
  else
    FAILED_SUBMITS=$((FAILED_SUBMITS+1))
    echo "REPAIR_SUBMIT_FAIL $SYSTEM $SUITE s$SHARD RC=$RC"
    printf '%s\n' "$OUT" | tail -30
  fi
done < "$TARGETS"

SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=LAUNCH_HOLDOUT_D500_REPAIR1_ISOLATED_UV
GATE=$([ "$SUBMITTED" -eq "$COUNT" ] && echo PASS || echo PARTIAL)
TARGET_FAILED_SHARDS=$COUNT
SUBMITTED=$SUBMITTED
FAILED_SUBMITS=$FAILED_SUBMITS
GPU_PER_JOB=A100x1
MAX_THEORETICAL_BURN_USD=$MAX_BURN
UV_CACHE_MODE=ISOLATED_PER_JOB
EXISTING_RUNNING_JOBS=UNTOUCHED
REPAIR_JOBS_FILE=$JOBS
NEXT=WATCH_ORIGINAL_AND_REPAIR1_TO_TERMINAL
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
