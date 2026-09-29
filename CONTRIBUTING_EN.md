# Contributing

[简体中文](CONTRIBUTING.md) · **English**

Questions, suggestions and improvements are welcome. See the [README](README_EN.md) for usage and the [security policy](SECURITY_EN.md) to report vulnerabilities privately.

## Questions and suggestions

Use [Issues](https://github.com/Luoxu777/codex-task-stats/issues) for usage problems and feature requests. For substantial behavior changes, describe the problem, use case and proposed approach first.

Include the following in a bug report:

- Program and Windows versions, client name and version, and `$PSVersionTable.PSVersion`.
- Installation method and Codex Home selection; replace private paths with placeholders.
- Minimal reproduction steps, expected and actual behavior, and affected scope.
- Relevant configuration, failed status fields and manually reviewed, minimal sanitized log excerpts.

Prefer synthetic Hook/JSONL samples; real conversations are not required. Keep technical discussions respectful and avoid personal attacks or disclosing other people's information.

## Development and validation

Use Windows 11 with Windows PowerShell 5.1. No additional package manager or server is required. Follow `.editorconfig` and `.gitattributes`: PowerShell uses UTF-8 BOM/CRLF; Markdown and JSON use UTF-8/LF.

Run from the repository root:

```powershell
# Documentation changes
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\documentation.tests.ps1
git diff --check

# Code, configuration, Hook template, installation or uninstall changes
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\test.ps1
```

The full suite validates installation, migration and removal in temporary Codex Homes. Keep test directories separate from real installations. For display changes, also verify a new task in the target client; record script checks and client observations separately.

## Commits and pull requests

- Focus on one problem or related behavior, preserving unrelated worktree changes. Do not commit ignored files, runtime data, user configuration or unsanitized logs.
- Use complete bilingual commit messages: a Chinese title and bullet list, followed by an English title and matching bullets, with blank lines between sections. Titles are complete sentences ending with a full stop. Use “主要内容 / Main changes” for section titles; initial feature commits may use “主要功能 / Main features”. Conventional Commit prefixes are not the default unless the maintainer requests them.
- Describe the background, changes, scope, actual validation and risks or unverified behavior in the PR.
- Update the corresponding Chinese and English documents for user-visible changes. Keep languages in separate files with matching sections and information, linked at the top.
- Use `VERSION` as the version source, organize the changelog by version and keep the README focused on general usage. Include release dates only when established.
- Synchronize `hooks.template.json`, the installer and relevant checks when Hook defaults change. Update both configuration references when settings change, explaining activation and migration.
- State the source, environment and scope of screenshots, preserving the original boundaries of historical validation records.

## License

Contributions follow the project's [MIT License](LICENSE). Retain relevant copyright and attribution notices.
