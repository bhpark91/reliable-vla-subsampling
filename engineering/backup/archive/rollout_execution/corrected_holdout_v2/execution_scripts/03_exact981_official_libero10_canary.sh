#!/usr/bin/env bash
set -Eeuo pipefail

: "${VLA_IRT_ARTIFACT_ROOT:?Set VLA_IRT_ARTIFACT_ROOT to the directory that contains the archived D500 artifact directories}"
HERE="$VLA_IRT_ARTIFACT_ROOT"
SSH_HOST="${SSH_HOST:-YOUR_SSH_HOST.invalid}"
SSH_PORT="${SSH_PORT:-YOUR_SSH_PORT}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/YOUR_KEY.pem}"

RATE=1.55
HARD_CAP_H=1.5
MAX_BURN=2.33

echo "============================================================"
echo " EXACT-981 OFFICIAL LIBERO-10 CANARY — WORKSPACE"
echo "============================================================"
echo "New VESSL jobs:          0"
echo "Workspace:               existing A100 x1 (kept running)"
echo "Official server:         OpenPI websocket_policy_server"
echo "Official client:         OpenPI examples/libero/main.py"
echo "Evaluation:              libero_10, 10 tasks x 1 episode"
echo "OpenPI pin:              981483dca0fd9acba698fea00aa6e52d56a66c58"
echo "Correction:              PR#971 z-score compatibility only"
echo "Hard execution cap:      ${HARD_CAP_H} h"
echo "Incremental max burn:    ~\$${MAX_BURN} at \$${RATE}/h"
echo "Workspace pause/stop:    NEVER"
echo "Research result writes:  runtime log only"
echo "============================================================"
read -rp "Proceed? [y/N] " OK
[[ "${OK,,}" == "y" ]] || { echo "ABORTED"; exit 0; }

test -s "$SSH_KEY" || { echo "ERROR=SSH_KEY_MISSING:$SSH_KEY"; exit 2; }

echo
echo "===== 1. SSH GATE ====="
ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=15 \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  "root@$SSH_HOST" \
  'echo SSH_GATE=PASS'

REMOTE="$(mktemp)"
cat > "$REMOTE" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 2>&1

ROOT=/data/vla-irt-cat-v2
EXACT=$ROOT/external/openpi-pi0fast-zscore-holdoutpin
EXACT_ENV=$ROOT/envs/openpi-pi0fast-zscore-exact981
LP_ENV=$ROOT/envs/libero-plus-v2
LP_PY=$LP_ENV/bin/python
OPENPI_CACHE=$ROOT/cache/openpi-pi0fast-zscore-data
HF_HOME_PERSIST=$ROOT/cache/huggingface
OUT=$ROOT/runtime/pi0fast-zscore/exact981-official-libero10-workspace-20260829

OPENPI_COMMIT=981483dca0fd9acba698fea00aa6e52d56a66c58

rm -rf "$OUT"
mkdir -p "$OUT/videos"

echo "===== A. VERIFY EXACT SOURCE ====="
test -d "$EXACT/.git"
test -x "$EXACT_ENV/bin/python"
test -x "$LP_PY"
test "$(git -C "$EXACT" rev-parse HEAD)" = "$OPENPI_COMMIT"
echo "OPENPI_HEAD=$(git -C "$EXACT" rev-parse HEAD)"

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

SERVER_PYTHONPATH="$EXACT/src:$EXACT/packages/openpi-client/src"
CLIENT_PYTHONPATH="$EXACT/packages/openpi-client/src:$EXACT/third_party/libero:$ROOT"

echo
echo "===== B. NORMALIZATION GATE ====="
PYTHONPATH="$SERVER_PYTHONPATH" "$EXACT_ENV/bin/python" - <<'PY'
import openpi.training.config as c
cfg=c.get_config("pi0_fast_libero")
dcfg=cfg.data.create(cfg.assets_dirs,cfg.model)
print("USE_QUANTILE_NORM="+str(dcfg.use_quantile_norm))
assert dcfg.use_quantile_norm is False
print("NORMALIZATION_GATE=PASS_ZSCORE")
PY

echo
echo "===== C. CLIENT IMPORT PREFLIGHT ====="
PYTHONPATH="$CLIENT_PYTHONPATH" "$LP_PY" - "$EXACT/examples/libero/main.py" <<'PY'
import importlib.util,sys,types
sys.modules["tyro"]=types.ModuleType("tyro")
spec=importlib.util.spec_from_file_location("official_libero_main",sys.argv[1])
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert callable(m.eval_libero)
print("OFFICIAL_CLIENT_IMPORT=PASS")
PY

echo
echo "===== D. CLEAR WORKSPACE PORT 8000 ONLY ====="
if command -v fuser >/dev/null 2>&1; then
  fuser -k 8000/tcp 2>/dev/null || true
fi
sleep 2

echo
echo "===== E. START OFFICIAL OPENPI WEBSOCKET SERVER ====="
cd "$EXACT"
PYTHONPATH="$SERVER_PYTHONPATH" \
"$EXACT_ENV/bin/python" "$EXACT/scripts/serve_policy.py" \
  --env LIBERO \
  --port 8000 \
  policy:checkpoint \
  --policy.config pi0_fast_libero \
  --policy.dir gs://openpi-assets/checkpoints/pi0_fast_libero \
  > "$OUT/server.log" 2>&1 &
SERVER_PID=$!
echo "SERVER_PID=$SERVER_PID"

cleanup() {
  set +e
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

READY=0
for I in $(seq 1 180); do
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "OFFICIAL_SERVER_DIED"
    tail -240 "$OUT/server.log" || true
    exit 50
  fi

  set +e
  H="$(
    python3 - <<'PY' 2>/dev/null
import urllib.request
r=urllib.request.urlopen("http://127.0.0.1:8000/healthz",timeout=2)
print(getattr(r,"status",200))
PY
  )"
  RC=$?
  set -e

  if [ "$RC" -eq 0 ] && [ "$H" = "200" ]; then
    READY=1
    break
  fi

  if [ $((I % 6)) -eq 0 ]; then
    echo "WAIT_OFFICIAL_SERVER=$I/180"
    tail -12 "$OUT/server.log" || true
  fi
  sleep 5
done

test "$READY" = "1" || {
  echo "OFFICIAL_SERVER_READY=FAIL"
  tail -240 "$OUT/server.log" || true
  exit 51
}
echo "OFFICIAL_SERVER_HEALTHZ=PASS"

echo
echo "===== F. RUN OFFICIAL LIBERO_10 — LIVE OUTPUT ====="
echo "You should now see task/episode progress live."
echo

cd "$EXACT"
set +e
timeout --signal=TERM --kill-after=60 4800 \
  env PYTHONPATH="$CLIENT_PYTHONPATH" \
      PYOPENGL_PLATFORM=egl \
      EGL_PLATFORM=device \
      MUJOCO_GL=egl \
      "$LP_PY" - "$EXACT/examples/libero/main.py" "$OUT/videos" \
      2>&1 <<'PY' | tee "$OUT/client.log"
import importlib.util
import logging
import sys
import types

main_path=sys.argv[1]
video_path=sys.argv[2]

# Tyro is used only by main.py's __main__ CLI path; eval_libero itself
# does not depend on it.
sys.modules["tyro"]=types.ModuleType("tyro")

spec=importlib.util.spec_from_file_location("official_libero_main",main_path)
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

logging.basicConfig(level=logging.INFO,force=True)

args=m.Args(
    host="127.0.0.1",
    port=8000,
    resize_size=224,
    replan_steps=5,
    task_suite_name="libero_10",
    num_steps_wait=10,
    num_trials_per_task=1,
    video_out_path=video_path,
    seed=7,
)

print("OFFICIAL_FUNCTION=examples/libero/main.py::eval_libero",flush=True)
print("OFFICIAL_SUITE=libero_10",flush=True)
print("OFFICIAL_TRIALS_PER_TASK=1",flush=True)
m.eval_libero(args)
PY
CLIENT_RC=${PIPESTATUS[0]}
set -e

echo
echo "CLIENT_RC=$CLIENT_RC"
if [ "$CLIENT_RC" -ne 0 ]; then
  echo "OFFICIAL_CANARY_ENGINEERING_GATE=FAIL"
  echo "===== SERVER TAIL ====="
  tail -220 "$OUT/server.log" || true
  exit 60
fi

echo
echo "===== G. PARSE RESULT ====="
python3 - "$OUT/client.log" "$OUT/result.json" <<'PY'
import json,re,sys
text=open(sys.argv[1],encoding="utf-8",errors="replace").read()

rates=re.findall(r"Total success rate:\s*([0-9.]+)",text)
eps=re.findall(r"Total episodes:\s*(\d+)",text)
caught=len(re.findall(r"Caught exception:",text))

print("RATE_MATCHES="+str(rates))
print("EP_MATCHES="+str(eps))
if not rates or not eps:
    raise SystemExit("PARSE_FAIL")

rate=float(rates[-1])
episodes=int(eps[-1])

print(f"OFFICIAL_LIBERO10_RATE={rate:.6f}")
print(f"OFFICIAL_LIBERO10_PERCENT={100*rate:.1f}")
print(f"OFFICIAL_LIBERO10_EPISODES={episodes}")
print(f"OFFICIAL_CLIENT_EXCEPTIONS={caught}")

assert episodes==10,episodes
assert caught==0,caught

sanity="HEALTHY" if rate >= 0.40 else "SUSPECT"
print("OFFICIAL_CANARY_ENGINEERING_GATE=PASS")
print("OFFICIAL_CANARY_PERFORMANCE_SANITY="+sanity)

body={
    "openpi_pin":"981483dca0fd9acba698fea00aa6e52d56a66c58",
    "correction":"PR971 z-score compatibility backport only",
    "use_quantile_norm":False,
    "server":"OpenPI scripts/serve_policy.py / WebsocketPolicyServer",
    "client":"OpenPI examples/libero/main.py::eval_libero",
    "suite":"libero_10",
    "episodes":episodes,
    "success_rate":rate,
    "engineering_gate":"PASS",
    "performance_sanity":sanity,
    "sanity_threshold":0.40,
}
json.dump(body,open(sys.argv[2],"w"),indent=2)

if sanity!="HEALTHY":
    raise SystemExit(70)
PY

echo
echo "===== FINAL ====="
echo "EXACT981_OFFICIAL_CANARY_GATE=PASS"
echo "WORKSPACE_ACTION=LEFT_RUNNING"
REMOTE

echo
echo "===== 2. UPLOAD WORKSPACE CANARY ====="
scp \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -P "$SSH_PORT" \
  "$REMOTE" \
  "root@$SSH_HOST:/root/run_exact981_official_workspace_canary.sh"
rm -f "$REMOTE"

echo
echo "===== 3. EXECUTE — LIVE ====="
set +e
ssh -tt \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -p "$SSH_PORT" \
  "root@$SSH_HOST" \
  'chmod 700 /root/run_exact981_official_workspace_canary.sh && timeout --signal=TERM --kill-after=120 5400 bash /root/run_exact981_official_workspace_canary.sh'
RC=$?
set -e

echo
echo "REMOTE_RC=$RC"
if [ "$RC" -eq 0 ]; then
  echo "GATE=EXACT981_OFFICIAL_WORKSPACE_CANARY_PASS"
  echo "NEXT=PATCH_PAPER_WITH_VALIDATED_CORRECTED_RESULTS"
else
  echo "GATE=EXACT981_OFFICIAL_WORKSPACE_CANARY_NOT_VALIDATED"
  echo "NEXT=INSPECT_LIVE_FAILURE_OUTPUT"
fi
echo "WORKSPACE=LEFT_RUNNING"
exit "$RC"
