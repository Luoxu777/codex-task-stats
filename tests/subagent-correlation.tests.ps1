[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $ProjectRoot 'src/lib/SubagentCorrelation.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "断言失败：$Message" }
}

$libraryPath = Join-Path $ProjectRoot 'src/lib/SubagentCorrelation.ps1'
$librarySource = [IO.File]::ReadAllText($libraryPath, [Text.Encoding]::UTF8)
Assert-True (-not ($librarySource -match '(?im)New-Object[^\r\n]*System\.Collections\.Generic\.List\s*\[')) '关联库不得使用 Windows PowerShell 5.1 不兼容的 New-Object Generic.List 构造'
Assert-True ($librarySource -match '\[System\.Collections\.Generic\.List\[object\]\]::new\(\)') '关联库应使用类型构造器创建 List[object]'
Assert-True ($librarySource -match '\.ToArray\(\)') '关联库应在 Generic.List 输出边界显式使用 ToArray()'

$compatibilityProbe = Invoke-V19SubagentCorrelationCompatibilityProbe
Assert-True ([bool]$compatibilityProbe.Passed) ('运行时兼容探针失败：' + [string]$compatibilityProbe.Code + ' / ' + [string]$compatibilityProbe.ExceptionType)
Assert-True ([string]::Equals([string]$compatibilityProbe.Code, 'OK', [StringComparison]::Ordinal)) '运行时兼容探针应返回 OK'
Assert-True ([int]$compatibilityProbe.ProbeVersion -eq 1) '运行时兼容探针版本应为 1'
Assert-True ([int]$compatibilityProbe.ReadEventCount -eq 2) '运行时兼容探针应读取两条子 turn 事件'
Assert-True ([int]$compatibilityProbe.MergedRunCount -eq 1) '运行时兼容探针应归并一个子 turn'
Assert-True ([int]$compatibilityProbe.MergedEventCount -eq 2) '运行时兼容探针应归并两条子 turn 事件'
Assert-True ([int]$compatibilityProbe.FallbackStartCount -eq 1) '运行时兼容探针应验证 spawn fallback'

foreach ($name in @(
    'spawn_agent',
    'collaboration.spawn_agent',
    'collaboration_spawn_agent',
    'collaborationspawn_agent',
    'local_tool/collaborationwait_agent',
    'collaboration_list_agents',
    'collaboration.respond_message'
)) {
    Assert-True (Test-V17IsAgentManagementTool -ToolName $name) "应识别 Agent 管理工具：$name"
}
foreach ($name in @('web.run', 'update_goal', 'create_goal', 'git')) {
    Assert-True (-not (Test-V17IsAgentManagementTool -ToolName $name)) "不应识别为 Agent 管理工具：$name"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-stats-v20-' + [Guid]::NewGuid().ToString('N'))
$journalDir = Join-Path $tempRoot 'journal'
$stateDir = Join-Path $tempRoot 'state'
$completedDir = Join-Path $tempRoot 'completed'
New-Item -ItemType Directory -Path $journalDir, $stateDir, $completedDir -Force | Out-Null
$encoding = [Text.UTF8Encoding]::new($false)

function Write-JsonLines {
    param([string]$Path, [object[]]$Events)
    $lines = @($Events | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 })
    [IO.File]::WriteAllLines($Path, $lines, $encoding)
}

try {
    $session = 'session-regression'
    $rootTurn = 'root-turn'
    $rootPath = Join-Path $journalDir 'root.jsonl'
    $rootEvents = @(
        [pscustomobject]@{ eventName='UserPromptSubmit'; sessionId=$session; turnId=$rootTurn; timestampUtc='2026-08-27T16:58:12Z' },
        [pscustomobject]@{ eventName='Stop'; sessionId=$session; turnId=$rootTurn; timestampUtc='2026-08-27T17:26:46Z' }
    )
    Write-JsonLines -Path $rootPath -Events $rootEvents

    $child1 = @(
        [pscustomobject]@{ eventName='SubagentStart'; sessionId=$session; turnId='child-1'; agentId='agent-1'; agentType='default'; timestampUtc='2026-08-27T17:19:12Z' },
        [pscustomobject]@{ eventName='PreToolUse'; sessionId=$session; turnId='child-1'; toolName='git'; toolUseId='tool-1'; timestampUtc='2026-08-27T17:19:13Z' }
    )
    $child2 = @(
        [pscustomobject]@{ eventName='SubagentStart'; sessionId=$session; turnId='child-2'; agentId='agent-2'; agentType='default'; timestampUtc='2026-08-27T17:19:19Z' }
    )
    Write-JsonLines -Path (Join-Path $journalDir 'child1.jsonl') -Events $child1
    Write-JsonLines -Path (Join-Path $journalDir 'child2.jsonl') -Events $child2
    [IO.File]::WriteAllText((Join-Path $stateDir 'child1.json'), '{}', $encoding)
    [IO.File]::WriteAllText((Join-Path $stateDir 'child2.json'), '{}', $encoding)

    # Same session but outside the root task window: must not merge.
    Write-JsonLines -Path (Join-Path $journalDir 'later.jsonl') -Events @(
        [pscustomobject]@{ eventName='SubagentStart'; sessionId=$session; turnId='later-child'; agentId='agent-3'; agentType='default'; timestampUtc='2026-08-27T17:33:12Z' }
    )
    # A completed child-like run must not be consumed.
    Write-JsonLines -Path (Join-Path $journalDir 'done.jsonl') -Events @(
        [pscustomobject]@{ eventName='SubagentStart'; sessionId=$session; turnId='done-child'; agentId='agent-4'; agentType='default'; timestampUtc='2026-08-27T17:20:00Z' }
    )
    [IO.File]::WriteAllText((Join-Path $completedDir 'done.json'), '{}', $encoding)
    # A different session must not merge.
    Write-JsonLines -Path (Join-Path $journalDir 'other.jsonl') -Events @(
        [pscustomobject]@{ eventName='SubagentStart'; sessionId='other-session'; turnId='other-child'; agentId='agent-5'; agentType='default'; timestampUtc='2026-08-27T17:20:00Z' }
    )

    $merge = Get-V17RelatedSubagentJournalData `
        -JournalDirectory $journalDir `
        -StateDirectory $stateDir `
        -CompletedDirectory $completedDir `
        -RootJournalPath $rootPath `
        -SessionId $session `
        -RootTurnId $rootTurn `
        -RootEvents $rootEvents `
        -StopTimeUtc ([DateTime]'2026-08-27T17:26:46Z')

    Assert-True (@($merge.RunHashes).Count -eq 2) '应只归并两个处于根任务时间窗内的孤立子 turn'
    Assert-True (@($merge.Events).Count -eq 3) '应归并两个 SubagentStart 和一个子工具事件'
    Assert-True (@($merge.RunHashes) -contains 'child1') '应包含 child1'
    Assert-True (@($merge.RunHashes) -contains 'child2') '应包含 child2'
    Assert-True (-not (@($merge.RunHashes) -contains 'later')) '不得串入后续 root turn'
    Assert-True (-not (@($merge.RunHashes) -contains 'done')) '不得吞并已有 completed 的运行'

    Remove-V17MergedSubagentArtifacts -MergeData $merge
    Assert-True (-not (Test-Path (Join-Path $journalDir 'child1.jsonl'))) '应清理 child1 journal'
    Assert-True (-not (Test-Path (Join-Path $journalDir 'child2.jsonl'))) '应清理 child2 journal'
    Assert-True (-not (Test-Path (Join-Path $stateDir 'child1.json'))) '应清理 child1 state'
    Assert-True (-not (Test-Path (Join-Path $stateDir 'child2.json'))) '应清理 child2 state'
    Assert-True (Test-Path (Join-Path $journalDir 'later.jsonl')) '不得清理不相关运行'

    $mainSource = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'src/codex-task-stats.ps1'))
    Assert-True ($mainSource -notmatch '未完成子Agent') '缺失 SubagentStop 不得进入客户端“其他”'
    $versionText = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'VERSION'), [Text.Encoding]::UTF8).Trim()
    Assert-True ([string]::Equals($versionText, 'v3.0', [StringComparison]::Ordinal)) 'VERSION 应为 v3.0'
    Assert-True ($mainSource -match 'schemaVersion = 11') '主处理器 state/completed schemaVersion 应为 11'

    $fallbackInput = @(
        [pscustomobject]@{ eventName='PostToolUse'; toolName='collaboration_spawn_agent'; toolUseId='spawn-tool-1'; success=$true; agentType='reviewer'; timestampUtc='2026-08-27T17:10:00Z' }
    )
    $fallbackOutput = @(Add-V17SpawnFallbackSubagentEvents -Events $fallbackInput)
    Assert-True (@($fallbackOutput | Where-Object { (Get-V17JournalEventName -Event $_) -eq 'SubagentStart' }).Count -eq 1) 'successful spawn fallback 应在生命周期事件完全缺失时建立一个子Agent'
    $realStartInput = @(
        [pscustomobject]@{ eventName='SubagentStart'; agentId='real-agent'; agentType='default'; timestampUtc='2026-08-27T17:10:00Z' },
        [pscustomobject]@{ eventName='PostToolUse'; toolName='collaboration_spawn_agent'; toolUseId='spawn-tool-2'; success=$true; timestampUtc='2026-08-27T17:10:01Z' }
    )
    $realStartOutput = @(Add-V17SpawnFallbackSubagentEvents -Events $realStartInput)
    Assert-True (@($realStartOutput | Where-Object { (Get-V17JournalEventName -Event $_) -eq 'SubagentStart' }).Count -eq 1) '已有真实 SubagentStart 时不得重复回退计数'

    Write-Host '子Agent关联与 PowerShell 5.1 兼容回归测试通过。'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
