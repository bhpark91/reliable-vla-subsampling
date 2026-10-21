#!/usr/bin/env bash
set -Eeuo pipefail
exec 2>&1

SYSTEM="${SYSTEM:?SYSTEM required}"
SUITE="${SUITE:?SUITE required}"
SHARD_ID="${SHARD_ID:?SHARD_ID required}"
SHARD_COUNT="${SHARD_COUNT:-5}"
RESULT_BRANCH="${RESULT_BRANCH:?RESULT_BRANCH required}"
RUN_TAG="${RUN_TAG:-d500-holdout-prod-v2-20260829}"

ROOT="/data/vla-irt-cat-v2"
HARNESS="$ROOT/external/vla-evaluation-harness"
LP_ENV="$ROOT/envs/libero-plus-v2"
LP_PY="$LP_ENV/bin/python"
LP_VLA="$LP_ENV/bin/vla-eval"
MANIFEST="$ROOT/manifests/discovery_500_primary.json"
WRAPPER="$ROOT/v2_tools/libero_plus_selected_v3.py"
RESTORE="$ROOT/tools/restore_libero_runtime.sh"

MAIN_COMMIT="d9efba94e7d4f2228d4735db00b4f92dd32a16e0"
HARNESS_COMMIT_PROVENANCE="2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56"
D500_SHA="87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1"
WRAPPER_SHA="0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae"
QUAL3WAY_OUTPUT="/scratch/holdout-clean-3way-20260829-055525"

BASE="/scratch/${RUN_TAG}/${SYSTEM}/${SUITE}/s${SHARD_ID}of${SHARD_COUNT}"
RUN="$BASE/run"
PERSIST="$ROOT/holdout_results_local/${RUN_TAG}/${SYSTEM}/${SUITE}/s${SHARD_ID}of${SHARD_COUNT}"
mkdir -p "$RUN"/{logs,results} "$PERSIST"

case "$SYSTEM" in
  pi05|pi0_fast|vlanext) ;;
  *) echo "ERROR=UNKNOWN_SYSTEM:$SYSTEM"; exit 2 ;;
esac
case "$SUITE" in
  libero_spatial|libero_object|libero_goal|libero_10) ;;
  *) echo "ERROR=UNKNOWN_SUITE:$SUITE"; exit 3 ;;
esac

echo "============================================================"
echo " D500 HOLDOUT PRODUCTION V2"
echo "============================================================"
echo "SYSTEM=$SYSTEM"
echo "SUITE=$SUITE"
echo "SHARD=$SHARD_ID/$SHARD_COUNT"
echo "GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "RUNTIME_SOURCE=PERSISTENT_/data"
echo "FRESH_RUNTIME_CLONE=NO"
echo "============================================================"

# ------------------------------------------------------------------
# Restore only the non-persistent container layer.  /data itself already
# contains the qualified harness, checkpoints, model caches and D500 assets.
# ------------------------------------------------------------------

test -s "$RESTORE" || {
  echo "ERROR=RUNTIME_RESTORE_SCRIPT_MISSING:$RESTORE"
  exit 10
}

echo
echo "===== RESTORE EPHEMERAL CONTAINER RUNTIME ====="
bash "$RESTORE"
echo "RUNTIME_RESTORE=PASS"

# ------------------------------------------------------------------
# Frozen persistent inputs.  Intentionally no git operation on the runtime
# harness: this exact /data tree passed the clean 3-way qualification.
# ------------------------------------------------------------------

test -d "$HARNESS"
test -x "$LP_PY"
test -x "$LP_VLA"
test -s "$MANIFEST"
test -s "$WRAPPER"

ACTUAL_MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
ACTUAL_WRAPPER_SHA="$(sha256sum "$WRAPPER" | awk '{print $1}')"
echo "MANIFEST_SHA=$ACTUAL_MANIFEST_SHA"
echo "WRAPPER_SHA=$ACTUAL_WRAPPER_SHA"
test "$ACTUAL_MANIFEST_SHA" = "$D500_SHA"
test "$ACTUAL_WRAPPER_SHA" = "$WRAPPER_SHA"
echo "FROZEN_D500_INPUTS=PASS"

export PYOPENGL_PLATFORM=egl
export EGL_PLATFORM=device
export MUJOCO_GL=egl
export NVIDIA_DRIVER_CAPABILITIES=all
export TOKENIZERS_PARALLELISM=false
export PYTHONDONTWRITEBYTECODE=1
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

export HOME="$ROOT/home-libero-plus"
export HF_HOME="$ROOT/cache/huggingface"
export HUGGINGFACE_HUB_CACHE="$ROOT/cache/huggingface/hub"
export TRANSFORMERS_CACHE="$ROOT/cache/huggingface/hub"
export UV_CACHE_DIR="$ROOT/cache/uv"
export UV_PYTHON_INSTALL_DIR="$ROOT/cache/uv-python"
export UV_LINK_MODE=copy
export UV_NO_CONFIG=1
export PYTHONPATH="$ROOT:$HARNESS/src:${PYTHONPATH:-}"

"$LP_PY" - <<'PY'
import cv2
from wand.image import Image
import robosuite, libero, vla_eval
from v2_tools.libero_plus_selected_v3 import SelectedLIBEROPlusBenchmarkV3
print("QUALIFIED_RUNTIME_IMPORT=PASS")
PY

# ------------------------------------------------------------------
# Deterministic 1/5 shard within each frozen suite.
# ------------------------------------------------------------------

SHARD_MANIFEST="$RUN/shard_manifest.json"
"$LP_PY" - "$MANIFEST" "$SUITE" "$SHARD_ID" "$SHARD_COUNT" "$SHARD_MANIFEST" <<'PY'
import json,sys
src,suite,sid,nsh,dst=sys.argv[1:]
sid=int(sid); nsh=int(nsh)
obj=json.load(open(src))
items=sorted(
    [x for x in obj["items"] if x["suite"]==suite],
    key=lambda x:int(x["discovery_index"]),
)
picked=[x for i,x in enumerate(items) if i % nsh == sid]
assert picked
out=dict(obj); out["items"]=picked
json.dump(out,open(dst,"w"),indent=2)
print("SHARD_N="+str(len(picked)))
print("INDEX_MIN="+str(min(int(x["discovery_index"]) for x in picked)))
print("INDEX_MAX="+str(max(int(x["discovery_index"]) for x in picked)))
PY

EXPECTED_N="$("$LP_PY" - "$SHARD_MANIFEST" <<'PY'
import json,sys
print(len(json.load(open(sys.argv[1]))["items"]))
PY
)"
echo "EXPECTED_N=$EXPECTED_N"
echo "SHARD_MANIFEST=PASS"

# ------------------------------------------------------------------
# Exact configs that passed CLEAN_3WAY_HOLDOUT_1ITEM_QUALIFICATION.
# ------------------------------------------------------------------

case "$SYSTEM" in
  pi05)
    SERVER_CFG="$HARNESS/configs/model_servers/pi0/libero.yaml"
    QUAL_JOB="job-REDACTED000004"
    FAMILY="pi_openpi"
    ;;
  pi0_fast)
    SERVER_CFG="$HARNESS/configs/model_servers/pi0/libero_fast.yaml"
    QUAL_JOB="job-REDACTED000002"
    FAMILY="pi_openpi"
    ;;
  vlanext)
    SERVER_CFG="$HARNESS/configs/model_servers/vlanext/${SUITE}.yaml"
    QUAL_JOB="job-REDACTED000005"
    FAMILY="vlanext"
    ;;
esac
test -s "$SERVER_CFG"
cp "$SERVER_CFG" "$RUN/server_config.yaml"

echo "SERVER_CFG=$SERVER_CFG"
echo "QUALIFICATION_JOB=$QUAL_JOB"
echo "FAMILY=$FAMILY"

# A fresh VESSL Job has its own network namespace; port 8000 must be free.
if ss -ltnp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:8000[[:space:]]' >/dev/null; then
  echo "ERROR=PORT_8000_ALREADY_IN_USE_AT_JOB_START"
  ss -ltnp 2>/dev/null | grep ':8000' || true
  exit 41
fi

# ------------------------------------------------------------------
# Model server.  Critical detail: cwd MUST be the harness because configs use
# relative `script: src/vla_eval/model_servers/...` paths.
# ------------------------------------------------------------------

cd "$HARNESS"

if [ "$SYSTEM" = "pi05" ] || [ "$SYSTEM" = "pi0_fast" ]; then
  env \
    PYTHONPATH="$HARNESS/src" \
    PYTHONSAFEPATH=1 \
    XLA_PYTHON_CLIENT_PREALLOCATE=false \
    "$LP_VLA" serve -c "$SERVER_CFG" --verbose \
    >"$RUN/logs/server.log" 2>&1 &
else
  env \
    PYTHONPATH="$HARNESS/src" \
    "$LP_VLA" serve -c "$SERVER_CFG" --verbose \
    >"$RUN/logs/server.log" 2>&1 &
fi
SERVER_PID=$!

cleanup () {
  set +e
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "SERVER_PID=$SERVER_PID"

READY=0
for I in $(seq 1 360); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "SERVER_PROCESS_DIED"
    tail -160 "$RUN/logs/server.log" || true
    exit 50
  fi

  set +e
  HEALTH="$(
    python3 - <<'PY' 2>/dev/null
import urllib.request
try:
    r=urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=2)
    print(getattr(r,"status",200))
except Exception:
    raise SystemExit(1)
PY
  )"
  HRC=$?
  set -e

  if [ "$HRC" -eq 0 ] && [ "$HEALTH" = "200" ]; then
    READY=1
    break
  fi

  if [ $((I % 12)) -eq 0 ]; then
    echo "WAIT_SERVER=$I/360"
    tail -8 "$RUN/logs/server.log" || true
  fi
  sleep 5
done

test "$READY" = "1"
kill -0 "$SERVER_PID"
echo "SERVER_HEALTH=PASS"
echo "NEW_SERVER_PROCESS_ALIVE=PASS"

# ------------------------------------------------------------------
# D500 rollout.
# ------------------------------------------------------------------

BENCH="$RUN/benchmark.yaml"
if [ "$SYSTEM" = "vlanext" ]; then
cat > "$BENCH" <<EOF
server:
  url: "ws://localhost:8000"
  timeout: 300
output_dir: "$RUN/results"
benchmarks:
  - benchmark: "v2_tools.libero_plus_selected_v3:SelectedLIBEROPlusBenchmarkV3"
    episodes_per_task: 1
    recording:
      record_video: false
    params:
      manifest_path: "$SHARD_MANIFEST"
      suite: $SUITE
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      send_wrist_image: true
      send_state: true
      quat_no_antipodal: true
      absolute_action: false
EOF
else
cat > "$BENCH" <<EOF
server:
  url: "ws://localhost:8000"
  timeout: 300
output_dir: "$RUN/results"
benchmarks:
  - benchmark: "v2_tools.libero_plus_selected_v3:SelectedLIBEROPlusBenchmarkV3"
    episodes_per_task: 1
    recording:
      record_video: false
    params:
      manifest_path: "$SHARD_MANIFEST"
      suite: $SUITE
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      send_wrist_image: true
      send_state: true
EOF
fi

set +e
timeout --signal=TERM --kill-after=60 14400 \
  "$LP_VLA" run --no-docker --config "$BENCH" \
  --eval-id "${RUN_TAG}-${SYSTEM}-${SUITE}-s${SHARD_ID}of${SHARD_COUNT}" \
  >"$RUN/logs/rollout.log" 2>&1
ROLLOUT_RC=$?
set -e
echo "ROLLOUT_RC=$ROLLOUT_RC"

# Stop the exact server started by this worker.
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

if [ "$ROLLOUT_RC" -ne 0 ]; then
  tail -180 "$RUN/logs/rollout.log" || true
fi

# ------------------------------------------------------------------
# Scientific response audit. `success` and `fail` are both valid outcomes;
# anything else is an engineering error and must be repaired, not scored zero.
# ------------------------------------------------------------------

SQLITE="$(find "$RUN/results" -maxdepth 2 -type f -name 'recording-*.sqlite' | head -1 || true)"
AUDIT_RC=0

if [ -z "$SQLITE" ] || [ ! -s "$SQLITE" ]; then
  echo "RESULT_SQLITE_MISSING=YES"
  AUDIT_RC=71
else
  set +e
  "$LP_PY" - "$SQLITE" "$EXPECTED_N" "$RUN/response_audit.json" <<'PY'
import json,sqlite3,sys
db,expected,out=sys.argv[1],int(sys.argv[2]),sys.argv[3]
con=sqlite3.connect(db)
rows=con.execute(
    "select task_name,status,steps,failure_reason,failure_detail,context "
    "from episode_results order by rowid"
).fetchall()
con.close()

errors=[]
counts={}
for i,(task,status,steps,reason,detail,context) in enumerate(rows):
    counts[status]=counts.get(status,0)+1
    if status not in ("success","fail"):
        errors.append({
            "row":i, "task_name":task, "status":status, "steps":steps,
            "failure_reason":reason, "failure_detail":detail, "context":context,
        })

body={
    "expected":expected,
    "observed":len(rows),
    "status_counts":counts,
    "engineering_errors":errors,
}
open(out,"w").write(json.dumps(body,indent=2,ensure_ascii=False)+"\n")
print("OBSERVED_N="+str(len(rows)))
print("STATUS_COUNTS="+json.dumps(counts,sort_keys=True))
print("ENGINEERING_ERRORS="+str(len(errors)))
assert len(rows)==expected,(len(rows),expected)
assert not errors,errors
PY
  AUDIT_RC=$?
  set -e
fi
echo "AUDIT_RC=$AUDIT_RC"

# ------------------------------------------------------------------
# FIRST persist to shared /data. This survives even if GitHub persistence
# later fails, so scientific rollouts cannot be lost due to a git/network issue.
# ------------------------------------------------------------------

echo
echo "===== PERSIST TO SHARED /data ====="
rm -rf "$PERSIST"
mkdir -p "$PERSIST"

cp "$SHARD_MANIFEST" "$PERSIST/"
cp "$BENCH" "$PERSIST/"
cp "$RUN/server_config.yaml" "$PERSIST/"
cp -a "$RUN/logs" "$PERSIST/"
cp -a "$RUN/results" "$PERSIST/"
if [ -s "$RUN/response_audit.json" ]; then
  cp "$RUN/response_audit.json" "$PERSIST/"
fi

cat > "$PERSIST/summary.env" <<EOF
SYSTEM=$SYSTEM
FAMILY=$FAMILY
SUITE=$SUITE
SHARD_ID=$SHARD_ID
SHARD_COUNT=$SHARD_COUNT
EXPECTED_N=$EXPECTED_N
ROLLOUT_RC=$ROLLOUT_RC
AUDIT_RC=$AUDIT_RC
GPU=A100
MAIN_COMMIT=$MAIN_COMMIT
HARNESS_COMMIT_PROVENANCE=$HARNESS_COMMIT_PROVENANCE
FROZEN_MANIFEST_SHA=$D500_SHA
V3_WRAPPER_SHA=$WRAPPER_SHA
QUALIFICATION_JOB=$QUAL_JOB
CLEAN_3WAY_QUALIFICATION=PASS
CLEAN_3WAY_QUALIFICATION_OUTPUT=$QUAL3WAY_OUTPUT
RUNTIME_SOURCE=PERSISTENT_/data
FRESH_RUNTIME_CLONE=NO
EOF

(
  cd "$PERSIST"
  find . -type f ! -name SHA256SUMS.txt -print0 | sort -z | xargs -0 sha256sum
) > "$PERSIST/SHA256SUMS.txt"

echo "SHARED_PERSIST=PASS"
echo "SHARED_PATH=$PERSIST"

# ------------------------------------------------------------------
# SECOND persist to unique Git branch. Clone occurs only after /data persistence.
# ------------------------------------------------------------------

GIT_PERSIST_RC=0
if [ -z "${GIT_TOKEN:-}" ]; then
  echo "GIT_PERSIST=SKIP_TOKEN_MISSING"
  GIT_PERSIST_RC=80
else
  GITDIR="$BASE/git-persist"
  ASKPASS="$(mktemp)"
  cat > "$ASKPASS" <<'EOF'
#!/bin/sh
case "$1" in
  *Username*) printf '%s\n' "bhpark91" ;;
  *Password*) printf '%s\n' "$GIT_TOKEN" ;;
  *) exit 1 ;;
esac
EOF
  chmod 700 "$ASKPASS"
  export GIT_ASKPASS="$ASKPASS"
  export GIT_TERMINAL_PROMPT=0

  set +e
  git clone -q https://github.com/bhpark91/vla-irt-cat-v2.git "$GITDIR"
  GRC=$?
  if [ "$GRC" -eq 0 ]; then
    git -C "$GITDIR" checkout -q "$MAIN_COMMIT"
    git -C "$GITDIR" checkout -q -b "$RESULT_BRANCH"
    DEST="holdout_results/${RUN_TAG}/${SYSTEM}/${SUITE}/s${SHARD_ID}of${SHARD_COUNT}"
    mkdir -p "$GITDIR/$DEST"
    cp -a "$PERSIST/." "$GITDIR/$DEST/"
    git -C "$GITDIR" add -f -- "$DEST"
    git -C "$GITDIR" \
      -c user.name="VLA IRT D500 Bot" \
      -c user.email="vla-irt-d500@invalid.local" \
      commit -q -m "Holdout D500 v2 shard $SYSTEM $SUITE s${SHARD_ID}of${SHARD_COUNT}"
    git -C "$GITDIR" push -q origin "$RESULT_BRANCH"
    GRC=$?
  fi
  set -e

  rm -f "$ASKPASS"

  if [ "$GRC" -eq 0 ]; then
    echo "GIT_PERSIST=PASS"
  else
    echo "GIT_PERSIST=FAIL_RC_$GRC"
    GIT_PERSIST_RC="$GRC"
  fi
fi

# Scientific validity decides whether the VESSL job succeeds.
if [ "$ROLLOUT_RC" -ne 0 ]; then
  echo "GATE=FAIL_ROLLOUT"
  exit "$ROLLOUT_RC"
fi
if [ "$AUDIT_RC" -ne 0 ]; then
  echo "GATE=FAIL_ENGINEERING_AUDIT"
  exit "$AUDIT_RC"
fi

echo
echo "===== CHATGPT_SUMMARY ====="
echo "TASK=D500_PROSPECTIVE_HOLDOUT_V2_SHARD"
echo "GATE=PASS"
echo "SYSTEM=$SYSTEM"
echo "FAMILY=$FAMILY"
echo "SUITE=$SUITE"
echo "SHARD=$SHARD_ID/$SHARD_COUNT"
echo "EXPECTED_N=$EXPECTED_N"
echo "ROLLOUT_RC=0"
echo "AUDIT_RC=0"
echo "ENGINEERING_ERRORS=0"
echo "SHARED_PERSIST=PASS"
echo "GIT_PERSIST_RC=$GIT_PERSIST_RC"
echo "RESULT_BRANCH=$RESULT_BRANCH"
echo "NEXT=COLLECT_AFTER_ALL_60_SHARDS"
echo "==========================="
