#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"

OUT="/mnt/c/Users/YOUR_USER/Downloads/d500-holdout-collected-20260829-164332"
ART="$OUT/artifacts"
SELECTED="$OUT/canonical_selected_normalized.tsv"
SOURCES="$OUT/selected_sources.tsv"

test -d "$OUT" || { echo "ERROR=OUT_MISSING:$OUT"; exit 2; }
test -s "$SELECTED" || { echo "ERROR=SELECTED_MISSING:$SELECTED"; exit 3; }
test -s "$SOURCES" || { echo "ERROR=SOURCES_MISSING:$SOURCES"; exit 4; }

echo "============================================================"
echo " RECOVER 2 MISSING CANONICAL SHARDS + AUDIT"
echo "============================================================"
echo "Existing collected shards: $(wc -l < "$SOURCES")"
echo "GPU jobs: 0"
echo "Recovery Git repo: Linux /tmp"
echo "gc.auto: disabled"
echo "============================================================"

MISSING="$OUT/missing_selected.tsv"
python3 - "$SELECTED" "$SOURCES" "$MISSING" <<'PY'
import csv,sys
sel,src,out=sys.argv[1:]
want=[]
with open(sel,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        # system suite shard source branch
        want.append(r)
have=set()
with open(src,newline='') as f:
    for r in csv.reader(f,delimiter='\t'):
        # system suite shard source branch commit
        have.add((r[0],r[1],r[2]))
missing=[r for r in want if (r[0],r[1],r[2]) not in have]
with open(out,"w",newline='') as f:
    csv.writer(f,delimiter='\t',lineterminator='\n').writerows(missing)
print("MISSING_SHARDS="+str(len(missing)))
for r in missing:
    print("MISSING="+"|".join(r[:4])+" branch="+r[4])
PY

N="$(wc -l < "$MISSING")"
if [ "$N" -eq 0 ]; then
  echo "MISSING_SHARDS=0"
elif [ "$N" -gt 5 ]; then
  echo "ERROR=UNEXPECTED_TOO_MANY_MISSING:$N"
  exit 5
fi

TMP="$(mktemp -d /tmp/d500-holdout-recover.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" remote add origin https://github.com/bhpark91/vla-irt-cat-v2.git
git -C "$TMP" config gc.auto 0
git -C "$TMP" config maintenance.auto false

RECOVERED=0

while IFS=$'\t' read -r SYSTEM SUITE SHARD SOURCE BRANCH; do
  [ -n "$SYSTEM" ] || continue

  echo
  echo "===== RECOVER $SYSTEM $SUITE s$SHARD source=$SOURCE ====="
  echo "BRANCH=$BRANCH"

  git -C "$TMP" -c gc.auto=0 fetch -q --force --depth=1 origin "$BRANCH"
  COMMIT="$(git -C "$TMP" rev-parse FETCH_HEAD)"

  PREFIX="$(
    git -C "$TMP" ls-tree -r --name-only "$COMMIT" |
      grep -E "^holdout_results/.+/${SYSTEM}/${SUITE}/s${SHARD}of5/" |
      sed -n '1{s#/[^/]*$##;p}'
  )"
  test -n "$PREFIX" || { echo "ERROR=RESULT_PREFIX_MISSING"; exit 10; }

  DEST="$ART/$SYSTEM/$SUITE/s${SHARD}of5"
  mkdir -p "$DEST"

  FILELIST="$(git -C "$TMP" ls-tree -r --name-only "$COMMIT" -- "$PREFIX")"
  SQLITE_REL="$(printf '%s\n' "$FILELIST" | grep -E '/recording-[^/]+\.sqlite$' | head -1 || true)"
  MAN_REL="$(printf '%s\n' "$FILELIST" | grep -E '/shard_manifest\.json$' | head -1 || true)"
  AUD_REL="$(printf '%s\n' "$FILELIST" | grep -E '/response_audit\.json$' | head -1 || true)"
  SUM_REL="$(printf '%s\n' "$FILELIST" | grep -E '/summary\.env$' | head -1 || true)"
  SHA_REL="$(printf '%s\n' "$FILELIST" | grep -E '/SHA256SUMS\.txt$' | head -1 || true)"

  test -n "$SQLITE_REL" || { echo "ERROR=SQLITE_MISSING"; exit 11; }
  test -n "$MAN_REL" || { echo "ERROR=MANIFEST_MISSING"; exit 12; }
  test -n "$AUD_REL" || { echo "ERROR=AUDIT_MISSING"; exit 13; }
  test -n "$SUM_REL" || { echo "ERROR=SUMMARY_MISSING"; exit 14; }

  git -C "$TMP" show "$COMMIT:$SQLITE_REL" > "$DEST/recording.sqlite"
  git -C "$TMP" show "$COMMIT:$MAN_REL" > "$DEST/shard_manifest.json"
  git -C "$TMP" show "$COMMIT:$AUD_REL" > "$DEST/response_audit.json"
  git -C "$TMP" show "$COMMIT:$SUM_REL" > "$DEST/summary.env"
  if [ -n "$SHA_REL" ]; then
    git -C "$TMP" show "$COMMIT:$SHA_REL" > "$DEST/SHA256SUMS.upstream.txt"
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
    >> "$SOURCES"

  RECOVERED=$((RECOVERED+1))
  echo "RECOVER=PASS $SYSTEM $SUITE s$SHARD"
done < "$MISSING"

echo
echo "RECOVERED=$RECOVERED"
echo "TOTAL_SELECTED_SOURCES=$(wc -l < "$SOURCES")"

python3 - "$SOURCES" <<'PY'
import csv,sys
rows=list(csv.reader(open(sys.argv[1]),delimiter='\t'))
keys=[tuple(r[:3]) for r in rows]
print("SOURCE_ROWS="+str(len(rows)))
print("SOURCE_UNIQUE_KEYS="+str(len(set(keys))))
assert len(rows)==60
assert len(set(keys))==60
print("SOURCE_COVERAGE=PASS")
PY

echo
echo "===== AUDIT + BUILD 1500-ROW LONG MATRIX ====="

python3 - "$ART" "$OUT" <<'PY'
import csv, json, sqlite3, sys
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
    for k in ("language","task_name","instruction","prompt"):
        v=x.get(k)
        if isinstance(v,str):
            return v
    return None

for system in systems:
    for suite in expected_suite:
        for shard in range(5):
            d=art/system/suite/f"s{shard}of5"
            if not d.exists():
                problems.append(f"missing artifact dir {d}")
                continue

            manifest=json.load(open(d/"shard_manifest.json"))
            items=get_items(manifest)
            audit=json.load(open(d/"response_audit.json"))

            if audit.get("expected") != len(items):
                problems.append(f"{system}/{suite}/s{shard}: audit expected != manifest n")
            if audit.get("observed") != len(items):
                problems.append(f"{system}/{suite}/s{shard}: audit observed != manifest n")
            if audit.get("engineering_errors"):
                problems.append(f"{system}/{suite}/s{shard}: engineering errors present")

            con=sqlite3.connect(d/"recording.sqlite")
            cols=[r[1] for r in con.execute("pragma table_info(episode_results)").fetchall()]
            want=["task_name","status","steps","failure_reason","failure_detail","context"]
            missing=[c for c in want if c not in cols]
            if missing:
                problems.append(f"{system}/{suite}/s{shard}: sqlite missing columns {missing}")
                con.close()
                continue

            eps=con.execute(
                "select task_name,status,steps,failure_reason,failure_detail,context "
                "from episode_results order by rowid"
            ).fetchall()
            con.close()

            if len(eps) != len(items):
                problems.append(f"{system}/{suite}/s{shard}: sqlite rows {len(eps)} != manifest {len(items)}")
                continue

            if any(r[1] not in ("success","fail") for r in eps):
                problems.append(f"{system}/{suite}/s{shard}: invalid status present")
                continue

            langs=[item_language(x) for x in items]
            if all(langs) and len(set(langs)) == len(langs) and set(r[0] for r in eps)==set(langs):
                by_lang={v:i for i,v in enumerate(langs)}
                pairs=[(items[by_lang[r[0]]],r) for r in eps]
                mapping="task_name"
            else:
                pairs=list(zip(items,eps))
                mapping="position"

            if mapping=="position":
                for pos,(it,ep) in enumerate(pairs):
                    try:
                        ctx=json.loads(ep[5]) if ep[5] else {}
                    except Exception:
                        ctx={}
                    for key in ("suite","task_id","category","difficulty_level"):
                        if key in it and key in ctx and it[key] != ctx[key]:
                            problems.append(
                                f"{system}/{suite}/s{shard}: positional mismatch row={pos} key={key}"
                            )

            for it,ep in pairs:
                idx=it.get("discovery_index")
                if idx is None:
                    problems.append(f"{system}/{suite}/s{shard}: discovery_index missing")
                    continue
                try:
                    ctx=json.loads(ep[5]) if ep[5] else {}
                except Exception:
                    ctx={}
                rows_out.append({
                    "system":system,
                    "family":"pi_openpi" if system in ("pi05","pi0_fast") else "vlanext",
                    "discovery_index":int(idx),
                    "suite":suite,
                    "task_name":ep[0],
                    "status":ep[1],
                    "success":1 if ep[1]=="success" else 0,
                    "steps":ep[2],
                    "failure_reason":ep[3],
                    "failure_detail":ep[4],
                    "task_id":ctx.get("task_id",it.get("task_id")),
                    "category":ctx.get("category",it.get("category")),
                    "difficulty_level":ctx.get("difficulty_level",it.get("difficulty_level")),
                    "shard":shard,
                    "mapping":mapping,
                })

            shard_audit.append({
                "system":system,"suite":suite,"shard":shard,
                "manifest_n":len(items),"sqlite_n":len(eps),
                "mapping":mapping,
                "success":sum(r[1]=="success" for r in eps),
                "fail":sum(r[1]=="fail" for r in eps),
            })

if len(rows_out)!=1500:
    problems.append(f"long rows != 1500: {len(rows_out)}")

kc=Counter((r["system"],r["discovery_index"]) for r in rows_out)
bad=[k for k,v in kc.items() if v!=1]
if bad:
    problems.append(f"non-unique system/discovery_index keys: {len(bad)}")

for s in systems:
    rr=[r for r in rows_out if r["system"]==s]
    if len(rr)!=500:
        problems.append(f"{s}: rows {len(rr)} != 500")
    inds={r["discovery_index"] for r in rr}
    if len(inds)!=500:
        problems.append(f"{s}: unique indices {len(inds)} != 500")
    for suite,n in expected_suite.items():
        c=sum(r["suite"]==suite for r in rr)
        if c!=n:
            problems.append(f"{s}/{suite}: rows {c} != {n}")

sets={s:{r["discovery_index"] for r in rows_out if r["system"]==s} for s in systems}
if not (sets[systems[0]]==sets[systems[1]]==sets[systems[2]]):
    problems.append("systems do not cover identical discovery_index set")

fields=[
    "system","family","discovery_index","suite","task_name","status","success",
    "steps","failure_reason","failure_detail","task_id","category",
    "difficulty_level","shard","mapping"
]
with open(out/"holdout_long_1500.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader()
    w.writerows(sorted(rows_out,key=lambda r:(r["system"],r["discovery_index"])))

fields2=["system","suite","shard","manifest_n","sqlite_n","mapping","success","fail"]
with open(out/"shard_audit.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=fields2); w.writeheader(); w.writerows(shard_audit)

by=defaultdict(dict); meta={}
for r in rows_out:
    by[r["discovery_index"]][r["system"]]=r["success"]
    meta[r["discovery_index"]]={
        "suite":r["suite"],"task_name":r["task_name"],
        "task_id":r["task_id"],"category":r["category"],
        "difficulty_level":r["difficulty_level"],
    }

wide_fields=["discovery_index","suite","task_name","task_id","category","difficulty_level",*systems]
with open(out/"holdout_wide_500x3.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=wide_fields); w.writeheader()
    for idx in sorted(by):
        row={"discovery_index":idx,**meta[idx]}; row.update(by[idx]); w.writerow(row)

scores={}
for s in systems:
    rr=[r for r in rows_out if r["system"]==s]
    succ=sum(r["success"] for r in rr)
    scores[s]={"success":succ,"total":len(rr),"score":succ/len(rr) if rr else None}

family_pi=(scores["pi05"]["score"]+scores["pi0_fast"]["score"])/2
family_vx=scores["vlanext"]["score"]
family_bal=(family_pi+family_vx)/2

report={
    "gate":"PASS" if not problems else "FAIL",
    "expected_rows":1500,
    "observed_rows":len(rows_out),
    "engineering_errors":sum(r["status"] not in ("success","fail") for r in rows_out),
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
    selected_sources.tsv \
    canonical_selected_normalized.tsv
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
TASK=RECOVER_AND_AUDIT_PROSPECTIVE_HOLDOUT_D500
GATE=PASS
CANONICAL_SHARDS=60
RECOVERED_MISSING_SHARDS=$RECOVERED
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
