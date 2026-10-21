# VLA evaluation integration code

- `benchmark/libero_plus_selected_v3.py`: final frozen 500-item wrapper.
- `adapters/calibration_expansion/`: VLA-Adapter, Xiaomi Robotics-0, and
  UniVLA OpenDriveLab evaluation-server adapters.

After `scripts/bootstrap_sources.sh`, run
`scripts/install_harness_overlay.sh` to copy these adapters into the pinned
evaluation harness and render the portable templates in `configs/models/`.

IRT, LOFO, static sampling, adaptive CAT, and reviewer-diagnostic producers
are under `reproducibility/` because they are executed directly by the
reproduction workflow.
