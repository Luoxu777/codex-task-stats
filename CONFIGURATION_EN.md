# Configuration and troubleshooting

[简体中文](CONFIGURATION.md) · **English**

Applies to **v4.0**. See the [README](README_EN.md) for usage and [config.example.json](config/config.example.json) for defaults.

## Configuration location and activation

Edit `<CodexHome>\task-stats\config\config.json` after making a backup. The repository example supplies defaults for installation and migration; editing it does not update an installed configuration. JSON does not support comments. Use `true` / `false` for booleans and unquoted numbers. Merge the properties you need rather than replacing the whole file with a fragment.

Settings are generally read by subsequent Hooks. Verify them in a new task because changing collection or baseline settings during a turn can leave gaps in evidence, and completed summaries may be cached. Configuration changes do not reformat saved logs or summaries. Missing or invalid `tokenStatistics` properties fall back to defaults; other fields do not share a universal type-correction policy, so follow the types below.

`collection.intermediateMode` records the installation mode. Synchronous/asynchronous execution depends on `async` in `hooks.json`; rerun the installer to change it. Neither this field nor a printed configuration value proves that the client has executed a Hook.

## Display and Token statistics

| Configuration path | Type / default | Meaning |
| --- | --- | --- |
| `schemaVersion` | Integer / `11` | Installer-managed configuration format, not the program version; do not increase manually |
| `display.multiline` | Boolean / `true` | Use real LF line breaks; when disabled, join with `｜` |
| `display.labelAlignment` | String / `center` | `center`, `left`, `right`, `none`; the first three align labels and Token values in multiline icon/plain styles |
| `display.showCoverageNotice` | Boolean / `false` | Append overall coverage information; individual incomplete-data notices still apply |
| `display.showSuccessStatus` | Boolean / `false` | Show successful status; other statuses remain visible |
| `display.hideEmptyCategories` | Boolean / `true` | Hide empty categories; Token zero values and missing-data notices remain visible |
| `display.emptyValue` | String / `无` | Placeholder for visible empty categories |
| `display.highlightStyle` | String / `icon` | `icon`, `bracket`, `none`; bracket style does not add alignment padding |
| `display.icons.*` | String map / see example | Icons for `start`, `end`, `mcp`, `skill`, `subagent`, `file`, `git`, `other` |
| `display.labels.*` | String map / see example | Labels for `mcp`, `skill`, `subagent`, `file`, `git`, `other`; does not translate client event names or all fixed Chinese text |
| `tokenStatistics.enabled` | Boolean / `true` | Enable Token collection, display and logging |
| `tokenStatistics.showTurn` | Boolean / `true` | Show the turn Token section |
| `tokenStatistics.showSession` | Boolean / `true` | Show the current-conversation Token section |
| `tokenStatistics.fields` | String array / all ten fields | Select visible metrics; an empty array hides the sections, while logs retain all known values |

See [Token statistics](README_EN.md#token-statistics) for field definitions, order, missing-data states and examples. See [Hook display notes (Chinese)](HOOK_DISPLAY.md) for alignment and client limitations.

## Skill collection

These settings primarily affect Skill evidence; `maxBytes` also controls the shared transcript-slice reader. Disabling one Skill source does not disable all Skill detection or independent Token collection.

| Configuration path | Type / default | Meaning |
| --- | --- | --- |
| `skillCollection.explicitMarkers` | String array / `["$"]` | Prompt markers for requested-use fallback; plain-text `@` is not inferred as a Skill marker; an empty array disables this source |
| `skillCollection.maxStructuredNodes` | Integer / `2000` | Structured-input traversal budget |
| `skillCollection.transcript.enabled` | Boolean / `true` | Enable Skill evidence collection from transcripts |
| `skillCollection.transcript.readMain` | Boolean / `true` | Read main-conversation Skill evidence |
| `skillCollection.transcript.readSubagents` | Boolean / `true` | Read Skill evidence from linked subagents |
| `skillCollection.transcript.requireSkillPathInXml` | Boolean / `true` | Require path evidence for XML Skill detection |
| `skillCollection.transcript.currentTurnLookbackEnabled` | Boolean / `true` | Allow bounded lookback for current-turn evidence |
| `skillCollection.transcript.lookbackBytes` | Integer / `1048576` | Lookback byte budget, 1 MiB by default |
| `skillCollection.transcript.settleInitialMs` | Integer / `100` | Initial wait before reading Skill transcripts, in milliseconds |
| `skillCollection.transcript.settleQuietMs` | Integer / `100` | Quiet window used to observe file stability, in milliseconds |
| `skillCollection.transcript.settleMaxMs` | Integer / `600` | Transcript stability-check limit after the initial wait, in milliseconds |
| `skillCollection.transcript.maxBytes` | Integer / `4194304` | Shared transcript-slice budget, 4 MiB by default, clamped to 64 KiB–32 MiB; also affects file, MCP and subagent activity collected through this reader |
| `skillCollection.transcript.maxLines` | Integer / `10000` | Skill transcript processing limit, clamped to 100–100000 lines |
| `skillCollection.commandRead.enabled` | Boolean / `true` | Detect commands that read `SKILL.md` |
| `skillCollection.commandRead.preferParsedCommand` | Boolean / `true` | Prefer structured command evidence |
| `skillCollection.commandRead.rawCommandFallback` | Boolean / `true` | Allow in-memory parsing of the original command as fallback; the original command is not saved |
| `skillCollection.commandRead.requireCompletedExecution` | Boolean / `true` | Require completed-execution evidence for command-read detection |

See [counting semantics](README_EN.md#skills) for `Skill ×N`, scope deduplication and evidence levels. Increasing read budgets cannot recover events the client never supplied.

## Files, activity and logs

| Configuration path | Type / default | Meaning |
| --- | --- | --- |
| `fileTracking.enabled` | Boolean / `true` | Enable file-change collection |
| `fileTracking.parseApplyPatch` | Boolean / `true` | Parse tool patches to help correlate editing evidence; not a global switch for native `FileChange` reads |
| `collection.settleInitialMs` | Integer / `350` | Initial wait for intermediate events before Stop aggregation, in milliseconds |
| `collection.settleQuietMs` | Integer / `350` | Journal stability window, in milliseconds |
| `collection.settleMaxMs` | Integer / `2500` | Journal stability-check limit after the initial wait, in milliseconds |
| `collection.includePermissionRequests` | Boolean / `true` | Count permission requests under other activity; does not control permission policy or Hook registration |
| `collection.includeCompaction` | Boolean / `true` | Count completed context compactions under other activity; does not control compaction |
| `logging.enabled` | Boolean / `true` | Write daily logs; disabling does not remove existing logs or statistics state |
| `logging.filePrefix` | String / `codex-task` | Log filename prefix, sanitized before use |
| `debug.enabled` | Boolean / `false` | Enable runtime diagnostics; see the location below |
| `toolAliases.*` | String map / see example | Name local tools that can be classified; defaults include `Bash`, `update_plan`, `view_image` |
| `commandLogging.mode` | String / `safe` | Only `safe` and `off` are supported; there is no raw-command `full` mode |
| `commandLogging.includeGit` | Boolean / `true` | Save sanitized Git command details; disabling does not stop Git counting |
| `commandLogging.includeShell` | Boolean / `true` | Save sanitized Shell command details; disabling does not stop Shell counting |
| `commandLogging.maxCommandChars` | Integer / `4096` | Sanitized-command truncation threshold, with an effective minimum of 128; a truncation marker is appended |
| `commandLogging.maxRunsPerTask` | Integer / `200` | Retained command-run details for Git and Shell separately, with an effective minimum of 1; not a total-call limit |

The shared transcript-slice byte budget can be adjusted above. File-content verification, subagent count/read-time limits and Token reads still have independent budgets. See [file counting](README_EN.md#files) and [Token boundaries](README_EN.md#missing-and-incomplete-data).

## Installation records and compatibility fields

These fields may still appear in defaults, migrated configuration or status output. Their presence does not mean legacy algorithms are running.

| Configuration path | Example default | Current behavior |
| --- | --- | --- |
| `collection.intermediateMode` | `quiet` | Installer-written mode record; use `-IntermediateMode Quiet/Strict` to change actual registration |
| `fileTracking.gitStatusSupplement` | `true` | Legacy field; current file counting does not read it or enable Git-status supplementation |
| `fileTracking.gitStatusTimeoutMs` | `1500` | Legacy field; current file counting does not read it |
| `fileTracking.maxGitStatusEntries` | `5000` | Legacy field; current file counting does not read it |
| `skillCollection.mode` | `multi-source` | Descriptive compatibility field; current evidence collection is always multi-source |
| `skillCollection.deduplicateWithinTurn` | `true` | Compatibility field; scope/name deduplication is always active, even if set to false |
| `agentManagementTools` | String array / see example | Compatibility list; current Agent management recognition is defined by program logic, not this list |

These compatibility fields can remain in existing configuration; manual removal is not required for upgrades.

## Installation and recommended settings

All scripts resolve Codex Home from explicit `-CodexHome`, then `CODEX_HOME`, then `.codex` under the current user's home directory. Use the same resolved location when maintaining an installation.

| Script / option | Purpose |
| --- | --- |
| `scripts/install.ps1 -IntermediateMode Quiet` | Default: synchronous start/end Hooks, asynchronous intermediate Hooks |
| `scripts/install.ps1 -IntermediateMode Strict` | Also run intermediate Hooks synchronously, potentially adding waiting or UI entries |
| `scripts/install.ps1 -Force` | Allow installation to continue when client configuration disables Hooks; does not enable Hooks |
| `scripts/status.ps1` | Check installed files against source, configuration, registration and compatibility probes; does not replace client-trigger validation |
| `scripts/apply-recommended-display.ps1` | Overwrite selected display and collection settings listed below; does not rewrite Hook registration |
| `scripts/uninstall.ps1` | See [uninstall](README_EN.md#uninstall) for cleanup scope, option combinations and confirmation |

The installer backs up configuration, Hooks and runtime files and merges configuration during migration. If installation fails, it attempts to restore replaced files. Backups are under `<CodexHome>\task-stats\backups`. They may contain original custom settings or Hook commands; do not publish them directly.

The recommended-settings script backs up configuration before writing and changes the following:

- Restores all display options, category labels and icons, plus Token collection, both ranges and all ten fields.
- Enables file collection and patch parsing; resets `gitStatusSupplement=true` and fills only missing legacy Git-scan budget fields. These remain compatibility fields as described above.
- Restores Skill structured-input budgets, command-read and transcript settings; resets the descriptive mode and deduplication fields; fills `explicitMarkers` only when missing, preserving existing marker choices.
- Restores Git/Shell detail switches and length/count limits. Preserves an existing `commandLogging.mode=off`; other modes are normalized to `safe`.
- Sets the configuration format version and removes the old default `toolAliases.apply_patch=文件修改`; other aliases keep their values.
- Leaves `collection`, `logging`, `debug` and `agentManagementTools` unchanged. Re-enabling Token collection therefore does not re-enable previously disabled daily logs.

From the repository root, preview the operation with the command below, replacing `-CodexHome` with the location used for installation:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\apply-recommended-display.ps1 -CodexHome "E:\.codex" -WhatIf
```

After reviewing the scope, remove `-WhatIf` to apply. This script changes the collection settings above as well as layout. Hook trust review is normally unnecessary for this operation; verify with a new task.

## Troubleshooting and diagnostics

| Symptom | First checks |
| --- | --- |
| No start notification or completion summary | Same Codex Home, client Hook enablement/trust, a full client restart and a new task |
| Failed health check | `OverallHealthy` and specific file, syntax, registration or probe failures; avoid reinstalling or using Force to mask the cause |
| Configuration changes have no effect | Whether the installed configuration was edited, whether the task is old, and whether Quiet/Strict was re-registered through the installer |
| Incomplete file statistics | File-statistics limitations in the log; legacy Git fields cannot replace missing native records |
| Token values show `未提供` or `未确认` | Usage fields, baseline, turn ownership and budgets in [Token troubleshooting](README_EN.md#verification-and-troubleshooting) |
| Skill counts differ from read counts | [Scope deduplication and evidence levels](README_EN.md#skills), plus disabled or missing sources |
| Unexpected line breaks, spaces or alignment | Separate actual output from rendering using [Hook/client boundaries (Chinese)](HOOK_DISPLAY.md#按数据流定位问题) |

Temporarily setting `debug.enabled=true` can create `<CodexHome>\task-stats\debug\codex-task-stats-YYYY-MM-DD.jsonl`, recording runtime events, session/turn identifiers and diagnostics. Fixed bootstrap-failure diagnostics may be independent of this switch; the status script reports available bootstrap diagnostic locations. Disable the switch after investigation; doing so does not delete existing diagnostic files.

`data/state`, `data/journal` and `data/completed` hold progress state, events and completed-result caches. Do not delete them while tasks are running. If a reset is needed, stop related tasks, preserve custom configuration and needed logs, then follow the documented uninstall/reinstall procedure.

Share only minimal sanitized excerpts when reporting problems, not complete conversation JSONL, configuration backups or user directories. Safe logging is best-effort redaction and still requires manual review before publication. Follow [Security](SECURITY_EN.md) for suspected sensitive-data exposure.
