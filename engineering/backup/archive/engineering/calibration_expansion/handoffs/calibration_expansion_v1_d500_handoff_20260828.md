# Calibration Expansion v1 — Critical-3 D500 Handoff

**Status:** `CALIBRATION_EXPANSION_ENGINEERING_SMOKE_COMPLETE`

## Critical path
- VLA-Adapter: `D500_READY=YES`
  - `SYSTEM_SLUG=vla_adapter`
  - `EXPECTED_RESULT_PATH=/scratch/calexp/results/discovery500/vla_adapter/d500-vla_adapter-calexp-v1/final`
  - `PROTOCOL_MATCH=YES`
  - engineering smoke job: `job-REDACTED000007`
- Xiaomi-Robotics-0: `D500_READY=YES`
  - `SYSTEM_SLUG=xiaomi_robotics_0`
  - `EXPECTED_RESULT_PATH=/scratch/calexp/results/discovery500/xiaomi_robotics_0/d500-xiaomi_robotics_0-calexp-v1/final`
  - `PROTOCOL_MATCH=YES`
  - engineering smoke job: `job-REDACTED000001`
- OpenDriveLab UniVLA: `D500_READY=YES`
  - `SYSTEM_SLUG=univla_opendrivelab`
  - `EXPECTED_RESULT_PATH=/scratch/calexp/results/discovery500/univla_opendrivelab/d500-univla_opendrivelab-calexp-v1/final`
  - `PROTOCOL_MATCH=YES`
  - engineering smoke job: `job-REDACTED000003`

## Governance
- LingBot 4-suite compatibility: `DEFERRED_NOT_RUN`.
- `TASK_SUCCESS_USED=false`
- `DISCOVERY500_OUTCOME_USED=false`
- `QUAL24_OUTCOME_USED=false`
- Existing Discovery-500 outcome data were not inspected.

## Protocol
- Frozen D500 manifest: `/data/vla-irt-cat-v2/manifests/discovery_500_primary.json`
- Manifest SHA256: `87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1`
- Canonical wrapper: `/data/vla-irt-cat-v2/v2_tools/libero_plus_selected_v3.py`
- Wrapper SHA256: `0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae`
- `seed=7`, `env_seed=7`, `num_steps_wait=10`
- suite-specific max steps unchanged

## UniVLA
- Canonical expansion adapter supplies `task_suite_name="libero"`.
