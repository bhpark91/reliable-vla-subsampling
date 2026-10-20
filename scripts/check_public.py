#!/usr/bin/env python3
"""Read-only integrity/data check; no network or full method analysis."""
from __future__ import annotations
import json
import sys
from pathlib import Path
sys.dont_write_bytecode = True
from public_data import check


def main() -> int:
    try:
        stats, _ = check(Path(__file__).resolve().parents[1])
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"PUBLIC_RELEASE_CHECK=FAIL ({exc})", file=sys.stderr)
        return 2
    print(json.dumps(stats, sort_keys=True))
    print("PUBLIC_RELEASE_CHECK=PASS")
    print("Scope: stored files, response schema, full-bank counts, and archived-table consistency only.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
