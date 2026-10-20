# Public response data

## Schema

`data/responses.csv` has exactly 500 rows. The first column is
`public_item_id` (`item_0001` through `item_0500`); the remaining 14 columns are
system identifiers. Every response is an integer `0` or `1`. There are no
imputed responses. Columns for all systems refer to the same public row.

`data/systems.csv` contains `system`, `family`, and `split`. The calibration
split has 11 systems in nine recorded families. The holdout split has three
systems in two recorded families. These family assignments are the project's
analysis conventions, not a fresh audit of every model's training lineage.

## Export transformation

The source's calibration and corrected holdout matrices were aligned by their
original indices and checked against their long-form tables. One shared row
permutation was applied to all systems. New public row IDs were assigned and
the permutation/lookup map was retained privately, outside this repository.
All 7,000 response values are unchanged. Full-bank per-system counts are also
checked against counts independently derived from the original long tables.

Not distributed: task instructions, original task/registry identifiers,
suite assignments, perturbation categories, difficulty labels, base-task
proxies, simulation seeds, rollout paths, private source history, and the row
lookup map. Original order is not encoded in the public IDs. Response patterns
may still be recognizable using external data; no confidentiality guarantee
or formal anonymization claim is made.

## Interpretation

A response is the recorded outcome of one system–item evaluation under the
study protocol. Repeated subsampling reuses these outcomes; it is not repeated
robot execution. A score is `successes / 500` for this bank, not the score on
the full upstream benchmark. Individual model implementations and checkpoint
choices may affect results; these data alone cannot establish performance of
all versions of a named model.

The corrected holdout responses are used. In particular, the `pi0_fast`
full-bank score in this artifact is 0.078, not an upstream benchmark score.
This release does not revalidate the rollout integration or correct unknown
original execution settings.

## Suitable uses

Inspecting response patterns, verifying full-bank counts, and inspecting the
published analysis source. Content-stratified or fixed-history adaptive
reproduction needs the original item metadata; public IDs are not a substitute.
Do not infer artificial strata from public ID ranges.
