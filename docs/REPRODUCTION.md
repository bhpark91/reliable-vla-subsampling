# What can be reproduced

| Component | Public files sufficient? | Verification performed for this release |
| --- | --- | --- |
| File inventory, hashes, response schema, split counts | Yes | Executed locally on the candidate |
| Per-system full-bank success counts/rates | Yes | Recomputed from public responses and compared to original-long-form counts |
| Archived tables rendered as Markdown | Yes, for display only | Checked against stored aggregate CSVs |
| Stratified, Rasch, or adaptive method MAEs | No | Not rerun from this restricted public edition |
| Original robot rollout collection | No | Not rerun |

## Public quick start

From the repository root, with Python 3.10 or later:

```bash
python3 scripts/check_public.py
python3 scripts/reproduce_public.py
python3 -m unittest discover -s tests -v
```

A successful analysis ends with `PUBLIC_SUMMARY_REPRODUCTION=PASS` and names
its output directory. It never prints the full-analysis pass marker. The
recomputed `full_bank_scores.csv` and `report.md` are written under `outputs/`.
By default each run gets a fresh directory; `--out PATH` requires a nonexistent
path under `outputs/`. Existing output is never overwritten.

The printed archived MAEs are not recomputed. The quick start uses no random
subsampling, fits no model, launches no GPU jobs, and adds no new control
experiment. It is a data/packaging check, not a scientific validation of every
claim.

## Preserved full-analysis source

`reference_code/reproducibility/` preserves the three analysis shell scripts,
the Rasch helper, and the original dependency specification/lockfile, unchanged
from the previously reviewed full candidate. The scripts expect the original
calibration/holdout files and bank manifest, including item classification.
Those inputs are deliberately absent from this edition. Do not put the public
matrix at an old file path or invent labels to make a script run.

The owner previously ran the complete metadata-bearing candidate and supplied
a successful core numerical verification record. That record applies to that
full candidate, not to this restricted edition. Its existing checks used
selected deterministic tolerances of 1e-6, LOFO rank tolerance of 0.01, and
Monte Carlo tolerance of 0.05 percentage points. This edition does not transplant
that record to a new manifest or claim a new full-analysis pass.

## Failure handling

Keep the first error and the output directory. Do not edit reference values or
hashes just to obtain a pass. `check_public.py` rejects unexpected files except
recognized runtime directories; the publisher uses an explicit file list, not
`git add .`. Changes to released inputs require a reviewed new release manifest.


## Engineering archive addition

Original recorded engineering files are also published under `engineering/backup/`.
See `engineering/README.md` and `engineering/SOURCE_INVENTORY.json`.
This addition does not rerun experiments, change historical evidence or grant
a new blanket license. Original metadata-dependent analysis limitations remain.
