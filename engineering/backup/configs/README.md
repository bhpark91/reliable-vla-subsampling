# Frozen configuration

- `study/final_registry.json`: the canonical 14-system inventory. Unknown
  revisions are written as the literal `UNKNOWN`, never guessed.
- `study/protocol_primary.yaml`: bank, wrapper hashes, seeds, and execution
  contract.
- `models/calibration_expansion/`: portable model-server configuration
  templates. `scripts/install_harness_overlay.sh` resolves their path tokens.
- `upstream/source_pins.json`: immutable upstream source/checkpoint pins for
  the three calibration-expansion systems used in the final study.
- `upstream/excluded_candidate_source_pins.json`: pins for investigated
  LingBot, NORA, and BAAI UniVLA candidates that are not in the final study.

The older incomplete registries remain in `archive/legacy/manifests/` only as
historical evidence; they are not the current configuration entry point.
