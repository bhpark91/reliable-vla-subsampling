import csv
import hashlib
import json
import random
import re
from collections import Counter, defaultdict
from pathlib import Path

from vla_eval.benchmarks.libero_plus.benchmark import LIBEROPlusBenchmark


ROOT = Path("/data/vla-irt-cat-v2")
OUT = ROOT / "manifests"

SEED = 20260824
TARGET = 500

SUITES = [
    "libero_spatial",
    "libero_object",
    "libero_goal",
    "libero_10",
]

EXPECTED_CATEGORIES = {
    "Background Textures",
    "Camera Viewpoints",
    "Language Instructions",
    "Light Conditions",
    "Objects Layout",
    "Robot Initial States",
    "Sensor Noise",
}

PRIMARY_CATEGORIES = EXPECTED_CATEGORIES - {"Sensor Noise"}


def stable_seed(*parts):
    raw = "|".join(map(str, parts))
    digest = hashlib.sha256(raw.encode()).hexdigest()
    return int(digest[:16], 16)


def registry_name(task):
    return getattr(task["task_obj"], "name")


def base_proxy(task):
    category = task.get("category")

    language = re.sub(
        r"\s+",
        " ",
        task.get("name", "").strip().lower(),
    )

    if category != "Language Instructions" and language:
        return language

    s = registry_name(task).lower()

    for marker in (
        "_language_",
        "_view_",
        "_light_",
    ):
        if marker in s:
            s = s.split(marker, 1)[0]

    s = re.sub(
        r"_(table|tb)_\d+(?:_.*)?$",
        "",
        s,
    )

    return s


def choose_diverse(candidates, quota, seed_parts):
    """
    Deterministic round-robin across base-task proxies.
    Requires quota <= len(candidates).
    """
    if quota == 0:
        return []

    if quota > len(candidates):
        raise RuntimeError(
            f"Internal allocation error: quota={quota}, "
            f"available={len(candidates)}, stratum={seed_parts}"
        )

    groups = defaultdict(list)

    for row in candidates:
        groups[row["base_proxy"]].append(row)

    rng = random.Random(
        stable_seed(SEED, *seed_parts)
    )

    keys = sorted(groups)
    rng.shuffle(keys)

    for key in keys:
        rng.shuffle(groups[key])

    result = []

    while len(result) < quota:
        progressed = False

        for key in keys:
            if groups[key]:
                result.append(groups[key].pop())
                progressed = True

                if len(result) == quota:
                    break

        if not progressed:
            break

    if len(result) != quota:
        raise RuntimeError(
            f"Diversity selector failed: quota={quota}, "
            f"got={len(result)}, stratum={seed_parts}"
        )

    return result


def feasible_difficulty_allocation(
    by_diff,
    total_quota,
    suite,
    category,
):
    """
    Start from an approximately equal allocation across difficulties 1-5.

    libero_goal's genuine difficulty=None stratum receives at most one item.

    If a desired difficulty quota exceeds the number of available items,
    clip it and deterministically redistribute the deficit to other
    difficulty levels within the SAME suite/category cell.
    """
    allocation = {}

    none_target = 1 if len(by_diff.get(None, [])) > 0 else 0
    allocation[None] = none_target

    remaining = total_quota - none_target

    base = remaining // 5
    remainder = remaining % 5

    difficulties = [1, 2, 3, 4, 5]

    remainder_order = difficulties.copy()

    random.Random(
        stable_seed(
            SEED,
            suite,
            category,
            "initial-difficulty-allocation",
        )
    ).shuffle(remainder_order)

    for d in difficulties:
        allocation[d] = base

    for d in remainder_order[:remainder]:
        allocation[d] += 1

    desired = dict(allocation)

    # Clip impossible allocations.
    for d in difficulties:
        available = len(by_diff.get(d, []))
        allocation[d] = min(
            allocation[d],
            available,
        )

    allocation[None] = min(
        allocation[None],
        len(by_diff.get(None, [])),
    )

    deficit = total_quota - sum(allocation.values())

    redistribution_order = difficulties.copy()

    random.Random(
        stable_seed(
            SEED,
            suite,
            category,
            "redistribution",
        )
    ).shuffle(redistribution_order)

    while deficit > 0:
        progressed = False

        for d in redistribution_order:
            available = len(by_diff.get(d, []))

            if allocation[d] < available:
                allocation[d] += 1
                deficit -= 1
                progressed = True

                if deficit == 0:
                    break

        if not progressed:
            raise RuntimeError(
                f"Cannot fill suite/category cell: "
                f"{suite} / {category}; "
                f"quota={total_quota}; "
                f"available={sum(len(v) for v in by_diff.values())}"
            )

    assert sum(allocation.values()) == total_quota

    return desired, allocation


print("Enumerating LIBERO-Plus...")

rows = []

for suite in SUITES:
    benchmark = LIBEROPlusBenchmark(
        suite=suite,
        seed=7,
        num_steps_wait=10,
    )

    tasks = benchmark.get_tasks()

    print(f"{suite}: {len(tasks)}")

    for task in tasks:
        rows.append(
            {
                "suite": suite,
                "task_id": int(task["task_id"]),
                "registry_name": registry_name(task),
                "language": task["name"],
                "category": task.get("category"),
                "difficulty": task.get("difficulty_level"),
                "base_proxy": base_proxy(task),
            }
        )


# ============================================================
# Universe gates
# ============================================================

assert len(rows) == 10030, len(rows)

observed_categories = {
    row["category"]
    for row in rows
}

assert observed_categories == EXPECTED_CATEGORIES

primary = [
    row
    for row in rows
    if row["category"] in PRIMARY_CATEGORIES
]

sensor = [
    row
    for row in rows
    if row["category"] == "Sensor Noise"
]

assert len(primary) == 8429, len(primary)
assert len(sensor) == 1601, len(sensor)

print("TOTAL_UNIVERSE =", len(rows))
print("PRIMARY_UNIVERSE =", len(primary))
print("SENSOR_NOISE_QUARANTINE =", len(sensor))


# ============================================================
# Suite × category quotas
# 24 cells, total 500.
# ============================================================

cells = sorted(
    (suite, category)
    for suite in SUITES
    for category in PRIMARY_CATEGORIES
)

assert len(cells) == 24

extra_cells = set(
    random.Random(SEED).sample(
        cells,
        20,
    )
)

cell_quota = {
    cell: 20 + int(cell in extra_cells)
    for cell in cells
}

assert sum(cell_quota.values()) == 500


# ============================================================
# Feasibility-aware difficulty allocation
# ============================================================

selected = []

allocation_audit = {}

for suite, category in cells:
    pool = [
        row
        for row in primary
        if row["suite"] == suite
        and row["category"] == category
    ]

    quota = cell_quota[
        (suite, category)
    ]

    by_diff = defaultdict(list)

    for row in pool:
        by_diff[row["difficulty"]].append(row)

    desired, realized = feasible_difficulty_allocation(
        by_diff,
        quota,
        suite,
        category,
    )

    cell_key = f"{suite}::{category}"

    allocation_audit[cell_key] = {
        "cell_quota": quota,
        "available": {
            str(d): len(by_diff.get(d, []))
            for d in [1, 2, 3, 4, 5, None]
        },
        "desired": {
            str(k): v
            for k, v in desired.items()
        },
        "realized": {
            str(k): v
            for k, v in realized.items()
        },
        "redistributed_items": sum(
            max(
                0,
                realized.get(d, 0)
                - desired.get(d, 0),
            )
            for d in [1, 2, 3, 4, 5, None]
        ),
    }

    for difficulty in [None, 1, 2, 3, 4, 5]:
        n = realized.get(
            difficulty,
            0,
        )

        chosen = choose_diverse(
            by_diff.get(difficulty, []),
            n,
            (
                suite,
                category,
                difficulty,
            ),
        )

        selected.extend(chosen)


# ============================================================
# Selection gates
# ============================================================

assert len(selected) == TARGET, len(selected)

unique_ids = {
    (
        row["suite"],
        row["registry_name"],
    )
    for row in selected
}

assert len(unique_ids) == TARGET

assert all(
    row["category"] != "Sensor Noise"
    for row in selected
)


selected = sorted(
    selected,
    key=lambda row: (
        row["suite"],
        row["category"],
        (
            99
            if row["difficulty"] is None
            else row["difficulty"]
        ),
        row["registry_name"],
    ),
)

for index, row in enumerate(selected):
    row["discovery_index"] = index


# ============================================================
# Audit
# ============================================================

def simple_counts(key):
    c = Counter(
        row[key]
        for row in selected
    )

    return {
        str(k): v
        for k, v in sorted(
            c.items(),
            key=lambda x: str(x[0]),
        )
    }


audit = {
    "schema_version": 2,
    "seed": SEED,
    "target": TARGET,

    "sampling_design":
        "balanced suite×category; approximately balanced difficulty "
        "subject to finite-stratum availability; deterministic redistribution",

    "official_difficulty_usage":
        "sampling metadata only; NOT treated as IRT item difficulty",

    "total_universe": len(rows),
    "primary_universe": len(primary),
    "sensor_noise_universe": len(sensor),

    "selected": len(selected),

    "unique_registry_names": len(unique_ids),

    "unique_base_proxies": len(
        {
            (
                row["suite"],
                row["base_proxy"],
            )
            for row in selected
        }
    ),

    "by_suite": simple_counts("suite"),
    "by_category": simple_counts("category"),
    "by_difficulty": simple_counts("difficulty"),

    "by_suite_category": dict(
        sorted(
            Counter(
                f'{row["suite"]}::{row["category"]}'
                for row in selected
            ).items()
        )
    ),

    "difficulty_allocation": allocation_audit,
}


# ============================================================
# Outputs
# ============================================================

json_path = OUT / "discovery_500_primary.json"
csv_path = OUT / "discovery_500_primary.csv"
audit_path = OUT / "discovery_500_audit.json"
sensor_path = OUT / "sensor_noise_quarantine_all.json"


manifest = {
    "schema_version": 2,
    "seed": SEED,

    "benchmark": "LIBERO-Plus",

    "benchmark_commit":
        "4976dc30028e805ff8094b55501d532c48fec182",

    "harness_version": "v0.4.0",

    "purpose":
        "heterogeneous VLA discovery before IRT item-bank fixation",

    "sampling_design":
        "balanced suite×category with feasibility-aware "
        "difficulty stratification",

    "sensor_noise_policy":
        "excluded from primary; quarantined pending "
        "reproducibility validation",

    "n_items": 500,

    "items": selected,
}


def atomic_json(path, obj):
    tmp = Path(
        str(path) + ".tmp"
    )

    tmp.write_text(
        json.dumps(
            obj,
            indent=2,
            ensure_ascii=False,
        )
    )

    tmp.replace(path)


atomic_json(
    json_path,
    manifest,
)

atomic_json(
    audit_path,
    audit,
)


csv_tmp = Path(
    str(csv_path) + ".tmp"
)

fields = [
    "discovery_index",
    "suite",
    "task_id",
    "registry_name",
    "language",
    "category",
    "difficulty",
    "base_proxy",
]

with csv_tmp.open(
    "w",
    newline="",
) as f:
    writer = csv.DictWriter(
        f,
        fieldnames=fields,
    )

    writer.writeheader()
    writer.writerows(selected)

csv_tmp.replace(csv_path)


sensor_sorted = sorted(
    sensor,
    key=lambda row: (
        row["suite"],
        (
            99
            if row["difficulty"] is None
            else row["difficulty"]
        ),
        row["registry_name"],
    ),
)

sensor_manifest = {
    "schema_version": 2,
    "status": "quarantine",

    "reason":
        "execution verified; scientific reproducibility "
        "not yet promoted",

    "n_items": len(sensor_sorted),

    "items": sensor_sorted,
}

atomic_json(
    sensor_path,
    sensor_manifest,
)


print()
print("===== SUMMARY =====")
print("SELECTED =", len(selected))
print("UNIQUE_ITEMS =", len(unique_ids))
print("UNIQUE_BASE_PROXIES =", audit["unique_base_proxies"])

print()
print("BY_SUITE =", audit["by_suite"])
print("BY_CATEGORY =", audit["by_category"])
print("BY_DIFFICULTY =", audit["by_difficulty"])

print()
print("===== CELLS REQUIRING REDISTRIBUTION =====")

redistributed = {
    key: value
    for key, value in allocation_audit.items()
    if value["redistributed_items"] > 0
}

print(
    json.dumps(
        redistributed,
        indent=2,
        ensure_ascii=False,
    )
)

print()
print("DISCOVERY_500_BUILD_PASS")
