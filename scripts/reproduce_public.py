#!/usr/bin/env python3
"""Recompute full-bank counts and render clearly labelled archived comparisons."""
from __future__ import annotations
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import secrets
import sys
sys.dont_write_bytecode = True
from public_data import ReleaseError, check, csv_string, read_csv, require


def render(root: Path, scores: list[dict]) -> str:
    out = ["# Public data report", "", "## Recomputed full-bank scores", "", "These counts/rates are recomputed from `data/responses.csv`.", "They are scores on this fixed bank, not upstream benchmark leaderboard scores.", "", "| System | Split | Successes / items | Success rate |", "| --- | --- | ---: | ---: |"]
    for s in scores:
        out.append(f"| {s['system']} | {s['split']} | {s['successes']}/{s['n_items']} | {float(s['success_rate']):.1%} |")
    out += ["", "## Archived method comparisons — displayed, NOT recomputed", "", "The public files do not include the original item classifications needed to", "rerun these method comparisons. No new sampling experiment has been run.", ""]
    for label, path, field in [
        ("Calibration", "calibration_comparison.csv", "family_mae_pp"),
        ("Prospective holdout", "holdout_comparison.csv", "family_balanced_mae_pp"),
    ]:
        _, rows = read_csv(root / "results/archived" / path)
        out += [f"### {label}", "", "| Budget | Procedure | Archived family-balanced MAE (pp) |", "| ---: | --- | ---: |"]
        for r in sorted(rows, key=lambda r: (int(r['budget']), float(r[field]))):
            out.append(f"| {r['budget']} | {r['method']} | {float(r[field]):.6f} |")
        out.append("")
    out += ["See `docs/LIMITATIONS.md` before interpreting any method differences.", ""]
    return "\n".join(out)


def reproduce(root: Path, out: Path | None = None) -> Path:
    stats, scores = check(root)
    allowed = (root / "outputs").resolve()
    if out is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        out = allowed / f"public_{stamp}_{secrets.token_hex(3)}"
    out = out.resolve()
    require(out != allowed and out.is_relative_to(allowed), "Output must be a new subdirectory under outputs/")
    require(not out.exists(), "Output already exists; choose a new directory")
    out.mkdir(parents=True, exist_ok=False)
    fields = ["system", "family", "split", "n_items", "successes", "success_rate"]
    (out / "full_bank_scores.csv").write_text(csv_string(scores, fields), encoding="utf-8")
    (out / "report.md").write_text(render(root, scores), encoding="utf-8")
    (out / "validation.json").write_text(json.dumps({**stats, "full_bank_score_reproduction": "PASS", "archived_comparison": "DISPLAY_ONLY_NOT_RECOMPUTED", "simulator_rerun": False, "new_control_experiment": False}, indent=2) + "\n", encoding="utf-8")
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, help="A nonexistent directory under repository outputs/")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        out = reproduce(root, args.out)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"PUBLIC_SUMMARY_REPRODUCTION=FAIL ({exc})", file=sys.stderr)
        return 2
    print("FULL_BANK_SCORES_CHECKED=14")
    print("RECORDED_RESPONSES=7000")
    print("ARCHIVED_METHOD_TABLES=DISPLAY_ONLY")
    print("FULL_METHOD_MAE_REPRODUCTION=NOT_PERFORMED")
    print("SIMULATOR_RERUN=NO")
    print("NEW_CONTROL_EXPERIMENT=NO")
    print(f"OUTPUT={out}")
    print("PUBLIC_SUMMARY_REPRODUCTION=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
