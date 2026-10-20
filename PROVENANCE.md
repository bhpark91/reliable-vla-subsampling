# Release provenance and verification boundaries

Release date: 2026-10-20. This is a restricted first public candidate derived
from the owner's reviewed 500-item, 14-system response-analysis package.

The source matrices were checked against their long-form tables before
export. A joint row permutation and new public item IDs remove direct
original-ID lookup from this release. System columns, response values, family
assignments, and split membership were preserved. Full-bank reference counts
were derived independently from original long-form records. The private
lookup map and original validation records are not published.

The six preserved full-analysis source/environment files and two original
aggregate comparison CSVs are byte-for-byte unchanged from the reviewed
candidate. The per-system holdout CSV exports only selected scalar fields
from its archived summary. The public summary/check tools and documentation
are new packaging code, not new study methods.

The original full CPU pass belongs to the earlier full candidate. This
edition has its own integrity/schema checks, full-bank count reproduction,
and packaging tests; it does not inherit a full-analysis pass. It includes
no new simulator runs, model training, control experiments, or manuscript.

`RELEASE_MANIFEST.json` records the public file inventory and SHA-256 hashes.
It excludes itself. Hashes check consistency, not legal permissions or
scientific correctness. The publishing helper outside this repository pins
the manifest hash and uses only its explicit file inventory.
