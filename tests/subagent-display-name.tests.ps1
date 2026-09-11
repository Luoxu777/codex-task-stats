[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$LibraryPath = Join-Path $ProjectRoot 'src\lib\SubagentCorrelation.ps1'
. $LibraryPath

function Assert-V21Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    if (-not [object]::Equals($Actual, $Expected)) {
        throw "$Message；预期：$Expected；实际：$Actual"
    }
}

function Assert-V21True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

$preOne = [ordered]@{
    event = 'PreToolUse'
    eventTime = '2026-01-01T00:00:01.0000000+00:00'
    toolName = 'collaboration_spawn_agent'
    toolUseId = 'spawn-name-1'
}
Add-V21SubagentSpawnMetadataToRecord -Record $preOne -EventName 'PreToolUse' -Payload ([PSCustomObject]@{
    tool_name = 'collaboration_spawn_agent'
    tool_input = [PSCustomObject]@{
        task_name = 'Code reviewer'
        prompt = 'customer-private-prompt-must-not-persist'
    }
})

$startOne = [PSCustomObject]@{
    event = 'SubagentStart'
    eventTime = '2026-01-01T00:00:02.0000000+00:00'
    agentId = 'agent-one'
    agentType = 'default'
}

$postOne = [ordered]@{
    event = 'PostToolUse'
    eventTime = '2026-01-01T00:00:03.0000000+00:00'
    toolName = 'collaboration_spawn_agent'
    toolUseId = 'spawn-name-1'
}
Add-V21SubagentSpawnMetadataToRecord -Record $postOne -EventName 'PostToolUse' -Payload ([PSCustomObject]@{
    tool_name = 'collaboration_spawn_agent'
    tool_response = [PSCustomObject]@{ success = $true; agent_id = 'agent-one'; task_name = 'Code reviewer' }
})

$preTwo = [ordered]@{
    event = 'PreToolUse'
    eventTime = '2026-01-01T00:00:04.0000000+00:00'
    toolName = 'collaborationspawn_agent'
    toolUseId = 'spawn-name-2'
}
Add-V21SubagentSpawnMetadataToRecord -Record $preTwo -EventName 'PreToolUse' -Payload ([PSCustomObject]@{
    tool_name = 'collaborationspawn_agent'
    tool_input = [PSCustomObject]@{ nickname = 'Architect reviewer' }
})

$startTwo = [PSCustomObject]@{
    event = 'SubagentStart'
    eventTime = '2026-01-01T00:00:05.0000000+00:00'
    agentId = 'agent-two'
    agentType = 'default'
}

$postTwo = [ordered]@{
    event = 'PostToolUse'
    eventTime = '2026-01-01T00:00:06.0000000+00:00'
    toolName = 'collaborationspawn_agent'
    toolUseId = 'spawn-name-2'
}
Add-V21SubagentSpawnMetadataToRecord -Record $postTwo -EventName 'PostToolUse' -Payload ([PSCustomObject]@{
    tool_name = 'collaborationspawn_agent'
    tool_response = [PSCustomObject]@{ success = $true; agent_id = 'agent-two'; nickname = 'Architect reviewer' }
})

$events = @(
    [PSCustomObject]$preOne,
    $startOne,
    [PSCustomObject]$postOne,
    [PSCustomObject]$preTwo,
    $startTwo,
    [PSCustomObject]$postTwo
)
$enriched = @(Add-V17SpawnFallbackSubagentEvents -Events $events)
$starts = @($enriched | Where-Object { $_.event -eq 'SubagentStart' })
Assert-V21Equal -Actual $starts.Count -Expected 2 -Message '子Agent身份数量不能因名称增强而改变'
Assert-V21True -Condition (@($starts.agentType) -contains 'Code reviewer') -Message '未关联 Code reviewer'
Assert-V21True -Condition (@($starts.agentType) -contains 'Architect reviewer') -Message '未关联 Architect reviewer'

$serializedPre = ([PSCustomObject]$preOne | ConvertTo-Json -Depth 8 -Compress)
Assert-V21True -Condition ($serializedPre -notmatch 'customer-private-prompt-must-not-persist') -Message 'Journal 记录了 prompt 原文'
Assert-V21True -Condition ($serializedPre -match 'Code reviewer') -Message 'Journal 未保留经过安全校验的短名称'

$unsafeRecord = [ordered]@{
    event = 'PreToolUse'
    toolName = 'collaboration.spawn_agent'
    toolUseId = 'unsafe-name'
}
Add-V21SubagentSpawnMetadataToRecord -Record $unsafeRecord -EventName 'PreToolUse' -Payload ([PSCustomObject]@{
    tool_name = 'collaboration.spawn_agent'
    tool_input = [PSCustomObject]@{ task_name = 'C:\private\customer-a' }
})
Assert-V21True -Condition (-not $unsafeRecord.Contains('spawnDisplayName')) -Message '路径型名称不应持久化'

$mismatchEvents = @(
    [PSCustomObject]$preOne,
    [PSCustomObject]@{ event = 'SubagentStart'; eventTime = '2026-01-01T00:00:02.0000000+00:00'; agentId = 'mismatch-a'; agentType = 'default' },
    [PSCustomObject]@{ event = 'SubagentStart'; eventTime = '2026-01-01T00:00:02.5000000+00:00'; agentId = 'mismatch-b'; agentType = 'default' },
    [PSCustomObject]$postOne
)
$mismatchResult = @(Add-V21SubagentDisplayNames -Events $mismatchEvents)
$mismatchStarts = @($mismatchResult | Where-Object { $_.event -eq 'SubagentStart' })
Assert-V21Equal -Actual @($mismatchStarts | Where-Object { $_.agentType -eq 'default' }).Count -Expected 2 -Message '数量不匹配时不能猜测名称'

$explicitPre = [PSCustomObject]@{
    event = 'PreToolUse'; eventTime = '2026-01-01T00:00:01.0000000+00:00'; toolUseId = 'explicit-1';
    spawnObservation = $true; spawnDisplayName = 'Research reviewer'; spawnDisplayNameSource = 'nickname'; spawnAgentId = 'explicit-agent'
}
$explicitPost = [PSCustomObject]@{
    event = 'PostToolUse'; eventTime = '2026-01-01T00:00:03.0000000+00:00'; toolUseId = 'explicit-1';
    spawnObservation = $true; spawnSucceeded = $true; spawnAgentId = 'explicit-agent'
}
$explicitStart = [PSCustomObject]@{
    event = 'SubagentStart'; eventTime = '2026-01-01T00:00:02.0000000+00:00'; agentId = 'explicit-agent'; agentType = 'default'
}
$explicitOther = [PSCustomObject]@{
    event = 'SubagentStart'; eventTime = '2026-01-01T00:00:04.0000000+00:00'; agentId = 'other-agent'; agentType = 'default'
}
$explicitResult = @(Add-V21SubagentDisplayNames -Events @($explicitPre, $explicitStart, $explicitPost, $explicitOther))
Assert-V21Equal -Actual ([string](@($explicitResult | Where-Object { [string](Get-V21PropertyValue -InputObject $_ -Names @('agentId')) -eq 'explicit-agent' })[0].agentType)) -Expected 'Research reviewer' -Message '显式 agent_id 映射失败'
Assert-V21Equal -Actual ([string](@($explicitResult | Where-Object { [string](Get-V21PropertyValue -InputObject $_ -Names @('agentId')) -eq 'other-agent' })[0].agentType)) -Expected 'default' -Message '未匹配 Agent 不应被猜测命名'

$probe = Invoke-V19SubagentCorrelationCompatibilityProbe
Assert-V21True -Condition ([bool]$probe.Passed) -Message ('兼容探针失败：' + [string]$probe.Code)
Assert-V21True -Condition ([bool]$probe.DisplayNameProbePassed) -Message '兼容探针未覆盖名称增强'
Assert-V21Equal -Actual ([int]$probe.DisplayNameCount) -Expected 2 -Message '名称兼容探针数量错误'

Write-Host '子Agent显示名称回归测试通过。'
