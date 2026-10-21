#!/usr/bin/env bash
set -euo pipefail

ROOT=/data/vla-irt-cat-v2
export PATH="$ROOT/tools/uv:/usr/local/bin:$HOME/.local/bin:$PATH"

echo "===== RESTORE PYTHON ====="
uv python install 3.8.20

echo "===== RESTORE SYSTEM LIBRARIES ====="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  imagemagick libmagickwand-dev libmagickcore-dev \
  libxcb1 libx11-6 libx11-xcb1 libxext6 libxrender1 libsm6 \
  libglib2.0-0 libgl1 libegl1 libgles2 libosmesa6 libglfw3 \
  libglew2.2 libxrandr2 libxinerama1 libxcursor1 libxi6 \
  libxkbcommon0 ffmpeg
ldconfig

echo "===== RESTORE LIBERO CONFIG ====="
mkdir -p /root/.libero
if [ -s "$ROOT/home-libero-plus/.libero/config.yaml" ]; then
  cp "$ROOT/home-libero-plus/.libero/config.yaml" /root/.libero/config.yaml
elif [ -s "$ROOT/home-libero-plus/config.yaml" ]; then
  cp "$ROOT/home-libero-plus/config.yaml" /root/.libero/config.yaml
fi

echo "===== VERIFY ====="
export PYOPENGL_PLATFORM=egl
export EGL_PLATFORM=device
export MUJOCO_GL=egl
export PYTHONPATH="$ROOT:$ROOT/external/vla-evaluation-harness/src"

"$ROOT/envs/libero-plus-v2/bin/python" - <<'PY'
import cv2
from wand.image import Image
import robosuite
import libero
import vla_eval
from v2_tools.libero_plus_selected_v3 import SelectedLIBEROPlusBenchmarkV3
print("PYTHON_RUNTIME=PASS")
print("CV2=PASS")
print("ROBOSUITE=PASS")
print("LIBERO_PLUS=PASS")
print("VLA_EVAL=PASS")
PY
echo "RUNTIME_RESTORE=PASS"
