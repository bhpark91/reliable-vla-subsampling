# Getting started on a new computer

## 1. Clone and verify

Use Linux or WSL with Bash and GNU coreutils. Install Git, GitHub CLI, and
`uv`, then authenticate to the private repository:

```bash
gh auth login
gh repo clone bhpark91/vla-irt-cat-backup
cd vla-irt-cat-backup
./scripts/verify_repository.sh
```

The verification checks all tracked-file hashes and the final bank/matrix
shape, binary response values, system membership, and frozen wrapper hashes.

## 2. Reproduce the final paper analyses

```bash
./scripts/reproduce.sh
```

The locked environment uses Python 3.12.3, NumPy 2.3.3, and SciPy 1.16.2.
Expect several minutes of CPU time. A successful run prints these gates among
its final lines:

```text
CORE_CONFIRMATORY_GATE=PASS
POSTHOC_EXACT_FROZEN_INPUT_GATE=PASS
RECONSTRUCTED_SENSITIVITY_GATE=NON_IDENTICAL_DRIFT_REPORTED
FINAL_REPRODUCTION=PASS
```

`NON_IDENTICAL_DRIFT_REPORTED` is an honest evidence classification, not a
failed run: those post-hoc controls require replaying an optimizer or adaptive
acquisition simulation whose tie ordering was not fully recoverable. Their
metric-by-metric drift is written to
`reproducibility/reproduced/final/posthoc/reproduction_summary.json`.

The historical 8-system check printed during this workflow is explicitly a
development recovery gate, not a final result.

Before citing calibration diagnostics, read
[`reproducibility/RECOVERY_LIMITATIONS.md`](reproducibility/RECOVERY_LIMITATIONS.md):
the archived log-loss/reliability/fit-flag values came from the recovered
unregularized bounded JML producer, while the sampling and holdout policy uses
the stated ridge=1/9 estimator.

## 3. Reproduce exploratory controls

```bash
uv run --project reproducibility --frozen --python 3.12.3 \
  python reproducibility/final/reproduce_posthoc.py
```

This regenerates 13 post-hoc tables. Tail risk, aggregation weighting,
pi0-fast breakdowns, and D500 composition are exact reductions of committed
frozen inputs. Adaptive-fraction, residual-size, content-constrained CAT,
selection concentration, overlap-exclusion, L2FO, and ridge controls are
reconstructed sensitivity analyses with drift reported separately. None makes
new VLA rollouts.

For the earlier clean-room development validation only:

```bash
./scripts/reproduce_development.sh
```

## 4. Restore source trees without model weights

```bash
./scripts/bootstrap_sources.sh
```

This clones the seven upstream repositories needed by the final 14-system
study at pinned commits into ignored `external/`. It does not download
weights. LingBot, NORA, and BAAI UniVLA were investigated as expansion
candidates but are not part of the final response matrices; their pins are
kept separately in `configs/upstream/excluded_candidate_source_pins.json`.
Use
`configs/study/final_registry.json` for checkpoint identifiers, adapters,
runtime evidence, and explicit unknowns.

Install the three repository-owned model-server adapters and render their
portable configuration templates into the pinned evaluation harness:

```bash
./scripts/install_harness_overlay.sh
```

The default weight location is the ignored `external/model-weights/` tree.
You may instead pass a harness path and model root explicitly:

```bash
./scripts/install_harness_overlay.sh /path/to/vla-evaluation-harness /path/to/model-weights
```

The script validates the harness commit, installs all adapter/config files,
and replaces `__REPO_ROOT__` and `__MODEL_ROOT__` in the rendered configs. It
does not download model weights. See `configs/models/README.md` for the
checkpoint-directory marker and UniVLA action-decoder requirements.

The complete pre-holdout engineering Git history can be restored locally with:

```bash
./scripts/restore_engineering_history.sh
```

That history is internal provenance, contains identity/infrastructure
metadata, and must not be used as a double-blind reviewer artifact.

## 5. Recreate raw VLA rollouts

Raw rollouts additionally require a Linux GPU host, LIBERO-Plus assets, model
weights, and model-specific environments. Keep unchanged:

- D500 manifest SHA256 `87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1`;
- wrapper SHA256 `0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae`;
- seed and environment seed 7;
- one binary episode per item;
- adapter, checkpoint, normalization, and action contract in the registry.

Original VESSL launch/repair scripts are retained under
`archive/rollout_execution/` as provenance. They contain obsolete absolute
paths and must be ported to a new scheduler rather than run verbatim.
