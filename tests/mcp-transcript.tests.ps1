[CmdletBinding()]
param([string]$ReplayTranscript, [string]$ReplayTurnId)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$global:OutputEncoding = $utf8
$project = Split-Path -Parent $PSScriptRoot
$main = Join-Path $project 'src\codex-task-stats.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
. (Join-Path $project 'src\lib\SubagentCorrelation.ps1')
$config = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ProgramVersion = 'v4.0'
$TestDurationMilliseconds = 0

function Check { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function McpRecord {
    param([string]$Id = 'exec-mysql', [string]$Turn = 'turn', [string]$Status = 'completed')
    return (@{timestamp='2026-09-10T05:44:09.652Z'; type='event_msg'; payload=@{
        type='item_completed'; turn_id=$Turn; item=@{
            type='McpToolCall'; id=$Id; server='mysql7'; tool='query'; status=$Status
            arguments=@{sql='PRIVATE_SQL_SENTINEL'}; result=@{isError=($Status -eq 'failed'); content='PRIVATE_RESULT_SENTINEL'}
        }
    }} | ConvertTo-Json -Depth 10 -Compress)
}
function Summary { param([object[]]$Events) return (Build-Summary -State @{} -Events $Events -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload @{} -MainSkillObservation $null) }

$record = McpRecord
$observation = Get-TranscriptActivityObservation -Text $record -ExpectedTurnId 'turn' -Cwd $project
Check ($observation.Events.Count -eq 1) '原生 McpToolCall 必须补采'
$summary = Summary $observation.Events
Check ($summary.McpItems.Count -eq 1 -and $summary.McpItems[0] -eq 'mysql7/query ×1') '必须显示实际服务和工具名称'
Check (($observation.Events | ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_SQL_SENTINEL|PRIVATE_RESULT_SENTINEL') '补采元数据不得保存 SQL 或结果'

$hook = [pscustomobject]@{event='PostToolUse'; toolName='mcp__mysql7__query'; toolUseId='exec-mysql'}
$mixed = Get-TranscriptActivityObservation -Text (@($record, $record, (McpRecord 'exec-second'), (McpRecord 'other' 'other-turn'), (McpRecord 'running' 'turn' 'in_progress')) -join "`n") -ExpectedTurnId 'turn' -Cwd $project
$summary = Summary (@($hook) + @($mixed.Events))
Check ($summary.McpItems[0] -eq 'mysql7/query ×2') 'Hook 和会话中的同一次调用只计一次，不得合并不同调用或串入其他轮次'
$failed = Get-TranscriptActivityObservation -Text (McpRecord 'failed' 'turn' 'failed') -ExpectedTurnId 'turn' -Cwd $project
Check ((Summary $failed.Events).McpItems[0] -eq 'mysql7/query ×1') '失败但已结束的调用沿用 Hook 的调用次数口径'
$missingId = Get-TranscriptActivityObservation -Text (McpRecord '') -ExpectedTurnId 'turn' -Cwd $project
Check ($missingId.Events.Count -eq 0) '没有稳定调用标识不能补采'
$textOnly = @{type='response_item';payload=@{type='custom_tool_call';name='exec';call_id='wrapper';input='tools.mcp__mysql7__query({})'}} | ConvertTo-Json -Compress
$mentioned = Get-TranscriptActivityObservation -Text $textOnly -ExpectedTurnId 'turn' -Cwd $project
Check ($mentioned.Events.Count -eq 0) '不能从代码文本猜测工具执行'
$outsideWindow = Get-TranscriptActivityObservation -Text $record -ExpectedTurnId 'turn' -Cwd $project -From ([DateTimeOffset]'2026-09-10T05:45:00Z')
Check ($outsideWindow.Events.Count -eq 0) '时间窗口之外的调用不得补采'

if ($ReplayTranscript) {
    $replay = Get-TranscriptActivityObservation -Text ([string](Read-TranscriptSlice -Path $ReplayTranscript -StartOffset 0).Text) -ExpectedTurnId $ReplayTurnId -Cwd $project
    $summary = Summary $replay.Events
    Check ($summary.McpItems.Count -eq 1 -and $summary.McpItems[0] -eq 'mysql7/query ×1') '真实会话回放应恢复 mysql7/query 一次'
    Write-Host '真实会话回放通过：mysql7/query x1。'
}

# 在隔离目录走 UserPromptSubmit -> Stop，验证补采结果实际进入界面摘要和持久日志。
$root = Join-Path $env:TEMP ('codex-mcp-transcript-' + [Guid]::NewGuid().ToString('N'))
$oldStatsHome = $env:CODEX_TASK_STATS_HOME
function Hook {
    param([string]$Event, [string]$Turn)
    $payload = @{session_id='mcp-regression';turn_id=$Turn;cwd=$root;transcript_path=$transcript;hook_event_name=$Event}
    if ($Event -eq 'PostToolUse') { $payload.tool_name='mcp__mysql7__query'; $payload.tool_use_id='exec-mysql' }
    $output = ($payload | ConvertTo-Json -Compress) | & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $main -Event $Event
    Check ($LASTEXITCODE -eq 0) 'Hook 进程必须成功'
    return ($output -join "`n" | ConvertFrom-Json)
}
try {
    $null = New-Item -ItemType Directory -Path $root
    $env:CODEX_TASK_STATS_HOME = Join-Path $root 'stats'
    $transcript = Join-Path $root 'transcript.jsonl'
    foreach ($turn in @('transcript-only', 'both-sources')) {
        $context = @{type='turn_context';payload=@{turn_id=$turn}} | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($transcript, $context + "`n", $utf8)
        $null = Hook 'UserPromptSubmit' $turn
        $line = McpRecord 'exec-mysql' $turn
        [IO.File]::AppendAllText($transcript, $line + "`n" + $line + "`n", $utf8)
        if ($turn -eq 'both-sources') {
            $null = Hook 'PostToolUse' $turn
            $events = @(Get-ChildItem (Join-Path $env:CODEX_TASK_STATS_HOME 'data\journal') -Filter '*.jsonl' | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } })
            Check (@($events | Where-Object { $_.event -eq 'PostToolUse' -and $_.toolName -eq 'mcp__mysql7__query' -and $_.toolUseId -eq 'exec-mysql' }).Count -eq 1) '双源测试必须实际写入 MCP Hook 记录'
        }
        $stop = Hook 'Stop' $turn
        Check ($stop.systemMessage -match 'mysql7/query.*1') 'Stop 摘要必须显示补采到的 MCP'
    }
    $logs = @(Get-ChildItem (Join-Path $env:CODEX_TASK_STATS_HOME 'logs') -Filter '*.log' | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join "`n"
    Check ($logs -match 'mysql7/query' -and $logs -notmatch 'MCP：无|PRIVATE_SQL_SENTINEL|PRIVATE_RESULT_SENTINEL') '日志必须记录 MCP 且不泄漏参数结果'
    Write-Host 'MCP 会话补采、重复去重、轮次隔离和 Stop 日志回归通过。'
}
finally {
    $env:CODEX_TASK_STATS_HOME = $oldStatsHome
    $full = [IO.Path]::GetFullPath($root)
    if ($full.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\', [StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('codex-mcp-transcript-')) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
