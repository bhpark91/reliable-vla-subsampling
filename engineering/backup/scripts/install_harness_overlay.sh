#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
HARNESS_DIR=${1:-"$REPO_ROOT/external/vla-evaluation-harness"}
MODEL_ROOT=${2:-${VLA_MODEL_ROOT:-"$REPO_ROOT/external/model-weights"}}
EXPECTED_HARNESS_REVISION=2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56

if [ ! -d "$HARNESS_DIR/.git" ]; then
  echo "missing harness checkout: $HARNESS_DIR" >&2
  echo "run ./scripts/bootstrap_sources.sh first" >&2
  exit 2
fi

actual_revision=$(git -C "$HARNESS_DIR" rev-parse HEAD)
if [ "$actual_revision" != "$EXPECTED_HARNESS_REVISION" ]; then
  echo "harness revision mismatch: $actual_revision != $EXPECTED_HARNESS_REVISION" >&2
  exit 3
fi

adapter_dest="$HARNESS_DIR/src/vla_eval/model_servers"
config_dest="$HARNESS_DIR/configs/model_servers"
if [ ! -d "$adapter_dest" ] || [ ! -d "$config_dest" ]; then
  echo "unexpected harness layout at $HARNESS_DIR" >&2
  exit 4
fi

for adapter in xiaomi_robotics_0 vla_adapter univla_opendrivelab; do
  cp "$REPO_ROOT/src/adapters/calibration_expansion/$adapter.py" \
    "$adapter_dest/$adapter.py"
done

python3 - "$REPO_ROOT" "$MODEL_ROOT" "$config_dest" <<'PY'
from __future__ import annotations

import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
model_root = Path(sys.argv[2]).resolve()
destination = Path(sys.argv[3]).resolve()
source_root = repo_root / "configs/models/calibration_expansion"

for source in sorted(source_root.glob("*/*.yaml")):
    relative = source.relative_to(source_root)
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    rendered = source.read_text(encoding="utf-8")
    rendered = rendered.replace("__REPO_ROOT__", str(repo_root))
    rendered = rendered.replace("__MODEL_ROOT__", str(model_root))
    if "__REPO_ROOT__" in rendered or "__MODEL_ROOT__" in rendered:
        raise RuntimeError(f"unresolved path token in {source}")
    target.write_text(rendered, encoding="utf-8")
PY

python3 - "$adapter_dest" <<'PY'
import sys
from pathlib import Path

adapter_root = Path(sys.argv[1])
for name in ("xiaomi_robotics_0", "vla_adapter", "univla_opendrivelab"):
    path = adapter_root / f"{name}.py"
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY

echo "HARNESS_OVERLAY=PASS"
echo "Harness: $HARNESS_DIR"
echo "Model root: $MODEL_ROOT"
echo "Model weights were not downloaded. Populate the paths recorded in the rendered YAML files."
