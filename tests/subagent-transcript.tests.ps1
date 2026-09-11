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
$ProgramVersion = 'v2.1'
$TestDurationMilliseconds = 0
$base = [DateTimeOffset]::Now.AddMinutes(-1)
function Check { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Activity {
    param([string]$Agent, [string]$Name, [string]$Kind='started', [string]$Turn='turn')
    return (@{timestamp=$base.AddSeconds(1).ToString('o');type='event_msg';payload=@{type='item_completed';turn_id=$Turn;item=@{
        type='SubAgentActivity';kind=$Kind;id=('call-'+$Agent);agent_thread_id=$Agent;agent_path=('/root/'+$Name)
    }}} | ConvertTo-Json -Depth 8 -Compress)
}
function Summary {
    param([object[]]$Events, [object]$Observation=$null)
    $merged = @(Add-V17SpawnFallbackSubagentEvents -Events $Events)
    return (Build-Summary -State @{} -Events $merged -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload @{} -MainSkillObservation $null -ActivityObservation $Observation)
}
$reviewer = Activity 'reviewer-id' 'code_reviewer'
$architect = Activity 'architect-id' 'architect'
$text = @($reviewer, $architect, $architect, (Activity 'parent' 'parent' 'interacted'), (Activity 'other' 'other' 'started' 'other-turn')) -join "`n"
$observation = Get-TranscriptActivityObservation -Text $text -ExpectedTurnId 'turn' -Cwd $project
Check ($observation.AgentIds.Count -eq 2 -and $observation.AgentIds -notcontains 'parent') '消息接收方不能成为子 Agent'
$hook = [pscustomobject]@{event='SubagentStart';agentId='reviewer-id';agentType='default';at=$base.ToString('o')}
$summary = Summary (@($hook)+@($observation.Events))
Check ($summary.AgentItems.Count -eq 2 -and $summary.AgentItems -contains 'code_reviewer ×1' -and $summary.AgentItems -contains 'architect ×1') '部分 Hook 缺失时必须按真实 ID 补齐，并避免已有 Agent 重复计数'
$post = [pscustomobject]@{event='PostToolUse';toolName='spawn_agent';toolUseId='call-architect-id';success=$true;spawnObservation=$true;spawnSucceeded=$true;spawnDisplayName='architect'}
$summary = Summary (@($hook,$post)+@($observation.Events))
Check ($summary.AgentItems.Count -eq 2) 'Hook、spawn 输出和原生启动记录并存不能重复计数'
$noTime = (Activity 'parent' 'parent' 'interacted') | ConvertFrom-Json
$noTime.PSObject.Properties.Remove('timestamp')
$ignored = Get-TranscriptActivityObservation -Text ($noTime|ConvertTo-Json -Depth 8 -Compress) -ExpectedTurnId 'turn' -Cwd $project -From $base
Check ($ignored.AgentIds.Count -eq 0 -and $ignored.ParseErrors -eq 0) '无时间戳的消息交互也不能造成文件统计误报'
$outside = Get-TranscriptActivityObservation -Text $text -ExpectedTurnId 'turn' -Cwd $project -From $base.AddSeconds(10)
Check ($outside.Events.Count -eq 0 -and $outside.AgentIds.Count -eq 0) '窗口之外的启动不得补采'

if ($ReplayTranscript) {
    $replay = Get-TranscriptActivityObservation -Text (Read-TranscriptSlice -Path $ReplayTranscript -StartOffset 0).Text -ExpectedTurnId $ReplayTurnId -Cwd $project
    $summary = Summary (@([pscustomobject]@{event='SubagentStart';agentId='01a089e6-74f8-7971-b9c1-84874711f15e';agentType='code_reviewer'})+@($replay.Events))
    Check ($summary.AgentItems.Count -eq 2 -and $summary.AgentItems -contains 'architect ×1') '真实截图回放必须恢复 Architect'
    $state = [pscustomobject]@{sessionId='01a089dd-a690-7b10-9eb4-4cce44b661b9';startedAt='2026-09-10T13:55:24+08:00'}
    $combined = Add-ChildFileActivity $replay @() $state ([pscustomobject]@{transcript_path=$ReplayTranscript;cwd=$project}) ([DateTimeOffset]'2026-09-10T14:07:33+08:00')
    Check ($combined.Reasons.Count -eq 0 -and $combined.ChildEditCount -eq 0) '真实只读审查 Agent 不应再触发文件记录误报'
    Write-Host '真实会话回放通过：两个审查 Agent 均计数，子 Agent 文件误报消失。'
}

$root = Join-Path $env:TEMP ('codex-agent-transcript-'+[Guid]::NewGuid().ToString('N'))
$oldStatsHome = $env:CODEX_TASK_STATS_HOME
function Hook {
    param([string]$Event)
    $payload = @{session_id='parent';turn_id='turn';cwd=$root;transcript_path=$transcript;hook_event_name=$Event}
    if ($Event -eq 'SubagentStart') { $payload.agent_id='reviewer-id';$payload.agent_type='default' }
    $json = $payload | ConvertTo-Json -Compress
    $output = $json | & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $main -Event $Event
    Check ($LASTEXITCODE -eq 0) 'Hook 子进程失败'
    return ($output -join "`n" | ConvertFrom-Json)
}
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $env:CODEX_TASK_STATS_HOME = Join-Path $root 'stats'
    $transcript = Join-Path $root 'rollout-parent.jsonl'
    [IO.File]::WriteAllText($transcript,('{"type":"turn_context","payload":{"turn_id":"turn"}}'+"`n"),$utf8)
    $null = Hook 'UserPromptSubmit'
    $base = [DateTimeOffset]::Now
    $text = @((Activity 'reviewer-id' 'code_reviewer'), (Activity 'architect-id' 'architect')) -join "`n"
    [IO.File]::AppendAllText($transcript,$text+"`n",$utf8)
    foreach ($id in @('reviewer-id','architect-id')) {
        $meta = @{type='session_meta';payload=@{id=$id;cwd=$root;source=@{subagent=@{thread_spawn=@{parent_thread_id='parent'}}}}} | ConvertTo-Json -Depth 8 -Compress
        $message = Activity 'parent' 'parent' 'interacted' 'child-turn'
        [IO.File]::WriteAllText((Join-Path $root ('rollout-'+$id+'.jsonl')),($meta+"`n"+$message+"`n"),$utf8)
    }
    $null = Hook 'SubagentStart'
    $journalEvents = @(Get-ChildItem (Join-Path $env:CODEX_TASK_STATS_HOME 'data\journal') -Filter '*.jsonl' | ForEach-Object { Get-Content $_.FullName -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json } })
    $starts = @($journalEvents | Where-Object { $_.event -eq 'SubagentStart' })
    Check ($starts.Count -eq 1 -and $starts[0].agentId -eq 'reviewer-id') '测试 Hook 必须实际保留真实 Agent ID'
    $stop = Hook 'Stop'
    Check ($stop.systemMessage -match 'code_reviewer ×1' -and $stop.systemMessage -match 'architect ×1') 'Stop 必须显示两个 Agent'
    Check ($stop.systemMessage -notmatch '统计不完整|未命名Agent|default') ('完整的只读子 Agent 记录不应误报：'+$stop.systemMessage)
    $logs = @(Get-ChildItem (Join-Path $env:CODEX_TASK_STATS_HOME 'logs') -Filter '*.log'|ForEach-Object{[IO.File]::ReadAllText($_.FullName)}) -join "`n"
    Check ($logs -match 'architect ×1' -and $logs -notmatch '子Agent文件记录缺失') '持久日志必须与摘要一致'

    # 仍保留真实采集缺口：原生新增后又被未记录的写入改变，不能虚报已完整核验。
    $file = Join-Path $root 'untracked-edit.txt'
    [IO.File]::WriteAllText($file,'changed outside FileChange',$utf8)
    $change = [pscustomobject]@{Path=$file;Detail=[pscustomobject]@{type='add';content='original'};Scope='root';EditId='add';Cwd=$root}
    $fileSummary = Get-NativeFileChangeSummary -Changes @($change) -Cwd $root
    Check ($fileSummary.Unknown -eq 1 -and $fileSummary.Total -eq 0) '真实内容不匹配仍须标记未确认'
    Write-Host '子 Agent 补采、去重、父子关系、文件告警与 Stop 日志回归通过。'
}
finally {
    $env:CODEX_TASK_STATS_HOME = $oldStatsHome
    $full = [IO.Path]::GetFullPath($root)
    if ($full.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full).StartsWith('codex-agent-transcript-')) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
}
