# Reliable Subsampling for VLA Evaluation

## Original engineering release

The GPU integration files under `engineering/backup/` are copies of the
existing research backup, not a new GPU runtime or rewritten evaluation pipeline.
Model algorithms, dependencies, experimental settings, results, and launch logic
are retained as recorded. Private deployment IDs, personal path prefixes and
historical SSH connection defaults are replaced with explicit placeholders.
See `engineering/PRIVACY_EXPORT.md` for the file-by-file verification boundary.
The project owner reports that H100 execution validation was completed before
these artifacts were archived. This export does not repeat those experiments or
claim a new independent hardware verification. Original A100 entries, historical
failures, and unresolved fields are preserved rather than relabeled.

The complete metadata-bearing response-analysis package has been retained. Its
core calibration, sampling, and holdout analyses were rerun by the owner and
passed the documented numerical checks. The public method-comparison workflow
is restricted because benchmark metadata and original item mapping were withheld
pending clarification of redistribution terms, not because the underlying inputs
were lost. Original GPU execution and response-level numerical analysis are
separate layers.

See [the engineering inventory and instructions](engineering/README.md).

**Can fewer simulator trials estimate a vision-language-action system's score on a fixed test bank?**

This project compares random sampling, stratified sampling, and Rasch-based
estimators using recorded responses from a fixed 500-item LIBERO-Plus bank.
The study includes 11 calibration systems from nine model families and three
prospective holdout systems from two additional families: **7,000 binary
responses** in total.

**Status:** unpublished research artifact; not an accepted publication.
**Release scope:** numerical responses, archived aggregate results, and analysis
source, plus the original GPU engineering archive. Benchmark item text, original item identifiers, and item-level
classification metadata are not included.

## Main observation

In the archived comparison, strong stratification and static Rasch estimation
had similar errors. The tested Rasch/Fisher adaptive procedure had larger
aggregate errors at budgets of 160 and 320 items. At budget 80, adaptive
selection had not started. This is a comparison of particular procedures on
one bank, not a general result against adaptive evaluation.

Archived prospective holdout results at a budget of 320 items:

| Procedure | Family-balanced MAE, percentage points |
| --- | ---: |
| Static Rasch with residual correction | 0.863 |
| Calibration-based Neyman stratification | 0.873 |
| Tested Rasch/Fisher adaptive procedure | 1.286 |

These are archived numbers, not new measurements produced by the quick start.
The two-family holdout is small. Repeated subsampling does not create additional
independent systems. See [results and interpretation](docs/RESULTS.md).

## Run with the public files only

Use Python **3.10 or later**. Run these commands from the repository root:

```bash
python3 scripts/check_public.py
python3 scripts/reproduce_public.py
python3 -m unittest discover -s tests -v
```

No GPU, account, network access, or third-party Python package is needed for
these commands. The first command checks the release and data. The second
recomputes the 14 full-bank success counts/rates from the public response
matrix, verifies them against independently exported reference counts, and
writes a report to a new `outputs/` subdirectory. It also formats the archived
method-comparison tables, explicitly marking those tables as archived.

**This quick start does not recompute the stratified/Rasch/adaptive method MAEs.**
Those analyses require the withheld item classification metadata and original
item order. The original analysis source is retained separately for inspection.
See [reproduction scope](docs/REPRODUCTION.md).

## What is available

| Path | Contents |
| --- | --- |
| [data/responses.csv](data/responses.csv) | 500 rows × 14 systems of recorded 0/1 outcomes; public item IDs only |
| [data/systems.csv](data/systems.csv) | System names, project family assignments, and calibration/holdout split |
| [results/reference](results/reference/) | Full-bank counts/rates, recomputable from the public matrix |
| [results/archived](results/archived/) | Existing aggregate comparisons and per-system holdout summaries |
| [reference_code](reference_code/) | Preserved analysis source; requires additional original metadata |
| [docs/DATA_CARD.md](docs/DATA_CARD.md) | Data schema, transformations, and intended use |
| [docs/LIMITATIONS.md](docs/LIMITATIONS.md) | Statistical, numerical, and release limitations |

Rows have been jointly permuted across all 14 systems. Public row IDs do not
encode original task IDs, and no direct lookup map is published. The 7,000
response values and alignment between systems are preserved. This is not a
claim of irreversible anonymization.

## Scope and limitations

The estimand is the mean response on this fixed bank under the recorded
response protocol, not universal VLA capability or a full LIBERO-Plus leaderboard
score. Original robot rollouts are not rerun here. Adaptive residual correction,
small calibration/holdout samples, and a recovered diagnostic model-label
mismatch remain unresolved; see the limitations document.

## Project and attribution

Project owner: **Bohyun Park**. AI coding agents were used extensively for
implementation. The project does not claim that all code was manually written
by the owner, nor that the benchmark or pretrained models were developed here.

LIBERO-Plus and the evaluated VLA models are upstream work. See
[third-party notices](THIRD_PARTY_NOTICES.md) and [license status](LICENSE_STATUS.md).
No blanket open-source license is assigned by this packaging step. Public
source availability is not a claim that unrestricted reuse has been granted.
