# Limitations and unresolved questions

## Scientific scope

The bank is fixed at 500 LIBERO-Plus items, with one recorded response per
system–item pair. Calibration contains 11 systems from nine families; holdout
contains three systems from two further families. Subsampling repetitions
characterize sampling uncertainty conditional on these responses, not transfer
to new families, banks, or simulator seeds. The two-family holdout gives the
single VLANeXt system half the family-balanced aggregate weight.

The bank's upstream difficulty labels used reference-model outcomes. The bank
was frozen before the study-generated responses, which is not the same as
outcome-free benchmark construction.

## Adaptive residual correction and comparison design

Exploration from a remaining item pool is not automatically an equal-inclusion-
probability sample of the original bank. Ability estimates also use observed
target responses. Exact design-unbiasedness is not asserted for the model-
assisted estimates. Adaptive acquisition changes the size/composition of the
residual sample as well as which items are selected; no causal decomposition
of the adaptive loss is claimed. Stronger matched baselines and further
controls remain future work.

## Diagnostic label mismatch

Source recovery identified that archived calibration log-loss, approximate
reliability, item-fit flags, and Rasch/LOFO diagnostic outputs were produced
with unregularized bounded joint maximum likelihood. The sampling and holdout
policies use ridge regularization with lambda=1/9. Those diagnostic values
must not be described as ridge-fit diagnostics. Item-level diagnostic files
are not distributed in this edition.

## Archived versus regenerated numerical results

The archived holdout adaptive MAE at budget 320 is 1.2862505524 percentage
points. The owner's subsequent full-candidate terminal output reported about
1.2580 percentage points. The approximately 0.0283-point difference passed
the existing 0.05-point Monte Carlo tolerance; it is not exact equality. Its
cause was not isolated in this release work. Archived tables are retained,
not silently overwritten with the rerun values. The method remained worse
than the static/Neyman procedures in that comparison.

Not every historical producer/random-number ordering was recovered. A passing
core numerical gate is not reproduction of every archived decimal. No new
rollout experiment or statistical control was performed for this edition.

## Restricted release

Without item classifications and original row order, the public matrix alone
cannot recreate the full stratified/adaptive comparison. Preserved source is
provided for inspection with this dependency explicit. Public IDs are not
original task IDs. Omitting metadata is a scope choice, not a legal opinion
that all remaining materials have been cleared for every reuse.

## Contribution and publication status

This is an unpublished research artifact, not an accepted publication.
AI coding agents were used extensively for implementation. The release does
not claim independent manual coding of the entire system, upstream model
training, resolution of reviewer concerns, or complete raw-rollout reproducibility.
