# Final study registry

`final_registry.json` is the single inventory for the 14 systems in the final
study: 11 calibration systems (9 families) and 3 corrected prospective-holdout
systems (2 families).

Use it to answer four separate questions without consulting historical logs:

1. Was the system in calibration or the corrected holdout?
2. Which scientific family was used for family-balanced evaluation?
3. Which source, checkpoint, adapter/config, and runtime evidence is frozen?
4. Which exact values could not be recovered from the committed evidence?

The literal value `UNKNOWN` is deliberate. Do not silently replace it with an
upstream default, current branch head, or current container tag. Such a
replacement would describe a new experiment, not reproduce the recorded one.

The registry supports two reproduction layers:

- **Response/analysis reproduction:** the committed 5,500 calibration and
  1,500 corrected-holdout binary responses are sufficient to rerun the final
  IRT, LOFO, sampling, CAT, and diagnostic analyses without VLA weights.
- **Raw rollout reconstruction:** download weights from the recorded upstream
  locations and follow the adapter/runtime contracts. No complete model stack
  is claimed bit-for-bit reproducible: each has at least one unresolved
  checkpoint, container, driver, or environment field. See
  `evidence_boundaries` in the registry.

The shared benchmark, harness, item-manifest, wrapper hashes, and primary
evaluation condition are recorded once under `shared_scientific_contract`.
System-specific entries contain only the model-side differences and evidence.
