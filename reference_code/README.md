# Preserved full-analysis source — additional inputs required

These six files are copied unchanged from the reviewed full-data candidate:

- `reproducibility/final/run_calibration.sh`
- `reproducibility/final/run_sampling.sh`
- `reproducibility/final/run_holdout.sh`
- `reproducibility/reproduce_rasch_lofo.py`
- `reproducibility/pyproject.toml`
- `reproducibility/uv.lock`

They include the project analysis code, not upstream robot-model or benchmark
implementations. The full-data candidate already separated the obsolete
8-system development execution from the final 11-system analysis. This
restricted release makes no further change to those algorithms or seeds.

The shell scripts require the complete original metadata-bearing inputs,
including a bank manifest and original row order. They are **not the public
quick start** and will not run from `data/responses.csv` alone. Dependencies
in the lockfile are for this preserved source, not for the standard-library
public summary tools. No archived diagnostic/source mismatch is silently fixed.

See `docs/REPRODUCTION.md` from the repository root for the precise scope.
