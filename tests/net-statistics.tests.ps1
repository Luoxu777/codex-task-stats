[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MainScript = Join-Path $ProjectRoot 'src\codex-task-stats.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($MainScript, [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}
. (Join-Path $ProjectRoot 'src\lib\SubagentCorrelation.ps1')
$config = Get-Content -LiteralPath (Join-Path $ProjectRoot 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ProgramVersion = 'v4.0'
$TestDurationMilliseconds = 0
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-net-stats-' + [Guid]::NewGuid().ToString('N'))
$work = Join-Path $testRoot 'workspace'
$oldStatsHome = $env:CODEX_TASK_STATS_HOME

function Assert-Net {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Invoke-NetHook {
    param([string]$Event, [string]$Turn = 'net-log-retry', [hashtable]$Fields = @{})
    $payload = @{session_id='net-session'; turn_id=$Turn; cwd=$work; hook_event_name=$Event}
    foreach ($key in $Fields.Keys) { $payload[$key] = $Fields[$key] }
    $jsonPayload = $payload | ConvertTo-Json -Compress -Depth 20
    $result = $jsonPayload |
        & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $MainScript -Event $Event
    Assert-Net ($LASTEXITCODE -eq 0) 'Hook 子进程失败'
    return ($result -join [Environment]::NewLine | ConvertFrom-Json)
}

try {
    $null = New-Item -ItemType Directory -Path $work -Force
    $original = Join-Path $work 'original.txt'
    [IO.File]::WriteAllText($original, '111', $Utf8NoBom)
    foreach ($command in @('Move-Item -LiteralPath original.txt -Destination renamed.txt -WhatIf', 'Rename-Item -LiteralPath original.txt -NewName renamed.txt -WhatIf')) {
        Assert-Net (@(Get-ShellMoveFileOperations -ToolInput ([pscustomobject]@{command=$command}) -Cwd $work).Count -eq 0) 'WhatIf 不得生成移动证据'
    }
    foreach ($command in @('git commit -amPRIVATE_MESSAGE_SENTINEL', 'git commit -amConfidentialTerm', 'git commit -am "PRIVATE_MESSAGE_SENTINEL"', 'git commit -nm PRIVATE_MESSAGE_SENTINEL', 'git commit -im PRIVATE_MESSAGE_SENTINEL', 'git commit --trailer=PRIVATE_MESSAGE_SENTINEL', 'git commit --trailer PRIVATE_MESSAGE_SENTINEL', 'curl.exe -dPRIVATE_FORM_SENTINEL https://example.invalid', 'curl.exe -d "PRIVATE_FORM_SENTINEL.txt" https://example.invalid', 'curl.exe --data ./PRIVATE_FORM_SENTINEL', 'curl.exe --json ./PRIVATE_FORM_SENTINEL')) {
        $observed = Get-SafeCommandObservation -ToolPayload ([pscustomobject]@{tool_name='Bash';cwd=$work;tool_input=[pscustomobject]@{command=$command}})
        Assert-Net (@($observed.safeCommands).Count -gt 0) '脱敏测试必须实际解析命令'
        Assert-Net (($observed.safeCommands -join ' ') -notmatch 'PRIVATE_(MESSAGE|FORM)_SENTINEL|ConfidentialTerm') ('参数未脱敏：' + $command)
    }

    # Read the same skill through both a child Hook and its transcript.
    $journalDir = Join-Path $testRoot 'child-journals'
    $null = New-Item -ItemType Directory -Path $journalDir
    $rootJournal = Join-Path $journalDir 'root.jsonl'
    $now = [DateTime]::UtcNow
    $rootEvents = @([pscustomobject]@{event='PreToolUse';at=$now.ToString('o');toolName='spawn_agent';toolUseId='spawn'})
    foreach ($agent in @('one', 'two')) {
        $events = @(
            @{event='SubagentStart';at=$now.ToString('o');agentId=$agent;agentType='reviewer';sessionId='session';turnId=$agent},
            @{event='PostToolUse';at=$now.ToString('o');toolName='Bash';toolUseId=('read-'+$agent);commandCategory='shell';commandReadSkills=@('analyze')},
            @{event='SubagentStop';at=$now.ToString('o');agentId=$agent;agentType='reviewer';commandReadSkills=@('analyze')}
        )
        $json = @($events | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress }) -join [Environment]::NewLine
        [IO.File]::WriteAllText((Join-Path $journalDir ($agent+'.jsonl')), $json, $Utf8NoBom)
    }
    $merge = Get-V17RelatedSubagentJournalData -JournalDirectory $journalDir -RootJournalPath $rootJournal -SessionId 'session' -RootTurnId 'root' -RootEvents $rootEvents -StopTimeUtc $now
    $summary = Build-Summary -State @{} -Events @($merge.Events) -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload @{} -MainSkillObservation $null
    Assert-Net ($summary.SkillLine -match 'analyze ×2') ('两个子Agent各读取一次，应去重为2而非3或4；实际：' + $summary.SkillLine + '；事件：' + (@($merge.Events) | ConvertTo-Json -Depth 6 -Compress))

    # Real Hook recovery: a directory at the daily log filename forces an I/O error.
    $runtime = Join-Path $testRoot 'runtime'
    $null = New-Item -ItemType Directory -Path (Join-Path $runtime 'config') -Force
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'config\config.example.json') -Destination (Join-Path $runtime 'config\config.json')
    $env:CODEX_TASK_STATS_HOME = $runtime
    $null = Invoke-NetHook 'UserPromptSubmit'
    $null = Invoke-NetHook 'PostToolUse' -Fields @{tool_name='Bash';tool_use_id='safe';tool_input=@{command='git commit -amPRIVATE_MESSAGE_SENTINEL'}}
    $dayLog = Join-Path $runtime ('logs\codex-task-' + [DateTime]::Now.ToString('yyyy-MM-dd') + '.log')
    $null = New-Item -ItemType Directory -Path $dayLog
    $failed = Invoke-NetHook 'Stop'
    Assert-Net ($failed.systemMessage -match '日志写入失败') ('写入失败必须可见；实际：' + ($failed | ConvertTo-Json -Compress))
    $donePath = @(Get-ChildItem -LiteralPath (Join-Path $runtime 'data\completed') -File)[0].FullName
    $pending = Read-JsonFile $donePath
    Assert-Net $pending.logPending '失败后应保留待补写状态'
    Assert-Net ($pending.summary -match 'Git *：运行 ×1') ('Hook 必须采集真实测试命令；实际：' + $pending.summary)
    Assert-Net ($pending.pendingSummary.StartedAt -is [string] -and $pending.pendingSummary.EndedAt -is [string]) '冻结的时间必须是ISO字符串'
    Assert-Net (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'data\journal') -File).Count -eq 1) '失败后不得删除原始Journal'
    Assert-Net (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'data\state') -File).Count -eq 1) '失败后不得删除原始state'
    Assert-Net ((Get-Content -LiteralPath $donePath -Raw -Encoding UTF8) -notmatch 'PRIVATE_MESSAGE_SENTINEL') '待补写汇总也必须脱敏'
    Remove-Item -LiteralPath $dayLog
    # PS5.1 recovery must preserve the offset and choose the original local day.
    $pending.pendingSummary.StartedAt = '2026-09-08T00:15:00+08:00'
    $pending.pendingSummary.EndedAt = '2026-09-08T00:30:00+08:00'
    [IO.File]::WriteAllText($donePath, ($pending | ConvertTo-Json -Depth 15 -Compress), $Utf8NoBom)
    $expectedEnd = [DateTimeOffset]::Parse($pending.pendingSummary.EndedAt).ToLocalTime()
    $dayLog = Join-Path $runtime ('logs\codex-task-' + $expectedEnd.ToString('yyyy-MM-dd') + '.log')
    [IO.File]::WriteAllText($original, 'after-stop', $Utf8NoBom)
    $retry = Invoke-NetHook 'Stop'
    Assert-Net ($retry.systemMessage -eq $pending.summary) '补写不得重新统计结束后的文件变化/用时'
    $null = Invoke-NetHook 'Stop'
    $logText = Get-Content -LiteralPath $dayLog -Raw -Encoding UTF8
    Assert-Net ($logText.Contains('结束时间：' + $expectedEnd.ToString('yyyy-MM-dd HH:mm:ss zzz'))) '补写的原始时区/日期发生偏移'
    Assert-Net ([Regex]::Matches($logText, '【任务信息】').Count -eq 1) '补写/重复Stop不得重复日志'
    Assert-Net (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'data\journal') -File).Count -eq 0) '成功补写后应清理Journal'
    Assert-Net (@(Get-ChildItem -LiteralPath (Join-Path $runtime 'data\state') -File).Count -eq 0) '成功补写后应清理state'
    # Simulate a successful append followed by failure to persist completion.
    [IO.File]::WriteAllText($donePath, ($pending | ConvertTo-Json -Depth 15 -Compress), $Utf8NoBom)
    $null = Invoke-NetHook 'Stop'
    $logText = Get-Content -LiteralPath $dayLog -Raw -Encoding UTF8
    Assert-Net ([Regex]::Matches($logText, '【任务信息】').Count -eq 1) '已有完成标记时不得重复追加'
    Write-Host '最终差异、脱敏、子Agent去重及日志恢复回归测试通过。'
}
finally {
    $env:CODEX_TASK_STATS_HOME = $oldStatsHome
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved).StartsWith('codex-net-stats-') -and (Test-Path -LiteralPath $resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

