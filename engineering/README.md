# Original GPU integration and execution artifacts

## What changed in this publication

Only export/documentation work. No new Docker runtime, model launcher, GPU test,
CPU resampling experiment, model training, or model download was performed.
Files in `backup/` retain their relative paths and modes. 62 files are
byte-for-byte copies; 18 files contain only documented privacy substitutions.
`SOURCE_INVENTORY.json` records both the original and published hashes.
Real credentials and withheld benchmark text remain blocking findings.
Recorded deployment identifiers are consistently replaced with placeholders.
Nothing is silently removed, and no experiment or new GPU runtime is introduced.

## How to read the archive

- `backup/src/`: the selected-bank wrapper and three repository adapters.
- `backup/configs/`: recorded model settings, source/checkpoint pins and registry.
- `backup/scripts/`: the original source bootstrap and harness-overlay installer.
- `backup/archive/`: recorded installation, execution, repair and environment
  evidence. Earlier attempts remain historical attempts, not newly validated runs.

The project owner reports prior H100 execution validation. Hardware strings in
individual records are left unchanged; an A100 record does not become an H100
record. File existence or a stored PASS marker is not presented as a new test.

## Use the original instructions

Read the scripts and their configuration files before running them on your own
GPU host. From `engineering/backup/`, the original source preparation commands
are `bash scripts/bootstrap_sources.sh` and
`bash scripts/install_harness_overlay.sh`. They are for later use by a reproducer,
not commands the project owner needs to repeat to publish this archive.

Upstream software, checkpoints, simulator assets, permissions, driver support,
and the original item-selection metadata remain external prerequisites. Historic
cloud launch scripts may reference the original scheduler and filesystem layout.
They are preserved as evidence and are not advertised as a new universal launcher.
See `configs/study/final_registry.json` for recorded conditions and unknowns.

The preserved `backup/GETTING_STARTED.md` remains a historical source document: some
commands there refer to the original private repository or omitted inputs. Its
private-history restoration commands are not part of this public export.

## Licenses and scope

No new blanket license is chosen by this export. Existing third-party notices
and license texts are retained separately. The exported adapters/compatibility
patches reference upstream software; models and benchmark assets are not bundled.
Code availability is not a claim that every historical environment is bitwise
frozen or that every GPU with any driver will produce identical results.
