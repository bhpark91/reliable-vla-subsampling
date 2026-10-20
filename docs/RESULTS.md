# Public data report

## Recomputed full-bank scores

These counts/rates are recomputed from `data/responses.csv`.
They are scores on this fixed bank, not upstream benchmark leaderboard scores.

| System | Split | Successes / items | Success rate |
| --- | --- | ---: | ---: |
| db_cogact | calibration | 351/500 | 70.2% |
| openvla | calibration | 118/500 | 23.6% |
| openvla_oft | calibration | 350/500 | 70.0% |
| x_vla | calibration | 369/500 | 73.8% |
| molmoact2 | calibration | 420/500 | 84.0% |
| vla_jepa | calibration | 410/500 | 82.0% |
| groot_n16 | calibration | 364/500 | 72.8% |
| groot_n17 | calibration | 376/500 | 75.2% |
| xiaomi_robotics_0 | calibration | 369/500 | 73.8% |
| vla_adapter | calibration | 310/500 | 62.0% |
| univla_opendrivelab | calibration | 297/500 | 59.4% |
| pi05 | holdout | 438/500 | 87.6% |
| pi0_fast | holdout | 39/500 | 7.8% |
| vlanext | holdout | 394/500 | 78.8% |

## Archived method comparisons — displayed, NOT recomputed

The public files do not include the original item classifications needed to
rerun these method comparisons. No new sampling experiment has been run.

### Calibration

| Budget | Procedure | Archived family-balanced MAE (pp) |
| ---: | --- | ---: |
| 80 | STRAT_REG | 2.957206 |
| 80 | ADAPT20_REG | 2.970642 |
| 80 | STRAT_NEYMAN_LOFO | 3.138177 |
| 80 | STRAT_BAL | 3.146780 |
| 80 | STRAT_PROP | 3.181304 |
| 80 | SRS | 3.574130 |
| 160 | STRAT_REG | 1.887491 |
| 160 | STRAT_NEYMAN_LOFO | 1.988655 |
| 160 | STRAT_PROP | 1.994601 |
| 160 | STRAT_BAL | 2.000633 |
| 160 | ADAPT20_REG | 2.047787 |
| 160 | SRS | 2.279026 |
| 320 | STRAT_REG | 0.966749 |
| 320 | STRAT_NEYMAN_LOFO | 1.005085 |
| 320 | STRAT_BAL | 1.021694 |
| 320 | STRAT_PROP | 1.028711 |
| 320 | SRS | 1.174975 |
| 320 | ADAPT20_REG | 1.257069 |

### Prospective holdout

| Budget | Procedure | Archived family-balanced MAE (pp) |
| ---: | --- | ---: |
| 80 | ADAPT20_REG | 2.688153 |
| 80 | STRAT_REG | 2.694326 |
| 80 | STRAT_NEYMAN_CAL | 2.754478 |
| 80 | STRAT_BAL | 2.807523 |
| 80 | STRAT_PROP | 2.814383 |
| 80 | SRS | 2.888113 |
| 160 | STRAT_REG | 1.714969 |
| 160 | STRAT_NEYMAN_CAL | 1.737013 |
| 160 | STRAT_PROP | 1.756153 |
| 160 | STRAT_BAL | 1.775815 |
| 160 | SRS | 1.852372 |
| 160 | ADAPT20_REG | 1.862269 |
| 320 | STRAT_REG | 0.863448 |
| 320 | STRAT_NEYMAN_CAL | 0.873458 |
| 320 | STRAT_BAL | 0.902750 |
| 320 | STRAT_PROP | 0.908374 |
| 320 | SRS | 0.954212 |
| 320 | ADAPT20_REG | 1.286251 |

See `docs/LIMITATIONS.md` before interpreting any method differences.
