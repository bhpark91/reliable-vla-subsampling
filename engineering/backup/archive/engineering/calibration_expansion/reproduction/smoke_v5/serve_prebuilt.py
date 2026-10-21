import json
import os
import sys
from pathlib import Path

from vla_eval.cli.config_loader import load_config

if len(sys.argv) != 2:
    raise SystemExit("usage: serve_prebuilt.py CONFIG")

cfg_path = Path(sys.argv[1]).resolve()
cfg = load_config(str(cfg_path))

raw = Path(str(cfg["script"]))

roots = [
    Path.cwd(),
    cfg_path.parent,
    Path(os.environ["CAL_OVER"]),
    Path(os.environ["CAL_REPO"]),
    Path(os.environ["CAL_HARNESS"]),
]

candidates = []

if raw.is_absolute():
    candidates.append(raw)
else:
    for root in roots:
        candidates.append(root / raw)

script = next((p.resolve() for p in candidates if p.is_file()), None)

if script is None:
    matches = []
    for root in [
        Path(os.environ["CAL_OVER"]),
        Path(os.environ["CAL_HARNESS"]),
        Path(os.environ["CAL_REPO"]),
    ]:
        if root.is_dir():
            matches.extend(root.rglob(raw.name))

    matches = [p.resolve() for p in matches if p.is_file()]

    uniq = []
    for p in matches:
        if p not in uniq:
            uniq.append(p)

    if len(uniq) != 1:
        print("SCRIPT_RESOLUTION_FAILED", raw, [str(x) for x in uniq], file=sys.stderr)
        raise SystemExit(31)

    script = uniq[0]

args = dict(cfg.get("args") or {})

# Accept both repaired top-level placement and the harness convention.
port = cfg.get("port", None)
host = cfg.get("host", None)

if "port" in args:
    port = args.pop("port")
if "host" in args:
    host = args.pop("host")

# Canonical smoke port.
port = 8000

def stringify(v):
    if isinstance(v, (list, dict)):
        return json.dumps(v)
    if v is None:
        return "null"
    return str(v)

argv = [sys.executable, str(script), f"--port={port}"]

if host is not None:
    argv.append(f"--host={stringify(host)}")

for k, v in args.items():
    argv.append(f"--args.{k}={stringify(v)}")

print("SERVER_SCRIPT=" + str(script), flush=True)
os.execv(sys.executable, argv)
