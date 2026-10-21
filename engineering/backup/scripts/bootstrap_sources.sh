#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DEST=${1:-"$REPO_ROOT/external"}

command -v git >/dev/null 2>&1 || {
  echo "git is required" >&2
  exit 127
}
mkdir -p "$DEST"

materialize() {
  name=$1
  url=$2
  revision=$3
  target="$DEST/$name"

  if [ -e "$target" ] && [ ! -d "$target/.git" ]; then
    echo "refusing to overwrite non-Git path: $target" >&2
    return 2
  fi
  if [ ! -d "$target/.git" ]; then
    git clone --filter=blob:none --no-checkout "$url" "$target"
  fi
  git -C "$target" fetch --depth 1 origin "$revision"
  git -C "$target" switch --detach FETCH_HEAD
  actual=$(git -C "$target" rev-parse HEAD)
  if [ "$actual" != "$revision" ]; then
    echo "revision mismatch for $name: $actual != $revision" >&2
    return 3
  fi
  printf '%-28s %s\n' "$name" "$actual"
}

materialize LIBERO-plus \
  https://github.com/sylvestf/LIBERO-plus.git \
  4976dc30028e805ff8094b55501d532c48fec182
materialize vla-evaluation-harness \
  https://github.com/allenai/vla-evaluation-harness.git \
  2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56
materialize openpi \
  https://github.com/Physical-Intelligence/openpi.git \
  981483dca0fd9acba698fea00aa6e52d56a66c58
materialize lerobot \
  https://github.com/huggingface/lerobot.git \
  0cf864870cf29f4738d3ade893e6fd13fbd7cdb5
materialize VLA-Adapter \
  https://github.com/OpenHelix-Team/VLA-Adapter.git \
  23fa0c9c159e2aa04341cdd3e924f44061311060
materialize Xiaomi-Robotics-0 \
  https://github.com/XiaomiRobotics/Xiaomi-Robotics-0.git \
  7c316604d43357d10b06d11fae4c39290c447da5
materialize UniVLA-OpenDriveLab \
  https://github.com/OpenDriveLab/UniVLA.git \
  0ab9e9dd3074ffa14fdd1a00aa2aa84e4f8e1352

echo "SOURCE_BOOTSTRAP=PASS"
echo "Model weights were not downloaded. See configs/study/final_registry.json."
echo "Next: ./scripts/install_harness_overlay.sh"
