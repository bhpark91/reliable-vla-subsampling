#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"

HERE="/mnt/c/Users/YOUR_USER/Downloads"
CANON="$HERE/d500-holdout-prod-v2-combined-watch-20260829/canonical-final.tsv"
ORIG="$HERE/d500-holdout-prod-v2-20260829-jobs.tsv"
REP="$HERE/d500-holdout-prod-v2-repair1-20260829-jobs.tsv"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HERE/d500-holdout-collected-${STAMP}"
REPO="$OUT/repo"
ART="$OUT/artifacts"
mkdir -p "$OUT" "$ART"

test -s "$CANON" || { echo "ERROR=CANONICAL_STATUS_MISSING:$CANON"; exit 2; }
test -s "$ORIG"  || { echo "ERROR=ORIG_JOBS_MISSING:$ORIG"; exit 3; }
test -s "$REP"   || { echo "ERROR=REPAIR_JOBS_MISSING:$REP"; exit 4; }

echo "============================================================"
echo " COLLECT + AUDIT D500 PROSPECTIVE HOLDOUT"
echo "============================================================"
echo "Canonical shards: 60"
echo "Expected systems:  3"
echo "Expected rows:     1500"
echo "New GPU jobs:      0"
echo "Primary source:    persisted Git result branches"
echo "============================================================"

echo
echo "===== CLONE REPOSITORY METADATA ====="
git clone -q --filter=blob:none --no-checkout \
  https://github.com/bhpark91/vla-irt-cat-v2.git "$REPO"
echo "CLONE=PASS"

# maps canonical shard -> result branch
declare -A ORIG_BRANCH REP_BRANCH
while IFS=$'\t' read -r SYSTEM SUITE SHARD JOB NAME BRANCH; do
  ORIG_BRANCH["$SYSTEM|$SUITE|$SHARD"]="$BRANCH"
done < "$ORIG"

while IFS=$'\t' read -r SYSTEM SUITE SHARD OLDJOB NEWJOB NAME BRANCH; do
  REP_BRANCH["$SYSTEM|$SUITE|$SHARD"]="$BRANCH"
done < "$REP"

MISSING_BRANCH=0
MISSING_FILES=0
COLLECTED=0
: > "$OUT/selected_sources.tsv"

echo
echo "===== NORMALIZE CANONICAL SELECTION ====="

# Never parse canonical-final.tsv directly with Bash `read`: empty repair fields
# are legal for original-success shards, and Bash whitespace IFS collapses
# consecutive tabs. Normalize in Python into a no-empty-field selection table.
SELECTED="$OUT/canonical_selected_normalized.tsv"
python3 - "$CANON" "$ORIG" "$REP" "$SELECTED" <<'PY'
import csv,sys
canon,orig,rep,out=sys.argv[1:]

ob={}
with open(orig,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        ob[(r[0],r[1],r[2])] = r[5]

rb={}
with open(rep,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        rb[(r[0],r[1],r[2])] = r[6]

rows=[]
with open(canon,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        if len(r) != 9:
            raise SystemExit(f"BAD_CANONICAL_ROW_COLUMNS={len(r)} row={r!r}")
        system,suite,shard,ojob,ostate,rjob,rstate,coverage,source=r
        key=(system,suite,shard)
        if coverage != "covered":
            raise SystemExit(f"UNCOVERED_CANONICAL_SHARD={'|'.join(key)}")
        if source == "original":
            branch=ob.get(key)
        elif source == "repair1":
            branch=rb.get(key)
        else:
            raise SystemExit(f"UNKNOWN_CANONICAL_SOURCE={source} key={'|'.join(key)}")
        if not branch:
            raise SystemExit(f"BRANCH_MAP_MISSING={'|'.join(key)} source={source}")
        rows.append([system,suite,shard,source,branch])

if len(rows) != 60:
    raise SystemExit(f"CANONICAL_SELECTION_COUNT={len(rows)} expected=60")

with open(out,"w",newline='') as f:
    w=csv.writer(f,delimiter='\t',lineterminator='\n')
    w.writerows(rows)

print("CANONICAL_SELECTION=PASS")
print("CANONICAL_SELECTION_ROWS=60")
print("ORIGINAL_SELECTED="+str(sum(r[3]=="original" for r in rows)))
print("REPAIR1_SELECTED="+str(sum(r[3]=="repair1" for r in rows)))
PY

echo
echo "===== FETCH 60 CANONICAL SHARDS ====="

while IFS=$'\t' read -r SYSTEM SUITE SHARD SOURCE BRANCH; do
  KEY="$SYSTEM|$SUITE|$SHARD"

  if [ -z "$BRANCH" ]; then
    echo "BRANCH_MAP_MISSING $KEY source=$SOURCE"
    MISSING_BRANCH=$((MISSING_BRANCH+1))
    continue
  fi

  set +e
  git -C "$REPO" fetch -q --depth=1 origin "$BRANCH"
  FRC=$?
  set -e
  if [ "$FRC" -ne 0 ]; then
    echo "BRANCH_FETCH_FAIL $KEY branch=$BRANCH"
    MISSING_BRANCH=$((MISSING_BRANCH+1))
    continue
  fi

  COMMIT="$(git -C "$REPO" rev-parse FETCH_HEAD)"
  PREFIX="$(
    git -C "$REPO" ls-tree -r --name-only "$COMMIT" |
      grep -E "^holdout_results/.+/${SYSTEM}/${SUITE}/s${SHARD}of5/" |
      sed -n '1{s#/[^/]*$##;p}'
  )"

  if [ -z "$PREFIX" ]; then
    echo "RESULT_PREFIX_MISSING $KEY branch=$BRANCH commit=$COMMIT"
    MISSING_FILES=$((MISSING_FILES+1))
    continue
  fi

  DEST="$ART/$SYSTEM/$SUITE/s${SHARD}of5"
  mkdir -p "$DEST"

  FILELIST="$(git -C "$REPO" ls-tree -r --name-only "$COMMIT" -- "$PREFIX")"
  SQLITE_REL="$(printf '%s\n' "$FILELIST" | grep -E '/recording-[^/]+\.sqlite$' | head -1 || true)"
  MAN_REL="$(printf '%s\n' "$FILELIST" | grep -E '/shard_manifest\.json$' | head -1 || true)"
  AUD_REL="$(printf '%s\n' "$FILELIST" | grep -E '/response_audit\.json$' | head -1 || true)"
  SUM_REL="$(printf '%s\n' "$FILELIST" | grep -E '/summary\.env$' | head -1 || true)"
  SHA_REL="$(printf '%s\n' "$FILELIST" | grep -E '/SHA256SUMS\.txt$' | head -1 || true)"

  if [ -z "$SQLITE_REL" ] || [ -z "$MAN_REL" ] || [ -z "$AUD_REL" ] || [ -z "$SUM_REL" ]; then
    echo "REQUIRED_FILE_MISSING $KEY branch=$BRANCH"
    echo "  sqlite=${SQLITE_REL:-MISSING}"
    echo "  manifest=${MAN_REL:-MISSING}"
    echo "  audit=${AUD_REL:-MISSING}"
    echo "  summary=${SUM_REL:-MISSING}"
    MISSING_FILES=$((MISSING_FILES+1))
    continue
  fi

  git -C "$REPO" show "$COMMIT:$SQLITE_REL" > "$DEST/recording.sqlite"
  git -C "$REPO" show "$COMMIT:$MAN_REL" > "$DEST/shard_manifest.json"
  git -C "$REPO" show "$COMMIT:$AUD_REL" > "$DEST/response_audit.json"
  git -C "$REPO" show "$COMMIT:$SUM_REL" > "$DEST/summary.env"
  if [ -n "$SHA_REL" ]; then
    git -C "$REPO" show "$COMMIT:$SHA_REL" > "$DEST/SHA256SUMS.upstream.txt"
  fi

  cat > "$DEST/source.env" <<EOF
SYSTEM=$SYSTEM
SUITE=$SUITE
SHARD=$SHARD
SOURCE=$SOURCE
RESULT_BRANCH=$BRANCH
RESULT_COMMIT=$COMMIT
RESULT_PREFIX=$PREFIX
EOF

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$SYSTEM" "$SUITE" "$SHARD" "$SOURCE" "$BRANCH" "$COMMIT" \
    >> "$OUT/selected_sources.tsv"

  COLLECTED=$((COLLECTED+1))
  printf 'COLLECT=%02d/60 PASS %-9s %-15s s%d source=%s\n' \
    "$COLLECTED" "$SYSTEM" "$SUITE" "$SHARD" "$SOURCE"
done < "$SELECTED"

echo
echo "COLLECTED_SHARDS=$COLLECTED"
echo "MISSING_BRANCHES=$MISSING_BRANCH"
echo "MISSING_REQUIRED_FILES=$MISSING_FILES"

if [ "$COLLECTED" -ne 60 ]; then
  SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=COLLECT_AUDIT_PROSPECTIVE_HOLDOUT_D500
GATE=NEEDS_SHARED_DATA_FALLBACK
CANONICAL_SHARDS=60
GIT_COLLECTED_SHARDS=$COLLECTED
MISSING_BRANCHES=$MISSING_BRANCH
MISSING_REQUIRED_FILES=$MISSING_FILES
GPU_JOBS_CREATED=0
OUTPUT=$OUT
NEXT=READ_MISSING_SHARDS_FROM_SHARED_/data
===========================
EOF
)"
  echo
  printf '%s\n' "$SUMMARY"
  if command -v clip.exe >/dev/null 2>&1; then
    printf '%s\n' "$SUMMARY" | clip.exe || true
    echo "CHATGPT_SUMMARY_COPIED=YES"
  fi
  exit 20
fi

echo
echo "===== AUDIT + BUILD 1500-ROW LONG MATRIX ====="

python3 - "$ART" "$OUT" <<'PY'
import csv, json, os, sqlite3, sys
from collections import Counter, defaultdict
from pathlib import Path

art = Path(sys.argv[1])
out = Path(sys.argv[2])

expected_suite = {
    "libero_spatial": 124,
    "libero_object": 126,
    "libero_goal": 125,
    "libero_10": 125,
}
systems = ["pi05", "pi0_fast", "vlanext"]

rows_out = []
problems = []
shard_audit = []

def get_items(obj):
    if isinstance(obj, dict) and isinstance(obj.get("items"), list):
        return obj["items"]
    raise AssertionError("manifest has no items list")

def item_language(x):
    for k in ("language", "task_name", "instruction", "prompt"):
        v = x.get(k)
        if isinstance(v, str):
            return v
    return None

for system in systems:
    for suite in expected_suite:
        for shard in range(5):
            d = art / system / suite / f"s{shard}of5"
            if not d.exists():
                problems.append(f"missing artifact dir {d}")
                continue

            manifest = json.load(open(d/"shard_manifest.json"))
            items = get_items(manifest)
            audit = json.load(open(d/"response_audit.json"))

            if audit.get("expected") != len(items):
                problems.append(f"{system}/{suite}/s{shard}: audit expected != manifest n")
            if audit.get("observed") != len(items):
                problems.append(f"{system}/{suite}/s{shard}: audit observed != manifest n")
            if audit.get("engineering_errors"):
                problems.append(f"{system}/{suite}/s{shard}: engineering errors present")

            con = sqlite3.connect(d/"recording.sqlite")
            cols = [r[1] for r in con.execute("pragma table_info(episode_results)").fetchall()]
            want = ["task_name","status","steps","failure_reason","failure_detail","context"]
            missing = [c for c in want if c not in cols]
            if missing:
                problems.append(f"{system}/{suite}/s{shard}: sqlite missing columns {missing}")
                con.close()
                continue
            eps = con.execute(
                "select task_name,status,steps,failure_reason,failure_detail,context "
                "from episode_results order by rowid"
            ).fetchall()
            con.close()

            if len(eps) != len(items):
                problems.append(
                    f"{system}/{suite}/s{shard}: sqlite rows {len(eps)} != manifest {len(items)}"
                )
                continue

            bad_status = [r for r in eps if r[1] not in ("success","fail")]
            if bad_status:
                problems.append(f"{system}/{suite}/s{shard}: invalid statuses {len(bad_status)}")
                continue

            # Strongest mapping: unique language/task_name equality.
            langs = [item_language(x) for x in items]
            if all(langs) and len(set(langs)) == len(langs):
                by_lang = {v:i for i,v in enumerate(langs)}
                if set(r[0] for r in eps) == set(langs):
                    pairs = [(items[by_lang[r[0]]], r) for r in eps]
                    mapping = "task_name"
                else:
                    pairs = list(zip(items, eps))
                    mapping = "position"
            else:
                pairs = list(zip(items, eps))
                mapping = "position"

            # If positional fallback is needed, require context fields to agree
            # with manifest wherever both sides expose them.
            if mapping == "position":
                for pos,(it,ep) in enumerate(pairs):
                    try:
                        ctx = json.loads(ep[5]) if ep[5] else {}
                    except Exception:
                        ctx = {}
                    for key in ("suite","task_id","category","difficulty_level"):
                        if key in it and key in ctx and it[key] != ctx[key]:
                            problems.append(
                                f"{system}/{suite}/s{shard}: positional mapping mismatch "
                                f"row={pos} key={key} manifest={it[key]!r} context={ctx[key]!r}"
                            )

            for it,ep in pairs:
                idx = it.get("discovery_index")
                if idx is None:
                    problems.append(f"{system}/{suite}/s{shard}: discovery_index missing")
                    continue
                try:
                    ctx = json.loads(ep[5]) if ep[5] else {}
                except Exception:
                    ctx = {}
                rows_out.append({
                    "system": system,
                    "family": "pi_openpi" if system in ("pi05","pi0_fast") else "vlanext",
                    "discovery_index": int(idx),
                    "suite": suite,
                    "task_name": ep[0],
                    "status": ep[1],
                    "success": 1 if ep[1] == "success" else 0,
                    "steps": ep[2],
                    "failure_reason": ep[3],
                    "failure_detail": ep[4],
                    "task_id": ctx.get("task_id", it.get("task_id")),
                    "category": ctx.get("category", it.get("category")),
                    "difficulty_level": ctx.get("difficulty_level", it.get("difficulty_level")),
                    "shard": shard,
                    "mapping": mapping,
                })

            shard_audit.append({
                "system": system, "suite": suite, "shard": shard,
                "manifest_n": len(items), "sqlite_n": len(eps),
                "mapping": mapping,
                "success": sum(1 for r in eps if r[1]=="success"),
                "fail": sum(1 for r in eps if r[1]=="fail"),
            })

# Global invariants.
if len(rows_out) != 1500:
    problems.append(f"long rows != 1500: {len(rows_out)}")

key_counts = Counter((r["system"], r["discovery_index"]) for r in rows_out)
dups = [k for k,v in key_counts.items() if v != 1]
if dups:
    problems.append(f"non-unique system/discovery_index keys: {len(dups)}")

for s in systems:
    rs=[r for r in rows_out if r["system"]==s]
    if len(rs) != 500:
        problems.append(f"{s}: rows {len(rs)} != 500")
    inds={r["discovery_index"] for r in rs}
    if len(inds) != 500:
        problems.append(f"{s}: unique indices {len(inds)} != 500")
    for suite,n in expected_suite.items():
        c=sum(1 for r in rs if r["suite"]==suite)
        if c != n:
            problems.append(f"{s}/{suite}: rows {c} != {n}")

# All three systems must cover exactly same D500 indices.
sets = {s:{r["discovery_index"] for r in rows_out if r["system"]==s} for s in systems}
if not (sets[systems[0]] == sets[systems[1]] == sets[systems[2]]):
    problems.append("systems do not cover identical discovery_index set")

fields = [
    "system","family","discovery_index","suite","task_name","status","success",
    "steps","failure_reason","failure_detail","task_id","category",
    "difficulty_level","shard","mapping"
]
with open(out/"holdout_long_1500.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=fields)
    w.writeheader()
    w.writerows(sorted(rows_out,key=lambda r:(r["system"],r["discovery_index"])))

with open(out/"shard_audit.csv","w",newline="",encoding="utf-8") as f:
    fields2=["system","suite","shard","manifest_n","sqlite_n","mapping","success","fail"]
    w=csv.DictWriter(f,fieldnames=fields2)
    w.writeheader()
    w.writerows(shard_audit)

# Wide 500x3.
by = defaultdict(dict)
meta = {}
for r in rows_out:
    by[r["discovery_index"]][r["system"]] = r["success"]
    meta[r["discovery_index"]] = {
        "suite":r["suite"], "task_name":r["task_name"],
        "task_id":r["task_id"], "category":r["category"],
        "difficulty_level":r["difficulty_level"],
    }

wide_fields = [
    "discovery_index","suite","task_name","task_id","category","difficulty_level",
    *systems
]
with open(out/"holdout_wide_500x3.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=wide_fields)
    w.writeheader()
    for idx in sorted(by):
        row={"discovery_index":idx, **meta[idx]}
        row.update(by[idx])
        w.writerow(row)

scores={}
for s in systems:
    rr=[r for r in rows_out if r["system"]==s]
    scores[s]={
        "success":sum(r["success"] for r in rr),
        "total":len(rr),
        "score":sum(r["success"] for r in rr)/len(rr) if rr else None,
    }

family_pi=(scores["pi05"]["score"]+scores["pi0_fast"]["score"])/2
family_vx=scores["vlanext"]["score"]
family_bal=(family_pi+family_vx)/2

report = {
    "gate":"PASS" if not problems else "FAIL",
    "expected_rows":1500,
    "observed_rows":len(rows_out),
    "engineering_errors": sum(
        1 for r in rows_out if r["status"] not in ("success","fail")
    ),
    "problems":problems,
    "scores":scores,
    "family_balanced_full_score":{
        "pi_openpi":family_pi,
        "vlanext":family_vx,
        "mean":family_bal,
    },
    "mapping_modes":dict(Counter(x["mapping"] for x in shard_audit)),
}
json.dump(report,open(out/"audit_report.json","w"),indent=2,ensure_ascii=False)

print("AUDIT_GATE="+report["gate"])
print("OBSERVED_ROWS="+str(report["observed_rows"]))
print("ENGINEERING_ERRORS="+str(report["engineering_errors"]))
print("MAPPING_MODES="+json.dumps(report["mapping_modes"],sort_keys=True))
for s in systems:
    x=scores[s]
    print(f"SCORE_{s.upper()}={x['success']}/{x['total']}={x['score']:.6f}")
print(f"FAMILY_PI_OPENPI={family_pi:.6f}")
print(f"FAMILY_VLANEXT={family_vx:.6f}")
print(f"FAMILY_BALANCED_FULL_SCORE={family_bal:.6f}")
if problems:
    print("PROBLEMS="+json.dumps(problems,ensure_ascii=False))
    raise SystemExit(30)
PY

echo
echo "===== SHA256 ====="
(
  cd "$OUT"
  sha256sum \
    holdout_long_1500.csv \
    holdout_wide_500x3.csv \
    shard_audit.csv \
    audit_report.json \
    selected_sources.tsv
) > "$OUT/SHA256SUMS.txt"
cat "$OUT/SHA256SUMS.txt"

SCORES="$(python3 - "$OUT/audit_report.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
for s in ("pi05","pi0_fast","vlanext"):
    q=x["scores"][s]
    print(f"{s}={q['success']}/{q['total']}={q['score']:.6f}")
print(f"family_balanced={x['family_balanced_full_score']['mean']:.6f}")
PY
)"

SUMMARY="$(
cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=COLLECT_AUDIT_PROSPECTIVE_HOLDOUT_D500
GATE=PASS
CANONICAL_SHARDS=60
COLLECTED_SHARDS=60
EXPECTED_RESPONSES=1500
OBSERVED_RESPONSES=1500
ENGINEERING_ERRORS=0
$(printf '%s\n' "$SCORES")
LONG_MATRIX=$OUT/holdout_long_1500.csv
WIDE_MATRIX=$OUT/holdout_wide_500x3.csv
AUDIT_REPORT=$OUT/audit_report.json
SHA256=$OUT/SHA256SUMS.txt
GPU_JOBS_CREATED=0
NEXT=RUN_FROZEN_PROSPECTIVE_METHOD_COMPARISON
===========================
EOF
)"
echo
printf '%s\n' "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
