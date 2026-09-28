# Codex Task Stats

The first input in each response (turn) shows its start time; additional inputs during that response each show their sequence number and input time in a separate notification. Stop measures elapsed time from that response's first input to its end. A new response resets timing and numbering, excluding idle time between responses. Additional inputs preserve file baselines, tool counts, Skills, and subagent statistics. Legacy session-wide timing caches are no longer used.

File counts use successful native FileChange records and read only touched files. Patches reconstruct initial content, including edits later reverted. Missing evidence is marked incomplete. Agent names use validated short task names and explicit identity/child-session metadata, never positional matching. Prompt hooks have a 10-second outer timeout and a 1-second lock wait; prompt handling no longer scans the workspace.

[简体中文](README.md) · **English**

> Privacy-first task telemetry for native Codex workflows on Windows. Track duration, MCP tools, Skills, subagents, file changes, Git activity, and local tool usage—automatically.

<p align="center">
  <img src="assets/preview.png" alt="Codex Task Stats task summary preview" width="760" />
</p>

Codex can spend a long time on complex tasks, but once a task finishes it can be surprisingly hard to answer simple questions: **How long did it run? Which MCP tools were used? Which Skills were invoked? How many subagents were started? How many files changed? What did Git actually do?**

Codex Task Stats answers those questions with user-level Hooks. The client gets one compact completion summary, while a more detailed, safety-rendered log is stored locally by day. Every project sharing the same Codex Home can use the same installation.

If it makes long-running Codex work easier to understand, review, and debug, consider starring the project ⭐.

## Highlights

- **Zero-friction task summaries** — show the start time and automatically summarize the task when it ends.
- **Real MCP usage** — aggregate actual calls by `server/tool`.
- **Multi-source Skill detection** — combine structured input, transcripts, subagent records, explicit markers, and `SKILL.md` read evidence.
- **Subagent accounting** — deduplicate by real `agent_id` and use readable role names when they can be linked safely.
- **File change summaries** — count added, modified and deleted paths from successful FileChange records; moves count as deletion of the source and addition of the destination.
- **Git semantics** — distinguish Git runs, commands, and state-changing operations; read-only commands and dry runs are not counted as changes.
- **Privacy-first logs** — `safe` mode hides sensitive arguments, remote addresses, free-form text, and paths outside the workspace.
- **Local and readable** — no service, database, or dashboard required; logs live directly under Codex Home.
- **Windows PowerShell 5.1 focused** — installation, health checks, and the core regression suite target native Windows behavior.

## What it looks like

Task start:

```text
🟢 开始：14:07:08
```

Task completion:

```text
🔴 结束：14:08:34（用时：1分26秒）
🔌 MCP：mysql_7/query ×2
🧩 Skill：analyze ×1
🤖 子Agent：code_reviewer ×1，architect ×1
📝 文件：修改 ×3
🌿 Git：运行 ×2，指令 ×6，变更 ×1
⚙️ 其他：Shell命令 ×2
```

Empty categories are hidden automatically. Successful tasks do not show a redundant “completed” status; failure, interruption, or unknown states are displayed explicitly.

The client may wrap the card depending on available width. By default, Codex Task Stats enables `display.multiline` and inserts real line breaks between categories. Setting it to `false` restores one logical line separated with `｜`. How line breaks appear depends on the client. See [Hook display and newline diagnostics (Chinese)](HOOK_DISPLAY.md) for configuration semantics, verification results, and troubleshooting.

## Where the Hooks appear

After installation, Hook events appear directly in the Codex / ChatGPT conversation timeline: `UserPromptSubmit` shows the task start time, while `Stop` shows the final task summary. Intermediate Hooks collect data silently by default, so they do not keep interrupting the conversation.

<p align="center">
  <img src="assets/hook-location.gif" alt="Where Codex Task Stats Hooks appear in the client" width="900" />
</p>

The animation above shows where Hook cards appear. The exact client styling may change over time, but the statistics are still attached to Hook events near the task they belong to.

> User-facing task text and local logs intentionally use Simplified Chinese; protocol names, identifiers, file names, and code-facing terms remain unchanged.

## Quick start

### Requirements

- Windows 11
- Native Windows Agent environment in the Codex / ChatGPT client
- Windows PowerShell 5.1
- A writable Codex Home for the current Windows user

### 1. Clone or download the repository

From the repository root you should see:

```text
src/
scripts/
config/
tests/
```

### 2. Run the regression suite first

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\test.ps1"
```

Install only after the full suite passes.

### 3. Install

Default Codex Home:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\install.ps1" `
  -IntermediateMode Quiet
```

Custom Codex Home:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\install.ps1" `
  -CodexHome "E:\.codex" `
  -IntermediateMode Quiet
```

Codex Home resolution order:

```text
-CodexHome parameter
→ CODEX_HOME environment variable
→ current-user .codex directory
```

The installer merges only Codex Task Stats handlers into `hooks.json`; it does not require replacing the entire file manually.

### 4. Check installation health

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\status.ps1" `
  -CodexHome "E:\.codex"
```

The status script checks runtime files, syntax, configuration, Hook registration, and key runtime compatibility probes.

## Detailed log example

The client summary stays compact, while the local daily log preserves more detail. A single task looks roughly like this:

```text
【任务信息】
程序版本：vX.X
开始时间：2026-09-01 14:07:08 +08:00
结束时间：2026-09-01 14:08:34 +08:00
用时：1分26秒

【执行结果】
状态：完成

【调用统计】
MCP：
  - mysql_7/query ×2
Skill：
  - analyze ×1
  - code-review ×2
子Agent：
  - code_reviewer ×1
  - architect ×1
Git：
  运行 ×2
  指令 ×6
  变更 ×1
其他：
  - Shell命令 ×2

【文件变更】
文件：
  - 修改 ×3

【统计完整性】
总体完整性：部分
```

See [`examples/detailed-task.log`](examples/detailed-task.log) for a full sanitized sample. Real logs can also include safety-rendered Git / Shell command details, Skill evidence sources, and completeness notes.

## Counting semantics

### MCP

Only actually executed MCP calls are counted, aggregated by `server/tool`. Identically named tools from different MCP servers remain separate.

### Skills

Skill detection is multi-source and intentionally best-effort. Changes in client events or transcript structure can cause omissions, so it should not be treated as a perfect audit trail.

### Subagents

Subagents are deduplicated by `agent_id`. Human-readable names are display-only evidence; if a safe and reliable mapping is unavailable, the lifecycle `agent_type` is used instead.

### Files

The client shows added, modified and deleted counts. Their sum is the confirmed total for this response, not necessarily the client's edited-file count. Moves count as source deletion and destination addition; each path belongs to at most one final category.

Successful FileChange events are deduplicated per response. Patches reconstruct initial content using targeted final-file reads. Reverted edits and create/delete pairs cancel; edits to newly created files remain additions. Delete/recreate pairs depend on final content. Staging or committing existing changes adds no file count. Failed records are excluded; mid-turn input preserves prior records.

There is no workspace scan; legacy gitStatusTimeoutMs and maxGitStatusEntries settings no longer affect file counts. Child transcripts are located only in the known transcript directory, checked against parent/child identities and restricted to the response time window. Changes are merged chronologically. CRLF/LF are normalized while final-newline differences are retained. Source text and diffs remain in memory, never in telemetry state or logs.

Shell, MCP or IDE writes without FileChange records may be missed. Missing/conflicting patches, unreadable files, truncated records or unavailable child transcripts produce confirmed counts plus an incomplete notice and a logged reason. Targeted reads allow 4 MiB per file, 1000 paths and approximately 32 MiB of text; reading has a 2-second budget and reconstruction a 4-second total budget. Child collection allows 16 agents and 2 seconds. Verification covers collected records, not a complete disk audit.

### Git

```text
Git: runs ×N, commands ×M, changes ×K
```

- **Run** — one completed Shell tool invocation that contains at least one Git command.
- **Command** — total top-level `git` / `git.exe` / `git.cmd` commands.
- **Change** — Git commands that can modify the worktree, index, local repository, refs, Git configuration, or a remote repository.

For example:

```powershell
git status; git diff; git add .; git commit -m "message"
```

is counted as:

```text
runs ×1, commands ×4, changes ×2
```

File-change counts and Git-change command counts are intentionally separate dimensions.

## Privacy model

Default command logging:

```json
{
  "commandLogging": {
    "mode": "safe",
    "includeGit": true,
    "includeShell": true
  }
}
```

Supported modes:

- `safe` — persist only safety-rendered command summaries.
- `off` — do not persist command details.

There is **no `full` mode for raw command persistence**.

The renderer attempts to hide API keys, tokens, passwords, cookies, authorization data, database credentials, authenticated URLs, Git remote credentials, commit messages, free-form arguments, absolute paths outside the workspace, and arguments that cannot be proven safe.

It does not persist command `stdout`, `stderr`, tool-return bodies, or per-command duration. The guiding rule is simple: **when safety is uncertain, hide more rather than persist raw content**.

Before sharing an issue or log publicly, review it again for credentials, private paths, and business data. `safe` is a best-effort rendering mechanism, not a general-purpose DLP or compliance product.

## Local logs and configuration

If a log write fails, the summary reports it and retains the frozen summary plus raw statistics. Another `Stop` for the same turn retries the write and cleans up only after success, preserving the original end time and counts. This is not an automatic background retry.

Default log location:

```text
<CodexHome>\task-stats\logs\codex-task-YYYY-MM-DD.log
```

Each task contains sections for task metadata, execution result, call statistics, file changes, Skill collection, and completeness. Logs avoid emoji so they remain easy to search, diff, and process with scripts.

Installed configuration:

```text
<CodexHome>\task-stats\config\config.json
```

[`config/config.example.json`](config/config.example.json) is the repository reference. It covers client labels/icons, Skill transcript windows, Git-assisted file collection, quiet intermediate Hooks, logging, `safe` / `off` command logging, and tool aliases.

## Uninstall

Remove Hooks only:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive `
  -ExecutionPolicy Bypass `
  -File ".\scripts\uninstall.ps1" `
  -CodexHome "E:\.codex"
```

For all options:

```powershell
Get-Help .\scripts\uninstall.ps1 -Full
```

The uninstaller backs up `hooks.json` first and removes only handlers owned by Codex Task Stats.

## Repository layout

```text
codex-task-stats/
├── assets/                # README preview image
├── config/                # default configuration
├── examples/              # sanitized log examples
├── scripts/               # install, status, test, uninstall
├── src/                   # Hook handler and subagent correlation logic
├── tests/                 # core regressions and minimal samples
├── hooks.template.json    # Hook structure reference
├── README.md
├── README_EN.md
└── LICENSE
```

## Known boundaries

- Skill counts depend on observable structured events, transcripts, and `SKILL.md` read evidence; format changes can cause omissions.
- Some managed tools may not expose complete standard Hook events.
- File changes caused indirectly through Shell commands cannot always be attributed perfectly.
- Subagent display names are used only when they can be linked safely and reliably; identity counting still relies on `agent_id`.
- Token usage and cache hit rates are currently out of scope.
