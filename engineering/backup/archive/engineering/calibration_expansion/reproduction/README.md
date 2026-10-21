# Calibration-expansion engineering-smoke reproduction

Canonical successful engineering-smoke evidence:

- `smoke_v5/`: VLA-Adapter and Xiaomi-Robotics-0 successful model load, health check, and one-step inference.
- `smoke_v7/`: OpenDriveLab UniVLA successful model load, health check, and one-step inference.
- Canonical model-server implementations and configs live under `../integrations/vla_eval_overlay/`.
- Source revisions are frozen by the calibration-expansion source-pin manifest.
- Python runtime directories, model weights, caches, raw rollout databases, and credentials are intentionally excluded from Git.

Final calibration-expansion commit preserved in provenance:
`08a6bc51eaa2890b41eb5ffd1080b983ee0c5e73`.

Engineering qualification is complete for the critical three systems. This directory is provenance/reproduction material, not a request to re-run qualification.
