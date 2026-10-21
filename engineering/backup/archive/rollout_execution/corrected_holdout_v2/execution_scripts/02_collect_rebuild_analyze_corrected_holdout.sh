#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$HOME/.local/bin:$PATH"

: "${VLA_IRT_ARTIFACT_ROOT:?Set VLA_IRT_ARTIFACT_ROOT to the directory that contains the archived D500 artifact directories}"
HERE="$VLA_IRT_ARTIFACT_ROOT"
WS="wsp-REDACTED000001"
SSH_KEY="$HOME/.ssh/YOUR_KEY.pem"
FALLBACK_HOST="YOUR_SSH_HOST.invalid"
FALLBACK_PORT="YOUR_SSH_PORT"

RUN_TAG="d500-pi0fast-zscore-corrected-v2-20260829"
REMOTE_ROOT="/data/vla-irt-cat-v2/corrected_results_local/$RUN_TAG/pi0_fast"
REMOTE_OUT="/data/vla-irt-cat-v2/corrected_analysis/$RUN_TAG"
LOCAL_BUNDLE="$HERE/${RUN_TAG}-collected.tar.gz"
LOCAL_EXTRACT="$HERE/${RUN_TAG}-collected"
ORIG_HOLD="$HERE/d500-holdout-collected-20260829-164332"
CORR_HOLD="$HERE/d500-holdout-corrected-pi0fast-zscore-20260829"

RATE=1.55
HARD_CAP_H=1
MAX_BURN=1.55

echo "============================================================"
echo " COLLECT 500 + REBUILD HOLDOUT + FROZEN ANALYSIS"
echo "============================================================"
echo "New VESSL jobs:            0"
echo "Workspace resumed:         existing A100 x1"
echo "Expected collector time:   minutes"
echo "Hard collector budget:     ${HARD_CAP_H}h"
echo "Max workspace burn:        ~\$${MAX_BURN}"
echo "GPU computation:           none; A100 only to mount /data"
echo "Remote result rows:        500"
echo "Existing holdout matrix:   preserved"
echo "Corrected holdout output:  $CORR_HOLD"
echo "============================================================"
read -rp "Proceed? [y/N] " OK
[[ "${OK,,}" == "y" ]] || { echo "ABORTED"; exit 0; }

test -s "$SSH_KEY" || { echo "ERROR=SSH_KEY_MISSING:$SSH_KEY"; exit 2; }
test -s "$ORIG_HOLD/holdout_long_1500.csv" || { echo "ERROR=ORIGINAL_LONG_MISSING"; exit 3; }
test -s "$ORIG_HOLD/holdout_wide_500x3.csv" || { echo "ERROR=ORIGINAL_WIDE_MISSING"; exit 4; }
command -v vesslctl >/dev/null
command -v ssh >/dev/null
command -v scp >/dev/null

echo
echo "===== 1. REQUIRE ALREADY-RUNNING WORKSPACE ====="
SHOW="$(vesslctl workspace show "$WS" 2>&1 || true)"
STATE="$(
  printf '%s\n' "$SHOW" |
  awk -F: '/^[[:space:]]*State:/ {
    sub(/^[^:]*:[[:space:]]*/,""); print tolower($0); exit
  }'
)"
echo "WORKSPACE_STATE=${STATE:-unknown}"
case "${STATE:-}" in
  running|ready) ;;
  *)
    echo "ERROR=WORKSPACE_NOT_RUNNING"
    echo "ACTION=START_WORKSPACE_THEN_REAUTHORIZE_SSH_KEY_IN_WEB_CONSOLE"
    printf '%s\n' "$SHOW"
    exit 10
    ;;
esac
echo "WORKSPACE_RUNNING=PASS"

echo
echo "===== 2. RESOLVE SSH ENDPOINT ====="
HOST="$(
  printf '%s\n' "$SHOW" |
  grep -oE '[A-Za-z0-9.-]+\.cloud\.vessl\.ai' |
  head -1 || true
)"
PORT="$(
  printf '%s\n' "$SHOW" |
  grep -oE -- '-p[[:space:]]+[0-9]+' |
  grep -oE '[0-9]+' |
  head -1 || true
)"
if [ -z "$PORT" ]; then
  PORT="$(
    printf '%s\n' "$SHOW" |
    grep -oE '[A-Za-z0-9.-]+\.cloud\.vessl\.ai:[0-9]+' |
    head -1 |
    sed -E 's/.*:([0-9]+)$/\1/' || true
  )"
fi
HOST="${HOST:-$FALLBACK_HOST}"
PORT="${PORT:-$FALLBACK_PORT}"
echo "SSH_HOST=$HOST"
echo "SSH_PORT=$PORT"

set +e
ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=15 \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -p "$PORT" \
  "root@$HOST" \
  'echo SSH_GATE=PASS' >/tmp/pi0fast-ssh-test.out 2>&1
SSH_RC=$?
set -e
cat /tmp/pi0fast-ssh-test.out
if [ "$SSH_RC" -ne 0 ]; then
  echo "ERROR=SSH_GATE_FAILED"
  echo "WORKSPACE_LEFT_RUNNING=YES"
  echo "ACTION=REAUTHORIZE_SSH_KEY_IN_WEB_CONSOLE_THEN_RERUN_THIS_SCRIPT"
  echo "===== WORKSPACE SHOW ====="
  printf '%s\n' "$SHOW"
  exit 11
fi

echo
echo "===== 3. BUILD REMOTE 500-ROW COLLECTOR ====="
REMOTE_SCRIPT="$(mktemp)"
cat > "$REMOTE_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=/data/vla-irt-cat-v2
RUN_TAG=d500-pi0fast-zscore-corrected-v2-20260829
SRC=$ROOT/corrected_results_local/$RUN_TAG/pi0_fast
OUT=$ROOT/corrected_analysis/$RUN_TAG
MANIFEST=$ROOT/manifests/discovery_500_primary.json
D500_SHA=87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1
WRAPPER=$ROOT/v2_tools/libero_plus_selected_v3.py
WRAPPER_SHA=0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae
OPENPI_PIN=981483dca0fd9acba698fea00aa6e52d56a66c58

rm -rf "$OUT"
mkdir -p "$OUT"

test -s "$MANIFEST"
test "$(sha256sum "$MANIFEST" | awk '{print $1}')" = "$D500_SHA"
test "$(sha256sum "$WRAPPER" | awk '{print $1}')" = "$WRAPPER_SHA"

python3 - "$SRC" "$OUT" "$MANIFEST" "$OPENPI_PIN" <<'PY'
from __future__ import annotations
import csv, json, sqlite3, sys, hashlib
from pathlib import Path
from collections import Counter, defaultdict

src=Path(sys.argv[1])
out=Path(sys.argv[2])
manifest_path=Path(sys.argv[3])
openpi_pin=sys.argv[4]

suites=["libero_10","libero_goal","libero_object","libero_spatial"]
expected_suite={
    "libero_10":125,
    "libero_goal":125,
    "libero_object":126,
    "libero_spatial":124,
}
shards=15

manifest=json.load(open(manifest_path,encoding="utf-8"))
all_items=manifest["items"]
assert len(all_items)==500
canon={int(x["discovery_index"]):x for x in all_items}
assert set(canon)==set(range(500))

def parse_env(path:Path):
    d={}
    for line in path.read_text().splitlines():
        if "=" in line:
            k,v=line.split("=",1)
            d[k]=v
    return d

def item_language(x):
    for k in ("language","task_name","instruction","prompt"):
        v=x.get(k)
        if isinstance(v,str):
            return v
    return None

rows=[]
problems=[]
shard_audit=[]
mapping_modes=Counter()

for suite in suites:
    for shard in range(shards):
        d=src/suite/f"s{shard}of{shards}"
        if not d.is_dir():
            problems.append(f"MISSING_DIR {d}")
            continue

        req=["summary.env","shard_manifest.json","response_audit.json"]
        for f in req:
            if not (d/f).is_file():
                problems.append(f"MISSING_FILE {d/f}")

        if any(not (d/f).is_file() for f in req):
            continue

        env=parse_env(d/"summary.env")
        if env.get("GATE")!="PASS":
            problems.append(f"BAD_GATE {suite} s{shard}: {env.get('GATE')}")
        if env.get("OPENPI_PIN")!=openpi_pin:
            problems.append(f"BAD_OPENPI_PIN {suite} s{shard}: {env.get('OPENPI_PIN')}")
        if env.get("USE_QUANTILE_NORM","").lower()!="false":
            problems.append(f"BAD_NORM {suite} s{shard}: {env.get('USE_QUANTILE_NORM')}")
        if "PR971_ZSCORE" not in env.get("CORRECTION",""):
            problems.append(f"BAD_CORRECTION {suite} s{shard}: {env.get('CORRECTION')}")

        sm=json.load(open(d/"shard_manifest.json",encoding="utf-8"))
        items=sm["items"]
        audit=json.load(open(d/"response_audit.json",encoding="utf-8"))
        if audit.get("expected")!=len(items):
            problems.append(f"AUDIT_EXPECTED_MISMATCH {suite} s{shard}")
        if audit.get("observed")!=len(items):
            problems.append(f"AUDIT_OBSERVED_MISMATCH {suite} s{shard}")
        if audit.get("engineering_errors"):
            problems.append(f"ENGINEERING_ERRORS {suite} s{shard}")

        dbs=list((d/"results").rglob("recording-*.sqlite"))
        if len(dbs)!=1:
            problems.append(f"SQLITE_COUNT {suite} s{shard} count={len(dbs)}")
            continue

        con=sqlite3.connect(dbs[0])
        cols=[r[1] for r in con.execute("pragma table_info(episode_results)").fetchall()]
        want=["task_name","status","steps","failure_reason","failure_detail","context"]
        miss=[c for c in want if c not in cols]
        if miss:
            problems.append(f"SQLITE_COLUMNS {suite} s{shard} missing={miss}")
            con.close()
            continue
        eps=con.execute(
            "select task_name,status,steps,failure_reason,failure_detail,context "
            "from episode_results order by rowid"
        ).fetchall()
        con.close()

        if len(eps)!=len(items):
            problems.append(f"ROW_COUNT {suite} s{shard} eps={len(eps)} items={len(items)}")
            continue
        bad=[r for r in eps if r[1] not in ("success","fail")]
        if bad:
            problems.append(f"BAD_STATUS {suite} s{shard} n={len(bad)}")
            continue

        langs=[item_language(x) for x in items]
        if all(langs) and len(set(langs))==len(langs) and set(r[0] for r in eps)==set(langs):
            by_lang={v:i for i,v in enumerate(langs)}
            pairs=[(items[by_lang[r[0]]],r) for r in eps]
            mapping="task_name"
        else:
            pairs=list(zip(items,eps))
            mapping="position"
            for pos,(it,ep) in enumerate(pairs):
                try:
                    ctx=json.loads(ep[5]) if ep[5] else {}
                except Exception:
                    ctx={}
                for key in ("suite","task_id","category","difficulty_level"):
                    if key in it and key in ctx and it[key]!=ctx[key]:
                        problems.append(
                            f"POSITION_MISMATCH {suite} s{shard} row={pos} "
                            f"key={key} manifest={it[key]!r} context={ctx[key]!r}"
                        )
        mapping_modes[mapping]+=1

        for it,ep in pairs:
            idx=int(it["discovery_index"])
            try:
                ctx=json.loads(ep[5]) if ep[5] else {}
            except Exception:
                ctx={}
            rows.append({
                "system":"pi0_fast",
                "family":"pi_openpi",
                "discovery_index":idx,
                "suite":suite,
                "task_name":ep[0],
                "status":ep[1],
                "success":1 if ep[1]=="success" else 0,
                "steps":ep[2],
                "failure_reason":ep[3],
                "failure_detail":ep[4],
                "task_id":ctx.get("task_id",it.get("task_id")),
                "category":ctx.get("category",it.get("category")),
                "difficulty_level":ctx.get(
                    "difficulty_level",
                    it.get("difficulty_level",it.get("difficulty"))
                ),
                "shard":shard,
                "mapping":mapping,
            })

        shard_audit.append({
            "suite":suite,
            "shard":shard,
            "expected":len(items),
            "observed":len(eps),
            "success":sum(r[1]=="success" for r in eps),
            "fail":sum(r[1]=="fail" for r in eps),
            "mapping":mapping,
            "openpi_pin":env.get("OPENPI_PIN"),
            "normalization":env.get("USE_QUANTILE_NORM"),
            "correction":env.get("CORRECTION"),
        })

# Global invariants.
if len(shard_audit)!=60:
    problems.append(f"SHARD_AUDIT_COUNT={len(shard_audit)} expected=60")
if len(rows)!=500:
    problems.append(f"ROW_TOTAL={len(rows)} expected=500")

keys=Counter(r["discovery_index"] for r in rows)
dups=[k for k,v in keys.items() if v!=1]
if dups:
    problems.append(f"NONUNIQUE_INDICES={dups[:20]}")
if set(keys)!=set(range(500)):
    missing=sorted(set(range(500))-set(keys))
    extra=sorted(set(keys)-set(range(500)))
    problems.append(f"INDEX_COVERAGE missing={missing[:20]} extra={extra[:20]}")

for r in rows:
    c=canon.get(r["discovery_index"])
    if c is None: continue
    for k in ("suite","task_id","category"):
        rv=r.get(k)
        cv=c.get(k)
        if rv not in (None,"") and cv not in (None,"") and str(rv)!=str(cv):
            problems.append(
                f"CANON_MISMATCH idx={r['discovery_index']} key={k} row={rv!r} canon={cv!r}"
            )

suite_counts=Counter(r["suite"] for r in rows)
if dict(suite_counts)!=expected_suite:
    problems.append(f"SUITE_COUNTS={dict(suite_counts)} expected={expected_suite}")

success=sum(r["success"] for r in rows)
score=success/500 if len(rows)==500 else None

fieldnames=[
    "system","family","discovery_index","suite","task_name","status","success",
    "steps","failure_reason","failure_detail","task_id","category",
    "difficulty_level","shard","mapping"
]
rows=sorted(rows,key=lambda r:r["discovery_index"])
with open(out/"pi0fast_corrected_long_500.csv","w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=fieldnames)
    w.writeheader(); w.writerows(rows)

with open(out/"pi0fast_corrected_wide_500x1.csv","w",newline="",encoding="utf-8") as f:
    fields=["discovery_index","suite","task_name","task_id","category","difficulty_level","pi0_fast"]
    w=csv.DictWriter(f,fieldnames=fields)
    w.writeheader()
    for r in rows:
        w.writerow({
            "discovery_index":r["discovery_index"],
            "suite":r["suite"],
            "task_name":r["task_name"],
            "task_id":r["task_id"],
            "category":r["category"],
            "difficulty_level":r["difficulty_level"],
            "pi0_fast":r["success"],
        })

with open(out/"shard_audit.csv","w",newline="",encoding="utf-8") as f:
    fields=list(shard_audit[0].keys()) if shard_audit else []
    w=csv.DictWriter(f,fieldnames=fields)
    if fields:
        w.writeheader(); w.writerows(shard_audit)

by_suite={}
for s in suites:
    rs=[r for r in rows if r["suite"]==s]
    by_suite[s]={
        "success":sum(r["success"] for r in rs),
        "total":len(rs),
        "score":sum(r["success"] for r in rs)/len(rs) if rs else None,
    }

by_cat={}
for cat in sorted(set(r["category"] for r in rows)):
    rs=[r for r in rows if r["category"]==cat]
    by_cat[cat]={
        "success":sum(r["success"] for r in rs),
        "total":len(rs),
        "score":sum(r["success"] for r in rs)/len(rs) if rs else None,
    }

report={
    "gate":"PASS" if not problems else "FAIL",
    "expected_rows":500,
    "observed_rows":len(rows),
    "expected_shards":60,
    "observed_shards":len(shard_audit),
    "engineering_errors":sum(
        1 for p in problems if "ENGINEERING" in p or "BAD_STATUS" in p
    ),
    "problems":problems,
    "openpi_pin":openpi_pin,
    "normalization":"z-score",
    "use_quantile_norm":False,
    "correction":"PR971 z-score compatibility backport only",
    "success":success,
    "total":len(rows),
    "score":score,
    "suite_scores":by_suite,
    "category_scores":by_cat,
    "mapping_modes":dict(mapping_modes),
}
(out/"audit_report.json").write_text(
    json.dumps(report,indent=2,ensure_ascii=False)+"\n",encoding="utf-8"
)

print("COLLECTED_SHARDS="+str(len(shard_audit)))
print("TOTAL_RESPONSES="+str(len(rows)))
print("TOTAL_SUCCESS="+str(success))
print(f"CORRECTED_D500_SCORE={score:.6f}" if score is not None else "CORRECTED_D500_SCORE=NA")
print(f"CORRECTED_D500_SCORE_PERCENT={100*score:.2f}" if score is not None else "CORRECTED_D500_SCORE_PERCENT=NA")
print("MAPPING_MODES="+json.dumps(dict(mapping_modes),sort_keys=True))
print("PROBLEMS="+str(len(problems)))
for p in problems[:50]:
    print("PROBLEM="+p)
print("CORRECTED_D500_GATE="+report["gate"])
if problems:
    raise SystemExit(20)
PY

(
  cd "$OUT"
  sha256sum pi0fast_corrected_long_500.csv \
            pi0fast_corrected_wide_500x1.csv \
            shard_audit.csv \
            audit_report.json > SHA256SUMS.txt
)

tar -C "$(dirname "$OUT")" -czf "$OUT.tar.gz" "$(basename "$OUT")"
sha256sum "$OUT.tar.gz" > "$OUT.tar.gz.sha256"

echo
echo "REMOTE_BUNDLE=$OUT.tar.gz"
echo "REMOTE_BUNDLE_SHA256=$(sha256sum "$OUT.tar.gz" | awk '{print $1}')"
echo "REMOTE_COLLECT_GATE=PASS"
REMOTE

scp \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -P "$PORT" \
  "$REMOTE_SCRIPT" \
  "root@$HOST:/root/collect_pi0fast_corrected_500.sh"
rm -f "$REMOTE_SCRIPT"

echo
echo "===== 4. RUN REMOTE COLLECTOR ====="
ssh \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -p "$PORT" \
  "root@$HOST" \
  'chmod 700 /root/collect_pi0fast_corrected_500.sh && bash /root/collect_pi0fast_corrected_500.sh' \
  | tee "$HERE/${RUN_TAG}-remote-collect.log"

grep -q '^REMOTE_COLLECT_GATE=PASS$' "$HERE/${RUN_TAG}-remote-collect.log" || {
  echo "ERROR=REMOTE_COLLECT_GATE_FAILED"
  exit 20
}

echo
echo "===== 5. DOWNLOAD CORRECTED 500 BUNDLE ====="
rm -f "$LOCAL_BUNDLE"
scp \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -P "$PORT" \
  "root@$HOST:$REMOTE_OUT.tar.gz" \
  "$LOCAL_BUNDLE"

scp \
  -o IdentitiesOnly=yes \
  -i "$SSH_KEY" \
  -P "$PORT" \
  "root@$HOST:$REMOTE_OUT.tar.gz.sha256" \
  "$LOCAL_BUNDLE.sha256.remote"

echo "LOCAL_BUNDLE_SHA256=$(sha256sum "$LOCAL_BUNDLE" | awk '{print $1}')"
cat "$LOCAL_BUNDLE.sha256.remote"

echo
echo "===== 6. PAUSE WORKSPACE NOW ====="
vesslctl workspace pause "$WS" >/dev/null
echo "WORKSPACE_PAUSE=PASS"

echo
echo "===== 7. EXTRACT LOCAL BUNDLE ====="
rm -rf "$LOCAL_EXTRACT"
mkdir -p "$LOCAL_EXTRACT"
tar -xzf "$LOCAL_BUNDLE" -C "$LOCAL_EXTRACT" --strip-components=1
test -s "$LOCAL_EXTRACT/pi0fast_corrected_long_500.csv"
test -s "$LOCAL_EXTRACT/audit_report.json"
cat "$LOCAL_EXTRACT/audit_report.json"

echo
echo "===== 8. REBUILD CORRECTED 1500-ROW HOLDOUT ====="
rm -rf "$CORR_HOLD"
mkdir -p "$CORR_HOLD"

python3 - \
  "$ORIG_HOLD/holdout_long_1500.csv" \
  "$ORIG_HOLD/holdout_wide_500x3.csv" \
  "$LOCAL_EXTRACT/pi0fast_corrected_long_500.csv" \
  "$CORR_HOLD" <<'PY'
import csv,json,sys
from pathlib import Path
from collections import Counter

orig_long=Path(sys.argv[1])
orig_wide=Path(sys.argv[2])
corr_pi=Path(sys.argv[3])
out=Path(sys.argv[4])

def read_csv(p):
    with p.open(newline="",encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

ol=read_csv(orig_long)
ow=read_csv(orig_wide)
cp=read_csv(corr_pi)

assert len(ol)==1500
assert len(ow)==500
assert len(cp)==500
assert Counter(r["system"] for r in ol)=={"pi05":500,"pi0_fast":500,"vlanext":500}
assert all(r["system"]=="pi0_fast" for r in cp)

corr_by={int(r["discovery_index"]):r for r in cp}
assert set(corr_by)==set(range(500))

# Preserve original pi05 and vlanext rows exactly; replace only pi0_fast.
keep=[r for r in ol if r["system"]!="pi0_fast"]
rows=keep+cp
order={"pi05":0,"pi0_fast":1,"vlanext":2}
rows=sorted(rows,key=lambda r:(order[r["system"]],int(r["discovery_index"])))
assert len(rows)==1500

long_fields=list(ol[0].keys())
assert list(cp[0].keys())==long_fields,(list(cp[0].keys()),long_fields)

with (out/"holdout_long_1500.csv").open("w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=long_fields)
    w.writeheader(); w.writerows(rows)

# Preserve all original wide metadata and the two unaffected systems;
# replace pi0_fast only.
wide_fields=list(ow[0].keys())
assert "pi0_fast" in wide_fields
wide=[]
for r in ow:
    i=int(r["discovery_index"])
    q=dict(r)
    q["pi0_fast"]=str(int(float(corr_by[i]["success"])))
    wide.append(q)

with (out/"holdout_wide_500x3.csv").open("w",newline="",encoding="utf-8") as f:
    w=csv.DictWriter(f,fieldnames=wide_fields)
    w.writeheader(); w.writerows(wide)

# Full score audit.
scores={}
for s in ("pi05","pi0_fast","vlanext"):
    rr=[r for r in rows if r["system"]==s]
    suc=sum(int(float(r["success"])) for r in rr)
    scores[s]={"success":suc,"total":500,"score":suc/500}

pi_family=(scores["pi05"]["score"]+scores["pi0_fast"]["score"])/2
fam_bal=(pi_family+scores["vlanext"]["score"])/2

audit={
    "gate":"PASS",
    "expected_rows":1500,
    "observed_rows":1500,
    "engineering_errors":0,
    "problems":[],
    "scores":scores,
    "family_balanced_full_score":{
        "pi_openpi":pi_family,
        "vlanext":scores["vlanext"]["score"],
        "mean":fam_bal,
    },
    "correction":{
        "system":"pi0_fast",
        "reason":"OpenPI pi0_fast_libero normalization regression",
        "openpi_pin":"981483dca0fd9acba698fea00aa6e52d56a66c58",
        "fix":"PR971 z-score compatibility backport only",
        "use_quantile_norm":False,
        "original_rows_preserved_for":["pi05","vlanext"],
    },
}
(out/"audit_report.json").write_text(
    json.dumps(audit,indent=2,ensure_ascii=False)+"\n",encoding="utf-8"
)

print("CORRECTED_HOLDOUT_ROWS=1500")
for s,v in scores.items():
    print(f"{s.upper()}_FULL_SCORE={v['score']:.6f}")
    print(f"{s.upper()}_FULL_SCORE_PERCENT={100*v['score']:.2f}")
print(f"FAMILY_BALANCED_FULL_SCORE={fam_bal:.6f}")
print("CORRECTED_HOLDOUT_GATE=PASS")
PY

cp "$LOCAL_EXTRACT/audit_report.json" "$CORR_HOLD/pi0fast_corrected_500_audit.json"
cp "$LOCAL_EXTRACT/shard_audit.csv" "$CORR_HOLD/pi0fast_corrected_shard_audit.csv"
cp "$LOCAL_EXTRACT/SHA256SUMS.txt" "$CORR_HOLD/pi0fast_corrected_SHA256SUMS.txt"

sha256sum \
  "$CORR_HOLD/holdout_long_1500.csv" \
  "$CORR_HOLD/holdout_wide_500x3.csv" \
  "$CORR_HOLD/audit_report.json" \
  > "$CORR_HOLD/input_SHA256SUMS.txt"

echo
echo "===== 9. RUN EXACT FROZEN PROSPECTIVE ANALYSIS ====="
ANALYSIS_SRC=""
for C in \
  "$HERE/d500-critical3-collected-20260829/repo/reproducibility/prospective_holdout_d500_v1/09_run_frozen_prospective_analysis.sh" \
  "$HERE/d500-holdout-collected-20260829-164332/repo/reproducibility/prospective_holdout_d500_v1/09_run_frozen_prospective_analysis.sh"
do
  if [ -s "$C" ]; then ANALYSIS_SRC="$C"; break; fi
done
if [ -z "$ANALYSIS_SRC" ]; then
  ANALYSIS_SRC="$(
    find "$HERE" -maxdepth 8 -type f -name '09_run_frozen_prospective_analysis.sh' \
      -print 2>/dev/null | head -1 || true
  )"
fi
test -s "$ANALYSIS_SRC" || {
  echo "ERROR=FROZEN_ANALYSIS_SCRIPT_NOT_FOUND"
  exit 30
}
echo "ANALYSIS_SOURCE=$ANALYSIS_SRC"

ANALYSIS_RUN="$CORR_HOLD/run_frozen_prospective_analysis_corrected.sh"
cp "$ANALYSIS_SRC" "$ANALYSIS_RUN"

python3 - "$ANALYSIS_RUN" "$CORR_HOLD" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
root=sys.argv[2]
s=p.read_text()
lines=s.splitlines()
out=[]
done=False
for line in lines:
    if line.startswith('HOLDROOT='):
        out.append(f'HOLDROOT="{root}"')
        done=True
    else:
        out.append(line)
assert done
p.write_text("\n".join(out)+"\n")
PY
chmod +x "$ANALYSIS_RUN"

bash "$ANALYSIS_RUN" | tee "$CORR_HOLD/frozen_analysis_run.log"

echo
echo "===== 10. KEY CORRECTED PROSPECTIVE RESULTS ====="
OVER="$CORR_HOLD/prospective_frozen_methods_v1/prospective_overall_summary.csv"
SYS="$CORR_HOLD/prospective_frozen_methods_v1/prospective_system_summary.csv"
DELTA="$CORR_HOLD/prospective_frozen_methods_v1/prospective_key_deltas.csv"
test -s "$OVER"
test -s "$SYS"

python3 - "$OVER" "$SYS" "$CORR_HOLD/audit_report.json" <<'PY'
import csv,json,sys
from collections import defaultdict

over=list(csv.DictReader(open(sys.argv[1],newline="",encoding="utf-8")))
sysrows=list(csv.DictReader(open(sys.argv[2],newline="",encoding="utf-8")))
audit=json.load(open(sys.argv[3]))

print("FULL_D500_SCORES")
for s,v in audit["scores"].items():
    print(f"  {s:10s} {100*v['score']:.2f}%")

print("\nOVERALL_FAMILY_BALANCED_MAE_PP")
for B in (80,160,320):
    rr=[r for r in over if int(r["budget"])==B]
    rr=sorted(rr,key=lambda r:float(r["family_balanced_mae_pp"]))
    print(f"B={B}")
    for r in rr:
        print(f"  {r['method']:18s} {float(r['family_balanced_mae_pp']):.4f}  rank={r['rank']}")

print("\nB320_PER_SYSTEM")
for s in ("pi05","pi0_fast","vlanext"):
    rr=[r for r in sysrows if r["system"]==s and int(r["budget"])==320]
    keep={"STRAT_NEYMAN_CAL","STRAT_REG","ADAPT20_REG"}
    rr=[r for r in rr if r["method"] in keep]
    print(s)
    for r in sorted(rr,key=lambda r:r["method"]):
        print(f"  {r['method']:18s} MAE={float(r['mae_pp']):.4f} P90={float(r['p90_abs_pp']):.4f} GT5={float(r['gt5_rate']):.5f}")

print("\nIMPORTANT_B80_NOTE=STRAT_REG_AND_ADAPT20_REG_SHARE_THE_SAME_80_ITEM_ANCHOR_PROCEDURE; any tiny difference in this producer is independent Monte Carlo stream noise, not an adaptive effect.")
print("FROZEN_CORRECTED_ANALYSIS=PASS")
PY

if [ -s "$DELTA" ]; then
  echo
  echo "===== KEY DELTAS ====="
  cat "$DELTA"
fi

SUMMARY="$(cat <<EOF
===== CHATGPT_SUMMARY =====
TASK=COLLECT_REBUILD_ANALYZE_PI0FAST_CORRECTED
REMOTE_60_SHARDS=PASS
CORRECTED_500_AUDIT=PASS
CORRECTED_HOLDOUT_1500=PASS
FROZEN_ANALYSIS=PASS
WORKSPACE_PAUSED=YES
CORRECTED_BUNDLE=$LOCAL_BUNDLE
CORRECTED_HOLDOUT=$CORR_HOLD
OVERALL_RESULTS=$OVER
SYSTEM_RESULTS=$SYS
NEXT=UPDATE_PAPER_FIGURE_TABLE_TEXT_FROM_CORRECTED_RESULTS
===========================
EOF
)"
echo
echo "$SUMMARY"

if command -v clip.exe >/dev/null 2>&1; then
  printf '%s\n' "$SUMMARY" | clip.exe || true
  echo "CHATGPT_SUMMARY_COPIED=YES"
fi
