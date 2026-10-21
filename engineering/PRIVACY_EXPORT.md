# Infrastructure-only privacy substitutions

This export preserves 62 backup files byte-for-byte and retains another
18 files with limited, explicitly recorded substitutions. All original
relative paths and executable modes are retained. The previous private candidate
and source Git checkout are not changed.

## Substitutions

Only personal home/Windows-download path prefixes, cloud job/workspace/volume
identifiers, the reviewed historical SSH host/port defaults, and the SSH key
filename are replaced. A single alias map is used across all exported records.
The original-to-placeholder map is private and is not committed.

The export verifies that reversing the listed substitutions exactly restores each
original byte sequence. Source and published hashes, substitution types/counts,
and affected line numbers are in `SOURCE_INVENTORY.json`. No whole line is deleted.
Model/checkpoint versions, package versions, seed values, action normalization,
algorithm logic, performance values, PASS/FAIL records and device labels are not
redesigned or relabeled. This export introduces no new runtime implementation.

## Using historical launch scripts

These are recorded scripts, not a new turnkey launcher. Before executing one,
replace `YOUR_USER`, `YOUR_SSH_HOST.invalid`, `YOUR_SSH_PORT`, `YOUR_KEY.pem`, and
`job-REDACTED...` / `wsp-REDACTED...` / `clustervol-REDACTED...` placeholders
with your own values where applicable. Recorded job IDs are evidence labels,
not reusable live jobs. Old scheduler layouts, external weights, benchmark assets,
license/access requirements, and omitted item metadata remain prerequisites.
Never execute an old repair/collection script against someone else's resources.

## Validation boundary

No GPU inference, simulator rollout, CPU statistical analysis, model download,
paid cloud operation or rerun was performed to export these files. Validation is
limited to source hashes, exact privacy-only transformations, manifest checks and
syntax parsing. Earlier experimental evidence retains its original scope.
The owner's previously reported H100 validation is not replaced by a new claim
that this export has independently run every model on every GPU.
