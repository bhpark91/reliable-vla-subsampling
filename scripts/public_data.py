"""Standard-library checks for the restricted response-data release.

These checks validate files and recorded outcomes, not the original simulator
or the statistical correctness of the preserved full-analysis methods.
"""
from __future__ import annotations

import csv
import hashlib
import io
import json
import math
import os
import re
from collections import defaultdict
from fractions import Fraction
from pathlib import Path, PurePosixPath

N_ITEMS = 500
N_SYSTEMS = 14
BUDGETS = {80, 160, 320}
PUBLIC_ID = re.compile(r"item_\d{4}\Z")
IDENTIFIER = re.compile(r"[a-z][a-z0-9_]*\Z")
METHODS = {"SRS", "STRAT_PROP", "STRAT_BAL", "STRAT_NEYMAN_CAL", "STRAT_REG", "ADAPT20_REG"}
RUNTIME_DIRS = {".git", "outputs", "__pycache__"}


class ReleaseError(ValueError):
    """The release does not satisfy its documented checks."""


def require(ok: bool, message: str) -> None:
    if not ok:
        raise ReleaseError(message)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_csv(path: Path, expected: list[str] | None = None) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        fields = reader.fieldnames or []
        require(len(fields) == len(set(fields)), f"Duplicate CSV column: {path.name}")
        if expected is not None:
            require(fields == expected, f"Unexpected CSV schema: {path.name}")
        rows = list(reader)
    require(bool(rows), f"Empty data file: {path.name}")
    for row in rows:
        require(None not in row and all(v is not None for v in row.values()), f"Ragged CSV: {path.name}")
    return fields, rows


def csv_string(rows: list[dict], fields: list[str]) -> str:
    out = io.StringIO(newline="")
    writer = csv.DictWriter(out, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
    return out.getvalue()


def verify_inventory(root: Path) -> dict[str, str]:
    root = root.resolve()
    manifest = json.loads((root / "RELEASE_MANIFEST.json").read_text(encoding="utf-8"))
    require(manifest.get("schema_version") == 1, "Unsupported manifest schema")
    files = manifest.get("files")
    require(isinstance(files, dict) and bool(files), "Manifest has no files")
    for rel, expected_hash in files.items():
        p = PurePosixPath(rel)
        require(not p.is_absolute() and all(x not in ("", ".", "..") for x in p.parts), "Unsafe manifest path")
        require("\\" not in rel and p.as_posix() == rel, "Noncanonical manifest path")
        require(not any(x in RUNTIME_DIRS for x in p.parts), "Runtime path in manifest")
        require(bool(re.fullmatch(r"[0-9a-f]{64}", expected_hash)), "Invalid file hash")
        target = root / rel
        require(target.is_file() and not target.is_symlink(), f"Missing/unsafe release file: {rel}")
        require(sha256(target) == expected_hash, f"Hash mismatch: {rel}")
    actual: set[str] = set()
    for directory, dirs, names in os.walk(root, followlinks=False):
        parent = Path(directory)
        for name in list(dirs):
            candidate = parent / name
            require(not candidate.is_symlink(), f"Symlink directory: {candidate.relative_to(root)}")
            if name == "__pycache__" or (parent == root and name in {".git", "outputs"}) or candidate.relative_to(root).as_posix() in {"engineering/backup/external", "engineering/backup/reproducibility/reproduced"}:
                dirs.remove(name)
        for name in names:
            candidate = parent / name
            require(not candidate.is_symlink(), f"Symlink file: {candidate.relative_to(root)}")
            actual.add(candidate.relative_to(root).as_posix())
    expected = set(files) | {"RELEASE_MANIFEST.json"}
    require(actual == expected, "Unexpected/missing public files: " + ", ".join(sorted(actual ^ expected)))
    return files


def load_public(root: Path) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    _, systems = read_csv(root / "data/systems.csv", ["system", "family", "split"])
    require(len(systems) == N_SYSTEMS, "Expected 14 systems")
    names = [s["system"] for s in systems]
    require(len(set(names)) == N_SYSTEMS, "Duplicate system identifier")
    require(all(IDENTIFIER.fullmatch(s["system"]) and IDENTIFIER.fullmatch(s["family"]) for s in systems), "Invalid system/family identifier")
    require(all(s["split"] in {"calibration", "holdout"} for s in systems), "Unknown split")
    cal = [s for s in systems if s["split"] == "calibration"]
    hold = [s for s in systems if s["split"] == "holdout"]
    require((len(cal), len(hold)) == (11, 3), "Incorrect split sizes")
    cf, hf = {s["family"] for s in cal}, {s["family"] for s in hold}
    require((len(cf), len(hf)) == (9, 2), "Incorrect family counts")
    require(cf.isdisjoint(hf), "Recorded calibration/holdout families overlap")
    _, rows = read_csv(root / "data/responses.csv", ["public_item_id"] + names)
    require(len(rows) == N_ITEMS, "Expected 500 items")
    ids = [r["public_item_id"] for r in rows]
    require(all(PUBLIC_ID.fullmatch(i) for i in ids), "Invalid public item ID")
    require(len(set(ids)) == N_ITEMS, "Duplicate public item ID")
    require(set(ids) == {f"item_{i:04d}" for i in range(1, N_ITEMS + 1)}, "Incorrect public ID set")
    require(all(r[s] in {"0", "1"} for r in rows for s in names), "Nonbinary/missing response")
    return systems, rows


def compute_scores(systems: list[dict[str, str]], rows: list[dict[str, str]]) -> list[dict]:
    result = []
    for s in systems:
        successes = sum(int(row[s["system"]]) for row in rows)
        result.append({**s, "n_items": len(rows), "successes": successes, "success_rate": f"{successes / len(rows):.6f}"})
    return result


def validate_reference_scores(root: Path, scores: list[dict]) -> None:
    fields = ["system", "family", "split", "n_items", "successes", "success_rate"]
    _, reference = read_csv(root / "results/reference/full_bank_scores.csv", fields)
    require(len(reference) == N_SYSTEMS, "Wrong number of reference scores")
    lookup = {s["system"]: s for s in reference}
    require(len(lookup) == N_SYSTEMS, "Duplicate reference system")
    require(set(lookup) == {s["system"] for s in scores}, "Reference systems differ")
    for score in scores:
        r = lookup[score["system"]]
        require(r["family"] == score["family"] and r["split"] == score["split"], "Reference family/split mismatch")
        require(int(r["n_items"]) == score["n_items"] and int(r["successes"]) == score["successes"], "Full-bank count mismatch")
        require(Fraction(r["success_rate"]) == Fraction(score["successes"], score["n_items"]), "Full-bank rate mismatch")


def finite_number(value: str, low: float = 0.0, high: float = 100.0) -> float:
    number = float(value)
    require(math.isfinite(number) and low <= number <= high, "Invalid archived numeric value")
    return number


def validate_archived(root: Path, scores: list[dict]) -> None:
    _, cal = read_csv(root / "results/archived/calibration_comparison.csv", ["method", "family_mae_pp", "source", "budget", "rank"])
    cal_methods = (METHODS - {"STRAT_NEYMAN_CAL"}) | {"STRAT_NEYMAN_LOFO"}
    require(len(cal) == 18, "Wrong calibration table size")
    require({(int(r["budget"]), r["method"]) for r in cal} == {(b, m) for b in BUDGETS for m in cal_methods}, "Invalid calibration comparison keys")
    for r in cal:
        finite_number(r["family_mae_pp"])
        require(1 <= int(r["rank"]) <= 6, "Invalid calibration rank")
    agg_fields = ["method", "budget", "family_balanced_mae_pp", "family_balanced_rmse_pp", "family_balanced_abs_bias_pp", "family_balanced_p90_abs_pp", "family_balanced_gt5_rate", "rank"]
    _, agg = read_csv(root / "results/archived/holdout_comparison.csv", agg_fields)
    require(len(agg) == 18, "Wrong holdout table size")
    require({(int(r["budget"]), r["method"]) for r in agg} == {(b, m) for b in BUDGETS for m in METHODS}, "Invalid holdout comparison keys")
    for r in agg:
        for field in agg_fields[2:7]:
            finite_number(r[field], high=1.0 if field.endswith("rate") else 100.0)
        require(1 <= int(r["rank"]) <= 6, "Invalid holdout rank")
    fields = ["method", "budget", "system", "family", "truth", "mean_estimate", "mae_pp", "rmse_pp", "bias_pp", "abs_bias_pp", "p90_abs_pp", "gt5_rate", "replicates"]
    _, rows = read_csv(root / "results/archived/holdout_by_system.csv", fields)
    hold = {s["system"]: s for s in scores if s["split"] == "holdout"}
    require(len(rows) == 54, "Wrong per-system holdout table size")
    require({(int(r["budget"]), r["method"], r["system"]) for r in rows} == {(b, m, s) for b in BUDGETS for m in METHODS for s in hold}, "Invalid per-system holdout keys")
    grouped: dict[tuple[int, str], dict[str, list[float]]] = defaultdict(lambda: defaultdict(list))
    for r in rows:
        s = hold[r["system"]]
        require(r["family"] == s["family"], "Archived family mismatch")
        require(Fraction(r["truth"]) == Fraction(s["successes"], s["n_items"]), "Archived truth mismatch")
        require(int(r["replicates"]) == 5000, "Unexpected archived replicate count")
        for field in fields[4:12]:
            finite_number(r[field], low=-100.0 if field == "bias_pp" else 0.0, high=1.0 if field in {"truth", "mean_estimate", "gt5_rate"} else 100.0)
        grouped[(int(r["budget"]), r["method"])][r["family"]].append(float(r["mae_pp"]))
    for r in agg:
        by_family = grouped[(int(r["budget"]), r["method"])]
        expected = sum(sum(v) / len(v) for v in by_family.values()) / len(by_family)
        require(abs(expected - float(r["family_balanced_mae_pp"])) < 1e-10, "Archived aggregate does not match per-system MAEs")


def check(root: Path, *, integrity: bool = True) -> tuple[dict, list[dict]]:
    files = verify_inventory(root) if integrity else {}
    systems, rows = load_public(root)
    scores = compute_scores(systems, rows)
    validate_reference_scores(root, scores)
    validate_archived(root, scores)
    stats = {"items": N_ITEMS, "systems": N_SYSTEMS, "responses": N_ITEMS * N_SYSTEMS, "calibration_systems": 11, "calibration_families": 9, "holdout_systems": 3, "holdout_families": 2, "manifest_files_checked": len(files), "full_method_analysis_reproduced": False}
    return stats, scores
