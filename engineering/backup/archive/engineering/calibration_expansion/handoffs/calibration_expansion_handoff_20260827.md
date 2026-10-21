# VLA-IRT-CAT v2 — Calibration Family Expansion Handoff

## Status

**FAMILY_EXPANSION_ENGINEERING_PREPARATION_COMPLETE**

This work was performed prospectively and independently of current
Discovery-500 and QUAL24 outcomes.

## Frozen preregistration

- Selection timestamp: 2026-08-27T08:34:55+09:00
- Preregistration commit:
  `35860e9266339424cc2ae5427f17ed86c0267e9c`
- Manifest SHA256:
  `6514d679d1ce0128a98a67e2c0e8fa4e7e0042712717a8c28e863d57e7664f59`

The preregistered candidate set was not changed after static qualification.

## Primary families prepared

| Family | Source/static | Adapter | Current state |
|---|---|---|---|
| VLA-Adapter | PASS | custom overlay CPU-static PASS | READY_FOR_MATERIALIZATION_AND_GPU_SMOKE |
| Xiaomi-Robotics-0 | PASS | custom overlay CPU-static PASS | READY_FOR_MATERIALIZATION_AND_GPU_SMOKE |
| OpenDriveLab UniVLA | PASS | custom overlay CPU-static PASS | READY_FOR_MATERIALIZATION_AND_GPU_SMOKE |
| LingBot-VA | PASS | existing pinned harness LeRobot integration | READY_FOR_MATERIALIZATION_AND_GPU_SMOKE |

## Conditional / reserve

- NORA: `HOLD_LICENSE_NO_GPU`
  - Public checkpoint and LIBERO evaluation path exist.
  - Exact source/artifact usage authority remains unresolved.
  - Do not execute GPU qualification until that gate is resolved.

- BAAI UniVLA: `RESERVE_NOT_SCHEDULED`
  - Public checkpoint exists.
  - Retained prospectively as reserve.
  - Do not promote based on performance of the primary candidates.

## Existing governance retained

- RynnVLA-002: excluded due to preexisting Chameleon asset
  legal/access-authority rule.
- WorldVLA: same lineage as RynnVLA for family accounting.
- StarVLA: merged into OpenVLA under preexisting family governance.

## Adapter commits

- Static qualification:
  `93e70b885aeace328a1551079910e66d4e0bd08f`
- Source/adapter contracts:
  `ae1b8cd6a537d186c7d3c21c7d6b1eb51fe9cad2`
- Xiaomi-Robotics-0:
  `72dce68fac527233675a66d39b23284a9ab20445`
- VLA-Adapter:
  `207f87079b832f1656c497fc957119324faaec5f`
- OpenDriveLab UniVLA:
  `5f4c051f81c74789949484b60aa9c229dcda2797`

Harness pin:
`2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56`

## What was NOT done

- No GPU qualification Job was submitted.
- No new VLA rollout was executed.
- No Discovery-500 outcome was used.
- No QUAL24 outcome was used.
- No success-rate threshold was used for inclusion/exclusion.
- The active Discovery-500 experiment was not modified.

## GPU smoke plan

Machine-readable plan:

`manifests/calibration_expansion_gpu_smoke_plan_v1.json`

The planned smoke gate is engineering-only.

A model passes engineering smoke if pinned artifacts load, the model server
becomes healthy, observations are accepted, finite correctly shaped actions
are produced, and the simulator can execute at least one control step.

Task success is explicitly NOT a qualification criterion.

## Research-director decision required

The research-director / general ChatGPT session should decide:

1. Whether to authorize materialization and GPU engineering smoke for the
   four primary families.
2. How the successfully qualified new families are assigned between
   calibration and prospective holdout under the preexisting split rules.
3. Whether NORA license authority can be resolved prospectively.
4. Whether BAAI UniVLA should remain reserve or be activated only under a
   preregistered non-performance contingency.
5. The final distinct-family count after reconciling the existing
   OpenVLA/StarVLA and calibration/holdout governance.

Do not reopen family selection using Discovery-500 or QUAL24 performance.
