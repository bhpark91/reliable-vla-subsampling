# Corrected prospective D500 holdout (v2)

This directory records the final correction and analysis provenance for the
prospective D500 holdout.

## Why v2 exists

The original `pi0_fast` holdout row was produced under an upstream OpenPI
normalization regression. The released `pi0_fast_libero` checkpoint requires
z-score normalization, while the pinned OpenPI source revision
`981483dca0fd9acba698fea00aa6e52d56a66c58` selected quantile normalization
for PI0-FAST.

The v2 correction:

- preserves the original OpenPI source pin `981483d...`;
- applies only the PR #971-style z-score compatibility backport;
- preserves the frozen D500 bank, wrapper, seeds, and evaluation protocol;
- reruns only `pi0_fast`;
- leaves `pi05` and `vlanext` responses unchanged.

## Validation

Corrected D500 `pi0_fast`: 39 / 500 = 7.8%.

As an independent runtime sanity gate, the same exact OpenPI pin plus the
z-score correction achieved 6 / 10 = 60% on the official standard
LIBERO-10 client, with zero client exceptions.

## Confirmatory vs exploratory

The prospective confirmatory comparison remains the policy frozen before
holdout: `ADAPT20_REG` (80-item shared anchor, then 8 Fisher-adaptive plus
32 random exploration items per 40-item batch).

`ADAPT100_REG` is a **post-hoc exploratory sensitivity** performed after
holdout outcomes were available. It changes every post-anchor acquisition to
Fisher-adaptive selection and therefore must not be interpreted as a
pre-holdout confirmatory result.

At B=320:

- STRAT_REG: 0.8634 pp family-balanced MAE
- STRAT_NEYMAN_CAL: 0.8735 pp
- ADAPT20_REG: 1.2863 pp
- ADAPT100_REG (post-hoc): 2.7116 pp

## Frozen identifiers

- D500 manifest SHA256:
  `87410957f255d73a6595365ca72cf380254b4d2bc0b98923deebe7bfcc8682b1`
- D500 wrapper SHA256:
  `0a9e558582b769b81d859f619850d9438de5a35004fe8c11b093560eb4674dae`
- OpenPI source pin:
  `981483dca0fd9acba698fea00aa6e52d56a66c58`
- VLA evaluation harness pin:
  `2680ab2fafe981c2dba63c6c1a4e7bb4415dbb56`
- Correction:
  PR #971-style z-score compatibility backport only.
