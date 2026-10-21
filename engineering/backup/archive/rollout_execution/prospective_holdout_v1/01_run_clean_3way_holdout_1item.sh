#!/usr/bin/env bash
set -Eeuo pipefail
exec 2>&1

ROOT="/data/vla-irt-cat-v2"
HARNESS="$ROOT/external/vla-evaluation-harness"
LP_PY="$ROOT/envs/libero-plus-v2/bin/python"
LP_VLA="$ROOT/envs/libero-plus-v2/bin/vla-eval"
MANIFEST="$ROOT/manifests/discovery_500_primary.json"
BASE="/scratch/holdout-clean-3way-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BASE"

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

echo "============================================================"
echo " CLEAN HOLDOUT 3-WAY 1-ITEM QUALIFICATION"
echo "============================================================"
echo "Systems: pi05, pi0_fast, vlanext"
echo "GPU: existing persistent A100"
echo "New GPU jobs: 0"
echo "============================================================"

kill_port () {
  echo "CLEAR_PORT_8000_BEGIN"

  # Kill only processes that are actually LISTENING on TCP/8000.
  PIDS="$(
    ss -ltnp 2>/dev/null \
      | grep -E '(^|[[:space:]])[^[:space:]]*:8000[[:space:]]' \
      | grep -oE 'pid=[0-9]+' \
      | cut -d= -f2 \
      | sort -u \
      | tr '\n' ' ' \
      || true
  )"

  echo "PORT_8000_PIDS=${PIDS:-none}"

  if [ -n "${PIDS:-}" ]; then
    kill $PIDS 2>/dev/null || true
    sleep 3
  fi

  if ss -ltnp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:8000[[:space:]]' >/dev/null; then
    echo "PORT_8000_STILL_LISTENING=YES"
    ss -ltnp 2>/dev/null | grep ':8000' || true

    PIDS2="$(
      ss -ltnp 2>/dev/null \
        | grep -E '(^|[[:space:]])[^[:space:]]*:8000[[:space:]]' \
        | grep -oE 'pid=[0-9]+' \
        | cut -d= -f2 \
        | sort -u \
        | tr '\n' ' ' \
        || true
    )"
    if [ -n "${PIDS2:-}" ]; then
      kill -9 $PIDS2 2>/dev/null || true
      sleep 2
    fi
  fi

  if ss -ltnp 2>/dev/null | grep -E '(^|[[:space:]])[^[:space:]]*:8000[[:space:]]' >/dev/null; then
    echo "ERROR=PORT_8000_STILL_IN_USE"
    ss -ltnp 2>/dev/null | grep ':8000' || true
    exit 40
  fi

  echo "CLEAR_PORT_8000=PASS"
}

make_item () {
  local suite="$1"
  local out="$2"
  "$LP_PY" - "$MANIFEST" "$suite" "$out" <<'PY'
import json,sys
src,suite,dst=sys.argv[1:]
obj=json.load(open(src))
items=sorted([x for x in obj["items"] if x["suite"]==suite],
             key=lambda x:int(x["discovery_index"]))
assert items
o=dict(obj); o["items"]=[items[0]]
json.dump(o,open(dst,"w"),indent=2)
x=items[0]
print("DISCOVERY_INDEX="+str(x["discovery_index"]))
print("LANGUAGE="+x.get("language",""))
PY
}

wait_server () {
  local pid="$1"
  local log="$2"
  local ready=0
  for I in $(seq 1 360); do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "SERVER_PROCESS_DIED"
      tail -120 "$log" || true
      return 50
    fi
    set +e
    H="$(python3 - <<'PY' 2>/dev/null
import urllib.request
try:
    r=urllib.request.urlopen("http://127.0.0.1:8000/health",timeout=2)
    print(getattr(r,"status",200))
except Exception:
    raise SystemExit(1)
PY
)"
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && [ "$H" = "200" ]; then
      ready=1; break
    fi
    if [ $((I % 12)) -eq 0 ]; then
      echo "WAIT_SERVER=$I/360"
      tail -8 "$log" || true
    fi
    sleep 5
  done
  test "$ready" = 1
  ss -ltnp | grep ':8000 ' || true
  echo "SERVER_HEALTH=PASS"
}

run_one () {
  local system="$1"
  local suite="$2"
  local cfg="$3"
  local extra="$4"
  local run="$BASE/$system"
  mkdir -p "$run"/{logs,results}
  local one="$run/one_item.json"
  make_item "$suite" "$one"

  echo
  echo "============================================================"
  echo " SYSTEM=$system"
  echo " SUITE=$suite"
  echo " CFG=$cfg"
  echo "============================================================"

  kill_port

  cd "$HARNESS"
  if [ "$system" = "pi05" ] || [ "$system" = "pi0_fast" ]; then
    env PYTHONPATH="$HARNESS/src" \
      PYTHONSAFEPATH=1 \
      XLA_PYTHON_CLIENT_PREALLOCATE=false \
      "$LP_VLA" serve -c "$cfg" --verbose \
      >"$run/logs/server.log" 2>&1 &
  else
    env PYTHONPATH="$HARNESS/src" \
      "$LP_VLA" serve -c "$cfg" --verbose \
      >"$run/logs/server.log" 2>&1 &
  fi
  local spid=$!
  echo "SERVER_PID=$spid"

  wait_server "$spid" "$run/logs/server.log"

  # Verify the newly launched parent is still alive after health succeeded.
  kill -0 "$spid"
  echo "NEW_SERVER_PROCESS_ALIVE=PASS"

  local bench="$run/benchmark.yaml"
  cat > "$bench" <<EOF
server:
  url: "ws://localhost:8000"
  timeout: 300
output_dir: "$run/results"
benchmarks:
  - benchmark: "v2_tools.libero_plus_selected_v3:SelectedLIBEROPlusBenchmarkV3"
    episodes_per_task: 1
    recording:
      record_video: false
    params:
      manifest_path: "$one"
      suite: $suite
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      send_wrist_image: true
      send_state: true
$extra
EOF

  set +e
  timeout --signal=TERM --kill-after=60 1800 \
    "$LP_VLA" run --no-docker --config "$bench" \
    --eval-id "holdout-clean-${system}-1item" \
    >"$run/logs/rollout.log" 2>&1
  local rc=$?
  set -e
  echo "ROLLOUT_RC=$rc"
  tail -60 "$run/logs/rollout.log" || true

  local sqlite
  sqlite="$(find "$run/results" -maxdepth 2 -type f -name 'recording-*.sqlite' | head -1 || true)"
  test -n "$sqlite"
  "$LP_PY" - "$sqlite" <<'PY'
import sqlite3,sys,json
db=sys.argv[1]
c=sqlite3.connect(db)
r=c.execute("select task_name,status,steps,failure_reason,failure_detail,context from episode_results order by rowid").fetchall()
c.close()
print("ROWS="+str(len(r)))
for x in r:
    print("ROW="+json.dumps({"task_name":x[0],"status":x[1],"steps":x[2],
                            "failure_reason":x[3],"failure_detail":x[4],
                            "context":x[5]},ensure_ascii=False))
assert len(r)==1
assert r[0][1] in ("success","fail")
PY

  if [ "$rc" -ne 0 ]; then
    echo "GATE=$system:FAIL"
    tail -120 "$run/logs/server.log" || true
    exit "$rc"
  fi

  echo "GATE=$system:PASS"

  # Kill parent and any children that may have survived.
  kill "$spid" 2>/dev/null || true
  sleep 2
  kill_port
}

run_one \
  pi05 \
  libero_spatial \
  "$HARNESS/configs/model_servers/pi0/libero.yaml" \
  ""

run_one \
  pi0_fast \
  libero_spatial \
  "$HARNESS/configs/model_servers/pi0/libero_fast.yaml" \
  ""

run_one \
  vlanext \
  libero_spatial \
  "$HARNESS/configs/model_servers/vlanext/libero_spatial.yaml" \
  "      quat_no_antipodal: true
      absolute_action: false"

echo
echo "===== CHATGPT_SUMMARY ====="
echo "TASK=CLEAN_3WAY_HOLDOUT_1ITEM_QUALIFICATION"
echo "GATE=PASS"
echo "PI05=PASS"
echo "PI0_FAST=PASS"
echo "VLANEXT=PASS"
echo "GPU=A100x1_PERSISTENT"
echo "GPU_JOBS_CREATED=0"
echo "OUTPUT=$BASE"
echo "NEXT=PATCH_PRODUCTION_WORKER_WITH_RUNTIME_RESTORE_AND_NO_FRESH_CLONES"
echo "==========================="
