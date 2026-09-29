# Security

[简体中文](SECURITY.md) · **English**

Report redaction failures, unintended sensitive-data persistence, unsafe path handling and installer/uninstaller scope problems privately.

## Reporting channel

Use **Report a vulnerability** on the repository's [Security page](https://github.com/Luoxu777/codex-task-stats/security).

If the option is unavailable, open an [Issue](https://github.com/Luoxu777/codex-task-stats/issues) only to request a private contact channel. Wait for the maintainer to provide one before sending details. Do not include vulnerability details, exploit code, credentials, conversations or sensitive logs in a public issue.

## Report contents

- Affected program version or commit, and Windows, PowerShell and client versions.
- Impact, minimal reproduction steps, and expected and actual behavior.
- Sanitized samples using substitute values; if safe to reproduce, indicate whether current source is still affected.

If real credentials have been exposed, revoke or rotate them first.

## Support scope

The project currently has no fixed response time, remediation deadline or older-version backport schedule. Identify affected versions so maintainers can assess and address the issue.

## Data protection

`safe` command logging provides best-effort redaction, not a general data loss prevention system. Configuration backups, other Hook commands, transcripts and separately captured diagnostics are not automatically sanitized. Review them manually before sharing.

Do not publish a complete Codex Home or real conversation JSONL. Report ordinary usage problems using the [contribution guidelines](CONTRIBUTING_EN.md).
