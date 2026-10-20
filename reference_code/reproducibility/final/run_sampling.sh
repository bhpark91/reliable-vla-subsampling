#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
REPO=${REPO:-"$REPO_ROOT"}
MATRIX=${MATRIX:-"$REPO/data/calibration/calibration_wide_500x11.csv"}
LONG=${LONG:-"$REPO/data/calibration/calibration_long_5500.csv"}
STRICT=${STRICT:-"$REPO/reproducibility/reproduced/final/expanded_rasch/strict_stratified_summary.json"}
OUT=${OUT:-"$REPO/reproducibility/reproduced/final/expanded_sampling"}
PYTHON=${PYTHON:-python3}

test -d "$REPO/data" || { echo "ERROR=REPO_MISSING"; exit 2; }
test -s "$MATRIX" || { echo "ERROR=EXPANDED_MATRIX_MISSING"; exit 4; }
test -s "$LONG" || { echo "ERROR=EXPANDED_LONG_MISSING"; exit 5; }
test -s "$STRICT" || { echo "ERROR=STRICT_STRATIFIED_SUMMARY_MISSING"; exit 6; }

mkdir -p "$OUT/expanded"

echo "============================================================"
echo " FROZEN STRAT_REG / ADAPT20_REG EXPANDED HEAD-TO-HEAD"
echo "============================================================"
echo "Final result:      frozen algorithm on 11-system / 9-family matrix"
echo "Frozen: RIDGE=1/9, anchor=80, batch=40, adapt=8, explore=32"
echo "Budgets: 80,160,320"
echo "Expanded replicates: 5000"
echo "GPU jobs: 0"
echo "============================================================"

# Only the frozen mathematical helper is needed by the final 11-system analysis.
cp "$REPO/reproducibility/reproduce_rasch_lofo.py" "$OUT/reproduce_rasch_lofo.py"

echo "===== EXPANDED 11-SYSTEM FROZEN SAMPLING ====="

"$PYTHON" - \
  "$OUT/reproduce_rasch_lofo.py" \
  "$MATRIX" "$LONG" "$REPO" "$STRICT" "$OUT/expanded" <<'PY'
from __future__ import annotations

import csv
import importlib.util
import json
import sys
from pathlib import Path

import numpy as np

rr_path=Path(sys.argv[1])
matrix_path=Path(sys.argv[2])
long_path=Path(sys.argv[3])
repo=Path(sys.argv[4])
strict_path=Path(sys.argv[5])
out=Path(sys.argv[6])
out.mkdir(parents=True,exist_ok=True)

spec=importlib.util.spec_from_file_location("rr_frozen",rr_path)
rr=importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)

RIDGE=1/9
BUDGETS=(80,160,320)
ANCHOR=80
ADAPT_N=8
EXPLORE_N=32
SEED=20260824
REPS=5000

def read_csv(p):
    with Path(p).open(newline="") as f:
        return list(csv.DictReader(f))

w=read_csv(matrix_path)
systems=list(w[0].keys())[4:]
Y=np.array([[int(r[s]) for s in systems] for r in w],float)  # items x systems
assert Y.shape==(500,11)

l=read_csv(long_path)
fam={}
for r in l:
    if r["system"] in fam:
        assert fam[r["system"]]==r["family"]
    fam[r["system"]]=r["family"]
assert set(fam)==set(systems)
fams=sorted(set(fam.values()))
assert len(fams)==9

N=len(Y)
man_path=repo/"data/bank/discovery_500_primary.json"
man=json.loads(man_path.read_text())
items=sorted(man["items"],key=lambda x:int(x["discovery_index"]))
suite=np.array([x["suite"] for x in items],object)
sn=sorted(set(suite))
sg={s:np.where(suite==s)[0] for s in sn}

def alloc(caps,total):
    keys=list(caps)
    sz=np.array([caps[k] for k in keys],float)
    ideal=total*sz/sz.sum()
    n=np.floor(ideal).astype(int)
    rem=total-int(n.sum())
    for q in sorted(range(len(keys)),key=lambda q:(-(ideal-n)[q],keys[q])):
        if rem<=0:
            break
        if n[q]<sz[q]:
            n[q]+=1
            rem-=1
    return {k:int(n[q]) for q,k in enumerate(keys)}

def theta(y,b):
    r=(y.sum()+.5)/(len(y)+1)
    th=float(np.log(r/(1-r)))
    for _ in range(60):
        p=rr.expit(th-b)
        sc=float((y-p).sum()-RIDGE*th)
        inf=float((p*(1-p)).sum()+RIDGE)
        th2=float(np.clip(th+sc/inf,-12,12))
        if abs(th2-th)<1e-12:
            th=th2
            break
        th=th2
    return th

lofo={}
var={}
for f in fams:
    keep=[j for j,s in enumerate(systems) if fam[s]!=f]
    yt=Y[:,keep]
    lofo[f]=rr.fit_rasch(yt)
    var[f]=(yt.sum(1)>0)&(yt.sum(1)<yt.shape[1])

def rs(rng,av,n):
    al=alloc({s:int(np.sum(av[sg[s]])) for s in sn},n)
    o=[]
    for s in sn:
        pool=sg[s][av[sg[s]]]
        if al[s]:
            o.extend(rng.choice(pool,size=al[s],replace=False).tolist())
    return np.array(o,int)

def info(th,b,av,n,elig):
    mask=av&elig
    pools={s:sg[s][mask[sg[s]]] for s in sn}
    al=alloc({s:len(pools[s]) for s in sn},n)
    o=[]
    for s in sn:
        pool=pools[s]
        if not al[s]:
            continue
        p=rr.expit(th-b[pool])
        inf=p*(1-p)
        order=np.lexsort((pool,-inf))
        o.extend(pool[order[:al[s]]].tolist())
    return np.array(o,int)

def pred(y,b,tm,rm):
    ii=np.where(tm)[0]
    th=theta(y[ii],b[ii])
    pall=rr.expit(th-b)
    corr=0.0
    for s in sn:
        g=sg[s]
        take=g[rm[g]]
        if len(take):
            corr+=(len(g)/N)*float(np.mean(y[take]-pall[take]))
    return float(np.clip(float(pall.mean())+corr,0,1)),th

def fb(sm):
    return float(np.mean([
        np.mean([sm[s] for s in systems if fam[s]==f])
        for f in fams
    ]))

# Exact clean-room STRAT_REG RNG scheme.
se={B:{s:[] for s in systems} for B in BUDGETS}
rng=np.random.default_rng(SEED)
for rep in range(REPS):
    perms={s:rng.permutation(sg[s]) for s in sn}
    samples={}
    for B in BUDGETS:
        al=alloc({s:len(sg[s]) for s in sn},B)
        samples[B]=np.concatenate([perms[s][:al[s]] for s in sn])
    for j,snme in enumerate(systems):
        b=lofo[fam[snme]]["b"]
        truth=float(Y[:,j].mean())
        for B in BUDGETS:
            mask=np.zeros(N,bool)
            mask[samples[B]]=True
            pr,_=pred(Y[:,j],b,mask,mask)
            se[B][snme].append(abs(pr-truth)*100)

# Exact clean-room ADAPT20_REG RNG/acquisition scheme.
ae={B:{s:[] for s in systems} for B in BUDGETS}
for rep in range(REPS):
    for j,snme in enumerate(systems):
        b=lofo[fam[snme]]["b"]
        elig=var[fam[snme]]
        truth=float(Y[:,j].mean())
        sr=(SEED*1000003+rep*1009+(j+1)*9176)%(2**63-1)
        rng=np.random.default_rng(sr)
        av=np.ones(N,bool)
        a=rs(rng,av,80)
        av[a]=False
        sel=np.zeros(N,bool)
        sel[a]=True
        rnd=sel.copy()
        pr,th=pred(Y[:,j],b,sel,rnd)
        ae[80][snme].append(abs(pr-truth)*100)
        while sel.sum()<320:
            ad=info(th,b,av,8,elig)
            av[ad]=False
            ex=rs(rng,av,32)
            av[ex]=False
            sel[ad]=True
            sel[ex]=True
            rnd[ex]=True
            pr,th=pred(Y[:,j],b,sel,rnd)
            B=int(sel.sum())
            if B in (160,320):
                ae[B][snme].append(abs(pr-truth)*100)

# Summaries.
methods={}
system_rows=[]
family_rows=[]
for meth,err in [("STRAT_REG",se),("ADAPT20_REG",ae)]:
    mm={}
    for B in BUDGETS:
        sm={s:float(np.mean(err[B][s])) for s in systems}
        sys_mae=float(np.mean(list(sm.values())))
        fam_mae=fb(sm)
        family_maes={}
        for f in fams:
            vals=[sm[s] for s in systems if fam[s]==f]
            family_maes[f]=float(np.mean(vals))
            family_rows.append({
                "method":meth,"budget":B,"family":f,
                "n_systems":len(vals),"mae_pp":family_maes[f],
            })
        mm[str(B)]={
            "family_mae_pp":fam_mae,
            "system_mae_pp":sys_mae,
            "family_mae_by_family":family_maes,
        }
        for s in systems:
            arr=np.asarray(err[B][s],float)
            system_rows.append({
                "method":meth,
                "budget":B,
                "system":s,
                "family":fam[s],
                "mae_pp":float(arr.mean()),
                "p90_abs_pp":float(np.quantile(arr,.9)),
                "gt5_rate":float(np.mean(arr>5.0)),
                "replicates":REPS,
            })
    methods[meth]=mm

strict=json.loads(strict_path.read_text())
strict_overall={
    (int(r["budget"]),r["method"]):r
    for r in strict["overall"]
}

head=[]
for B in BUDGETS:
    candidates=[]
    for m in ("SRS","STRAT_PROP","STRAT_BAL","STRAT_NEYMAN_LOFO"):
        r=strict_overall[(B,m)]
        candidates.append({
            "method":m,
            "family_mae_pp":float(r["family_balanced_mae_pp"]),
            "source":"strict_classical",
        })
    for m in ("STRAT_REG","ADAPT20_REG"):
        candidates.append({
            "method":m,
            "family_mae_pp":float(methods[m][str(B)]["family_mae_pp"]),
            "source":"frozen_irt_sampling",
        })
    candidates=sorted(candidates,key=lambda x:x["family_mae_pp"])
    for rank,x in enumerate(candidates,1):
        x.update({"budget":B,"rank":rank})
        head.append(x)

# Bootstrap families for key deltas.
rngb=np.random.default_rng(20260829)
BOOT=10000
boot_rows=[]
pure_family={}
with (Path(strict_path).parent/"stratified_family_summary.csv").open(newline="") as f:
    strict_family=list(csv.DictReader(f))
for r in strict_family:
    pure_family[(r["family"],int(r["budget"]),r["method"])]=float(r["mae_pp"])

frozen_family={(r["family"],int(r["budget"]),r["method"]):float(r["mae_pp"]) for r in family_rows}

for B in BUDGETS:
    comparisons=[
        ("STRAT_REG","STRAT_NEYMAN_LOFO"),
        ("ADAPT20_REG","STRAT_NEYMAN_LOFO"),
        ("ADAPT20_REG","STRAT_REG"),
    ]
    for a,b in comparisons:
        diffs=[]
        for f in fams:
            av=frozen_family[(f,B,a)] if a in ("STRAT_REG","ADAPT20_REG") else pure_family[(f,B,a)]
            bv=frozen_family[(f,B,b)] if b in ("STRAT_REG","ADAPT20_REG") else pure_family[(f,B,b)]
            diffs.append(av-bv)
        diffs=np.asarray(diffs,float)
        boots=np.empty(BOOT)
        for k in range(BOOT):
            ix=rngb.integers(0,len(fams),size=len(fams))
            boots[k]=diffs[ix].mean()
        boot_rows.append({
            "budget":B,
            "method_a":a,
            "method_b":b,
            "delta_mae_pp_a_minus_b":float(diffs.mean()),
            "ci95_lo":float(np.quantile(boots,.025)),
            "ci95_hi":float(np.quantile(boots,.975)),
            "families":len(fams),
        })

def write_csv(path,rows):
    rows=list(rows)
    if not rows:
        return
    with Path(path).open("w",newline="") as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

write_csv(out/"expanded_system_summary.csv",system_rows)
write_csv(out/"expanded_family_summary.csv",family_rows)
write_csv(out/"expanded_head_to_head.csv",head)
write_csv(out/"expanded_family_bootstrap_deltas.csv",boot_rows)

body={
    "schema_version":"frozen_cleanroom_sampling_expanded_v1",
    "source_cleanroom_commit":"425ebeda4e5c0375a1a8072ed74b0da06a234369",
    "seed":SEED,
    "reps":REPS,
    "systems":len(systems),
    "families":len(fams),
    "items":500,
    "frozen_constants":{
        "RIDGE":RIDGE,
        "budgets":list(BUDGETS),
        "anchor":ANCHOR,
        "adaptive_per_batch":ADAPT_N,
        "random_exploration_per_batch":EXPLORE_N,
        "suite_stratification":True,
        "estimator":"Rasch + suite-stratified residual correction",
    },
    "methods":methods,
    "head_to_head":head,
    "bootstrap_deltas":boot_rows,
}
(out/"expanded_sampling_summary.json").write_text(json.dumps(body,indent=2)+"\n")

print("===== EXPANDED FROZEN SAMPLING =====")
for B in BUDGETS:
    print(f"--- B={B} ---")
    for m in ("STRAT_REG","ADAPT20_REG"):
        print(
            f"{m:14s} family_MAE="
            f"{methods[m][str(B)]['family_mae_pp']:.4f}pp "
            f"system_MAE={methods[m][str(B)]['system_mae_pp']:.4f}pp"
        )

print()
print("===== ALL-METHOD HEAD-TO-HEAD =====")
for B in BUDGETS:
    print(f"--- B={B} ---")
    rows=[r for r in head if r["budget"]==B]
    for r in sorted(rows,key=lambda x:x["rank"]):
        print(
            f"{r['rank']}. {r['method']:20s} "
            f"MAE={r['family_mae_pp']:.4f}pp "
            f"source={r['source']}"
        )

print()
print("===== KEY FAMILY-BOOTSTRAP DELTAS =====")
for r in boot_rows:
    print(
        f"B={r['budget']} {r['method_a']} - {r['method_b']}: "
        f"{r['delta_mae_pp_a_minus_b']:+.4f}pp "
        f"95%CI=[{r['ci95_lo']:+.4f},{r['ci95_hi']:+.4f}]"
    )

print()
print("===== CHATGPT_SUMMARY =====")
print("TASK=FROZEN_SAMPLING_EXPANDED_HEAD_TO_HEAD")
print("GATE=PASS")
print("DEVELOPMENT_8SYSTEM_GATE=PASS")
print("SYSTEMS=11")
print("FAMILIES=9")
print("REPS=5000")
for B in BUDGETS:
    print(f"B{B}_STRAT_REG_MAE_PP={methods['STRAT_REG'][str(B)]['family_mae_pp']:.6f}")
    print(f"B{B}_ADAPT20_REG_MAE_PP={methods['ADAPT20_REG'][str(B)]['family_mae_pp']:.6f}")
    best=min([r for r in head if r["budget"]==B],key=lambda x:x["family_mae_pp"])
    print(f"B{B}_BEST_METHOD={best['method']}")
    print(f"B{B}_BEST_MAE_PP={best['family_mae_pp']:.6f}")
print(f"OUTPUT={out}")
print("NEXT=INTERPRET_INCREMENTAL_VALUE_OF_IRT_AND_CAT")
print("===========================")
PY

echo
echo "===== OUTPUT FILES ====="
ls -lh "$OUT" "$OUT/expanded" | sed -n '1,50p'
