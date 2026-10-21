#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"

: "${VLA_IRT_ARTIFACT_ROOT:?Set VLA_IRT_ARTIFACT_ROOT to the directory that contains the archived D500 artifact directories}"
HERE="$VLA_IRT_ARTIFACT_ROOT"
SSH_HOST="${SSH_HOST:-YOUR_SSH_HOST.invalid}"
SSH_PORT="${SSH_PORT:-YOUR_SSH_PORT}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/YOUR_KEY.pem}"

WS="wsp-REDACTED000001"
IMAGE="ghcr.io/allenai/vla-evaluation-harness/libero@sha256:2a4566009395888ae3904bde87cffceea7526e2e0f0667b933cae0e8e6134413"
VOL="clustervol-REDACTED000001"
RESOURCE="resourcespec-a100x1"

RUN_TAG="d500-pi0fast-zscore-corrected-v2-20260829"
SHARDS=15
COUNT=$((4 * SHARDS))
RATE=1.55
JOB_HARD_CAP_H=3
MAX_BURN="$(python3 - <<PY
print(f"{${COUNT} * ${JOB_HARD_CAP_H} * ${RATE}:.2f}")
PY
)"
JOBS="$HERE/${RUN_TAG}-jobs.tsv"
PREP_LOG="$HERE/${RUN_TAG}-prep.log"

OPENPI_COMMIT="981483dca0fd9acba698fea00aa6e52d56a66c58"
HARNESS_COMMIT="2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56"

echo "============================================================"
echo " PI0-FAST CORRECTED D500 V2 — 60x A100"
echo "============================================================"
echo "New jobs:                $COUNT"
echo "GPU/job:                 A100 x1"
echo "Suites:                  4"
echo "Shards/suite:            $SHARDS"
echo "Items/job:               ~8-9"
echo "Hard cap/job:            ${JOB_HARD_CAP_H}h"
echo "A100 rate:               \$${RATE}/h"
echo "Absolute theoretical:    ~\$${MAX_BURN}"
echo "OpenPI exact pin:        $OPENPI_COMMIT"
echo "Correction:              PR#971 z-score only"
echo "Existing holdout matrix: NOT overwritten"
echo "============================================================"
read -rp "Proceed? [y/N] " OK
[[ "${OK,,}" == "y" ]] || { echo "ABORTED"; exit 0; }

test -s "$SSH_KEY"
command -v vesslctl >/dev/null
command -v ssh >/dev/null
command -v scp >/dev/null

if [ -s "$JOBS" ]; then
  echo "ERROR=JOBS_FILE_ALREADY_EXISTS:$JOBS"
  cat "$JOBS"
  exit 19
fi

EXISTING="$(
  vesslctl job list 2>/dev/null |
  grep -E 'pfc2-(sp|ob|go|l10)-s[0-9]+of15' || true
)"
if [ -n "$EXISTING" ]; then
  echo "ERROR=V2_CORRECTED_JOBS_ALREADY_EXIST"
  printf '%s\n' "$EXISTING"
  exit 19
fi

# -------------------------------------------------------------------
# Remote PREP repair: reuses exact repo/env already created successfully.
# Fixes only the server-config invocation bug:
# libero_fast.yaml puts port under args, while pi0.py expects --port top-level.
# -------------------------------------------------------------------

PREP="$(mktemp)"
cat > "$PREP" <<'PREP'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 2>&1

ROOT=/data/vla-irt-cat-v2
HARNESS=$ROOT/external/vla-evaluation-harness
LP_ENV=$ROOT/envs/libero-plus-v2
LP_PY=$LP_ENV/bin/python
LP_VLA=$LP_ENV/bin/vla-eval

EXACT=$ROOT/external/openpi-pi0fast-zscore-holdoutpin
EXACT_ENV=$ROOT/envs/openpi-pi0fast-zscore-exact981
OPENPI_CACHE=$ROOT/cache/openpi-pi0fast-zscore-data
HF_HOME_PERSIST=$ROOT/cache/huggingface
PREP_RUN=$ROOT/runtime/pi0fast-zscore/parallel-prep-v2-20260829

MANIFEST=$ROOT/manifests/discovery_500_primary.json
WRAPPER=$ROOT/v2_tools/libero_plus_selected_v3.py
RESTORE=$ROOT/tools/restore_libero_runtime.sh
SOURCE_CFG=$HARNESS/configs/model_servers/pi0/libero_fast.yaml
SANITIZED_CFG=$ROOT/runtime/pi0fast-zscore/libero_fast_exact981_sanitized.yaml

OPENPI_COMMIT=981483dca0fd9acba698fea00aa6e52d56a66c58
HARNESS_COMMIT=2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56
D500_SHA=87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1
WRAPPER_SHA=0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae

mkdir -p "$PREP_RUN"

echo "===== REPAIR PREP 1. VERIFY EXISTING EXACT RUNTIME ====="
test -d "$EXACT/.git"
test -x "$EXACT_ENV/bin/python"
test "$(git -C "$EXACT" rev-parse HEAD)" = "$OPENPI_COMMIT"
test "$(sha256sum "$MANIFEST" | awk '{print $1}')" = "$D500_SHA"
test "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$WRAPPER_SHA"
git -C "$EXACT" diff --check
echo "EXACT_RUNTIME_REUSE=PASS"

echo
echo "===== REPAIR PREP 2. SANITIZE SERVER CONFIG ====="
# Direct pi0.py parser owns --port at top level. Remove args.port only.
python3 - "$SOURCE_CFG" "$SANITIZED_CFG" <<'PY'
from pathlib import Path
import sys
src=Path(sys.argv[1]).read_text().splitlines()
out=[]
removed=0
for line in src:
    if line.strip() == "port: 8000":
        removed += 1
        continue
    out.append(line)
assert removed == 1, removed
Path(sys.argv[2]).write_text("\n".join(out)+"\n")
print("REMOVED_ARGS_PORT="+str(removed))
PY
grep -n . "$SANITIZED_CFG"
if grep -Eq '^[[:space:]]+port:' "$SANITIZED_CFG"; then
  echo "ERROR=ARGS_PORT_STILL_PRESENT"
  exit 31
fi
echo "SANITIZED_SERVER_CONFIG=PASS"

echo
echo "===== REPAIR PREP 3. RESTORE EPHEMERAL LIBS ====="
bash "$RESTORE"

export PYOPENGL_PLATFORM=egl
export EGL_PLATFORM=device
export MUJOCO_GL=egl
export NVIDIA_DRIVER_CAPABILITIES=all
export TOKENIZERS_PARALLELISM=false
export PYTHONDONTWRITEBYTECODE=1
export XLA_PYTHON_CLIENT_PREALLOCATE=false
export PYTHONSAFEPATH=1
export OPENPI_DATA_HOME="$OPENPI_CACHE"
export HF_HOME="$HF_HOME_PERSIST"
export HUGGINGFACE_HUB_CACHE="$HF_HOME_PERSIST/hub"
export TRANSFORMERS_CACHE="$HF_HOME_PERSIST/hub"
export HOME="$ROOT/home-libero-plus"
export PYTHONPATH="$EXACT/src:$HARNESS/src:$ROOT:${PYTHONPATH:-}"

echo
echo "===== REPAIR PREP 4. NORMALIZATION RECHECK ====="
"$EXACT_ENV/bin/python" - <<'PY'
import openpi.training.config as c
cfg=c.get_config("pi0_fast_libero")
v=cfg.data.create(cfg.assets_dirs,cfg.model).use_quantile_norm
print("USE_QUANTILE_NORM="+str(v))
assert v is False
print("NORMALIZATION_GATE=PASS_ZSCORE")
PY

echo
echo "===== REPAIR PREP 5. START EXACT SERVER WITH TOP-LEVEL --port ====="
if command -v fuser >/dev/null 2>&1; then
  fuser -k 8000/tcp 2>/dev/null || true
fi
cd "$HARNESS"
"$EXACT_ENV/bin/python" "$HARNESS/src/vla_eval/model_servers/pi0.py" \
  --config "$SANITIZED_CFG" \
  --port 8000 \
  --verbose \
  > "$PREP_RUN/server.log" 2>&1 &
SERVER_PID=$!

cleanup() {
  set +e
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

READY=0
for I in $(seq 1 360); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "PREP_SERVER_DIED"
    tail -220 "$PREP_RUN/server.log" || true
    exit 50
  fi
  set +e
  H="$(
    python3 - <<'PY' 2>/dev/null
import urllib.request
r=urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=2)
print(getattr(r,"status",200))
PY
  )"
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] && [ "$H" = "200" ]; then
    READY=1
    break
  fi
  if [ $((I % 12)) -eq 0 ]; then
    echo "WAIT_SERVER=$I/360"
    tail -12 "$PREP_RUN/server.log" || true
  fi
  sleep 5
done
test "$READY" = "1"
echo "PREP_SERVER_HEALTH=PASS"

echo
echo "===== REPAIR PREP 6. ONE FROZEN D500 HARNESS CANARY ====="
ONE_MAN="$PREP_RUN/oneitem_manifest.json"
"$LP_PY" - "$MANIFEST" "$ONE_MAN" <<'PY'
import json,sys
o=json.load(open(sys.argv[1]))
x=sorted(o["items"], key=lambda z:int(z["discovery_index"]))[0]
q=dict(o); q["items"]=[x]
json.dump(q,open(sys.argv[2],"w"),indent=2)
print("ONE_INDEX="+str(x["discovery_index"]))
print("ONE_SUITE="+x["suite"])
PY

ONE_SUITE="$("$LP_PY" - "$ONE_MAN" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))["items"][0]["suite"])
PY
)"

rm -rf "$PREP_RUN/oneitem_results"
cat > "$PREP_RUN/oneitem.yaml" <<EOF
server:
  url: "ws://localhost:8000"
  timeout: 300
output_dir: "$PREP_RUN/oneitem_results"
benchmarks:
  - benchmark: "v2_tools.libero_plus_selected_v3:SelectedLIBEROPlusBenchmarkV3"
    episodes_per_task: 1
    recording:
      record_video: false
    params:
      manifest_path: "$ONE_MAN"
      suite: $ONE_SUITE
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      send_wrist_image: true
      send_state: true
EOF

set +e
timeout --signal=TERM --kill-after=60 1800 \
  "$LP_VLA" run --no-docker \
  --config "$PREP_RUN/oneitem.yaml" \
  --eval-id "pi0fast-zscore-exact981-prep-v2-20260829" \
  > "$PREP_RUN/oneitem_rollout.log" 2>&1
ONE_RC=$?
set -e
echo "ONEITEM_RC=$ONE_RC"
if [ "$ONE_RC" -ne 0 ]; then
  tail -220 "$PREP_RUN/oneitem_rollout.log" || true
  exit 60
fi

DB="$(find "$PREP_RUN/oneitem_results" -type f -name 'recording-*.sqlite' | head -1)"
test -s "$DB"
"$LP_PY" - "$DB" <<'PY'
import sqlite3,sys
con=sqlite3.connect(sys.argv[1])
rows=con.execute(
  "select status,failure_reason,failure_detail from episode_results"
).fetchall()
con.close()
print("ONEITEM_ROWS="+str(len(rows)))
print("ONEITEM_STATUS="+str(rows[0][0] if rows else None))
assert len(rows)==1
assert rows[0][0] in ("success","fail"),rows
print("HARNESS_PROTOCOL_CANARY=PASS")
PY

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

echo
echo "PREP_GATE=PASS"
echo "SANITIZED_CFG=$SANITIZED_CFG"
PREP

echo
echo "===== RUN REPAIRED PREP ====="
scp \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -P "$SSH_PORT" \
  "$PREP" \
  "root@$SSH_HOST:/root/pi0fast_parallel_prep_v2.sh"

set +e
ssh \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  "root@$SSH_HOST" \
  'chmod 700 /root/pi0fast_parallel_prep_v2.sh && bash /root/pi0fast_parallel_prep_v2.sh' \
  2>&1 | tee "$PREP_LOG"
PREP_RC=${PIPESTATUS[0]}
set -e
rm -f "$PREP"

if [ "$PREP_RC" -ne 0 ] || ! grep -q '^PREP_GATE=PASS$' "$PREP_LOG"; then
  echo
  echo "GATE=PREP_FAILED_NO_BATCH_SUBMITTED"
  echo "PREP_RC=$PREP_RC"
  echo "PREP_LOG=$PREP_LOG"
  exit 30
fi

echo
echo "PREP_GATE=PASS — SAFE TO SUBMIT 60 JOBS"

# -------------------------------------------------------------------
# Worker: reuses exact immutable /data repo/env/cache prepared above.
# -------------------------------------------------------------------

WORKER="$(mktemp)"
cat > "$WORKER" <<'WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 2>&1

SUITE="${SUITE:?}"
SHARD_ID="${SHARD_ID:?}"
SHARD_COUNT="${SHARD_COUNT:?}"
RUN_TAG="${RUN_TAG:?}"

ROOT=/data/vla-irt-cat-v2
HARNESS=$ROOT/external/vla-evaluation-harness
LP_ENV=$ROOT/envs/libero-plus-v2
LP_PY=$LP_ENV/bin/python
LP_VLA=$LP_ENV/bin/vla-eval
EXACT=$ROOT/external/openpi-pi0fast-zscore-holdoutpin
EXACT_ENV=$ROOT/envs/openpi-pi0fast-zscore-exact981
OPENPI_CACHE=$ROOT/cache/openpi-pi0fast-zscore-data
HF_HOME_PERSIST=$ROOT/cache/huggingface
MANIFEST=$ROOT/manifests/discovery_500_primary.json
WRAPPER=$ROOT/v2_tools/libero_plus_selected_v3.py
RESTORE=$ROOT/tools/restore_libero_runtime.sh
SANITIZED_CFG=$ROOT/runtime/pi0fast-zscore/libero_fast_exact981_sanitized.yaml

OPENPI_COMMIT=981483dca0fd9acba698fea00aa6e52d56a66c58
D500_SHA=87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1
WRAPPER_SHA=0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae

PERSIST=$ROOT/corrected_results_local/$RUN_TAG/pi0_fast/$SUITE/s${SHARD_ID}of${SHARD_COUNT}
mkdir -p "$PERSIST"/{logs,results}
exec > >(tee "$PERSIST/worker.log") 2>&1

echo "============================================================"
echo " PI0-FAST CORRECTED SHARD"
echo "============================================================"
echo "SUITE=$SUITE"
echo "SHARD=$SHARD_ID/$SHARD_COUNT"
echo "GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "============================================================"

if [ -s "$PERSIST/summary.env" ] && grep -q '^GATE=PASS$' "$PERSIST/summary.env"; then
  echo "ALREADY_COMPLETE=YES"
  exit 0
fi

bash "$RESTORE"

test -x "$EXACT_ENV/bin/python"
test -s "$SANITIZED_CFG"
test "$(git -C "$EXACT" rev-parse HEAD)" = "$OPENPI_COMMIT"
test "$(sha256sum "$MANIFEST" | awk '{print $1}')" = "$D500_SHA"
test "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$WRAPPER_SHA"

export PYOPENGL_PLATFORM=egl
export EGL_PLATFORM=device
export MUJOCO_GL=egl
export NVIDIA_DRIVER_CAPABILITIES=all
export TOKENIZERS_PARALLELISM=false
export PYTHONDONTWRITEBYTECODE=1
export XLA_PYTHON_CLIENT_PREALLOCATE=false
export PYTHONSAFEPATH=1
export OPENPI_DATA_HOME="$OPENPI_CACHE"
export HF_HOME="$HF_HOME_PERSIST"
export HUGGINGFACE_HUB_CACHE="$HF_HOME_PERSIST/hub"
export TRANSFORMERS_CACHE="$HF_HOME_PERSIST/hub"
export HOME="$ROOT/home-libero-plus"
export PYTHONPATH="$EXACT/src:$HARNESS/src:$ROOT:${PYTHONPATH:-}"

"$EXACT_ENV/bin/python" - <<'PY'
import openpi.training.config as c
cfg=c.get_config("pi0_fast_libero")
v=cfg.data.create(cfg.assets_dirs,cfg.model).use_quantile_norm
print("USE_QUANTILE_NORM="+str(v))
assert v is False
print("NORMALIZATION_GATE=PASS_ZSCORE")
PY

SHARD_MAN="$PERSIST/shard_manifest.json"
"$LP_PY" - "$MANIFEST" "$SUITE" "$SHARD_ID" "$SHARD_COUNT" "$SHARD_MAN" <<'PY'
import json,sys
src,suite,sid,nsh,dst=sys.argv[1:]
sid=int(sid); nsh=int(nsh)
o=json.load(open(src))
items=sorted([x for x in o["items"] if x["suite"]==suite],
             key=lambda x:int(x["discovery_index"]))
picked=[x for i,x in enumerate(items) if i % nsh == sid]
assert picked
q=dict(o); q["items"]=picked
json.dump(q,open(dst,"w"),indent=2)
print("SHARD_N="+str(len(picked)))
PY

EXPECTED="$("$LP_PY" - "$SHARD_MAN" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))["items"]))
PY
)"
echo "EXPECTED_N=$EXPECTED"

cd "$HARNESS"
"$EXACT_ENV/bin/python" "$HARNESS/src/vla_eval/model_servers/pi0.py" \
  --config "$SANITIZED_CFG" \
  --port 8000 \
  --verbose \
  > "$PERSIST/logs/server.log" 2>&1 &
SERVER_PID=$!

cleanup() {
  set +e
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

READY=0
for I in $(seq 1 360); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "SERVER_DIED"
    tail -200 "$PERSIST/logs/server.log" || true
    exit 50
  fi
  set +e
  H="$(
    python3 - <<'PY' 2>/dev/null
import urllib.request
r=urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=2)
print(getattr(r,"status",200))
PY
  )"
  RC=$?
  set -e
  if [ "$RC" -eq 0 ] && [ "$H" = "200" ]; then
    READY=1
    break
  fi
  sleep 5
done
test "$READY" = "1"
echo "SERVER_HEALTH=PASS"

rm -rf "$PERSIST/results"
cat > "$PERSIST/benchmark.yaml" <<EOF
server:
  url: "ws://localhost:8000"
  timeout: 300
output_dir: "$PERSIST/results"
benchmarks:
  - benchmark: "v2_tools.libero_plus_selected_v3:SelectedLIBEROPlusBenchmarkV3"
    episodes_per_task: 1
    recording:
      record_video: false
    params:
      manifest_path: "$SHARD_MAN"
      suite: $SUITE
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      send_wrist_image: true
      send_state: true
EOF

set +e
timeout --signal=TERM --kill-after=60 9000 \
  "$LP_VLA" run --no-docker \
  --config "$PERSIST/benchmark.yaml" \
  --eval-id "${RUN_TAG}-pi0fast-${SUITE}-s${SHARD_ID}of${SHARD_COUNT}" \
  > "$PERSIST/logs/rollout.log" 2>&1
RRC=$?
set -e
echo "ROLLOUT_RC=$RRC"
if [ "$RRC" -ne 0 ]; then
  tail -220 "$PERSIST/logs/rollout.log" || true
  exit 60
fi

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

DB="$(find "$PERSIST/results" -type f -name 'recording-*.sqlite' | head -1)"
test -s "$DB"

"$LP_PY" - "$DB" "$EXPECTED" "$PERSIST/response_audit.json" <<'PY'
import json,sqlite3,sys
db,expected,out=sys.argv[1],int(sys.argv[2]),sys.argv[3]
con=sqlite3.connect(db)
rows=con.execute(
  "select task_name,status,steps,failure_reason,failure_detail,context "
  "from episode_results order by rowid"
).fetchall()
con.close()

counts={}; errors=[]
for i,(task,status,steps,reason,detail,context) in enumerate(rows):
    counts[status]=counts.get(status,0)+1
    if status not in ("success","fail"):
        errors.append({
          "row":i,"task_name":task,"status":status,"steps":steps,
          "failure_reason":reason,"failure_detail":detail,"context":context,
        })

body={"expected":expected,"observed":len(rows),
      "status_counts":counts,"engineering_errors":errors}
open(out,"w").write(json.dumps(body,indent=2,ensure_ascii=False)+"\n")
print("OBSERVED_N="+str(len(rows)))
print("STATUS_COUNTS="+json.dumps(counts,sort_keys=True))
print("ENGINEERING_ERRORS="+str(len(errors)))
assert len(rows)==expected,(len(rows),expected)
assert not errors,errors
PY

cat > "$PERSIST/summary.env" <<EOF
GATE=PASS
SYSTEM=pi0_fast
SUITE=$SUITE
SHARD_ID=$SHARD_ID
SHARD_COUNT=$SHARD_COUNT
EXPECTED_N=$EXPECTED
OPENPI_PIN=$OPENPI_COMMIT
CORRECTION=PR971_ZSCORE_COMPATIBILITY_BACKPORT_ONLY
USE_QUANTILE_NORM=false
D500_SHA=$D500_SHA
WRAPPER_SHA=$WRAPPER_SHA
EOF

echo "SHARD_GATE=PASS"
WORKER

PAYLOAD="$(base64 -w0 "$WORKER")"
rm -f "$WORKER"

echo
echo "===== FREE DEBUG A100 BEFORE BATCH ====="
WS_STATE="$(
  vesslctl workspace show "$WS" 2>/dev/null |
  awk -F: '/^State:/ {sub(/^[^:]*:[ \t]*/,""); print tolower($0); exit}'
)"
echo "WORKSPACE_STATE_BEFORE=${WS_STATE:-unknown}"
if [ "${WS_STATE:-}" = "running" ]; then
  vesslctl workspace pause "$WS"
fi

STOPPED=0
for I in $(seq 1 120); do
  WS_STATE="$(
    vesslctl workspace show "$WS" 2>/dev/null |
    awk -F: '/^State:/ {sub(/^[^:]*:[ \t]*/,""); print tolower($0); exit}'
  )"
  printf '\rWORKSPACE_STATE=%s' "${WS_STATE:-unknown}"
  case "${WS_STATE:-}" in
    paused|stopped|standby) STOPPED=1; break ;;
  esac
  sleep 3
done
echo
test "$STOPPED" = "1"

echo
echo "===== SUBMIT $COUNT A100 JOBS ====="
: > "$JOBS"

declare -A SHORT_SUITE=(
  [libero_spatial]="sp"
  [libero_object]="ob"
  [libero_goal]="go"
  [libero_10]="l10"
)
SUITES=(libero_spatial libero_object libero_goal libero_10)

SUBMITTED=0
FAILED=0

for SUITE in "${SUITES[@]}"; do
  for SHARD_ID in $(seq 0 $((SHARDS-1))); do
    NAME="pfc2-${SHORT_SUITE[$SUITE]}-s${SHARD_ID}of${SHARDS}"
    CMD="echo '$PAYLOAD' | base64 -d > /tmp/pi0fast_corrected_worker_v2.sh && chmod 700 /tmp/pi0fast_corrected_worker_v2.sh && timeout --signal=TERM --kill-after=120 10800 bash /tmp/pi0fast_corrected_worker_v2.sh"

    set +e
    OUT="$(
      vesslctl job create \
        --name "$NAME" \
        --image "$IMAGE" \
        --resource-spec "$RESOURCE" \
        --cluster-volume "$VOL:/data" \
        --env "SUITE=$SUITE" \
        --env "SHARD_ID=$SHARD_ID" \
        --env "SHARD_COUNT=$SHARDS" \
        --env "RUN_TAG=$RUN_TAG" \
        --cmd "$CMD" \
        2>&1
    )"
    RC=$?
    set -e

    JOB="$(printf '%s\n' "$OUT" | grep -oE 'job-[a-z0-9]+' | tail -1)"
    if [ "$RC" -eq 0 ] && [ -n "$JOB" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$SUITE" "$SHARD_ID" "$JOB" "$NAME" "$RUN_TAG" >> "$JOBS"
      SUBMITTED=$((SUBMITTED+1))
      printf 'SUBMIT=%02d/%02d PASS %-15s s%-2d %s\n' \
        "$SUBMITTED" "$COUNT" "$SUITE" "$SHARD_ID" "$JOB"
    else
      FAILED=$((FAILED+1))
      echo "SUBMIT_FAIL SUITE=$SUITE SHARD=$SHARD_ID RC=$RC"
      printf '%s\n' "$OUT" | tail -30
    fi
  done
done

echo
echo "===== SUBMISSION SUMMARY ====="
echo "SUBMITTED=$SUBMITTED"
echo "FAILED_SUBMITS=$FAILED"
echo "JOBS_FILE=$JOBS"
echo "MAX_THEORETICAL_BURN_USD=$MAX_BURN"

if [ "$SUBMITTED" -ne "$COUNT" ]; then
  echo "GATE=PARTIAL_SUBMISSION"
  exit 40
fi

SUMMARY="$(cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=LAUNCH_PI0FAST_CORRECTED_D500_V2
GATE=PASS
PREP_GATE=PASS
HARNESS_PROTOCOL_CANARY=PASS
TOTAL_JOBS=$COUNT
GPU_PER_JOB=A100x1
SHARDS_PER_SUITE=$SHARDS
SUITES=4
TOTAL_D500_ITEMS=500
OPENPI_PIN=$OPENPI_COMMIT
CORRECTION=PR971_ZSCORE_ONLY
MAX_THEORETICAL_BURN_USD=$MAX_BURN
JOBS_FILE=$JOBS
RESULT_ROOT=/data/vla-irt-cat-v2/corrected_results_local/$RUN_TAG
NEXT=WATCH_60_JOBS_THEN_COLLECT_500
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
fi
