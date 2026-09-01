function Test-V17IsAgentManagementTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [AllowNull()]
        [object]$ToolName
    )

    if ($null -eq $ToolName) {
        return $false
    }

    $rawName = [string]$ToolName
    if ([string]::IsNullOrWhiteSpace($rawName)) {
        return $false
    }

    # Codex has exposed the same Collaboration operations using dot,
    # underscore and flattened spellings. Compare semantic names instead of
    # one transport spelling.
    $semanticName = [regex]::Replace($rawName.Trim().ToLowerInvariant(), '[^a-z0-9]', '')
    $legacyNames = @(
        'spawnagent',
        'sendmessage',
        'respondmessage',
        'sendinput',
        'wait',
        'waitagent',
        'listagents',
        'closeagent',
        'resumeagent',
        'followuptask',
        'interruptagent',
        'stopagent'
    )

    if ($legacyNames -contains $semanticName) {
        return $true
    }

    foreach ($operation in $legacyNames) {
        if ($semanticName.EndsWith(('collaboration' + $operation), [System.StringComparison]::Ordinal)) {
            return $true
        }
    }

    return $false
}

function Test-V17IsSpawnAgentTool {
    [CmdletBinding()]
    param([AllowNull()][object]$ToolName)

    if ($null -eq $ToolName) { return $false }
    $semanticName = [regex]::Replace(([string]$ToolName).Trim().ToLowerInvariant(), '[^a-z0-9]', '')
    return ($semanticName -eq 'spawnagent' -or $semanticName.EndsWith('collaborationspawnagent', [StringComparison]::Ordinal))
}

function Get-V17Sha256Prefix {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Text, [int]$Length = 20)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        $hex = -join ($hash | ForEach-Object { $_.ToString('x2') })
        if ($Length -lt 1 -or $Length -gt $hex.Length) { $Length = $hex.Length }
        return $hex.Substring(0, $Length)
    }
    finally {
        $sha.Dispose()
    }
}

function Test-V17PostToolUseSucceeded {
    [CmdletBinding()]
    param([AllowNull()][object]$Event)

    $isError = Get-V17ObjectPropertyValue -Object $Event -Names @('isError', 'is_error', 'error')
    if ($isError -is [bool] -and $isError) { return $false }

    $success = Get-V17ObjectPropertyValue -Object $Event -Names @('success', 'succeeded', 'ok')
    if ($success -is [bool]) { return $success }

    $status = Get-V17ObjectPropertyValue -Object $Event -Names @('status', 'resultStatus', 'result_status')
    if ($null -ne $status) {
        $normalizedStatus = ([string]$status).Trim().ToLowerInvariant()
        if (@('success', 'succeeded', 'completed', 'complete', 'ok') -contains $normalizedStatus) { return $true }
        if (@('failed', 'failure', 'error', 'cancelled', 'canceled', 'denied') -contains $normalizedStatus) { return $false }
    }

    # No explicit success evidence: do not invent an Agent.
    return $false
}

function Add-V17SpawnFallbackSubagentEventsCore {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events)

    $eventList = @($Events)
    $lifecycleStarts = @($eventList | Where-Object { (Get-V17JournalEventName -Event $_) -eq 'SubagentStart' })
    if ($lifecycleStarts.Count -gt 0) {
        return $eventList
    }

    $syntheticEvents = [System.Collections.Generic.List[object]]::new()
    foreach ($eventItem in $eventList) {
        if ((Get-V17JournalEventName -Event $eventItem) -ne 'PostToolUse') { continue }
        $toolName = Get-V17ObjectPropertyValue -Object $eventItem -Names @('toolName', 'tool_name', 'name')
        if (-not (Test-V17IsSpawnAgentTool -ToolName $toolName)) { continue }
        if (-not (Test-V17PostToolUseSucceeded -Event $eventItem)) { continue }

        $toolUseId = Get-V17ObjectPropertyValue -Object $eventItem -Names @('toolUseId', 'tool_use_id', 'callId', 'call_id')
        if ($null -eq $toolUseId -or [string]::IsNullOrWhiteSpace([string]$toolUseId)) { continue }

        $agentType = Get-V17ObjectPropertyValue -Object $eventItem -Names @('agentType', 'agent_type')
        $agentTypeText = if ($null -eq $agentType) { 'default' } else { ([string]$agentType).Trim() }
        if ($agentTypeText -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { $agentTypeText = 'default' }
        $eventTime = Get-V17JournalEventTimeUtc -Event $eventItem
        $eventTimeText = if ($null -eq $eventTime) { [DateTime]::UtcNow.ToString('o') } else { $eventTime.ToString('o') }
        $fallbackId = 'spawn-fallback-' + (Get-V17Sha256Prefix -Text ([string]$toolUseId))

        # Include the normalized aliases used by historical journal schemas.
        $syntheticEvents.Add([pscustomobject]@{
            eventName       = 'SubagentStart'
            event_name      = 'SubagentStart'
            hookEventName   = 'SubagentStart'
            hook_event_name = 'SubagentStart'
            agentId         = $fallbackId
            agent_id        = $fallbackId
            agentType       = $agentTypeText
            agent_type      = $agentTypeText
            timestampUtc    = $eventTimeText
            timestamp_utc   = $eventTimeText
            evidence        = 'successful-collaboration-spawn-fallback'
        })
    }

    if ($syntheticEvents.Count -eq 0) { return $eventList }
    return Sort-V17JournalEvents -Events (@($eventList) + $syntheticEvents.ToArray())
}

function Get-V17ObjectPropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [int]$Depth = 0
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            return $property.Value
        }
    }

    if ($Depth -ge 4) {
        return $null
    }

    foreach ($containerName in @('payload', 'data', 'context', 'hookInput', 'hook_input', 'eventData', 'event_data', 'record', 'details', 'metadata')) {
        $containerProperty = $Object.PSObject.Properties[$containerName]
        if ($null -eq $containerProperty -or $null -eq $containerProperty.Value) {
            continue
        }

        $nestedValue = Get-V17ObjectPropertyValue -Object $containerProperty.Value -Names $Names -Depth ($Depth + 1)
        if ($null -ne $nestedValue) {
            return $nestedValue
        }
    }

    return $null
}

function Get-V17JournalEventName {
    [CmdletBinding()]
    param([AllowNull()][object]$Event)

    $value = Get-V17ObjectPropertyValue -Object $Event -Names @(
        'eventName', 'event_name', 'eventType', 'event_type', 'hookEventName', 'hook_event_name', 'hookEvent', 'hook_event', 'event', 'type'
    )
    if ($null -eq $value) { return '' }
    return ([string]$value).Trim()
}

function ConvertTo-V17UtcDateTime {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }

    $parsed = [DateTimeOffset]::MinValue
    $styles = [Globalization.DateTimeStyles]::AllowWhiteSpaces -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTimeOffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }

    $milliseconds = [long]0
    if ([long]::TryParse($text, [ref]$milliseconds)) {
        try {
            if ($milliseconds -gt 100000000000) {
                return [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).UtcDateTime
            }
            if ($milliseconds -gt 1000000000) {
                return [DateTimeOffset]::FromUnixTimeSeconds($milliseconds).UtcDateTime
            }
        }
        catch {
            return $null
        }
    }

    return $null
}

function Get-V17JournalEventTimeUtc {
    [CmdletBinding()]
    param([AllowNull()][object]$Event)

    $value = Get-V17ObjectPropertyValue -Object $Event -Names @(
        'timestampUtc', 'timestamp_utc', 'timestamp', 'timeUtc', 'time_utc',
        'createdAtUtc', 'created_at_utc', 'createdAt', 'created_at'
    )
    return ConvertTo-V17UtcDateTime -Value $value
}

function Read-V17JsonLines {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $lines = [System.IO.File]::ReadAllLines($Path, $encoding)
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $parsed = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $parsed) { $result.Add($parsed) }
        }
        catch {
            # A partially-written line must never make Stop fail. The normal
            # journal reader remains authoritative for the root journal.
        }
    }

    return $result.ToArray()
}

function Test-V17RunArtifactExists {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RunHash
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $false
    }

    $match = Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $RunHash } |
        Select-Object -First 1
    return ($null -ne $match)
}

function Get-V17RunArtifactPaths {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Directory,
        [Parameter(Mandatory = $true)][string]$RunHash
    )

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $RunHash } |
        ForEach-Object { $_.FullName })
}

function Get-V17RelatedSubagentJournalData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JournalDirectory,
        [AllowNull()][string]$StateDirectory,
        [AllowNull()][string]$CompletedDirectory,
        [Parameter(Mandatory = $true)][string]$RootJournalPath,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$RootTurnId,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$RootEvents,
        [DateTime]$StopTimeUtc = ([DateTime]::UtcNow)
    )

    $emptyResult = [pscustomobject]@{
        Events       = @()
        RunHashes    = @()
        JournalPaths = @()
        StatePaths   = @()
    }

    if (-not (Test-Path -LiteralPath $JournalDirectory -PathType Container)) {
        return $emptyResult
    }

    $rootStartUtc = $null
    foreach ($rootEvent in @($RootEvents)) {
        $eventTime = Get-V17JournalEventTimeUtc -Event $rootEvent
        if ($null -eq $eventTime) { continue }
        $eventName = Get-V17JournalEventName -Event $rootEvent
        if ($eventName -eq 'UserPromptSubmit') {
            $rootStartUtc = $eventTime
            break
        }
        if ($null -eq $rootStartUtc -or $eventTime -lt $rootStartUtc) {
            $rootStartUtc = $eventTime
        }
    }

    if ($null -eq $rootStartUtc -and (Test-Path -LiteralPath $RootJournalPath -PathType Leaf)) {
        $rootStartUtc = (Get-Item -LiteralPath $RootJournalPath).CreationTimeUtc
    }
    if ($null -eq $rootStartUtc) {
        # Refuse an unbounded same-session merge. Missing data is safer than
        # contaminating a neighbouring root turn.
        return $emptyResult
    }

    $lowerBoundUtc = $rootStartUtc.AddSeconds(-5)
    $upperBoundUtc = $StopTimeUtc.ToUniversalTime().AddSeconds(30)
    $rootFullPath = [System.IO.Path]::GetFullPath($RootJournalPath)
    $mergedEvents = [System.Collections.Generic.List[object]]::new()
    $runHashes = [System.Collections.Generic.List[string]]::new()
    $journalPaths = [System.Collections.Generic.List[string]]::new()
    $statePaths = [System.Collections.Generic.List[string]]::new()

    $journalFiles = @(Get-ChildItem -LiteralPath $JournalDirectory -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue)
    foreach ($journalFile in $journalFiles) {
        if ([System.IO.Path]::GetFullPath($journalFile.FullName) -eq $rootFullPath) { continue }

        $runHash = $journalFile.BaseName
        if (Test-V17RunArtifactExists -Directory $CompletedDirectory -RunHash $runHash) {
            continue
        }

        $candidateEvents = @(Read-V17JsonLines -Path $journalFile.FullName)
        if ($candidateEvents.Count -eq 0) { continue }

        $candidateSessionId = $null
        $candidateTurnId = $null
        $subagentStartUtc = $null
        $hasSubagentStart = $false
        $hasRootPrompt = $false

        foreach ($candidateEvent in $candidateEvents) {
            if ($null -eq $candidateSessionId) {
                $candidateSessionId = Get-V17ObjectPropertyValue -Object $candidateEvent -Names @('sessionId', 'session_id')
            }
            if ($null -eq $candidateTurnId) {
                $candidateTurnId = Get-V17ObjectPropertyValue -Object $candidateEvent -Names @('turnId', 'turn_id')
            }

            $eventName = Get-V17JournalEventName -Event $candidateEvent
            if ($eventName -eq 'UserPromptSubmit') { $hasRootPrompt = $true }
            if ($eventName -eq 'SubagentStart') {
                $hasSubagentStart = $true
                $candidateTime = Get-V17JournalEventTimeUtc -Event $candidateEvent
                if ($null -ne $candidateTime -and ($null -eq $subagentStartUtc -or $candidateTime -lt $subagentStartUtc)) {
                    $subagentStartUtc = $candidateTime
                }
            }
        }

        if (-not $hasSubagentStart -or $hasRootPrompt) { continue }

        # Some v1.7 journals keep run identity only in the companion state file.
        # Read only identity fields; never copy the state body into the merged event stream.
        $candidateStatePaths = @(Get-V17RunArtifactPaths -Directory $StateDirectory -RunHash $runHash)
        if (($null -eq $candidateSessionId -or $null -eq $candidateTurnId) -and $candidateStatePaths.Count -gt 0) {
            foreach ($candidateStatePath in $candidateStatePaths) {
                try {
                    $candidateState = Get-Content -LiteralPath $candidateStatePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($null -eq $candidateSessionId) {
                        $candidateSessionId = Get-V17ObjectPropertyValue -Object $candidateState -Names @('sessionId', 'session_id')
                    }
                    if ($null -eq $candidateTurnId) {
                        $candidateTurnId = Get-V17ObjectPropertyValue -Object $candidateState -Names @('turnId', 'turn_id')
                    }
                    if ($null -ne $candidateSessionId -and $null -ne $candidateTurnId) { break }
                }
                catch {
                    # Ignore malformed companion state and keep the bounded no-merge default.
                }
            }
        }

        if ($null -eq $candidateSessionId -or -not [string]::Equals([string]$candidateSessionId, $SessionId, [StringComparison]::Ordinal)) {
            continue
        }
        if ($null -ne $candidateTurnId -and [string]::Equals([string]$candidateTurnId, $RootTurnId, [StringComparison]::Ordinal)) {
            continue
        }

        if ($null -eq $subagentStartUtc) {
            $subagentStartUtc = $journalFile.CreationTimeUtc
        }
        if ($subagentStartUtc -lt $lowerBoundUtc -or $subagentStartUtc -gt $upperBoundUtc) {
            continue
        }

        foreach ($candidateEvent in $candidateEvents) { $mergedEvents.Add($candidateEvent) }
        $runHashes.Add($runHash)
        $journalPaths.Add($journalFile.FullName)
        if ($null -eq $candidateStatePaths) {
            $candidateStatePaths = @(Get-V17RunArtifactPaths -Directory $StateDirectory -RunHash $runHash)
        }
        foreach ($statePath in @($candidateStatePaths)) {
            if (-not $statePaths.Contains($statePath)) { $statePaths.Add($statePath) }
        }
    }

    return [pscustomobject]@{
        Events       = $mergedEvents.ToArray()
        RunHashes    = $runHashes.ToArray()
        JournalPaths = $journalPaths.ToArray()
        StatePaths   = $statePaths.ToArray()
    }
}

function Sort-V17JournalEvents {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Events)

    $index = 0
    $decorated = foreach ($eventItem in @($Events)) {
        $eventTime = Get-V17JournalEventTimeUtc -Event $eventItem
        if ($null -eq $eventTime) { $eventTime = [DateTime]::MaxValue }
        [pscustomobject]@{ Event = $eventItem; Time = $eventTime; Index = $index }
        $index++
    }
    return @($decorated | Sort-Object Time, Index | ForEach-Object { $_.Event })
}

function Remove-V17MergedSubagentArtifacts {
    [CmdletBinding()]
    param([AllowNull()][object]$MergeData)

    if ($null -eq $MergeData) { return }
    $paths = @($MergeData.JournalPaths) + @($MergeData.StatePaths)
    foreach ($path in $paths | Select-Object -Unique) {
        if ([string]::IsNullOrWhiteSpace([string]$path)) { continue }
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            }
        }
        catch {
            # Cleanup is best-effort. Never fail an already completed root task.
        }
    }
}

function Invoke-V19SubagentCorrelationCompatibilityProbeCore {
    [CmdletBinding()]
    param()

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-stats-v19-compat-' + [Guid]::NewGuid().ToString('N'))
    $journalDirectory = Join-Path $tempRoot 'journal'
    $stateDirectory = Join-Path $tempRoot 'state'
    $completedDirectory = Join-Path $tempRoot 'completed'
    $encoding = [Text.UTF8Encoding]::new($false)

    try {
        $null = New-Item -ItemType Directory -Path $journalDirectory, $stateDirectory, $completedDirectory -Force

        # The v1.8 failure reproduces even for an empty List[object]. Exercise the
        # empty JSONL path first so status/install can detect this runtime defect.
        $emptyPath = Join-Path $journalDirectory 'empty.jsonl'
        [IO.File]::WriteAllText($emptyPath, '', $encoding)
        $emptyRead = @(Read-V17JsonLines -Path $emptyPath)
        if ($emptyRead.Count -ne 0) {
            throw [InvalidOperationException]::new('EMPTY_JSONL_RESULT_INVALID')
        }

        $sessionId = 'compat-session'
        $rootTurnId = 'compat-root-turn'
        $rootJournalPath = Join-Path $journalDirectory 'root.jsonl'
        $childJournalPath = Join-Path $journalDirectory 'child.jsonl'
        $childStatePath = Join-Path $stateDirectory 'child.json'
        $rootEvents = @(
            [pscustomobject]@{
                eventName = 'UserPromptSubmit'
                sessionId = $sessionId
                turnId = $rootTurnId
                timestampUtc = '2026-08-27T16:58:12Z'
            },
            [pscustomobject]@{
                eventName = 'Stop'
                sessionId = $sessionId
                turnId = $rootTurnId
                timestampUtc = '2026-08-27T17:26:46Z'
            }
        )
        $childEvents = @(
            [pscustomobject]@{
                eventName = 'SubagentStart'
                sessionId = $sessionId
                turnId = 'compat-child-turn'
                agentId = 'compat-agent'
                agentType = 'default'
                timestampUtc = '2026-08-27T17:19:12Z'
            },
            [pscustomobject]@{
                eventName = 'PreCompact'
                sessionId = $sessionId
                turnId = 'compat-child-turn'
                timestampUtc = '2026-08-27T17:19:13Z'
            }
        )

        $rootLines = @($rootEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
        $childLines = @($childEvents | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 })
        [IO.File]::WriteAllLines($rootJournalPath, $rootLines, $encoding)
        [IO.File]::WriteAllLines($childJournalPath, $childLines, $encoding)
        [IO.File]::WriteAllText($childStatePath, '{}', $encoding)

        $childRead = @(Read-V17JsonLines -Path $childJournalPath)
        if ($childRead.Count -ne 2) {
            throw [InvalidOperationException]::new('JSONL_READ_COUNT_INVALID')
        }

        $merge = Get-V17RelatedSubagentJournalData `
            -JournalDirectory $journalDirectory `
            -StateDirectory $stateDirectory `
            -CompletedDirectory $completedDirectory `
            -RootJournalPath $rootJournalPath `
            -SessionId $sessionId `
            -RootTurnId $rootTurnId `
            -RootEvents $rootEvents `
            -StopTimeUtc ([DateTime]'2026-08-27T17:26:46Z')

        if (@($merge.RunHashes).Count -ne 1 -or
            @($merge.Events).Count -ne 2 -or
            -not (@($merge.RunHashes) -contains 'child')) {
            throw [InvalidOperationException]::new('SUBAGENT_MERGE_RESULT_INVALID')
        }

        $fallbackInput = @(
            [pscustomobject]@{
                eventName = 'PostToolUse'
                toolName = 'collaboration_spawn_agent'
                toolUseId = 'compat-spawn-call'
                success = $true
                agentType = 'reviewer'
                timestampUtc = '2026-08-27T17:10:00Z'
            }
        )
        $fallbackOutput = @(Add-V17SpawnFallbackSubagentEvents -Events $fallbackInput)
        $fallbackStarts = @($fallbackOutput | Where-Object {
            (Get-V17JournalEventName -Event $_) -eq 'SubagentStart'
        })
        if ($fallbackStarts.Count -ne 1) {
            throw [InvalidOperationException]::new('SPAWN_FALLBACK_RESULT_INVALID')
        }

        Remove-V17MergedSubagentArtifacts -MergeData $merge
        if ((Test-Path -LiteralPath $childJournalPath -PathType Leaf) -or
            (Test-Path -LiteralPath $childStatePath -PathType Leaf) -or
            -not (Test-Path -LiteralPath $rootJournalPath -PathType Leaf)) {
            throw [InvalidOperationException]::new('MERGED_ARTIFACT_CLEANUP_INVALID')
        }

        return [pscustomobject]@{
            Passed = $true
            Code = 'OK'
            ProbeVersion = 1
            ExceptionType = ''
            ReadEventCount = $childRead.Count
            MergedRunCount = @($merge.RunHashes).Count
            MergedEventCount = @($merge.Events).Count
            FallbackStartCount = $fallbackStarts.Count
        }
    }
    catch {
        return [pscustomobject]@{
            Passed = $false
            Code = 'SUBAGENT_RUNTIME_COMPATIBILITY_FAILED'
            ProbeVersion = 1
            ExceptionType = $_.Exception.GetType().FullName
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
# v2.1: safe subagent display-name evidence. Only exact metadata fields from
# collaboration spawn payloads are considered. Prompt/message/tool payload text
# is never copied into the Journal.
function Get-V21PropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($name in $Names) {
            foreach ($key in @($InputObject.Keys)) {
                if ([string]::Equals([string]$key, $name, [StringComparison]::OrdinalIgnoreCase)) {
                    return $InputObject[$key]
                }
            }
        }
        return $null
    }

    foreach ($name in $Names) {
        foreach ($property in @($InputObject.PSObject.Properties)) {
            if ([string]::Equals([string]$property.Name, $name, [StringComparison]::OrdinalIgnoreCase)) {
                return $property.Value
            }
        }
    }

    return $null
}

function Set-V21PropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    if ($InputObject -is [System.Collections.IDictionary]) {
        $InputObject[$Name] = $Value
        return
    }

    $existing = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $existing) {
        $existing.Value = $Value
        return
    }

    $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
}

function Find-V21ExactNamedValue {
    param(
        [AllowNull()]
        [object]$Root,

        [Parameter(Mandatory = $true)]
        [string[]]$Names,

        [ValidateRange(0, 8)]
        [int]$MaxDepth = 4
    )

    if ($null -eq $Root) {
        return $null
    }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([PSCustomObject]@{ Value = $Root; Depth = 0 })

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $value = $item.Value
        $depth = [int]$item.Depth

        if ($null -eq $value -or $value -is [string]) {
            continue
        }

        if ($value -is [System.Collections.IDictionary]) {
            foreach ($wantedName in $Names) {
                foreach ($key in @($value.Keys)) {
                    if ([string]::Equals([string]$key, $wantedName, [StringComparison]::OrdinalIgnoreCase)) {
                        return [PSCustomObject]@{
                            Name = [string]$key
                            Value = $value[$key]
                        }
                    }
                }
            }

            if ($depth -lt $MaxDepth) {
                foreach ($key in @($value.Keys)) {
                    $queue.Enqueue([PSCustomObject]@{
                        Value = $value[$key]
                        Depth = $depth + 1
                    })
                }
            }
            continue
        }

        if ($value -is [System.Collections.IEnumerable]) {
            if ($depth -lt $MaxDepth) {
                foreach ($child in @($value)) {
                    $queue.Enqueue([PSCustomObject]@{
                        Value = $child
                        Depth = $depth + 1
                    })
                }
            }
            continue
        }

        $properties = @($value.PSObject.Properties)
        foreach ($wantedName in $Names) {
            foreach ($property in $properties) {
                if ([string]::Equals([string]$property.Name, $wantedName, [StringComparison]::OrdinalIgnoreCase)) {
                    return [PSCustomObject]@{
                        Name = [string]$property.Name
                        Value = $property.Value
                    }
                }
            }
        }

        if ($depth -lt $MaxDepth) {
            foreach ($property in $properties) {
                $queue.Enqueue([PSCustomObject]@{
                    Value = $property.Value
                    Depth = $depth + 1
                })
            }
        }
    }

    return $null
}

function ConvertTo-V21SafeSubagentDisplayName {
    param(
        [AllowNull()]
        [object]$Value,

        [string]$Source = ''
    )

    if ($null -eq $Value -or $Value -isnot [string]) {
        return $null
    }

    $candidate = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    if ($candidate.Length -gt 48 -or $candidate -match '[\x00-\x1F\x7F]') {
        return $null
    }

    if ($candidate -match '(?i)(?:https?://|file://|[A-Za-z]:[\\/]|\\\\|/|@|=|\?|&|%[0-9A-F]{2})') {
        return $null
    }

    if ($candidate -match '(?i)(?:api[_ -]?key|authorization|bearer|cookie|password|passwd|secret|token)') {
        return $null
    }

    if ($candidate -notmatch '^[\p{L}\p{M}\p{N}][\p{L}\p{M}\p{N} ._-]*$') {
        return $null
    }

    $candidate = [Regex]::Replace($candidate, '\s+', ' ')
    $candidate = $candidate.Trim([char[]]@(' ', '.', '_', '-'))
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $null
    }

    $tokenCount = @($candidate -split '[ _.-]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($tokenCount -gt 6) {
        return $null
    }

    if ([string]::Equals($candidate, 'default', [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }

    # Spawn display fields may be caller-controlled. In safe mode, persist them
    # only when every token is a generic Agent-role term; project/customer labels
    # therefore fall back to lifecycle agent_type.
    if ($Source -in @('task_name', 'nickname', 'display_name')) {
        $allowedRoleTokens = @(
            'agent', 'architect', 'architecture', 'audit', 'auditor',
            'code', 'coder', 'debug', 'debugger', 'design', 'designer',
            'developer', 'docs', 'documentation', 'engineer', 'implement',
            'implementer', 'performance', 'plan', 'planner', 'qa',
            'refactor', 'research', 'researcher', 'review', 'reviewer',
            'security', 'test', 'tester', 'validate', 'validator',
            'verify', 'verifier', 'writer'
        )
        foreach ($token in @($candidate.ToLowerInvariant() -split '[ _.-]+')) {
            if ([string]::IsNullOrWhiteSpace($token)) {
                continue
            }
            if ($allowedRoleTokens -notcontains $token) {
                return $null
            }
        }
    }

    return $candidate
}

function ConvertTo-V21SafeAgentId {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or $Value -isnot [string]) {
        return $null
    }

    $candidate = ([string]$Value).Trim()
    if ($candidate.Length -lt 1 -or $candidate.Length -gt 128) {
        return $null
    }

    if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]*$') {
        return $null
    }

    return $candidate
}

function Test-V21SubagentSpawnToolName {
    param([AllowNull()][object]$ToolName)

    if ($null -eq $ToolName) {
        return $false
    }

    $normalized = ([string]$ToolName).ToLowerInvariant() -replace '[^a-z0-9]', ''
    return $normalized -in @('spawnagent', 'collaborationspawnagent')
}

function Get-V21SpawnPayloadRoots {
    param(
        [AllowNull()]
        [object]$Payload,

        [ValidateSet('Input', 'Response')]
        [string]$Kind
    )

    if ($null -eq $Payload) {
        return @()
    }

    if ($Kind -eq 'Input') {
        $names = @('tool_input', 'toolInput', 'input', 'arguments', 'args')
    }
    else {
        $names = @('tool_response', 'toolResponse', 'response', 'result', 'output')
    }

    $roots = @()
    foreach ($name in $names) {
        $value = Get-V21PropertyValue -InputObject $Payload -Names @($name)
        if ($null -ne $value) {
            $roots += $value
        }
    }

    return @($roots)
}

function Get-V21SafeSpawnMetadata {
    param([AllowNull()][object]$Payload)

    $inputRoots = @(Get-V21SpawnPayloadRoots -Payload $Payload -Kind Input)
    $responseRoots = @(Get-V21SpawnPayloadRoots -Payload $Payload -Kind Response)

    $displayObservation = $null
    $displaySource = ''

    $displaySearches = @(
        [PSCustomObject]@{ Roots = $responseRoots; Names = @('nickname'); Source = 'nickname' },
        [PSCustomObject]@{ Roots = $responseRoots; Names = @('display_name', 'displayName', 'agent_name', 'agentName'); Source = 'display_name' },
        [PSCustomObject]@{ Roots = $responseRoots; Names = @('task_name', 'taskName'); Source = 'task_name' },
        [PSCustomObject]@{ Roots = $inputRoots; Names = @('nickname'); Source = 'nickname' },
        [PSCustomObject]@{ Roots = $inputRoots; Names = @('display_name', 'displayName', 'agent_name', 'agentName'); Source = 'display_name' },
        [PSCustomObject]@{ Roots = $inputRoots; Names = @('task_name', 'taskName'); Source = 'task_name' }
    )

    foreach ($search in $displaySearches) {
        foreach ($root in @($search.Roots)) {
            $found = Find-V21ExactNamedValue -Root $root -Names $search.Names -MaxDepth 3
            if ($null -eq $found) {
                continue
            }

            $safe = ConvertTo-V21SafeSubagentDisplayName -Value $found.Value -Source $search.Source
            if (-not [string]::IsNullOrWhiteSpace($safe)) {
                $displayObservation = $safe
                $displaySource = [string]$search.Source
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($displayObservation)) {
            break
        }
    }

    $agentType = $null
    foreach ($root in @($responseRoots + $inputRoots)) {
        $foundType = Find-V21ExactNamedValue -Root $root -Names @('agent_type', 'agentType') -MaxDepth 3
        if ($null -eq $foundType) {
            continue
        }
        $safeType = ConvertTo-V21SafeSubagentDisplayName -Value $foundType.Value -Source 'agent_type'
        if (-not [string]::IsNullOrWhiteSpace($safeType)) {
            $agentType = $safeType
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($displayObservation) -and -not [string]::IsNullOrWhiteSpace($agentType)) {
        $displayObservation = $agentType
        $displaySource = 'agent_type'
    }

    $agentId = $null
    foreach ($root in $responseRoots) {
        $foundId = Find-V21ExactNamedValue -Root $root -Names @('agent_id', 'agentId') -MaxDepth 3
        if ($null -eq $foundId) {
            continue
        }
        $safeId = ConvertTo-V21SafeAgentId -Value $foundId.Value
        if (-not [string]::IsNullOrWhiteSpace($safeId)) {
            $agentId = $safeId
            break
        }
    }

    return [PSCustomObject]@{
        DisplayName = $displayObservation
        DisplayNameSource = $displaySource
        AgentType = $agentType
        AgentId = $agentId
    }
}

function Test-V21SpawnPostSucceeded {
    param([AllowNull()][object]$Payload)

    $isError = Find-V21ExactNamedValue -Root $Payload -Names @('is_error', 'isError') -MaxDepth 4
    if ($null -ne $isError -and [bool]$isError.Value) {
        return $false
    }

    $success = Find-V21ExactNamedValue -Root $Payload -Names @('success', 'succeeded') -MaxDepth 4
    if ($null -ne $success -and $success.Value -is [bool] -and -not [bool]$success.Value) {
        return $false
    }

    $status = Find-V21ExactNamedValue -Root $Payload -Names @('status') -MaxDepth 4
    if ($null -ne $status) {
        $statusText = ([string]$status.Value).Trim().ToLowerInvariant()
        if ($statusText -in @('failed', 'failure', 'error', 'cancelled', 'canceled', 'denied')) {
            return $false
        }
    }

    return $true
}

function Add-V21SubagentSpawnMetadataToRecord {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Record,

        [AllowNull()]
        [object]$Payload,

        [AllowNull()]
        [string]$EventName
    )

    $toolName = Get-V21PropertyValue -InputObject $Record -Names @('toolName', 'tool_name')
    if ([string]::IsNullOrWhiteSpace([string]$toolName)) {
        $toolName = Get-V21PropertyValue -InputObject $Payload -Names @('tool_name', 'toolName')
    }

    if (-not (Test-V21SubagentSpawnToolName -ToolName $toolName)) {
        return
    }

    $normalizedEvent = ([string]$EventName).Trim()
    if ($normalizedEvent -notin @('PreToolUse', 'PostToolUse')) {
        return
    }

    $metadata = Get-V21SafeSpawnMetadata -Payload $Payload
    Set-V21PropertyValue -InputObject $Record -Name 'spawnObservation' -Value $true

    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.DisplayName)) {
        Set-V21PropertyValue -InputObject $Record -Name 'spawnDisplayName' -Value ([string]$metadata.DisplayName)
        Set-V21PropertyValue -InputObject $Record -Name 'spawnDisplayNameSource' -Value ([string]$metadata.DisplayNameSource)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.AgentType)) {
        Set-V21PropertyValue -InputObject $Record -Name 'spawnAgentType' -Value ([string]$metadata.AgentType)
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$metadata.AgentId)) {
        Set-V21PropertyValue -InputObject $Record -Name 'spawnAgentId' -Value ([string]$metadata.AgentId)
    }

    if ($normalizedEvent -eq 'PostToolUse') {
        Set-V21PropertyValue -InputObject $Record -Name 'spawnSucceeded' -Value ([bool](Test-V21SpawnPostSucceeded -Payload $Payload))
    }
}

function Test-V21WeakAgentType {
    param([AllowNull()][object]$Value)

    $text = ([string]$Value).Trim()
    return (
        [string]::IsNullOrWhiteSpace($text) -or
        [string]::Equals($text, 'default', [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals($text, '未命名Agent', [StringComparison]::Ordinal)
    )
}

function Add-V21SubagentDisplayNames {
    param([AllowNull()][object[]]$Events)

    $eventList = @(Sort-V17JournalEvents -Events @($Events))
    if ($eventList.Count -eq 0) {
        return @()
    }

    $startsById = [ordered]@{}
    $startOrder = @()
    foreach ($eventItem in $eventList) {
        $eventName = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('event', 'hookEvent'))
        if ($eventName -ne 'SubagentStart') {
            continue
        }

        $agentId = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('agentId', 'agent_id'))
        if ([string]::IsNullOrWhiteSpace($agentId) -or $startsById.Contains($agentId)) {
            continue
        }

        $startsById[$agentId] = $eventItem
        $startOrder += $agentId
    }

    if ($startOrder.Count -eq 0) {
        return $eventList
    }

    $spawnGroups = [ordered]@{}
    $spawnSequence = 0
    foreach ($eventItem in $eventList) {
        $isObservation = Get-V21PropertyValue -InputObject $eventItem -Names @('spawnObservation')
        if ($null -eq $isObservation -or -not [bool]$isObservation) {
            continue
        }

        $toolUseId = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('toolUseId', 'tool_use_id'))
        if ([string]::IsNullOrWhiteSpace($toolUseId)) {
            $toolUseId = 'event-' + $spawnSequence.ToString([Globalization.CultureInfo]::InvariantCulture)
        }
        $spawnSequence++

        if (-not $spawnGroups.Contains($toolUseId)) {
            $spawnGroups[$toolUseId] = [ordered]@{
                ToolUseId = $toolUseId
                DisplayName = ''
                DisplayNameSource = ''
                AgentId = ''
                Succeeded = $false
            }
        }

        $group = $spawnGroups[$toolUseId]
        $name = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('spawnDisplayName'))
        if ([string]::IsNullOrWhiteSpace([string]$group.DisplayName) -and -not [string]::IsNullOrWhiteSpace($name)) {
            $group.DisplayName = $name
            $group.DisplayNameSource = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('spawnDisplayNameSource'))
        }

        $spawnAgentId = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('spawnAgentId'))
        if ([string]::IsNullOrWhiteSpace([string]$group.AgentId) -and -not [string]::IsNullOrWhiteSpace($spawnAgentId)) {
            $group.AgentId = $spawnAgentId
        }

        $eventName = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('event', 'hookEvent'))
        $succeeded = Get-V21PropertyValue -InputObject $eventItem -Names @('spawnSucceeded')
        if ($eventName -eq 'PostToolUse' -and $null -ne $succeeded -and [bool]$succeeded) {
            $group.Succeeded = $true
        }
    }

    $usableSpawns = @(
        foreach ($key in @($spawnGroups.Keys)) {
            $group = $spawnGroups[$key]
            if ([bool]$group.Succeeded -and -not [string]::IsNullOrWhiteSpace([string]$group.DisplayName)) {
                [PSCustomObject]$group
            }
        }
    )

    if ($usableSpawns.Count -eq 0) {
        return $eventList
    }

    $nameByAgentId = @{}
    $sourceByAgentId = @{}
    $usedToolUseIds = @{}

    foreach ($spawn in $usableSpawns) {
        if (
            -not [string]::IsNullOrWhiteSpace([string]$spawn.AgentId) -and
            $startsById.Contains([string]$spawn.AgentId) -and
            -not $nameByAgentId.ContainsKey([string]$spawn.AgentId)
        ) {
            $nameByAgentId[[string]$spawn.AgentId] = [string]$spawn.DisplayName
            $sourceByAgentId[[string]$spawn.AgentId] = [string]$spawn.DisplayNameSource
            $usedToolUseIds[[string]$spawn.ToolUseId] = $true
        }
    }

    $unmatchedAgentIds = @(
        foreach ($agentId in $startOrder) {
            if (-not $nameByAgentId.ContainsKey($agentId)) {
                $agentId
            }
        }
    )

    $unmatchedSpawns = @(
        foreach ($spawn in $usableSpawns) {
            if (-not $usedToolUseIds.ContainsKey([string]$spawn.ToolUseId)) {
                $spawn
            }
        }
    )

    # V2 collaboration may expose task_name/nickname without an agent_id. In the
    # aggregate-only client display, an equal one-to-one multiset is sufficient:
    # identity/count still come exclusively from lifecycle agent_id values.
    if ($unmatchedAgentIds.Count -gt 0 -and $unmatchedAgentIds.Count -eq $unmatchedSpawns.Count) {
        for ($index = 0; $index -lt $unmatchedAgentIds.Count; $index++) {
            $agentId = [string]$unmatchedAgentIds[$index]
            $spawn = $unmatchedSpawns[$index]
            $nameByAgentId[$agentId] = [string]$spawn.DisplayName
            $sourceByAgentId[$agentId] = [string]$spawn.DisplayNameSource
        }
    }

    if ($nameByAgentId.Count -eq 0) {
        return $eventList
    }

    foreach ($eventItem in $eventList) {
        $eventName = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('event', 'hookEvent'))
        if ($eventName -notin @('SubagentStart', 'SubagentStop')) {
            continue
        }

        $agentId = [string](Get-V21PropertyValue -InputObject $eventItem -Names @('agentId', 'agent_id'))
        if ([string]::IsNullOrWhiteSpace($agentId) -or -not $nameByAgentId.ContainsKey($agentId)) {
            continue
        }

        $currentType = Get-V21PropertyValue -InputObject $eventItem -Names @('agentType', 'agent_type')
        if (-not (Test-V21WeakAgentType -Value $currentType)) {
            continue
        }

        Set-V21PropertyValue -InputObject $eventItem -Name 'agentOriginalType' -Value ([string]$currentType)
        Set-V21PropertyValue -InputObject $eventItem -Name 'agentDisplayName' -Value ([string]$nameByAgentId[$agentId])
        Set-V21PropertyValue -InputObject $eventItem -Name 'agentDisplayNameSource' -Value ([string]$sourceByAgentId[$agentId])
        Set-V21PropertyValue -InputObject $eventItem -Name 'agentType' -Value ([string]$nameByAgentId[$agentId])
    }

    return $eventList
}

function Add-V17SpawnFallbackSubagentEvents {
    param([AllowNull()][object[]]$Events)

    $coreEvents = @(Add-V17SpawnFallbackSubagentEventsCore -Events @($Events))
    return Add-V21SubagentDisplayNames -Events $coreEvents
}

function Invoke-V19SubagentCorrelationCompatibilityProbe {
    $base = Invoke-V19SubagentCorrelationCompatibilityProbeCore
    if ($null -eq $base -or -not [bool](Get-V21PropertyValue -InputObject $base -Names @('Passed'))) {
        return $base
    }

    try {
        $preOne = [ordered]@{
            event = 'PreToolUse'
            eventTime = '2026-01-01T00:00:01.0000000+00:00'
            toolName = 'collaboration_spawn_agent'
            toolUseId = 'display-probe-1'
        }
        Add-V21SubagentSpawnMetadataToRecord -Record $preOne -EventName 'PreToolUse' -Payload ([PSCustomObject]@{
            tool_name = 'collaboration_spawn_agent'
            tool_input = [PSCustomObject]@{
                task_name = 'Code reviewer'
                prompt = 'this text must never be persisted'
            }
        })

        $postOne = [ordered]@{
            event = 'PostToolUse'
            eventTime = '2026-01-01T00:00:03.0000000+00:00'
            toolName = 'collaboration_spawn_agent'
            toolUseId = 'display-probe-1'
        }
        Add-V21SubagentSpawnMetadataToRecord -Record $postOne -EventName 'PostToolUse' -Payload ([PSCustomObject]@{
            tool_name = 'collaboration_spawn_agent'
            tool_response = [PSCustomObject]@{
                success = $true
                task_name = 'Code reviewer'
            }
        })

        $preTwo = [ordered]@{
            event = 'PreToolUse'
            eventTime = '2026-01-01T00:00:04.0000000+00:00'
            toolName = 'collaborationspawn_agent'
            toolUseId = 'display-probe-2'
        }
        Add-V21SubagentSpawnMetadataToRecord -Record $preTwo -EventName 'PreToolUse' -Payload ([PSCustomObject]@{
            tool_name = 'collaborationspawn_agent'
            tool_input = [PSCustomObject]@{ nickname = 'Architect reviewer' }
        })

        $postTwo = [ordered]@{
            event = 'PostToolUse'
            eventTime = '2026-01-01T00:00:06.0000000+00:00'
            toolName = 'collaborationspawn_agent'
            toolUseId = 'display-probe-2'
        }
        Add-V21SubagentSpawnMetadataToRecord -Record $postTwo -EventName 'PostToolUse' -Payload ([PSCustomObject]@{
            tool_name = 'collaborationspawn_agent'
            tool_response = [PSCustomObject]@{ success = $true; nickname = 'Architect reviewer' }
        })

        $probeEvents = @(
            [PSCustomObject]$preOne,
            [PSCustomObject]@{ event = 'SubagentStart'; eventTime = '2026-01-01T00:00:02.0000000+00:00'; agentId = 'probe-agent-1'; agentType = 'default' },
            [PSCustomObject]$postOne,
            [PSCustomObject]$preTwo,
            [PSCustomObject]@{ event = 'SubagentStart'; eventTime = '2026-01-01T00:00:05.0000000+00:00'; agentId = 'probe-agent-2'; agentType = 'default' },
            [PSCustomObject]$postTwo
        )

        $enriched = @(Add-V21SubagentDisplayNames -Events $probeEvents)
        $displayNames = @(
            $enriched |
                Where-Object { [string](Get-V21PropertyValue -InputObject $_ -Names @('event')) -eq 'SubagentStart' } |
                ForEach-Object { [string](Get-V21PropertyValue -InputObject $_ -Names @('agentType')) }
        )

        if (
            $displayNames.Count -ne 2 -or
            $displayNames -notcontains 'Code reviewer' -or
            $displayNames -notcontains 'Architect reviewer'
        ) {
            throw '显示名称兼容探针未得到两个预期名称。'
        }

        $serializedPre = ([PSCustomObject]$preOne | ConvertTo-Json -Depth 8 -Compress)
        if ($serializedPre -match 'this text must never be persisted') {
            throw '显示名称兼容探针错误保留了 prompt。'
        }

        $base | Add-Member -NotePropertyName DisplayNameProbePassed -NotePropertyValue $true -Force
        $base | Add-Member -NotePropertyName DisplayNameCount -NotePropertyValue 2 -Force
        return $base
    }
    catch {
        return [PSCustomObject]@{
            Passed = $false
            Code = 'DISPLAY_NAME_PROBE_FAILED'
            Message = '子Agent显示名称兼容探针失败。'
            ProbeVersion = Get-V21PropertyValue -InputObject $base -Names @('ProbeVersion')
            ReadEventCount = Get-V21PropertyValue -InputObject $base -Names @('ReadEventCount')
            MergedRunCount = Get-V21PropertyValue -InputObject $base -Names @('MergedRunCount')
            MergedEventCount = Get-V21PropertyValue -InputObject $base -Names @('MergedEventCount')
            FallbackStartCount = Get-V21PropertyValue -InputObject $base -Names @('FallbackStartCount')
            DisplayNameProbePassed = $false
            DisplayNameCount = 0
        }
    }
}
