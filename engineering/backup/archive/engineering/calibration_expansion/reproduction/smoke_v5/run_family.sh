#!/usr/bin/env bash
set -u
set -o pipefail

FAMILY="$1"
CFG="$2"
RUN_TAG="$3"

BASE="/scratch/calexp"
OLD="/data/vla-irt-cat-v2"
REPO="$BASE/repo"
HARNESS="$BASE/external/vla-evaluation-harness"
OVER="$REPO/integrations/vla_eval_overlay"
BUNDLE="$BASE/gpu-smoke-v2/$RUN_TAG"

RUNDIR="$BUNDLE/$FAMILY"
LOCAL="$BUNDLE/runtime/$FAMILY"
ENV="$LOCAL/env"
SUMMARY="$RUNDIR/summary.env"

mkdir -p "$RUNDIR"/{results,logs}
rm -rf "$LOCAL"
mkdir -p "$LOCAL"

STAGE="startup"
SERVER_PID=""

export UV_CACHE_DIR="$BASE/cache/uv"
export UV_LINK_MODE=copy
# Batch image carries a historical uv cutoff. Disable it explicitly.
export UV_EXCLUDE_NEWER=false
# Also ignore image/user uv.toml / pyproject uv configuration.
export UV_NO_CONFIG=1

export HF_HOME="$BASE/cache/hf"
export HUGGINGFACE_HUB_CACHE="$BASE/cache/hf/hub"
export TRANSFORMERS_CACHE="$BASE/cache/hf/hub"
export TORCH_HOME="$BASE/cache/torch"
export XDG_CACHE_HOME="$BASE/cache/xdg"

export HF_HUB_DISABLE_TELEMETRY=1
export TOKENIZERS_PARALLELISM=false
export PYTHONDONTWRITEBYTECODE=1

export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export NUMEXPR_NUM_THREADS=1

export CAL_OVER="$OVER"
export CAL_REPO="$REPO"
export CAL_HARNESS="$HARNESS"

write_fail () {
    RC="$1"

    {
      echo "FAMILY=$FAMILY"
      echo "ENGINEERING_SMOKE=FAIL"
      echo "FAIL_STAGE=$STAGE"
      echo "RC=$RC"
      echo "TASK_SUCCESS_USED=false"
      echo "DISCOVERY500_OUTCOME_USED=false"
      echo "QUAL24_OUTCOME_USED=false"
    } > "$SUMMARY"

    echo "FAMILY=$FAMILY"
    echo "ENGINEERING_SMOKE=FAIL"
    echo "FAIL_STAGE=$STAGE"
    echo "RC=$RC"
}

cleanup () {
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "FAMILY=$FAMILY"
echo "GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

# ------------------------------------------------------------
# Fresh Batch-local environment.  Never execute Workspace venv.
# ------------------------------------------------------------

STAGE="prepare_runtime"

if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh \
      > "$RUNDIR/logs/uv-install.sh" || {
        write_fail 40
        exit 40
      }

    sh "$RUNDIR/logs/uv-install.sh" \
      >> "$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 41
        exit 41
      }

    export PATH="$HOME/.local/bin:$PATH"
fi

case "$FAMILY" in

vla_adapter)
    SRC="$BASE/external/VLA-Adapter"
    PYVER="3.10.16"

    uv venv --clear --python "$PYVER" "$ENV" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 42; exit 42;
      }

    uv pip install --python "$ENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cu121 \
      torch==2.2.0+cu121 torchvision==0.17.0+cu121 torchaudio==2.2.0+cu121 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 43; exit 43;
      }

    uv pip install --python "$ENV/bin/python" \
      -e "$HARNESS" -e "$SRC" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 44; exit 44;
      }

    uv pip install --python "$ENV/bin/python" \
      --no-deps tensorflow-metadata==1.15.0 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 45; exit 45;
      }

    uv pip install --python "$ENV/bin/python" msgpack-numpy \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 46; exit 46;
      }

    WRIST=true
    STATE=true
    PP="$OVER/src:$SRC:$HARNESS/src:$REPO"
    ;;

xiaomi)
    SRC="$BASE/external/Xiaomi-Robotics-0"
    PYVER="3.12"

    uv venv --clear --python "$PYVER" "$ENV" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 42; exit 42;
      }

    uv pip install --python "$ENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cu128 \
      torch==2.8.0+cu128 torchvision==0.23.0+cu128 torchaudio==2.8.0+cu128 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 43; exit 43;
      }

    uv pip install --python "$ENV/bin/python" \
      -e "$HARNESS" \
      transformers==4.57.1 accelerate pillow sentencepiece protobuf \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 44; exit 44;
      }

    echo "STEP=xiaomi_flash_attn"

    apt-get update -qq \
      >>"$RUNDIR/logs/install.log" 2>&1 || true

    DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
      libegl1 libgl1 libgles2 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 47
        exit 47
      }

    XABI="$("$ENV/bin/python" - <<'PYABI'
import torch
print("TRUE" if torch._C._GLIBCXX_USE_CXX11_ABI else "FALSE")
PYABI
)"

    XWHEEL="https://github.com/Dao-AILab/flash-attention/releases/download/v2.8.3/flash_attn-2.8.3%2Bcu12torch2.8cxx11abi${XABI}-cp312-cp312-linux_x86_64.whl"

    UV_NO_CONFIG=1 UV_EXCLUDE_NEWER=false \
    uv pip install \
      --python "$ENV/bin/python" \
      --no-deps \
      "$XWHEEL" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 48
        exit 48
      }

    "$ENV/bin/python" - >>"$RUNDIR/logs/install.log" 2>&1 <<'PYFA'
import torch, flash_attn
print("CUDA_VISIBLE=" + str(torch.cuda.is_available()))
print("FLASH_ATTN=" + flash_attn.__version__)
assert torch.cuda.is_available()
assert flash_attn.__version__ == "2.8.3"
PYFA
    FA_RC=$?
    if [ "$FA_RC" -ne 0 ]; then
        write_fail 49
        exit 49
    fi

    echo "STEP=xiaomi_einops"

    UV_NO_CONFIG=1 UV_EXCLUDE_NEWER=false \
    uv pip install \
      --python "$ENV/bin/python" \
      einops packaging \
      >>"$RUNDIR/logs/install.log" 2>&1

    EINOPS_RC=$?

    if [ "$EINOPS_RC" -ne 0 ]; then
        write_fail 53
        exit 53
    fi

    WRIST=true
    STATE=true
    PP="$OVER/src:$SRC:$HARNESS/src:$REPO"
    ;;

univla)
    SRC="$BUNDLE/univla-src"
    PYVER="3.10.16"

    apt-get update -qq \
      >>"$RUNDIR/logs/install.log" 2>&1 || true

    DEBIAN_FRONTEND=noninteractive \
      apt-get install -y -qq libgl1 libglib2.0-0 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 47; exit 47;
      }

    uv venv --clear --python "$PYVER" "$ENV" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 42; exit 42;
      }

    uv pip install --python "$ENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cu121 \
      torch==2.2.0+cu121 torchvision==0.17.0+cu121 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 43; exit 43;
      }

    uv pip install --python "$ENV/bin/python" \
      -e "$HARNESS" -e "$SRC" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 44; exit 44;
      }

    uv pip install --python "$ENV/bin/python" \
      --no-deps tensorflow-metadata==1.15.0 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 45; exit 45;
      }

    uv pip install --python "$ENV/bin/python" \
      braceexpand webdataset==0.2.111 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 46; exit 46;
      }

    echo "STEP=univla_flash_attn"

    UABI="$("$ENV/bin/python" - <<'PYABI'
import torch
print("TRUE" if torch._C._GLIBCXX_USE_CXX11_ABI else "FALSE")
PYABI
)"

    UWHEEL="https://github.com/Dao-AILab/flash-attention/releases/download/v2.5.5/flash_attn-2.5.5%2Bcu122torch2.2cxx11abi${UABI}-cp310-cp310-linux_x86_64.whl"

    UV_NO_CONFIG=1 UV_EXCLUDE_NEWER=false \
    uv pip install \
      --python "$ENV/bin/python" \
      --no-deps \
      "$UWHEEL" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 48
        exit 48
      }

    "$ENV/bin/python" - >>"$RUNDIR/logs/install.log" 2>&1 <<'PYFA'
import torch, flash_attn
print("CUDA_VISIBLE=" + str(torch.cuda.is_available()))
print("FLASH_ATTN=" + flash_attn.__version__)
assert torch.cuda.is_available()
assert flash_attn.__version__ == "2.5.5"
PYFA
    FA_RC=$?
    if [ "$FA_RC" -ne 0 ]; then
        write_fail 49
        exit 49
    fi

    WRIST=false
    STATE=false
    PP="$OVER/src:$SRC:$HARNESS/src:$REPO"
    ;;

lingbot)
    PYVER="3.12"

    uv venv --clear --python "$PYVER" "$ENV" \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 42; exit 42;
      }

    uv pip install --python "$ENV/bin/python" \
      --index-url https://download.pytorch.org/whl/cu126 \
      torch==2.9.0+cu126 torchvision==0.24.0+cu126 torchaudio==2.9.0+cu126 \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 43; exit 43;
      }

    uv pip install --python "$ENV/bin/python" \
      -e "$HARNESS" \
      'lerobot[lingbot_va] @ git+https://github.com/huggingface/lerobot.git@v0.6.0' \
      >>"$RUNDIR/logs/install.log" 2>&1 || {
        write_fail 44; exit 44;
      }

    WRIST=true
    STATE=false
    PP="$HARNESS/src:$REPO"
    ;;

*)
    STAGE="family_dispatch"
    write_fail 39
    exit 39
    ;;
esac

uv pip freeze --python "$ENV/bin/python" \
  > "$RUNDIR/runtime-freeze.txt" 2>/dev/null

sha256sum "$RUNDIR/runtime-freeze.txt" \
  | awk '{print $1}' \
  > "$RUNDIR/runtime-freeze.sha256"

echo "RUNTIME_ENV=READY"

# ------------------------------------------------------------
# Start actual model server.
# ------------------------------------------------------------

STAGE="model_server_start"

env \
  PYTHONPATH="$PP" \
  "$ENV/bin/python" \
  "$BUNDLE/serve_prebuilt.py" \
  "$CFG" \
  >"$RUNDIR/logs/server.log" 2>&1 &

SERVER_PID=$!

STAGE="wait_server_health"
READY=0

for I in $(seq 1 540); do

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "SERVER_PROCESS_DIED=true"
        tail -12 "$RUNDIR/logs/server.log" 2>/dev/null || true
        write_fail 50
        exit 50
    fi

    python3 - <<'PY' >/dev/null 2>&1
import urllib.request
r = urllib.request.urlopen("http://127.0.0.1:8000/health", timeout=2)
raise SystemExit(0 if getattr(r, "status", 200) == 200 else 1)
PY

    if [ "$?" -eq 0 ]; then
        READY=1
        break
    fi

    sleep 5
done

if [ "$READY" -ne 1 ]; then
    echo "SERVER_HEALTH_TIMEOUT=true"
    tail -12 "$RUNDIR/logs/server.log" 2>/dev/null || true
    write_fail 51
    exit 51
fi

echo "SERVER_HEALTH=PASS"

# ------------------------------------------------------------
# Canonical one-step LIBERO-10 engineering smoke.
# No task success/reward is used for qualification.
# ------------------------------------------------------------

BENCH="$RUNDIR/benchmark.yaml"

cat > "$BENCH" <<EOF
server:
  url: "ws://localhost:8000"

output_dir: "$RUNDIR/results"

benchmarks:
  - benchmark: "vla_eval.benchmarks.libero.benchmark:LIBEROBenchmark"
    episodes_per_task: 1
    max_tasks: 1
    recording:
      record_video: false
    params:
      suite: libero_10
      seed: 7
      env_seed: 7
      num_steps_wait: 10
      max_steps: 1
      send_wrist_image: $WRIST
      send_state: $STATE
EOF

STAGE="benchmark_runtime_check"

conda run --no-capture-output -n libero python -c \
  'import libero, vla_eval; print("LIBERO_BENCH_ENV=PASS")' \
  >>"$RUNDIR/logs/rollout.log" 2>&1

BENCH_RC=$?

if [ "$BENCH_RC" -ne 0 ]; then
    write_fail 52
    exit 52
fi

STAGE="one_step_inference"

export VLA_EVAL_WATCHDOG_TIMEOUT_S=900

set +e
timeout --signal=TERM --kill-after=30 900 \
  conda run --no-capture-output -n libero vla-eval run \
    --no-docker \
    --config "$BENCH" \
    --eval-id "${RUN_TAG}-${FAMILY}" \
  >"$RUNDIR/logs/rollout.log" 2>&1

ROLL_RC=$?
set -e 2>/dev/null || true

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

if [ "$ROLL_RC" -ne 0 ]; then
    echo "ROLL_RC=$ROLL_RC"
    tail -12 "$RUNDIR/logs/rollout.log" 2>/dev/null || true
    write_fail "$ROLL_RC"
    exit "$ROLL_RC"
fi

# Run success with max_steps=1 requires one valid model response/action.
if ! grep -qE 'Connected to ws://(localhost|127\.0\.0\.1):8000' \
        "$RUNDIR/logs/rollout.log"; then
    STAGE="connection_audit"
    tail -12 "$RUNDIR/logs/rollout.log" 2>/dev/null || true
    write_fail 60
    exit 60
fi

FREEZE_SHA="$(cat "$RUNDIR/runtime-freeze.sha256")"

{
  echo "FAMILY=$FAMILY"
  echo "ENGINEERING_SMOKE=PASS"
  echo "SERVER_HEALTH=PASS"
  echo "INFERENCE_ONE_STEP=PASS"
  echo "SUITE=libero_10"
  echo "TASK_INDEX=0"
  echo "SEED=7"
  echo "MAX_STEPS=1"
  echo "RUNTIME_FREEZE_SHA=$FREEZE_SHA"
  echo "TASK_SUCCESS_USED=false"
  echo "DISCOVERY500_OUTCOME_USED=false"
  echo "QUAL24_OUTCOME_USED=false"
} > "$SUMMARY"

echo "ENGINEERING_SMOKE=PASS"
echo "INFERENCE_ONE_STEP=PASS"
echo "RUNTIME_FREEZE_SHA=$FREEZE_SHA"
exit 0
