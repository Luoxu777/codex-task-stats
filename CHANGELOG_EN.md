# Changelog

[简体中文](CHANGELOG.md) · **English**

Feature changes, fixes and compatibility notes. See the [README](README_EN.md) for usage and upgrades.

## v4.0

### Added

- Turn and current-conversation Token statistics with ten metrics, scope and field selection, missing-data states and logging.
- Configuration reference, contribution guidelines and private security-reporting instructions.

### Improved

- Right-aligned multiline Token values using existing label alignment; single-line, bracket and unaligned modes remain compact.
- Updated the category and Token preview, aligned documentation examples, and clarified Skill deduplication, other activity, configuration activation and uninstall scope.

### Fixed

- Aligned the Hook template's start timeout with the installer's 10 seconds.
- Completed uninstall parameter help, including option combinations and which logs and backups are retained.

### Upgrade notes

- Configuration stays at `schemaVersion: 11`. Install using the original Codex Home; existing configuration is backed up and migrated.
- The recommended-settings script overwrites selected customization. See the [configuration reference](CONFIGURATION_EN.md#installation-and-recommended-settings).
- Full cleanup deletes logs and backups. Review the [uninstall scope](README_EN.md#uninstall) before proceeding.
- Token values are read-time snapshots, not final billing. Independent subagent usage is not added separately. See [Token statistics](README_EN.md#token-statistics).

## v3.0

### Improved

- Added plain-text label alignment and improved reused-subagent accounting.
- Updated usage instructions, screenshots and the detailed log example.

### Fixed

- Fixed incorrect file counts caused by a leading BOM and clarified verification-failure reasons.
