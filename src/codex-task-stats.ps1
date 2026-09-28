[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        'UserPromptSubmit',
        'PreToolUse',
        'PermissionRequest',
        'PostToolUse',
        'PreCompact',
        'PostCompact',
        'SubagentStart',
        'SubagentStop',
        'Stop'
    )]
    [string]$Event,

    # Internal deterministic test seam. Hook registrations never pass this value.
    [double]$TestDurationMilliseconds = -1
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$eventReceivedAt = [DateTimeOffset]::Now
$eventWatch = [Diagnostics.Stopwatch]::StartNew()

$script:BootstrapPhase = 'initialization'

function Write-BootstrapFailureRecord {
    param(
        [string]$EventName,
        [object]$ErrorRecord
    )

    try {
        $bootstrapRoot = $env:CODEX_TASK_STATS_HOME
        if ([string]::IsNullOrWhiteSpace($bootstrapRoot)) {
            $bootstrapRoot = Split-Path -Parent $PSScriptRoot
        }
        if ([string]::IsNullOrWhiteSpace($bootstrapRoot)) {
            return
        }

        $bootstrapRoot = [IO.Path]::GetFullPath($bootstrapRoot)
        $bootstrapDebugRoot = Join-Path $bootstrapRoot 'debug'
        if (-not (Test-Path -LiteralPath $bootstrapDebugRoot -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $bootstrapDebugRoot -Force
        }

        $errorType = 'unknown-error-type'
        if ($null -ne $ErrorRecord -and
            $null -ne $ErrorRecord.PSObject.Properties['Exception'] -and
            $null -ne $ErrorRecord.Exception) {
            $errorType = [string]$ErrorRecord.Exception.GetType().FullName
        }

        $record = [ordered]@{
            at = [DateTimeOffset]::Now.ToString('o')
            event = [string]$EventName
            phase = [string]$script:BootstrapPhase
            errorType = $errorType
            message = 'Hook 初始化或未处理错误；异常正文和输入内容未记录。'
        }
        $line = ($record | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine
        $path = Join-Path $bootstrapDebugRoot ('codex-task-stats-bootstrap-' + [DateTimeOffset]::Now.ToString('yyyy-MM-dd') + '.jsonl')
        $bytes = ([Text.UTF8Encoding]::new($false)).GetBytes($line)
        $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        # Bootstrap diagnostics must never interrupt Codex.
    }
}

# Fail open even when initialization fails before the normal event handler reaches
# its own try/catch. Stop and SubagentStop require valid JSON when stdout is used.
trap {
    try { Write-BootstrapFailureRecord -EventName $Event -ErrorRecord $_ } catch { }
    try {
        if ($Event -eq 'UserPromptSubmit') {
            $timeText = [DateTimeOffset]::Now.ToLocalTime().ToString('HH:mm:ss')
            [Console]::Out.WriteLine('{"continue":true,"systemMessage":"\ud83d\udfe2 \u5f00\u59cb\uff1a' + $timeText + '"}')
        }
        elseif ($Event -eq 'Stop') {
            [Console]::Out.WriteLine('{"continue":true,"systemMessage":"\u4efb\u52a1\u7edf\u8ba1\u751f\u6210\u5931\u8d25\uff0c\u5df2\u8df3\u8fc7\uff1bCodex \u4efb\u52a1\u4e0d\u53d7\u5f71\u54cd\u3002"}')
        }
        elseif ($Event -eq 'SubagentStop') {
            [Console]::Out.WriteLine('{}')
        }
    }
    catch { }
    exit 0
}

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom

function Get-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function Set-PropertyValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Get-ConfigValue {
    param(
        [object]$Config,
        [string[]]$Path,
        [object]$Default
    )

    $current = $Config
    foreach ($segment in $Path) {
        if ($null -eq $current) {
            return $Default
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $Default
        }

        $current = $property.Value
    }

    if ($null -eq $current) {
        return $Default
    }

    return $current
}

function ConvertFrom-JsonStringCapture {
    param([string]$Value)

    try {
        return ('"' + $Value + '"' | ConvertFrom-Json)
    }
    catch {
        return $Value
    }
}

function Recover-JsonStringField {
    param(
        [string]$Raw,
        [string]$FieldName
    )

    $pattern = '"' + [Regex]::Escape($FieldName) + '"\s*:\s*"(?<value>(?:\\.|[^"\\])*)"'
    $match = [Regex]::Match($Raw, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return ConvertFrom-JsonStringCapture -Value $match.Groups['value'].Value
}

function Recover-JsonBooleanField {
    param(
        [string]$Raw,
        [string]$FieldName
    )

    $pattern = '"' + [Regex]::Escape($FieldName) + '"\s*:\s*(?<value>true|false)'
    $match = [Regex]::Match($Raw, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }

    return [string]::Equals($match.Groups['value'].Value, 'true', [StringComparison]::OrdinalIgnoreCase)
}

function Read-HookPayload {
    param([string]$Raw)

    try {
        return [PSCustomObject]@{
            Payload = ($Raw | ConvertFrom-Json)
            ParseError = $null
            Recovered = $false
        }
    }
    catch {
        # If a payload is malformed, recover only stable metadata fields needed
        # for fail-open handling; never persist the raw prompt or assistant text.
        $recoveredPayload = [PSCustomObject]@{
            session_id = Recover-JsonStringField -Raw $Raw -FieldName 'session_id'
            turn_id = Recover-JsonStringField -Raw $Raw -FieldName 'turn_id'
            transcript_path = Recover-JsonStringField -Raw $Raw -FieldName 'transcript_path'
            cwd = Recover-JsonStringField -Raw $Raw -FieldName 'cwd'
            hook_event_name = Recover-JsonStringField -Raw $Raw -FieldName 'hook_event_name'
            model = Recover-JsonStringField -Raw $Raw -FieldName 'model'
            permission_mode = Recover-JsonStringField -Raw $Raw -FieldName 'permission_mode'
            stop_hook_active = Recover-JsonBooleanField -Raw $Raw -FieldName 'stop_hook_active'
            status = Recover-JsonStringField -Raw $Raw -FieldName 'status'
            turn_status = Recover-JsonStringField -Raw $Raw -FieldName 'turn_status'
            final_status = Recover-JsonStringField -Raw $Raw -FieldName 'final_status'
        }

        return [PSCustomObject]@{
            Payload = $recoveredPayload
            ParseError = $_.Exception.Message
            Recovered = $true
        }
    }
}

function Get-Sha256Hex {
    param([string]$Text)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Invoke-WithMutex {
    param(
        [string]$Name,
        [int]$TimeoutMs,
        [scriptblock]$ScriptBlock
    )

    $mutex = [System.Threading.Mutex]::new($false, $Name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMs)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "等待互斥锁超时：$Name"
        }

        return & $ScriptBlock
    }
    finally {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch { }
        }
        $mutex.Dispose()
    }
}

function Write-Utf8FileAtomic {
    param(
        [string]$Path,
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $tempPath = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tempPath, $Content, $Utf8NoBom)
        $null = Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Append-Utf8Line {
    param(
        [string]$Path,
        [string]$Line
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Append,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    try {
        $writer = [IO.StreamWriter]::new($stream, $Utf8NoBom)
        try {
            $writer.WriteLine($Line)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Read-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return ($text | ConvertFrom-Json)
}

function Normalize-StableId {
    param(
        [object]$Value,
        [string]$Fallback
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    $id = [string]$Value
    $id = [Regex]::Replace($id, '[\r\n\t]+', '')
    $id = [Regex]::Replace($id, '[\x00-\x1F\x7F]', '')
    $id = $id.Trim()
    if ([string]::IsNullOrWhiteSpace($id)) {
        return $Fallback
    }

    # Stable IDs are used for deduplication and hashing, not UI display. Do not
    # truncate them, because two long IDs could otherwise collapse together.
    return $id
}

function Sanitize-DisplayName {
    param(
        [object]$Value,
        [string]$Fallback = 'unknown'
    )

    if ($null -eq $Value) {
        return $Fallback
    }

    $name = [string]$Value
    $name = [Regex]::Replace($name, '[\r\n\t]+', ' ')
    $name = [Regex]::Replace($name, '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', '')
    $name = $name.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $Fallback
    }

    if ($name.Length -gt 160) {
        $name = $name.Substring(0, 157) + '...'
    }

    return $name
}

function Sanitize-FileNameComponent {
    param(
        [object]$Value,
        [string]$Fallback
    )

    $name = Sanitize-DisplayName -Value $Value -Fallback $Fallback
    $name = [Regex]::Replace($name, '[\\/:*?"<>|]', '-')
    $name = $name.Trim([char[]]@(' ', '.'))
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $Fallback
    }
    if ($name.Length -gt 80) {
        $name = $name.Substring(0, 80)
    }
    return $name
}

function Convert-McpToolName {
    param([string]$ToolName)

    if (-not $ToolName.StartsWith('mcp__', [StringComparison]::OrdinalIgnoreCase)) {
        return Sanitize-DisplayName -Value $ToolName
    }

    $rest = $ToolName.Substring(5)
    $parts = $rest -split '__', 2
    if ($parts.Count -ge 2) {
        return (Sanitize-DisplayName -Value $parts[0]) + '/' + (Sanitize-DisplayName -Value $parts[1])
    }

    return Sanitize-DisplayName -Value $rest
}

function Add-OrderedCount {
    param(
        [hashtable]$Counts,
        [System.Collections.ArrayList]$Order,
        [string]$Name,
        [int]$Increment = 1
    )

    if (-not $Counts.ContainsKey($Name)) {
        $Counts[$Name] = 0
        $null = $Order.Add($Name)
    }
    $Counts[$Name] = [int]$Counts[$Name] + $Increment
}

function Format-CountLine {
    param(
        [string]$Label,
        [hashtable]$Counts,
        [System.Collections.ArrayList]$Order,
        [string]$EmptyValue,
        [ValidateSet('icon', 'bracket', 'none')]
        [string]$HighlightStyle = 'none',
        [string]$Icon = ''
    )

    if ($Order.Count -eq 0) {
        return "$Label：$EmptyValue"
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Order) {
        $parts.Add("$name ×$($Counts[$name])")
    }

    $prefix = "$Label："
    switch ($HighlightStyle) {
        'icon' {
            if (-not [string]::IsNullOrWhiteSpace($Icon)) {
                $prefix = "$Icon $Label："
            }
        }
        'bracket' {
            $prefix = "【$Label】"
        }
    }

    return $prefix + ($parts -join '，')
}


function Format-GitLine {
    param(
        [string]$Label,
        [int]$RunCount,
        [int]$InstructionCount,
        [int]$ChangeCount,
        [string]$EmptyValue,
        [ValidateSet('icon', 'bracket', 'none')]
        [string]$HighlightStyle = 'none',
        [string]$Icon = ''
    )

    if ($RunCount -le 0) {
        return "$Label：$EmptyValue"
    }

    $prefix = "$Label："
    switch ($HighlightStyle) {
        'icon' {
            if (-not [string]::IsNullOrWhiteSpace($Icon)) {
                $prefix = "$Icon $Label："
            }
        }
        'bracket' {
            $prefix = "【$Label】"
        }
    }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("运行 ×$RunCount")
    $parts.Add("指令 ×$InstructionCount")
    if ($ChangeCount -gt 0) {
        $parts.Add("变更 ×$ChangeCount")
    }

    return $prefix + ($parts -join '，')
}

function Get-CountItems {
    param(
        [hashtable]$Counts,
        [System.Collections.ArrayList]$Order
    )

    $items = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Order) {
        $items.Add("$name ×$($Counts[$name])")
    }
    return @($items)
}

function Add-LogCountCategory {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Label,
        [object[]]$Items,
        [string]$EmptyValue
    )

    $safeItems = @($Items)
    if ($safeItems.Count -eq 0) {
        $Lines.Add("$Label：$EmptyValue")
        return
    }

    $Lines.Add("$Label：")
    foreach ($item in $safeItems) {
        $Lines.Add('  - ' + [string]$item)
    }
}


function Add-LogGitCategory {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [string]$Label,
        [int]$ChangeCount,
        [int]$RunCount,
        [int]$InstructionCount,
        [object[]]$Runs,
        [string]$EmptyValue
    )

    if ($RunCount -le 0) {
        $Lines.Add("$Label：$EmptyValue")
        return
    }

    $Lines.Add("$Label：")
    $Lines.Add("  运行 ×$RunCount")
    $Lines.Add("  指令 ×$InstructionCount")
    if ($ChangeCount -gt 0) {
        $Lines.Add("  变更 ×$ChangeCount")
    }

    $safeRuns = @($Runs)
    if ($safeRuns.Count -eq 0) {
        return
    }

    $Lines.Add('  命令：')
    $runIndex = 0
    foreach ($run in $safeRuns) {
        $runIndex++
        $runInstructionCount = [int](Get-PropertyValue -Object $run -Name 'instructionCount' -Default 0)
        $Lines.Add("    运行 $runIndex（指令 ×$runInstructionCount）：")
        $commands = @((Get-PropertyValue -Object $run -Name 'commands' -Default @()))
        if ($commands.Count -eq 0) {
            $Lines.Add('      - <命令明细未记录>')
            continue
        }
        foreach ($command in $commands) {
            $Lines.Add('      - ' + [string]$command)
        }
    }
}

function Add-LogShellCommandDetails {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [object[]]$Runs
    )

    $safeRuns = @($Runs)
    if ($safeRuns.Count -eq 0) {
        return
    }

    $Lines.Add('  命令：')
    $runIndex = 0
    foreach ($run in $safeRuns) {
        $runIndex++
        $Lines.Add("    运行 $runIndex：")
        $commands = @((Get-PropertyValue -Object $run -Name 'commands' -Default @()))
        if ($commands.Count -eq 0) {
            $Lines.Add('      - <命令明细未记录>')
            continue
        }
        foreach ($command in $commands) {
            $Lines.Add('      - ' + [string]$command)
        }
    }
}

function Format-Duration {
    param([double]$Milliseconds)

    if ($Milliseconds -lt 0) {
        return '未知'
    }

    # Round the total duration once, using conventional half-up behavior, and
    # only then split it into hours/minutes/seconds. This prevents values such
    # as 59.5 seconds from becoming "59秒" or "1分60秒".
    [Int64]$totalSeconds = [Convert]::ToInt64(
        [Math]::Round($Milliseconds / 1000.0, 0, [MidpointRounding]::AwayFromZero)
    )

    if ($totalSeconds -le 0) {
        return '不足1秒'
    }

    [Int64]$hours = [Math]::Floor($totalSeconds / 3600)
    [Int64]$minutes = [Math]::Floor(($totalSeconds % 3600) / 60)
    [Int64]$secondsRemainder = $totalSeconds % 60

    $parts = [System.Collections.Generic.List[string]]::new()
    if ($hours -gt 0) {
        $parts.Add($hours.ToString([Globalization.CultureInfo]::InvariantCulture) + '小时')
    }
    if ($minutes -gt 0) {
        $parts.Add($minutes.ToString([Globalization.CultureInfo]::InvariantCulture) + '分')
    }
    if ($secondsRemainder -gt 0) {
        $parts.Add($secondsRemainder.ToString([Globalization.CultureInfo]::InvariantCulture) + '秒')
    }

    if ($parts.Count -eq 0) {
        return '不足1秒'
    }

    return ($parts -join '')
}


function Get-FileIdentityHash {
    param(
        [object]$PathValue,
        [string]$Cwd
    )

    if ($null -eq $PathValue) {
        return ''
    }

    $pathText = [string]$PathValue
    $pathText = [Regex]::Replace($pathText, '[\r\n\t]+', '')
    $pathText = [Regex]::Replace($pathText, '[\x00-\x1F\x7F]', '')
    $pathText = $pathText.Trim()
    if ($pathText.Length -ge 2 -and $pathText[0] -eq '"' -and $pathText[$pathText.Length - 1] -eq '"') {
        $pathText = $pathText.Substring(1, $pathText.Length - 2)
    }
    if ([string]::IsNullOrWhiteSpace($pathText)) {
        return ''
    }

    $canonical = $pathText
    try {
        if ([IO.Path]::IsPathRooted($pathText)) {
            $canonical = [IO.Path]::GetFullPath($pathText)
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Cwd) -and (Test-Path -LiteralPath $Cwd -PathType Container)) {
            $canonical = [IO.Path]::GetFullPath((Join-Path $Cwd $pathText))
        }
    }
    catch {
        $canonical = $pathText
    }

    $canonical = $canonical.Replace('\', '/')
    $canonical = $canonical.TrimEnd([char[]]@('/'))
    $canonical = $canonical.ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($canonical)) {
        return ''
    }

    return Get-Sha256Hex -Text $canonical
}

function Test-IsApplyPatchTool {
    param([string]$ToolName)

    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        return $false
    }

    return [Regex]::IsMatch(
        $ToolName.Trim(),
        '^apply[_-]?patch$',
        ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    )
}

function Test-IsCommandExecutionTool {
    param([string]$ToolName)

    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        return $false
    }

    $normalized = $ToolName.Trim().ToLowerInvariant()
    if (@('bash', 'shell', 'powershell', 'pwsh', 'cmd', 'exec', 'exec_command', 'terminal') -contains $normalized) {
        return $true
    }

    return [Regex]::IsMatch(
        $normalized,
        '(^|[/:._-])(bash|shell|powershell|pwsh|cmd|exec|exec_command|terminal)([/:._-]|$)',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Get-ToolInputCommandText {
    param(
        [object]$ToolInput,
        [int]$Depth = 0
    )

    if ($null -eq $ToolInput -or $Depth -gt 4) {
        return ''
    }

    if ($ToolInput -is [string] -or $ToolInput -is [char]) {
        $text = [string]$ToolInput
        if ($Depth -lt 4 -and $text.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) {
            try {
                $decoded = $text | ConvertFrom-Json
                $nestedText = Get-ToolInputCommandText -ToolInput $decoded -Depth ($Depth + 1)
                if (-not [string]::IsNullOrWhiteSpace($nestedText)) {
                    return $nestedText
                }
            }
            catch { }
        }
        return $text
    }

    if ($ToolInput -is [Array]) {
        $parts = [System.Collections.Generic.List[string]]::new()
        foreach ($entry in @($ToolInput)) {
            $part = Get-ToolInputCommandText -ToolInput $entry -Depth ($Depth + 1)
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $parts.Add($part)
            }
        }
        return ($parts -join "`n")
    }

    # Codex tool payloads vary between clients and versions. Prefer explicit
    # command-like properties and recurse through wrapper objects. The returned
    # string is used only in memory and is never persisted.
    foreach ($propertyName in @('command', 'cmd', 'script', 'patch', 'input')) {
        $candidate = Get-PropertyValue -Object $ToolInput -Name $propertyName -Default $null
        if ($null -eq $candidate) { continue }
        $text = Get-ToolInputCommandText -ToolInput $candidate -Depth ($Depth + 1)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            return $text
        }
    }

    return ''
}


function Get-CommandLoggingMode {
    $mode = ([string](Get-ConfigValue -Config $config -Path @('commandLogging', 'mode') -Default 'safe')).Trim().ToLowerInvariant()
    if ([string]::Equals($mode, 'off', [StringComparison]::Ordinal)) {
        return 'off'
    }

    # 为保证敏感信息不会因配置失误而落盘，除 off 外统一回退到 safe。
    return 'safe'
}

function ConvertTo-PlainCommandToken {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $text = [string]$Value
    $text = [Regex]::Replace($text, '[\r\n\t]+', ' ')
    $text = [Regex]::Replace($text, '[\x00-\x1F\x7F]', '')
    $text = $text.Trim()
    if ($text.Length -ge 2) {
        $first = $text[0]
        $last = $text[$text.Length - 1]
        if (($first -eq [char]34 -and $last -eq [char]34) -or
            ($first -eq [char]39 -and $last -eq [char]39) -or
            ($first -eq [char]96 -and $last -eq [char]96)) {
            $text = $text.Substring(1, $text.Length - 2)
        }
    }

    return $text.Trim()
}

function Test-ContainsSensitiveCommandValue {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $patterns = @(
        '(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|passwd|pwd|secret|authorization|cookie|private[_-]?key|client[_-]?secret)\b\s*[:=]',
        '(?i)\bBearer\s+\S+',
        '(?i)\b(?:sk|pk|ghp|github_pat|xox[baprs]|AKIA)[-_A-Za-z0-9]{8,}',
        '(?i)-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
        '(?i)\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'
    )
    foreach ($pattern in $patterns) {
        if ([Regex]::IsMatch($Text, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            return $true
        }
    }

    return $false
}

function Test-IsRemoteAddressToken {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return [Regex]::IsMatch(
        $Text,
        '(?i)^(?:[a-z][a-z0-9+.-]*://|[^@\s]+@[^:\s]+:)',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Format-SafeCommandToken {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    if ($Text -match '\s') {
        return "'" + $Text.Replace("'", "''") + "'"
    }
    return $Text
}

function ConvertTo-SafeWorkspacePath {
    param(
        [object]$Value,
        [string]$Cwd
    )

    $text = ConvertTo-PlainCommandToken -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '<路径已隐藏>'
    }
    if ($text.StartsWith('$', [StringComparison]::Ordinal) -or
        $text.StartsWith('%', [StringComparison]::Ordinal)) {
        return '<变量>'
    }
    if (Test-ContainsSensitiveCommandValue -Text $text) {
        return '<敏感信息已隐藏>'
    }

    try {
        if ([IO.Path]::IsPathRooted($text)) {
            $fullPath = [IO.Path]::GetFullPath($text)
            if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
                $fullCwd = [IO.Path]::GetFullPath($Cwd).TrimEnd([char[]]@('\', '/'))
                if ([string]::Equals($fullPath.TrimEnd([char[]]@('\', '/')), $fullCwd, [StringComparison]::OrdinalIgnoreCase)) {
                    return '.'
                }

                $cwdPrefix = $fullCwd + [IO.Path]::DirectorySeparatorChar
                if ($fullPath.StartsWith($cwdPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    $relative = $fullPath.Substring($cwdPrefix.Length)
                    return Format-SafeCommandToken -Text $relative
                }
            }
            return '<路径已隐藏>'
        }
    }
    catch {
        return '<路径已隐藏>'
    }

    if ([Regex]::IsMatch($text, '(^|[\\/])\.\.([\\/]|$)')) {
        return '<路径已隐藏>'
    }

    if ($text.Length -gt 512) {
        return '<路径已隐藏>'
    }

    return Format-SafeCommandToken -Text $text
}

function Test-IsPathLikeCommandToken {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    return [IO.Path]::IsPathRooted($Text) -or
        $Text.StartsWith('.', [StringComparison]::Ordinal) -or
        $Text.StartsWith('~', [StringComparison]::Ordinal) -or
        $Text.Contains('\') -or
        $Text.Contains('/') -or
        [Regex]::IsMatch($Text, '\.[A-Za-z0-9]{1,12}$')
}

function Test-IsGitCommandName {
    param([string]$CommandName)

    if ([string]::IsNullOrWhiteSpace($CommandName)) {
        return $false
    }

    $candidate = ConvertTo-PlainCommandToken -Value $CommandName
    $candidate = $candidate.TrimStart([char[]]@('&', ' '))
    try {
        $leaf = [IO.Path]::GetFileName($candidate.Replace('/', '\'))
    }
    catch {
        $leaf = $candidate
    }

    return @('git', 'git.exe', 'git.cmd') -contains $leaf.ToLowerInvariant()
}

function Get-PowerShellCommandAsts {
    param([string]$CommandText)

    $commands = [System.Collections.Generic.List[object]]::new()
    $parseErrorCount = 0
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return [PSCustomObject]@{
            Commands = @()
            ParseErrorCount = 0
        }
    }

    try {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $CommandText,
            [ref]$tokens,
            [ref]$parseErrors
        )
        $parseErrorCount = @($parseErrors).Count
        foreach ($node in @($ast.FindAll(
            { param($candidate) $candidate -is [System.Management.Automation.Language.CommandAst] },
            $true
        ))) {
            $commands.Add($node)
        }
    }
    catch {
        $parseErrorCount = 1
    }

    return [PSCustomObject]@{
        Commands = @($commands)
        ParseErrorCount = $parseErrorCount
    }
}


function Get-GitCommandParts {
    param([object]$CommandAst)

    $subcommand = ''
    $arguments = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $CommandAst) {
        return [PSCustomObject]@{ Subcommand = ''; Arguments = @() }
    }

    $elements = @($CommandAst.CommandElements)
    $skipGlobalValue = $false
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $token = ConvertTo-PlainCommandToken -Value ([string]$elements[$index].Extent.Text)
        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        $lower = $token.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($subcommand)) {
            if ($skipGlobalValue) {
                $skipGlobalValue = $false
                continue
            }
            if (@('-c', '--git-dir', '--work-tree', '--namespace', '--exec-path') -contains $lower) {
                $skipGlobalValue = $true
                continue
            }
            if ($lower -match '^--(?:git-dir|work-tree|namespace|exec-path)=') { continue }
            if ($lower.StartsWith('-', [StringComparison]::Ordinal)) { continue }

            $subcommand = $lower
            continue
        }

        # Preserve short-option case because Git assigns different meanings to
        # flags such as add -n (dry-run) and add -N (intent-to-add).
        $arguments.Add($token)
    }

    return [PSCustomObject]@{
        Subcommand = $subcommand
        Arguments = @($arguments)
    }
}

function Test-GitArgumentPresent {
    param(
        [string[]]$Arguments,
        [string[]]$Names
    )

    foreach ($argument in @($Arguments)) {
        foreach ($name in @($Names)) {
            if ([string]::Equals($argument, $name, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            if ($name.StartsWith('--', [StringComparison]::Ordinal) -and
                $argument.StartsWith($name + '=', [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Test-GitShortFlagPresent {
    param(
        [string[]]$Arguments,
        [char]$Flag
    )

    foreach ($argumentValue in @($Arguments)) {
        $argument = [string]$argumentValue
        if ([string]::IsNullOrWhiteSpace($argument) -or $argument.Length -lt 2) {
            continue
        }
        if ($argument[0] -ne [char]'-' -or
            ($argument.Length -gt 1 -and $argument[1] -eq [char]'-')) {
            continue
        }

        # Windows PowerShell 5.1 can select an unexpected String.IndexOf
        # overload for a [char] argument. Compare characters explicitly so
        # -n and combined forms such as -nd/-dn/-nfd remain deterministic.
        foreach ($candidateFlag in $argument.Substring(1).ToCharArray()) {
            if ($candidateFlag -ceq $Flag) {
                return $true
            }
        }
    }
    return $false
}

function Get-GitPositionalArguments {
    param(
        [string[]]$Arguments,
        [string[]]$OptionsWithValue = @()
    )

    $positionals = [System.Collections.Generic.List[string]]::new()
    $skipNext = $false
    foreach ($argument in @($Arguments)) {
        if ($skipNext) {
            $skipNext = $false
            continue
        }
        if ($OptionsWithValue -contains $argument) {
            $skipNext = $true
            continue
        }
        $hasInlineOptionValue = $false
        foreach ($optionName in @($OptionsWithValue)) {
            if ($optionName.StartsWith('--', [StringComparison]::Ordinal) -and
                $argument.StartsWith($optionName + '=', [StringComparison]::OrdinalIgnoreCase)) {
                $hasInlineOptionValue = $true
                break
            }
        }
        if ($hasInlineOptionValue -or $argument.StartsWith('-', [StringComparison]::Ordinal)) {
            continue
        }
        $positionals.Add($argument)
    }
    return @($positionals)
}

function Test-IsGitChangeCommandAst {
    param([object]$CommandAst)

    $parts = Get-GitCommandParts -CommandAst $CommandAst
    $subcommand = [string]$parts.Subcommand
    $arguments = @($parts.Arguments)
    if ([string]::IsNullOrWhiteSpace($subcommand)) { return $false }

    $readOnlyCommands = @(
        'status', 'diff', 'log', 'show', 'blame', 'grep', 'ls-files', 'rev-parse',
        'describe', 'shortlog', 'whatchanged', 'ls-tree', 'name-rev', 'for-each-ref',
        'count-objects', 'show-ref', 'merge-base', 'cat-file', 'help', 'version'
    )
    if ($readOnlyCommands -contains $subcommand) { return $false }

    switch ($subcommand) {
        'branch' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-d', '--delete', '-m', '--move', '-c', '--copy', '--set-upstream-to', '--unset-upstream', '--edit-description')) { return $true }
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-a', '--all', '-r', '--remotes', '-l', '--list', '--show-current', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at', '--format', '--sort', '-v', '--verbose', '--column', '--color', '--ignore-case')) { return $false }
            return @(Get-GitPositionalArguments -Arguments $arguments).Count -gt 0
        }
        'tag' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-d', '--delete', '-f', '--force', '-a', '--annotate', '-s', '--sign', '-u', '--local-user', '-m', '--message', '-F', '--file')) { return $true }
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-l', '--list', '-v', '--verify', '-n', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at', '--format', '--sort', '--column', '--color')) { return $false }
            return @(Get-GitPositionalArguments -Arguments $arguments).Count -gt 0
        }
        'clean' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-n', '--dry-run')) { return $false }
            if (Test-GitShortFlagPresent -Arguments $arguments -Flag 'n') { return $false }
            return $true
        }
        'apply' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--check', '--stat', '--numstat', '--summary')) { return $false }
            return $true
        }
        'stash' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -gt 0 -and @('list', 'show') -contains $positionals[0]) { return $false }
            return $true
        }
        'remote' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--dry-run')) { return $false }
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('add', 'remove', 'rm', 'rename', 'set-url', 'set-head', 'set-branches', 'prune', 'update') -contains $positionals[0]
        }
        'config' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--add', '--replace-all', '--unset', '--unset-all', '--rename-section', '--remove-section', '--edit', '-e')) { return $true }
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--get', '--get-all', '--get-regexp', '--get-urlmatch', '--list', '-l', '--show-origin', '--show-scope', '--name-only')) { return $false }
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments -OptionsWithValue @('--file', '-f', '--blob', '--type', '--default'))
            return $positionals.Count -ge 2
        }
        'worktree' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--dry-run')) { return $false }
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('add', 'move', 'remove', 'prune', 'lock', 'unlock', 'repair') -contains $positionals[0]
        }
        'notes' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('add', 'append', 'copy', 'edit', 'merge', 'remove', 'prune') -contains $positionals[0]
        }
        'submodule' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('add', 'update', 'deinit', 'sync', 'set-branch', 'set-url', 'absorbgitdirs') -contains $positionals[0]
        }
        'sparse-checkout' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('init', 'set', 'add', 'reapply', 'disable') -contains $positionals[0]
        }
        'reflog' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            return @('delete', 'expire') -contains $positionals[0]
        }
        'bisect' {
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            if ($positionals.Count -eq 0) { return $false }
            if (@('log', 'visualize', 'view') -contains $positionals[0]) { return $false }
            return $true
        }
        'symbolic-ref' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('--delete')) { return $true }
            $positionals = @(Get-GitPositionalArguments -Arguments $arguments)
            return $positionals.Count -ge 2
        }
        'replace' {
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-d', '--delete')) { return $true }
            if (Test-GitArgumentPresent -Arguments $arguments -Names @('-l', '--list')) { return $false }
            return @(Get-GitPositionalArguments -Arguments $arguments).Count -ge 2
        }
        'hash-object' {
            return Test-GitArgumentPresent -Arguments $arguments -Names @('-w')
        }
        'fsck' {
            return Test-GitArgumentPresent -Arguments $arguments -Names @('--lost-found')
        }
    }

    $alwaysChanging = @(
        'add', 'commit', 'push', 'pull', 'fetch', 'merge', 'rebase', 'revert',
        'cherry-pick', 'reset', 'restore', 'switch', 'checkout', 'rm', 'mv', 'init',
        'clone', 'am', 'update-index', 'update-ref', 'read-tree', 'write-tree',
        'commit-tree', 'mktag', 'pack-refs', 'repack', 'gc', 'prune', 'maintenance'
    )
    if ($alwaysChanging -contains $subcommand) {
        if (Test-GitArgumentPresent -Arguments $arguments -Names @('--dry-run')) { return $false }
        if (@('add', 'push', 'rm', 'mv') -contains $subcommand -and (Test-GitShortFlagPresent -Arguments $arguments -Flag 'n')) { return $false }
        if ([string]::Equals($subcommand, 'rebase', [StringComparison]::Ordinal) -and
            (Test-GitArgumentPresent -Arguments $arguments -Names @('--show-current-patch'))) { return $false }
        return $true
    }

    return $false
}

function Get-PowerShellLiteralVariableMap {
    param([string]$CommandText)

    $values = @{}
    if ([string]::IsNullOrWhiteSpace($CommandText)) { return $values }

    try {
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($CommandText, [ref]$tokens, [ref]$parseErrors)
        foreach ($assignment in @($ast.FindAll(
            { param($candidate) $candidate -is [System.Management.Automation.Language.AssignmentStatementAst] },
            $true
        ))) {
            if ($assignment.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) { continue }
            if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }

            $name = [string]$assignment.Left.VariablePath.UserPath
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $value = $null
            if ($assignment.Right -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $value = [string]$assignment.Right.Value
            }
            elseif ($assignment.Right -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and @($assignment.Right.NestedExpressions).Count -eq 0) {
                $value = [string]$assignment.Right.Value
            }
            elseif ($assignment.Right -is [System.Management.Automation.Language.ConstantExpressionAst]) {
                $value = [string]$assignment.Right.Value
            }

            # Windows PowerShell may wrap a literal RHS in a pipeline/command
            # expression. Accept only a standalone quoted literal; never evaluate
            # arbitrary expressions while resolving rename paths.
            if ($null -eq $value) {
                $rightText = ([string]$assignment.Right.Extent.Text).Trim()
                $literalMatch = [Regex]::Match($rightText, '^(?<quote>[''"])(?<value>.*)\k<quote>$')
                if ($literalMatch.Success) {
                    $candidate = [string]$literalMatch.Groups['value'].Value
                    if (-not ($literalMatch.Groups['quote'].Value -eq '"' -and $candidate.Contains('$'))) {
                        $value = $candidate
                    }
                }
            }

            if ($null -ne $value) {
                $values[$name.ToLowerInvariant()] = [string]$value
            }
        }
    }
    catch { }

    return $values
}

function Resolve-CommandLiteralValue {
    param(
        [string]$RawValue,
        [hashtable]$Variables
    )

    $value = ConvertTo-PlainCommandToken -Value $RawValue
    if ([string]::IsNullOrWhiteSpace($value)) { return '' }

    $match = [Regex]::Match($value, '^\$\{?(?<name>[A-Za-z_][A-Za-z0-9_]*)\}?$')
    if ($match.Success) {
        $name = $match.Groups['name'].Value.ToLowerInvariant()
        if ($Variables.ContainsKey($name)) {
            return [string]$Variables[$name]
        }
        return ''
    }

    return $value
}

function Get-ShellMoveFileOperations {
    param(
        [object]$ToolInput,
        [string]$Cwd
    )

    $operations = [System.Collections.Generic.List[object]]::new()
    $commandText = Get-ToolInputCommandText -ToolInput $ToolInput
    if ([string]::IsNullOrWhiteSpace($commandText)) { return @($operations) }

    $variables = Get-PowerShellLiteralVariableMap -CommandText $commandText
    $parsed = Get-PowerShellCommandAsts -CommandText $commandText
    foreach ($commandAst in @($parsed.Commands)) {
        $commandName = [string]$commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
        try { $commandName = [IO.Path]::GetFileName($commandName.Replace('/', '\')) } catch { }
        $commandName = $commandName.ToLowerInvariant()

        $isMove = @('move-item', 'move', 'mv', 'mi') -contains $commandName
        $isRename = @('rename-item', 'rename', 'ren', 'rni') -contains $commandName
        if (-not $isMove -and -not $isRename) { continue }
        if (@($commandAst.CommandElements | Where-Object { $_.Extent.Text -match '(?i)^-(?:whatif|wi)(?::\$?true)?$' }).Count -gt 0) { continue }

        $sourceRaw = ''
        $targetRaw = ''
        $pending = ''
        $positionals = [System.Collections.Generic.List[string]]::new()
        $elements = @($commandAst.CommandElements)
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $raw = [string]$elements[$index].Extent.Text
            $token = ConvertTo-PlainCommandToken -Value $raw
            if ([string]::IsNullOrWhiteSpace($token)) { continue }
            $lower = $token.ToLowerInvariant()

            if (-not [string]::IsNullOrWhiteSpace($pending)) {
                if ([string]::Equals($pending, 'source', [StringComparison]::Ordinal)) { $sourceRaw = $raw }
                else { $targetRaw = $raw }
                $pending = ''
                continue
            }

            if (@('-path', '-literalpath') -contains $lower) { $pending = 'source'; continue }
            if ($isMove -and [string]::Equals($lower, '-destination', [StringComparison]::Ordinal)) { $pending = 'target'; continue }
            if ($isRename -and [string]::Equals($lower, '-newname', [StringComparison]::Ordinal)) { $pending = 'target'; continue }
            if ($token.StartsWith('-', [StringComparison]::Ordinal)) { continue }
            $positionals.Add($raw)
        }

        if ([string]::IsNullOrWhiteSpace($sourceRaw) -and $positionals.Count -gt 0) { $sourceRaw = [string]$positionals[0] }
        if ([string]::IsNullOrWhiteSpace($targetRaw) -and $positionals.Count -gt 1) { $targetRaw = [string]$positionals[1] }

        $sourcePath = Resolve-CommandLiteralValue -RawValue $sourceRaw -Variables $variables
        $targetPath = Resolve-CommandLiteralValue -RawValue $targetRaw -Variables $variables
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($targetPath)) { continue }

        if ($isRename -and -not [IO.Path]::IsPathRooted($targetPath)) {
            try {
                $sourceFullPath = if ([IO.Path]::IsPathRooted($sourcePath)) { [IO.Path]::GetFullPath($sourcePath) } elseif (-not [string]::IsNullOrWhiteSpace($Cwd)) { [IO.Path]::GetFullPath((Join-Path $Cwd $sourcePath)) } else { $sourcePath }
                $sourceParent = Split-Path -Parent $sourceFullPath
                if (-not [string]::IsNullOrWhiteSpace($sourceParent)) { $targetPath = Join-Path $sourceParent $targetPath }
            }
            catch { }
        }
        elseif ($isMove) {
            try {
                $targetCandidate = if ([IO.Path]::IsPathRooted($targetPath)) { $targetPath } elseif (-not [string]::IsNullOrWhiteSpace($Cwd)) { Join-Path $Cwd $targetPath } else { $targetPath }
                if (Test-Path -LiteralPath $targetCandidate -PathType Container) {
                    $targetPath = Join-Path $targetCandidate ([IO.Path]::GetFileName($sourcePath))
                }
            }
            catch { }
        }

        $sourceId = Get-FileIdentityHash -PathValue $sourcePath -Cwd $Cwd
        $targetId = Get-FileIdentityHash -PathValue $targetPath -Cwd $Cwd
        if ([string]::IsNullOrWhiteSpace($sourceId) -or [string]::IsNullOrWhiteSpace($targetId) -or
            [string]::Equals($sourceId, $targetId, [StringComparison]::Ordinal)) { continue }

        $operations.Add([PSCustomObject][ordered]@{
            kind = 'renamed'
            sourceId = $sourceId
            targetId = $targetId
            source = 'shell-move'
        })
    }

    return @($operations)
}

function Limit-SafeCommandText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $maxChars = [int](Get-ConfigValue -Config $config -Path @('commandLogging', 'maxCommandChars') -Default 4096)
    if ($maxChars -lt 128) {
        $maxChars = 128
    }
    if ($Text.Length -le $maxChars) {
        return $Text
    }

    return $Text.Substring(0, $maxChars) + '…<已截断>'
}

function ConvertTo-SafeGenericToken {
    param(
        [object]$Value,
        [string]$Cwd,
        [switch]$PathExpected
    )

    $text = ConvertTo-PlainCommandToken -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return '<内容已隐藏>'
    }
    if ($PathExpected -or (Test-IsPathLikeCommandToken -Text $text)) {
        return ConvertTo-SafeWorkspacePath -Value $text -Cwd $Cwd
    }
    if ($text.StartsWith('$', [StringComparison]::Ordinal)) {
        return '<变量>'
    }
    if (Test-IsRemoteAddressToken -Text $text) {
        return '<远程地址已隐藏>'
    }
    if (Test-ContainsSensitiveCommandValue -Text $text) {
        return '<敏感信息已隐藏>'
    }
    if ($text.Length -gt 128) {
        return '<内容已隐藏>'
    }
    if ([Regex]::IsMatch($text, '^[A-Za-z0-9._~^:/+\-=,*\[\]]+$')) {
        return $text
    }

    return '<内容已隐藏>'
}

function ConvertTo-SafeGitCommandAst {
    param(
        [object]$CommandAst,
        [string]$Cwd
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('git')
    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -le 1) {
        return 'git'
    }

    $subcommand = ''
    $redactNext = $false
    $pathNext = $false
    $configNonOptionCount = 0

    for ($index = 1; $index -lt $elements.Count; $index++) {
        $raw = [string]$elements[$index].Extent.Text
        $token = ConvertTo-PlainCommandToken -Value $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($redactNext) {
            $parts.Add('<内容已隐藏>')
            $redactNext = $false
            continue
        }
        if ($pathNext) {
            $parts.Add((ConvertTo-SafeWorkspacePath -Value $token -Cwd $Cwd))
            $pathNext = $false
            continue
        }

        $lower = $token.ToLowerInvariant()
        if (@('-c', '-C', '--git-dir', '--work-tree') -contains $token) {
            $parts.Add($token)
            if ([string]::Equals($token, '-c', [StringComparison]::Ordinal)) {
                $redactNext = $true
            }
            else {
                $pathNext = $true
            }
            continue
        }

        if ($lower -match '^--(?:git-dir|work-tree)=') {
            $namePart = $token.Substring(0, $token.IndexOf('=') + 1)
            $valuePart = $token.Substring($token.IndexOf('=') + 1)
            $parts.Add($namePart + (ConvertTo-SafeWorkspacePath -Value $valuePart -Cwd $Cwd))
            continue
        }
        if ($lower -match '^--(?:message|author|date|cleanup|gpg-sign)=') {
            $namePart = $token.Substring(0, $token.IndexOf('=') + 1)
            $parts.Add($namePart + '<内容已隐藏>')
            continue
        }
        if ($lower -match '^(?:--password|--token|--api-key)=') {
            $namePart = $token.Substring(0, $token.IndexOf('=') + 1)
            $parts.Add($namePart + '<敏感信息已隐藏>')
            continue
        }
        if (@('-m', '--message', '--author', '--date', '--trailer', '--format', '--pretty', '--grep', '--grep-reflog', '-g', '-s', '--exec') -contains $lower -or $token -cmatch '^-[a-ln-zA-Z]+m$') {
            $parts.Add($token)
            $redactNext = $true
            continue
        }
        if ($token -cmatch '^-(?<flags>[a-zA-Z]*?m).+') {
            $parts.Add('-' + $Matches['flags'] + '<内容已隐藏>')
            continue
        }

        if ([string]::IsNullOrWhiteSpace($subcommand) -and -not $token.StartsWith('-', [StringComparison]::Ordinal)) {
            $subcommand = $lower
            $parts.Add((ConvertTo-SafeGenericToken -Value $token -Cwd $Cwd))
            continue
        }

        if ([string]::Equals($subcommand, 'config', [StringComparison]::Ordinal)) {
            if ($token.StartsWith('-', [StringComparison]::Ordinal)) {
                $parts.Add($token)
                continue
            }

            $configNonOptionCount++
            if ($configNonOptionCount -eq 1) {
                $parts.Add((ConvertTo-SafeGenericToken -Value $token -Cwd $Cwd))
            }
            else {
                $parts.Add('<敏感信息已隐藏>')
            }
            continue
        }

        if (Test-IsRemoteAddressToken -Text $token) {
            $parts.Add('<远程地址已隐藏>')
            continue
        }
        if (Test-ContainsSensitiveCommandValue -Text $token) {
            $parts.Add('<敏感信息已隐藏>')
            continue
        }
        if ($token.StartsWith('--', [StringComparison]::Ordinal) -and $token.Contains('=')) {
            $optionName = $token.Substring(0, $token.IndexOf('=') + 1)
            $parts.Add($optionName + '<内容已隐藏>')
            continue
        }
        if ($token.StartsWith('-', [StringComparison]::Ordinal)) {
            # Unknown compact short options may contain a message or credential.
            if ($token -match '^-[^-].{1,}' -and $token -cnotmatch '^-[a-zA-Z]{1,3}$') { $parts.Add('<参数已隐藏>') }
            else { $parts.Add($token) }
            continue
        }

        $parts.Add((ConvertTo-SafeGenericToken -Value $token -Cwd $Cwd))
    }

    return Limit-SafeCommandText -Text ($parts -join ' ')
}

function ConvertTo-SafeShellCommandAst {
    param(
        [object]$CommandAst,
        [string]$Cwd
    )

    $commandName = [string]$CommandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($commandName)) {
        return '<命令内容已隐藏：无法安全解析>'
    }

    try {
        $safeCommandName = [IO.Path]::GetFileName((ConvertTo-PlainCommandToken -Value $commandName).Replace('/', '\'))
    }
    catch {
        $safeCommandName = ConvertTo-PlainCommandToken -Value $commandName
    }
    $safeCommandName = Sanitize-DisplayName -Value $safeCommandName -Fallback '未知命令'

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add($safeCommandName)
    $elements = @($CommandAst.CommandElements)
    if ($elements.Count -le 1) {
        return $safeCommandName
    }

    $pathOptions = @(
        '-path', '-literalpath', '--path', '--file', '-file',
        '-workingdirectory', '-workdir', '--cwd', '-directory'
    )
    $sensitiveOptions = @(
        '-pattern', '--pattern', '-command', '--command', '-encodedcommand',
        '-scriptblock', '-argumentlist', '-headers', '-body', '-credential',
        '-password', '--password', '-token', '--token', '-apikey', '--api-key',
        '-uri', '--url', '-filter', '-replace', '-match', '-connectionstring',
        '--connection-string', '-u', '--user', '--username', '-value', '--value',
        '-inputobject', '-text', '-message', '--message', '-d', '-h', '-e', '-c',
        '--data', '--data-raw', '--data-binary', '--data-urlencode', '--json', '--header', '--form', '-f'
    )
    $commandLower = $safeCommandName.ToLowerInvariant()
    $safePlainSubcommands = @{
        'npm' = @('run', 'install', 'ci', 'test', 'build', 'start')
        'npm.cmd' = @('run', 'install', 'ci', 'test', 'build', 'start')
        'pnpm' = @('run', 'install', 'test', 'build', 'start')
        'pnpm.cmd' = @('run', 'install', 'test', 'build', 'start')
        'yarn' = @('run', 'install', 'test', 'build', 'start')
        'yarn.cmd' = @('run', 'install', 'test', 'build', 'start')
        'dotnet' = @('build', 'test', 'restore', 'publish', 'run')
        'docker' = @('build', 'run', 'pull', 'push', 'compose', 'ps', 'logs')
        'docker.exe' = @('build', 'run', 'pull', 'push', 'compose', 'ps', 'logs')
    }
    $pathNext = $false
    $redactNext = $false
    $plainValueCount = 0

    for ($index = 1; $index -lt $elements.Count; $index++) {
        $raw = [string]$elements[$index].Extent.Text
        $token = ConvertTo-PlainCommandToken -Value $raw
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }

        if ($redactNext) {
            $parts.Add('<内容已隐藏>')
            $redactNext = $false
            continue
        }
        if ($pathNext) {
            $parts.Add((ConvertTo-SafeWorkspacePath -Value $token -Cwd $Cwd))
            $pathNext = $false
            continue
        }

        $lower = $token.ToLowerInvariant()
        if ($pathOptions -contains $lower) {
            $parts.Add($token)
            $pathNext = $true
            continue
        }
        if ($sensitiveOptions -contains $lower) {
            $parts.Add($token)
            $redactNext = $true
            continue
        }
        if ($lower -match '^-(?:d|h|e|c|f).+' -or $lower -match '^-(?:data|header|body|command):') {
            $parts.Add('<参数已隐藏>')
            continue
        }
        if ($lower -match '^(?:-p|-u|--password=|--token=|--api-key=|--url=|--uri=).+') {
            $optionName = if ($token.Contains('=')) { $token.Substring(0, $token.IndexOf('=') + 1) } else { $token.Substring(0, [Math]::Min(2, $token.Length)) }
            $parts.Add($optionName + '<敏感信息已隐藏>')
            continue
        }
        if (Test-IsRemoteAddressToken -Text $token) {
            $parts.Add('<远程地址已隐藏>')
            continue
        }
        if (Test-ContainsSensitiveCommandValue -Text $token) {
            $parts.Add('<敏感信息已隐藏>')
            continue
        }
        if ($token.StartsWith('-', [StringComparison]::Ordinal)) {
            if ($token.Contains('=')) {
                $optionName = $token.Substring(0, $token.IndexOf('=') + 1)
                $parts.Add($optionName + '<内容已隐藏>')
            }
            else {
                # Preserve known switches, never arbitrary option-shaped text.
                if ($token -match '^--[a-zA-Z][a-zA-Z-]*$' -or
                    $token -match '^-[a-zA-Z]$' -or
                    $lower -in @('-raw', '-recurse', '-force', '-whatif', '-noprofile', '-noninteractive', '-nologo', '-all', '-short', '-literalpath', '-destination', '-newname')) { $parts.Add($token) }
                else { $parts.Add('<参数已隐藏>') }
            }
            continue
        }
        if (Test-IsPathLikeCommandToken -Text $token) {
            $parts.Add((ConvertTo-SafeWorkspacePath -Value $token -Cwd $Cwd))
            continue
        }
        if ($token.StartsWith('$', [StringComparison]::Ordinal)) {
            $parts.Add('<变量>')
            continue
        }

        $plainValueCount++
        $allowedPlain = $false
        if ($safePlainSubcommands.ContainsKey($commandLower)) {
            foreach ($allowedValue in @($safePlainSubcommands[$commandLower])) {
                if ([string]::Equals([string]$allowedValue, $lower, [StringComparison]::OrdinalIgnoreCase)) {
                    $allowedPlain = $true
                    break
                }
            }
        }
        if ($plainValueCount -eq 1 -and $allowedPlain) {
            $parts.Add($token)
        }
        else {
            # 普通参数可能包含口令、业务文本或个人信息；无法证明安全时整项隐藏。
            $parts.Add('<内容已隐藏>')
        }
    }

    return Limit-SafeCommandText -Text ($parts -join ' ')
}

function Get-FallbackGitCommandTexts {
    param(
        [string]$CommandText,
        [string]$Cwd
    )

    $results = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($CommandText)) {
        return @($results)
    }

    foreach ($segmentValue in [Regex]::Split($CommandText, '(?:\r\n|\n|\r|;|&&|\|\|)')) {
        $segment = ([string]$segmentValue).Trim()
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $match = [Regex]::Match(
            $segment,
            '(?i)^(?:&\s*)?(?:(?:[A-Za-z]:[\\/][^;"''\r\n]*[\\/])?git(?:\.exe|\.cmd)?)(?=\s|$)'
        )
        if (-not $match.Success) {
            continue
        }

        $parsed = Get-PowerShellCommandAsts -CommandText $segment
        $rendered = $false
        foreach ($commandAst in @($parsed.Commands)) {
            if (Test-IsGitCommandName -CommandName ([string]$commandAst.GetCommandName())) {
                $results.Add((ConvertTo-SafeGitCommandAst -CommandAst $commandAst -Cwd $Cwd))
                $rendered = $true
            }
        }
        if (-not $rendered) {
            $results.Add('git <参数已隐藏>')
        }
    }

    return @($results)
}

function Get-SafeCommandObservation {
    param([object]$ToolPayload)

    $empty = [PSCustomObject][ordered]@{
        category = ''
        gitInstructionCount = 0
        gitChangeCount = 0
        safeCommands = @()
        parseErrorCount = 0
    }

    if ($null -eq $ToolPayload) {
        return $empty
    }

    $toolName = [string](Get-PropertyValue -Object $ToolPayload -Name 'tool_name' -Default '')
    if (-not (Test-IsCommandExecutionTool -ToolName $toolName)) {
        return $empty
    }

    $cwd = [string](Get-PropertyValue -Object $ToolPayload -Name 'cwd' -Default '')
    $toolInput = Get-PropertyValue -Object $ToolPayload -Name 'tool_input' -Default $null
    $commandText = Get-ToolInputCommandText -ToolInput $toolInput
    $parsed = Get-PowerShellCommandAsts -CommandText $commandText

    $gitCommands = [System.Collections.Generic.List[string]]::new()
    $shellCommands = [System.Collections.Generic.List[string]]::new()
    $gitChangeCount = 0
    foreach ($commandAst in @($parsed.Commands)) {
        $commandName = [string]$commandAst.GetCommandName()
        if (Test-IsGitCommandName -CommandName $commandName) {
            $gitCommands.Add((ConvertTo-SafeGitCommandAst -CommandAst $commandAst -Cwd $cwd))
            if (Test-IsGitChangeCommandAst -CommandAst $commandAst) {
                $gitChangeCount++
            }
        }
        else {
            $shellCommands.Add((ConvertTo-SafeShellCommandAst -CommandAst $commandAst -Cwd $cwd))
        }
    }

    if ($gitCommands.Count -eq 0) {
        foreach ($fallbackCommand in @(Get-FallbackGitCommandTexts -CommandText $commandText -Cwd $cwd)) {
            $gitCommands.Add([string]$fallbackCommand)
        }
    }

    $mode = Get-CommandLoggingMode
    $includeGit = [bool](Get-ConfigValue -Config $config -Path @('commandLogging', 'includeGit') -Default $true)
    $includeShell = [bool](Get-ConfigValue -Config $config -Path @('commandLogging', 'includeShell') -Default $true)
    if ($gitCommands.Count -gt 0) {
        $safeGitCommands = @()
        if ($mode -eq 'safe' -and $includeGit) {
            $safeGitCommands = @($gitCommands)
        }
        return [PSCustomObject][ordered]@{
            category = 'git'
            gitInstructionCount = $gitCommands.Count
            gitChangeCount = $gitChangeCount
            safeCommands = @($safeGitCommands)
            parseErrorCount = [int]$parsed.ParseErrorCount
        }
    }

    if ($shellCommands.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($commandText)) {
        $shellCommands.Add('<命令内容已隐藏：无法安全解析>')
    }

    $safeShellCommands = @()
    if ($mode -eq 'safe' -and $includeShell) {
        $safeShellCommands = @($shellCommands)
    }
    return [PSCustomObject][ordered]@{
        category = 'shell'
        gitInstructionCount = 0
        gitChangeCount = 0
        safeCommands = @($safeShellCommands)
        parseErrorCount = [int]$parsed.ParseErrorCount
    }
}


function Get-ApplyPatchFileOperations {
    param(
        [object]$ToolInput,
        [string]$Cwd
    )

    $operations = [System.Collections.Generic.List[object]]::new()
    $trackingEnabled = [bool](Get-ConfigValue -Config $config -Path @('fileTracking', 'enabled') -Default $true)
    $parseEnabled = [bool](Get-ConfigValue -Config $config -Path @('fileTracking', 'parseApplyPatch') -Default $true)
    if (-not $trackingEnabled -or -not $parseEnabled) {
        return @($operations)
    }

    $commandText = Get-ToolInputCommandText -ToolInput $ToolInput
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return @($operations)
    }

    $lines = [Regex]::Split($commandText, "\r\n|\n|\r")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        $match = [Regex]::Match(
            $line,
            '^\*\*\*\s+(?<kind>Add|Delete|Update)\s+File:\s*(?<path>.+?)\s*$',
            [Text.RegularExpressions.RegexOptions]::CultureInvariant
        )
        if (-not $match.Success) {
            continue
        }

        $kind = $match.Groups['kind'].Value
        $sourceId = Get-FileIdentityHash -PathValue $match.Groups['path'].Value -Cwd $Cwd
        if ([string]::IsNullOrWhiteSpace($sourceId)) {
            continue
        }

        switch ($kind) {
            'Add' {
                $operations.Add([PSCustomObject][ordered]@{
                    kind = 'added'
                    pathId = $sourceId
                    source = 'apply_patch'
                })
            }
            'Delete' {
                $operations.Add([PSCustomObject][ordered]@{
                    kind = 'deleted'
                    pathId = $sourceId
                    source = 'apply_patch'
                })
            }
            'Update' {
                $moveMatch = $null
                if (($index + 1) -lt $lines.Count) {
                    $moveMatch = [Regex]::Match(
                        [string]$lines[$index + 1],
                        '^\*\*\*\s+Move\s+to:\s*(?<path>.+?)\s*$',
                        [Text.RegularExpressions.RegexOptions]::CultureInvariant
                    )
                }

                if ($null -ne $moveMatch -and $moveMatch.Success) {
                    $targetId = Get-FileIdentityHash -PathValue $moveMatch.Groups['path'].Value -Cwd $Cwd
                    if (-not [string]::IsNullOrWhiteSpace($targetId) -and
                        -not [string]::Equals($sourceId, $targetId, [StringComparison]::Ordinal)) {
                        $operations.Add([PSCustomObject][ordered]@{
                            kind = 'renamed'
                            sourceId = $sourceId
                            targetId = $targetId
                            source = 'apply_patch'
                        })
                    }
                    else {
                        $operations.Add([PSCustomObject][ordered]@{
                            kind = 'modified'
                            pathId = $sourceId
                            source = 'apply_patch'
                        })
                    }
                    $index++
                }
                else {
                    $operations.Add([PSCustomObject][ordered]@{
                        kind = 'modified'
                        pathId = $sourceId
                        source = 'apply_patch'
                    })
                }
            }
        }
    }

    return @($operations)
}

function Undo-FileChangeDiff {
    param([AllowEmptyString()][string]$Text, [AllowEmptyString()][string]$Diff)
    if ($Diff -eq '') { return $Text }
    $hunks = [Collections.Generic.List[object]]::new()
    $hunk = $null
    $previous = ''
    foreach ($line in ($Diff.Replace("`r`n", "`n") -split "`n")) {
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            $hunk = @{start=[int]$Matches[3]; oldCount=1; newCount=1; before=[Collections.Generic.List[string]]::new(); after=[Collections.Generic.List[string]]::new()}
            if ($Matches[2]) { $hunk.oldCount = [int]$Matches[2] }
            if ($Matches[4]) { $hunk.newCount = [int]$Matches[4] }
            $hunks.Add($hunk); $previous = ''; continue
        }
        if ($null -eq $hunk) {
            if ($line -eq '' -or $line.StartsWith('--- ') -or $line.StartsWith('+++ ')) { continue }
            throw 'unsupported-diff'
        }
        if ($line -eq '\ No newline at end of file') {
            if ($previous -eq '') { throw 'invalid-newline-marker' }
            foreach ($side in @('before','after')) {
                if (($side -eq 'before' -and $previous -eq '+') -or ($side -eq 'after' -and $previous -eq '-')) { continue }
                $last = $hunk[$side].Count - 1
                $hunk[$side][$last] = $hunk[$side][$last].TrimEnd([char]10)
            }
            $previous = ''; continue
        }
        if ($line -eq '') { continue }
        $previous = $line.Substring(0,1)
        $value = $line.Substring(1) + "`n"
        switch ($previous) {
            ' ' { $hunk.before.Add($value); $hunk.after.Add($value) }
            '-' { $hunk.before.Add($value) }
            '+' { $hunk.after.Add($value) }
            default { throw 'unsupported-diff-line' }
        }
    }
    if ($hunks.Count -eq 0) { throw 'missing-diff-hunks' }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($Text, '[^\n]*\n|[^\n]+$')) { $lines.Add($match.Value) }
    $nextStart = $lines.Count + 1
    for ($i=$hunks.Count-1; $i -ge 0; $i--) {
        $h = $hunks[$i]
        $start = if ($h.newCount -eq 0) { $h.start } else { $h.start - 1 }
        if ($h.oldCount -ne $h.before.Count -or $h.newCount -ne $h.after.Count -or $start -lt 0 -or $start+$h.newCount -gt $lines.Count -or $start+$h.newCount -gt $nextStart) { throw 'invalid-diff-range' }
        for ($j=0; $j -lt $h.newCount; $j++) {
            if (-not [string]::Equals($lines[$start+$j], $h.after[$j], [StringComparison]::Ordinal)) { throw 'diff-content-mismatch' }
        }
        $lines.RemoveRange($start,$h.newCount)
        $lines.InsertRange($start,$h.before)
        $nextStart = $start
    }
    return ($lines -join '')
}

function Read-ChangedFileContent {
    param([string]$Path)
    $stream = $null; $reader = $null
    try {
        # ponytail: only touched UTF-8 text files, at most 4 MiB each. Unsupported
        # content remains unconfirmed rather than falling back to a workspace scan.
        $stream = [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        if ($stream.Length -gt 4194304) { throw 'file-too-large' }
        $length = $stream.Length; $modified = [IO.File]::GetLastWriteTimeUtc($Path)
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true)
        $text = $reader.ReadToEnd()
        if ($text.IndexOf([char]0) -ge 0 -or $stream.Length -ne $length -or [IO.File]::GetLastWriteTimeUtc($Path) -ne $modified) { throw 'unstable-or-binary-file' }
        return @{exists=$true; text=$text.Replace("`r`n","`n"); known=$true}
    }
    catch [IO.FileNotFoundException] { return @{exists=$false; text=''; known=$true} }
    catch [IO.DirectoryNotFoundException] { return @{exists=$false; text=''; known=$true} }
    catch { return @{exists=$false; text=''; known=$false} }
    finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
}

function Get-NativeFileChangeSummary {
    param([object[]]$Changes, [string]$Cwd, [object[]]$RequiredEdits=@())
    $final = @{}; $current = @{}; $paths = @{}; $records = [Collections.Generic.List[object]]::new()
    $reasons = [Collections.Generic.List[string]]::new()
    $nativeEdits = @{}
    $watch = [Diagnostics.Stopwatch]::StartNew()
    # No raw paths, source text or diffs escape this in-memory reduction.
    foreach ($change in @($Changes)) {
        if ($null -eq $change) { continue }
        try {
            $changeCwd = [string](Get-PropertyValue -Object $change -Name 'Cwd' -Default $Cwd)
            $path = [string]$change.Path
            if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path $changeCwd $path }
            $path = [IO.Path]::GetFullPath($path)
            $id = Get-FileIdentityHash -PathValue $path -Cwd $Cwd
            $paths[$id] = $path
            $target = $id
            $move = [string](Get-PropertyValue -Object $change.Detail -Name 'move_path' -Default '')
            if ($move) {
                if (-not [IO.Path]::IsPathRooted($move)) { $move = Join-Path $changeCwd $move }
                $move = [IO.Path]::GetFullPath($move)
                $target = Get-FileIdentityHash -PathValue $move -Cwd $Cwd
                $paths[$target] = $move
            }
            $records.Add(@{id=$id; target=$target; detail=$change.Detail})
            $scope=[string](Get-PropertyValue -Object $change -Name 'Scope' -Default 'root')
            if ($scope -ne 'root') { $scope='agent:'+$scope }
            foreach ($pathId in @($id,$target)) {
                $key=$scope+"`n"+$pathId
                if (-not $nativeEdits.ContainsKey($key)) { $nativeEdits[$key]=@{} }
                $nativeEdits[$key][[string](Get-PropertyValue -Object $change -Name 'EditId' -Default $records.Count)]=$true
            }
        }
        catch { $reasons.Add('文件路径无法解析') }
    }
    $textChars = 0
    foreach ($id in $paths.Keys) {
        if ($watch.ElapsedMilliseconds -gt 2000 -or $final.Count -ge 1000 -or $textChars -gt 16777216) {
            $value = @{exists=$false; text=''; known=$false}
            if (-not $reasons.Contains('涉及文件读取超出预算')) { $reasons.Add('涉及文件读取超出预算') }
        } else { $value = Read-ChangedFileContent -Path $paths[$id] }
        $textChars += $value.text.Length
        $final[$id] = $value
        $current[$id] = $value.Clone()
    }
    foreach ($required in @($RequiredEdits)) {
        $key=$required.scope+"`n"+$required.pathId
        if (-not $nativeEdits.ContainsKey($key) -or $nativeEdits[$key].Count -lt $required.count) {
            if ($current.ContainsKey($required.pathId)) { $current[$required.pathId].known=$false }
            if (-not $reasons.Contains('存在未匹配原生记录的成功编辑')) { $reasons.Add('存在未匹配原生记录的成功编辑') }
        }
    }
    for ($i=$records.Count-1; $i -ge 0; $i--) {
        if ($watch.ElapsedMilliseconds -gt 4000) {
            $reasons.Add('补丁核验超出时间预算')
            foreach ($key in $current.Keys) { $current[$key].known=$false }
            break
        }
        $record = $records[$i]; $id=$record.id; $target=$record.target; $detail=$record.detail
        try {
            if (-not $current[$id].known -or -not $current[$target].known) { throw 'unknown-content' }
            switch ([string](Get-PropertyValue -Object $detail -Name 'type')) {
                'add' {
                    if ($null -eq $detail.PSObject.Properties['content'] -or -not $current[$id].exists -or
                        -not [string]::Equals($current[$id].text,([string]$detail.content).Replace("`r`n","`n"),[StringComparison]::Ordinal)) { throw 'add-content-mismatch' }
                    $current[$id] = @{exists=$false; text=''; known=$true}
                }
                'delete' {
                    if ($null -eq $detail.PSObject.Properties['content'] -or $current[$id].exists) { throw 'delete-content-missing' }
                    $current[$id] = @{exists=$true; text=([string]$detail.content).Replace("`r`n","`n"); known=$true}
                }
                'update' {
                    if ($null -eq $detail.PSObject.Properties['unified_diff'] -or -not $current[$target].exists -or ($target -ne $id -and $current[$id].exists)) { throw 'update-content-missing' }
                    $before = Undo-FileChangeDiff -Text $current[$target].text -Diff ([string]$detail.unified_diff)
                    $current[$id] = @{exists=$true; text=$before; known=$true}
                    if ($target -ne $id) { $current[$target] = @{exists=$false; text=''; known=$true} }
                }
                default { throw 'unknown-change-type' }
            }
        }
        catch {
            $current[$id].known=$false; $current[$target].known=$false
            if (-not $reasons.Contains('补丁或内容证据缺失、不匹配或文件不可读')) { $reasons.Add('补丁或内容证据缺失、不匹配或文件不可读') }
        }
    }
    $added=0; $modified=0; $deleted=0; $unknown=0
    foreach ($id in $paths.Keys) {
        $before=$current[$id]; $after=$final[$id]
        if (-not $before.known -or -not $after.known) { $unknown++; continue }
        if (-not $before.exists -and $after.exists) { $added++ }
        elseif ($before.exists -and -not $after.exists) { $deleted++ }
        elseif ($before.exists -and $after.exists -and -not [string]::Equals($before.text,$after.text,[StringComparison]::Ordinal)) { $modified++ }
    }
    return [pscustomobject]@{Added=$added; Modified=$modified; Deleted=$deleted; Total=($added+$modified+$deleted); Unknown=$unknown; Reasons=@($reasons); PathIds=@($paths.Keys)}
}


function Normalize-SkillName {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $name = [string]$Value
    $name = [Regex]::Replace($name, '[\r\n\t]+', '')
    $name = [Regex]::Replace($name, '[\x00-\x1F\x7F]', '')
    $name = $name.Trim()
    if ($name.StartsWith('$', [StringComparison]::Ordinal) -or
        $name.StartsWith('@', [StringComparison]::Ordinal)) {
        $name = $name.Substring(1)
    }

    if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 128) {
        return ''
    }

    if (-not [Regex]::IsMatch(
        $name,
        '^[\p{L}\p{N}][\p{L}\p{N}._:/-]{0,127}$',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )) {
        return ''
    }

    return $name.ToLowerInvariant()
}

function Add-UniqueSkillName {
    param(
        [System.Collections.Generic.List[string]]$List,
        [object]$Value
    )

    $name = Normalize-SkillName -Value $Value
    if (-not [string]::IsNullOrWhiteSpace($name) -and -not $List.Contains($name)) {
        $List.Add($name)
    }
}

function Get-SkillNameFromSkillFilePath {
    param([object]$PathValue)

    if ($null -eq $PathValue) {
        return ''
    }

    $pathText = [string]$PathValue
    $pathText = [Regex]::Replace($pathText, '[\r\n\t]+', '')
    $pathText = [Regex]::Replace($pathText, '[\x00-\x1F\x7F]', '')
    $pathText = $pathText.Trim()
    $pathText = $pathText.Trim([char[]]@(34, 39, 96))
    if ([string]::IsNullOrWhiteSpace($pathText)) {
        return ''
    }

    try {
        if ($pathText.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) {
            $uri = [Uri]$pathText
            if ($uri.IsFile) {
                $pathText = $uri.LocalPath
            }
        }
        $pathText = [Uri]::UnescapeDataString($pathText)
    }
    catch { }

    $segments = @([Regex]::Split($pathText, '[\\/]+') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($segments.Count -lt 2) {
        return ''
    }
    if (-not [string]::Equals([string]$segments[$segments.Count - 1], 'SKILL.md', [StringComparison]::OrdinalIgnoreCase)) {
        return ''
    }

    return Normalize-SkillName -Value $segments[$segments.Count - 2]
}

function ConvertTo-CommandText {
    param([object]$Value)

    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [Array]) {
        return (@($Value) | ForEach-Object { [string]$_ }) -join "`n"
    }
    return [string]$Value
}

function Get-RawCommandSkillNames {
    param([object]$CommandValue)

    $results = [System.Collections.Generic.List[string]]::new()
    $enabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'enabled') -Default $true)
    $fallbackEnabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'rawCommandFallback') -Default $true)
    if (-not $enabled -or -not $fallbackEnabled) {
        return @($results)
    }

    $commandText = ConvertTo-CommandText -Value $CommandValue
    if ([string]::IsNullOrWhiteSpace($commandText)) {
        return @($results)
    }

    $readVerbPattern = '(?i)(?:\bGet-Content\b|(?<![\p{L}\p{N}_-])(?:gc|cat|type)(?![\p{L}\p{N}_-])\s+|\bReadAllText\s*\(|\bread_file\b)'
    $pathPattern = '(?<![\p{L}\p{N}._:/-])(?<name>[\p{L}\p{N}][\p{L}\p{N}._:-]{0,127})[\\/]+SKILL\.md'

    # Associate each candidate path with the command segment that contains the
    # read operation. A single script can both read one file and write another;
    # globally matching every SKILL.md path after seeing one read verb would
    # incorrectly classify the write target as a Skill invocation.
    $segments = [Regex]::Split($commandText, '(?:\r\n|\n|\r|;|&&|\|\||\|)')
    foreach ($segmentValue in $segments) {
        $segment = [string]$segmentValue
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        if (-not [Regex]::IsMatch($segment, $readVerbPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            continue
        }

        foreach ($match in [Regex]::Matches(
            $segment,
            $pathPattern,
            ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)
        )) {
            Add-UniqueSkillName -List $results -Value $match.Groups['name'].Value
        }
    }

    return @($results)
}

function Get-ParsedCommandSkillNames {
    param([object]$ParsedCommands)

    $results = [System.Collections.Generic.List[string]]::new()
    $enabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'enabled') -Default $true)
    if (-not $enabled -or $null -eq $ParsedCommands) {
        return @($results)
    }

    foreach ($entry in @($ParsedCommands)) {
        if ($null -eq $entry) { continue }
        $typeText = ([string](Get-PropertyValue -Object $entry -Name 'type' -Default '')).Trim()
        if (-not [string]::Equals($typeText, 'read', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        foreach ($propertyName in @('path', 'file', 'source_path', 'sourcePath')) {
            $pathValue = Get-PropertyValue -Object $entry -Name $propertyName -Default $null
            foreach ($candidate in @($pathValue)) {
                $name = Get-SkillNameFromSkillFilePath -PathValue $candidate
                if (-not [string]::IsNullOrWhiteSpace($name)) {
                    Add-UniqueSkillName -List $results -Value $name
                }
            }
        }
    }

    return @($results)
}

function Test-CommandExecutionCompleted {
    param([object]$StatusValue)

    $requireCompleted = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'requireCompletedExecution') -Default $true)
    if (-not $requireCompleted) {
        return $true
    }

    $statusText = ''
    if ($null -ne $StatusValue) {
        $statusText = ([string]$StatusValue).Trim().ToLowerInvariant()
    }
    if ([string]::IsNullOrWhiteSpace($statusText)) {
        return $false
    }

    return $statusText -match '^(completed|complete|success|succeeded|ok)$'
}

function Get-TranscriptRecordTurnId {
    param([object]$Record)

    if ($null -eq $Record) { return '' }
    foreach ($fieldName in @('turn_id', 'turnId')) {
        $value = [string](Get-PropertyValue -Object $Record -Name $fieldName -Default '')
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    }

    $payloadValue = Get-PropertyValue -Object $Record -Name 'payload' -Default $null
    if ($null -ne $payloadValue) {
        foreach ($fieldName in @('turn_id', 'turnId')) {
            $value = [string](Get-PropertyValue -Object $payloadValue -Name $fieldName -Default '')
            if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
        }

        $metadataValue = Get-PropertyValue -Object $payloadValue -Name 'internal_chat_message_metadata_passthrough' -Default $null
        if ($null -ne $metadataValue) {
            foreach ($fieldName in @('turn_id', 'turnId')) {
                $value = [string](Get-PropertyValue -Object $metadataValue -Name $fieldName -Default '')
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
        }

        $itemValue = Get-PropertyValue -Object $payloadValue -Name 'item' -Default $null
        if ($null -ne $itemValue) {
            foreach ($fieldName in @('turn_id', 'turnId')) {
                $value = [string](Get-PropertyValue -Object $itemValue -Name $fieldName -Default '')
                if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
        }
    }

    return ''
}

function Test-TranscriptRecordBelongsToTurn {
    param(
        [object]$Record,
        [string]$ExpectedTurnId
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedTurnId)) {
        return $true
    }
    $recordTurnId = Get-TranscriptRecordTurnId -Record $Record
    if ([string]::IsNullOrWhiteSpace($recordTurnId)) {
        return $false
    }
    return [string]::Equals($recordTurnId, $ExpectedTurnId, [StringComparison]::Ordinal)
}

function Get-CommandReadSkillNamesFromTranscriptObject {
    param(
        [object]$Record,
        [string]$ExpectedTurnId = ''
    )

    $results = [System.Collections.Generic.List[string]]::new()
    $enabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'enabled') -Default $true)
    if (-not $enabled -or $null -eq $Record) {
        return @($results)
    }
    if (-not (Test-TranscriptRecordBelongsToTurn -Record $Record -ExpectedTurnId $ExpectedTurnId)) {
        return @($results)
    }

    $topType = ([string](Get-PropertyValue -Object $Record -Name 'type' -Default '')).Trim()
    $payloadValue = Get-PropertyValue -Object $Record -Name 'payload' -Default $null

    if ([string]::Equals($topType, 'event_msg', [StringComparison]::OrdinalIgnoreCase)) {
        $payloadType = ([string](Get-PropertyValue -Object $payloadValue -Name 'type' -Default '')).Trim()
        if (-not [string]::Equals($payloadType, 'item_completed', [StringComparison]::OrdinalIgnoreCase)) {
            return @($results)
        }

        $itemValue = Get-PropertyValue -Object $payloadValue -Name 'item' -Default $null
        $itemType = ([string](Get-PropertyValue -Object $itemValue -Name 'type' -Default '')).Trim()
        if (-not [string]::Equals($itemType, 'CommandExecution', [StringComparison]::OrdinalIgnoreCase)) {
            return @($results)
        }
        if (-not (Test-CommandExecutionCompleted -StatusValue (Get-PropertyValue -Object $itemValue -Name 'status' -Default $null))) {
            return @($results)
        }

        $parsedNames = @(Get-ParsedCommandSkillNames -ParsedCommands (Get-PropertyValue -Object $itemValue -Name 'parsed_cmd' -Default $null))
        foreach ($name in $parsedNames) {
            Add-UniqueSkillName -List $results -Value $name
        }

        $preferParsed = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'preferParsedCommand') -Default $true)
        if ($parsedNames.Count -eq 0 -or -not $preferParsed) {
            foreach ($name in @(Get-RawCommandSkillNames -CommandValue (Get-PropertyValue -Object $itemValue -Name 'command' -Default $null))) {
                Add-UniqueSkillName -List $results -Value $name
            }
        }
        return @($results)
    }

    # Some desktop/runtime builds persist a completed command call as a
    # response_item custom_tool_call but omit CommandExecution.parsed_cmd. Treat
    # its completed status and command-execution tool name as a bounded fallback.
    # The complete input is used only in memory and is never written to state or
    # logs. A later CommandExecution record for the same Skill is deduplicated by
    # scope + normalized Skill name.
    if ([string]::Equals($topType, 'response_item', [StringComparison]::OrdinalIgnoreCase)) {
        $payloadType = ([string](Get-PropertyValue -Object $payloadValue -Name 'type' -Default '')).Trim()
        if (-not [string]::Equals($payloadType, 'custom_tool_call', [StringComparison]::OrdinalIgnoreCase)) {
            return @($results)
        }
        $toolName = [string](Get-PropertyValue -Object $payloadValue -Name 'name' -Default '')
        if (-not (Test-IsCommandExecutionTool -ToolName $toolName)) {
            return @($results)
        }
        if (-not (Test-CommandExecutionCompleted -StatusValue (Get-PropertyValue -Object $payloadValue -Name 'status' -Default $null))) {
            return @($results)
        }

        $commandText = Get-ToolInputCommandText -ToolInput (Get-PropertyValue -Object $payloadValue -Name 'input' -Default $null)
        foreach ($name in @(Get-RawCommandSkillNames -CommandValue $commandText)) {
            Add-UniqueSkillName -List $results -Value $name
        }
    }

    return @($results)
}

function Get-CommandReadSkillNamesFromToolPayload {
    param([object]$ToolPayload)

    $results = [System.Collections.Generic.List[string]]::new()
    $enabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'commandRead', 'enabled') -Default $true)
    if (-not $enabled -or $null -eq $ToolPayload) {
        return @($results)
    }

    $toolName = [string](Get-PropertyValue -Object $ToolPayload -Name 'tool_name' -Default '')
    if (-not (Test-IsCommandExecutionTool -ToolName $toolName)) {
        return @($results)
    }

    $toolInput = Get-PropertyValue -Object $ToolPayload -Name 'tool_input' -Default $null
    $commandText = Get-ToolInputCommandText -ToolInput $toolInput
    foreach ($name in @(Get-RawCommandSkillNames -CommandValue $commandText)) {
        Add-UniqueSkillName -List $results -Value $name
    }
    return @($results)
}

function Get-ExplicitSkillNames {
    param([object]$PromptValue)

    $results = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $PromptValue) {
        return @($results)
    }

    $prompt = [string]$PromptValue
    if ([string]::IsNullOrWhiteSpace($prompt)) {
        return @($results)
    }

    $markers = Get-ConfigValue -Config $config -Path @('skillCollection', 'explicitMarkers') -Default @('$')
    foreach ($markerValue in @($markers)) {
        $marker = [string]$markerValue
        if ([string]::IsNullOrWhiteSpace($marker)) {
            continue
        }

        # @ mentions are intentionally not inferred from plain prompt text. They
        # are accepted only when structured input or transcript evidence confirms
        # an actual Skill. This avoids classifying people, companies, and emails.
        if ([string]::Equals($marker, '@', [StringComparison]::Ordinal)) {
            continue
        }

        $pattern = '(?<![\p{L}\p{N}_])' + [Regex]::Escape($marker) + '(?<name>[\p{L}\p{N}][\p{L}\p{N}._:/-]{0,127})(?![\p{L}\p{N}._:/-])'
        foreach ($match in [Regex]::Matches($prompt, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
            Add-UniqueSkillName -List $results -Value $match.Groups['name'].Value
        }
    }

    return @($results)
}

function Get-StructuredSkillNames {
    param(
        [object]$Value,
        [switch]$Strict
    )

    $results = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        return @($results)
    }

    $maxNodes = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'maxStructuredNodes') -Default 2000)
    if ($maxNodes -lt 50) { $maxNodes = 50 }
    if ($maxNodes -gt 20000) { $maxNodes = 20000 }

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([PSCustomObject]@{ Node = $Value; Depth = 0; SkillContext = $false })
    $visited = 0

    while ($stack.Count -gt 0 -and $visited -lt $maxNodes) {
        $entry = $stack.Pop()
        $node = $entry.Node
        $depth = [int]$entry.Depth
        $skillContext = [bool]$entry.SkillContext
        $visited++

        if ($null -eq $node -or $depth -gt 10) {
            continue
        }

        if ($node -is [string]) {
            if ($skillContext) {
                Add-UniqueSkillName -List $results -Value $node
            }
            continue
        }

        if ($node -is [System.Collections.IDictionary]) {
            $propertyMap = @{}
            foreach ($key in $node.Keys) {
                $propertyMap[[string]$key] = $node[$key]
            }
        }
        elseif ($node -is [PSCustomObject]) {
            $propertyMap = @{}
            foreach ($property in $node.PSObject.Properties) {
                $propertyMap[$property.Name] = $property.Value
            }
        }
        elseif ($node -is [System.Collections.IEnumerable]) {
            $items = @($node)
            for ($index = $items.Count - 1; $index -ge 0; $index--) {
                $stack.Push([PSCustomObject]@{ Node = $items[$index]; Depth = ($depth + 1); SkillContext = $skillContext })
            }
            continue
        }
        else {
            continue
        }

        $typeText = ''
        foreach ($typeField in @('type', 'kind', 'input_type', 'inputType', 'item_type', 'itemType')) {
            if ($propertyMap.ContainsKey($typeField) -and $null -ne $propertyMap[$typeField]) {
                $typeText = ([string]$propertyMap[$typeField]).Trim().ToLowerInvariant()
                if (-not [string]::IsNullOrWhiteSpace($typeText)) { break }
            }
        }
        $typedSkill = [Regex]::IsMatch(
            $typeText,
            '^(skill|skill[_-](input|mention|selection|reference|invocation|injection|use)|selected[_-]skill|injected[_-]skill|agent[_-]skill)$'
        )
        $objectSkillContext = $skillContext -or $typedSkill

        foreach ($propertyName in @($propertyMap.Keys)) {
            $child = $propertyMap[$propertyName]
            $lowerName = ([string]$propertyName).ToLowerInvariant()

            switch -Regex ($lowerName) {
                '^(name)$' {
                    if ($objectSkillContext) {
                        Add-UniqueSkillName -List $results -Value $child
                    }
                    continue
                }
                '^(skill_name|skillname)$' {
                    Add-UniqueSkillName -List $results -Value $child
                    continue
                }
                '^(skill|selected_skill|selectedskill|mentioned_skill|mentionedskill|injected_skill|injectedskill|skill_input|skillinput)$' {
                    if ($child -is [string]) {
                        Add-UniqueSkillName -List $results -Value $child
                    }
                    else {
                        $stack.Push([PSCustomObject]@{ Node = $child; Depth = ($depth + 1); SkillContext = $true })
                    }
                    continue
                }
                '^(selected_skills|selectedskills|mentioned_skills|mentionedskills|injected_skills|injectedskills|skill_inputs|skillinputs)$' {
                    $stack.Push([PSCustomObject]@{ Node = $child; Depth = ($depth + 1); SkillContext = $true })
                    continue
                }
                '^(available_skills|availableskills|skills_instructions|skillsinstructions|skill_catalog|skillcatalog|available_skill_catalog|availableskillcatalog)$' {
                    # Available-Skill catalogs describe routing options. They are
                    # not evidence that a Skill was selected or injected.
                    continue
                }
                '^(skills)$' {
                    if (-not $Strict -or $objectSkillContext) {
                        $stack.Push([PSCustomObject]@{ Node = $child; Depth = ($depth + 1); SkillContext = $true })
                    }
                    # In strict mode, a generic top-level `skills` collection is
                    # treated as an available catalog. Confirmed structured input
                    # must carry a Skill-specific type or property name.
                    continue
                }
                default {
                    if ($null -ne $child -and $child -isnot [string]) {
                        $stack.Push([PSCustomObject]@{ Node = $child; Depth = ($depth + 1); SkillContext = $false })
                    }
                }
            }
        }
    }

    return @($results)
}

function Get-StringValuesForSkillScan {
    param([object]$Value)

    $results = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Value) {
        return @($results)
    }

    $maxNodes = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'maxStructuredNodes') -Default 2000)
    if ($maxNodes -lt 50) { $maxNodes = 50 }
    if ($maxNodes -gt 20000) { $maxNodes = 20000 }

    $stack = [System.Collections.Generic.Stack[object]]::new()
    $stack.Push([PSCustomObject]@{ Node = $Value; Depth = 0 })
    $visited = 0

    while ($stack.Count -gt 0 -and $visited -lt $maxNodes) {
        $entry = $stack.Pop()
        $node = $entry.Node
        $depth = [int]$entry.Depth
        $visited++

        if ($null -eq $node -or $depth -gt 10) {
            continue
        }

        if ($node -is [string]) {
            $textValue = [string]$node
            if ($textValue.IndexOf('<skill', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $results.Add($textValue)
            }
            continue
        }

        if ($node -is [System.Collections.IDictionary]) {
            foreach ($key in $node.Keys) {
                $stack.Push([PSCustomObject]@{ Node = $node[$key]; Depth = ($depth + 1) })
            }
            continue
        }

        if ($node -is [PSCustomObject]) {
            foreach ($property in $node.PSObject.Properties) {
                $stack.Push([PSCustomObject]@{ Node = $property.Value; Depth = ($depth + 1) })
            }
            continue
        }

        if ($node -is [System.Collections.IEnumerable]) {
            foreach ($item in @($node)) {
                $stack.Push([PSCustomObject]@{ Node = $item; Depth = ($depth + 1) })
            }
        }
    }

    return @($results)
}

function Get-XmlSkillNamesFromText {
    param([string]$Text)

    $results = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @($results)
    }

    $requirePath = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'requireSkillPathInXml') -Default $true)
    $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::Singleline -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant

    # The session bootstrap can contain an available-Skill catalog. It is routing
    # metadata, not evidence that any Skill was actually injected for this Turn.
    # Remove known catalog containers before matching concrete <skill> payloads.
    $scanText = [Regex]::Replace($Text, '<skills_instructions\b[^>]*>.*?</skills_instructions>', '', $options)
    $scanText = [Regex]::Replace($scanText, '<available_skills\b[^>]*>.*?</available_skills>', '', $options)

    foreach ($match in [Regex]::Matches($scanText, '<skill\b(?<attrs>[^>]*)>(?<body>.*?)</skill>', $options)) {
        $body = $match.Groups['body'].Value
        $attributeText = $match.Groups['attrs'].Value
        $hasSkillPath = [Regex]::IsMatch($body, '<path\b[^>]*>.*?SKILL\.md\s*</path>', $options) -or
            [Regex]::IsMatch($attributeText, '\bpath\s*=\s*["''].*?SKILL\.md.*?["'']', $options)
        if ($requirePath -and -not $hasSkillPath) {
            continue
        }

        $nameText = ''
        $nameMatch = [Regex]::Match($body, '<name\b[^>]*>(?<name>.*?)</name>', $options)
        if ($nameMatch.Success) {
            $nameText = $nameMatch.Groups['name'].Value
        }
        else {
            $attributeMatch = [Regex]::Match($match.Groups['attrs'].Value, '\bname\s*=\s*["''](?<name>[^"'']+)["'']', $options)
            if ($attributeMatch.Success) {
                $nameText = $attributeMatch.Groups['name'].Value
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($nameText)) {
            try { $nameText = [Net.WebUtility]::HtmlDecode($nameText) } catch { }
            Add-UniqueSkillName -List $results -Value $nameText
        }
    }

    return @($results)
}

function Get-TranscriptBaselineMetadata {
    param([object]$PathValue)

    $pathText = ''
    if ($null -ne $PathValue) {
        $pathText = ([string]$PathValue).Trim()
    }
    $identityHash = Get-FileIdentityHash -PathValue $pathText -Cwd ''

    $available = $false
    [Int64]$length = 0
    if (-not [string]::IsNullOrWhiteSpace($pathText)) {
        try {
            if (Test-Path -LiteralPath $pathText -PathType Leaf) {
                $item = Get-Item -LiteralPath $pathText
                $length = [Int64]$item.Length
                $available = $true
            }
        }
        catch { }
    }

    return [PSCustomObject]@{
        IdentityHash = $identityHash
        BaselineBytes = $length
        Available = $available
    }
}

function Wait-ForTranscriptSettle {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }

    $initialMs = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'settleInitialMs') -Default 100)
    $quietMs = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'settleQuietMs') -Default 100)
    $maxMs = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'settleMaxMs') -Default 600)
    if ($initialMs -gt 0) { Start-Sleep -Milliseconds $initialMs }
    if ($maxMs -le 0) { return }

    $started = [DateTime]::UtcNow
    $stableSince = [DateTime]::UtcNow
    $lastSignature = ''
    while (([DateTime]::UtcNow - $started).TotalMilliseconds -lt $maxMs) {
        $signature = 'missing'
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                $item = Get-Item -LiteralPath $Path
                $signature = $item.Length.ToString() + ':' + $item.LastWriteTimeUtc.Ticks.ToString()
            }
        }
        catch { }

        if ($signature -ne $lastSignature) {
            $lastSignature = $signature
            $stableSince = [DateTime]::UtcNow
        }
        elseif (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge $quietMs) {
            break
        }
        Start-Sleep -Milliseconds 25
    }
}

function Read-TranscriptSlice {
    param(
        [string]$Path,
        [Int64]$StartOffset,
        [Int64]$EndOffset = -1
    )

    $maxBytes = [Int64](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'maxBytes') -Default 4194304)
    if ($maxBytes -lt 65536) { $maxBytes = 65536 }
    if ($maxBytes -gt 33554432) { $maxBytes = 33554432 }

    $stream = $null
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        [Int64]$length = $stream.Length
        [Int64]$actualStart = [Math]::Max(0, $StartOffset)
        [Int64]$actualEnd = $length
        if ($EndOffset -ge 0) {
            $actualEnd = [Math]::Min($length, [Math]::Max(0, $EndOffset))
        }

        $rewritten = $false
        if ($actualStart -gt $length) {
            $actualStart = 0
            $actualEnd = $length
            $rewritten = $true
        }
        if ($actualStart -gt $actualEnd) {
            $actualStart = $actualEnd
        }

        $skipPartialFirstLine = $false
        if ($actualStart -gt 0) {
            $null = $stream.Seek($actualStart - 1, [IO.SeekOrigin]::Begin)
            $previousByte = $stream.ReadByte()
            if ($previousByte -ne 10 -and $previousByte -ne 13) {
                $skipPartialFirstLine = $true
            }
        }

        $null = $stream.Seek($actualStart, [IO.SeekOrigin]::Begin)
        [Int64]$remaining = [Math]::Max(0, $actualEnd - $actualStart)
        [int]$readLength = [int][Math]::Min($remaining, $maxBytes)
        [byte[]]$buffer = [byte[]]::new($readLength)
        $totalRead = 0
        while ($totalRead -lt $readLength) {
            $read = $stream.Read($buffer, $totalRead, $readLength - $totalRead)
            if ($read -le 0) { break }
            $totalRead += $read
        }

        $text = ''
        if ($totalRead -gt 0) {
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $totalRead)
        }
        if ($skipPartialFirstLine -and -not [string]::IsNullOrEmpty($text)) {
            $newlineIndex = $text.IndexOf("`n", [StringComparison]::Ordinal)
            if ($newlineIndex -ge 0) {
                $text = $text.Substring($newlineIndex + 1)
            }
            else {
                $text = ''
            }
        }

        # When reading a bounded lookback range or a max-size slice, do not
        # parse an incomplete trailing JSONL record.
        [Int64]$readEnd = $actualStart + $totalRead
        if ($readEnd -lt $length -and -not [string]::IsNullOrEmpty($text)) {
            $lastReadByte = if ($totalRead -gt 0) { [int]$buffer[$totalRead - 1] } else { -1 }
            if ($lastReadByte -ne 10 -and $lastReadByte -ne 13) {
                $lastNewlineIndex = $text.LastIndexOf("`n", [StringComparison]::Ordinal)
                if ($lastNewlineIndex -ge 0) {
                    $text = $text.Substring(0, $lastNewlineIndex + 1)
                }
                else {
                    $text = ''
                }
            }
        }

        return [PSCustomObject]@{
            Text = $text
            BytesRead = $totalRead
            Truncated = ($remaining -gt $maxBytes)
            Rewritten = $rewritten
            StartOffset = $actualStart
            EndOffset = $readEnd
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Parse-TranscriptSkillSlice {
    param(
        [string]$Text,
        [string]$ExpectedTurnId = '',
        [switch]$RequireTurnMatch
    )

    $skills = [System.Collections.Generic.List[string]]::new()
    $commandReadSkills = [System.Collections.Generic.List[string]]::new()
    $linesParsed = 0
    $parseErrors = 0
    $maxLines = [int](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'maxLines') -Default 10000)
    if ($maxLines -lt 100) { $maxLines = 100 }
    if ($maxLines -gt 100000) { $maxLines = 100000 }

    $lines = [Regex]::Split([string]$Text, '\r?\n')
    $lineLimit = [Math]::Min($lines.Count, $maxLines)
    for ($index = 0; $index -lt $lineLimit; $index++) {
        $line = [string]$lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $linesParsed++

        $jsonObject = $null
        $jsonParsed = $false
        $recordAccepted = -not $RequireTurnMatch
        try {
            $jsonObject = $line | ConvertFrom-Json
            $jsonParsed = $true
            if ($RequireTurnMatch) {
                $recordAccepted = Test-TranscriptRecordBelongsToTurn -Record $jsonObject -ExpectedTurnId $ExpectedTurnId
            }

            if ($recordAccepted) {
                foreach ($name in @(Get-StructuredSkillNames -Value $jsonObject -Strict)) {
                    Add-UniqueSkillName -List $skills -Value $name
                }
                $turnIdForCommandRead = ''
                if ($RequireTurnMatch) { $turnIdForCommandRead = $ExpectedTurnId }
                foreach ($name in @(Get-CommandReadSkillNamesFromTranscriptObject -Record $jsonObject -ExpectedTurnId $turnIdForCommandRead)) {
                    Add-UniqueSkillName -List $commandReadSkills -Value $name
                }
                foreach ($textValue in @(Get-StringValuesForSkillScan -Value $jsonObject)) {
                    foreach ($name in @(Get-XmlSkillNamesFromText -Text ([string]$textValue))) {
                        Add-UniqueSkillName -List $skills -Value $name
                    }
                }
            }
        }
        catch {
            $parseErrors++
        }

        if (-not $RequireTurnMatch -or ($jsonParsed -and $recordAccepted)) {
            foreach ($name in @(Get-XmlSkillNamesFromText -Text $line)) {
                Add-UniqueSkillName -List $skills -Value $name
            }
        }
    }

    return [PSCustomObject][ordered]@{
        SkillNames = @($skills)
        CommandReadSkillNames = @($commandReadSkills)
        LinesParsed = $linesParsed
        ParseErrors = $parseErrors
    }
}

function Get-TranscriptSkillObservation {
    param(
        [object]$PathValue,
        [Int64]$BaselineBytes,
        [string]$ExpectedIdentityHash,
        [string]$Source,
        [string]$ExpectedTurnId = ''
    )

    $result = [ordered]@{
        SkillNames = @()
        CommandReadSkillNames = @()
        Source = $Source
        Status = '不可用'
        ReadSucceeded = $false
        Truncated = $false
        LookbackUsed = $false
        BytesRead = 0
        LinesParsed = 0
        ParseErrors = 0
    }

    $enabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'enabled') -Default $true)
    if (-not $enabled) {
        $result.Status = '已关闭'
        return [PSCustomObject]$result
    }

    $pathText = ''
    if ($null -ne $PathValue) { $pathText = ([string]$PathValue).Trim() }
    if ([string]::IsNullOrWhiteSpace($pathText)) {
        return [PSCustomObject]$result
    }

    $identityHash = Get-FileIdentityHash -PathValue $pathText -Cwd ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedIdentityHash) -and
        -not [string]::Equals($identityHash, $ExpectedIdentityHash, [StringComparison]::OrdinalIgnoreCase)) {
        $result.Status = '路径不匹配'
        return [PSCustomObject]$result
    }

    if (-not (Test-Path -LiteralPath $pathText -PathType Leaf)) {
        return [PSCustomObject]$result
    }

    try {
        Wait-ForTranscriptSettle -Path $pathText
        $slice = Read-TranscriptSlice -Path $pathText -StartOffset $BaselineBytes
        $result.BytesRead = [int]$slice.BytesRead
        $result.Truncated = [bool]$slice.Truncated
        $result.Status = if ([bool]$slice.Truncated) { '已读取（达到上限）' } elseif ([bool]$slice.Rewritten) { '已读取（文件重写）' } else { '已读取' }
        $result.ReadSucceeded = $true

        $skills = [System.Collections.Generic.List[string]]::new()
        $commandReadSkills = [System.Collections.Generic.List[string]]::new()
        if ([bool]$slice.Rewritten -and -not [string]::IsNullOrWhiteSpace($ExpectedTurnId)) {
            $parsed = Parse-TranscriptSkillSlice -Text ([string]$slice.Text) -ExpectedTurnId $ExpectedTurnId -RequireTurnMatch
        }
        else {
            $parsed = Parse-TranscriptSkillSlice -Text ([string]$slice.Text)
        }
        $result.LinesParsed += [int]$parsed.LinesParsed
        $result.ParseErrors += [int]$parsed.ParseErrors
        foreach ($name in @($parsed.SkillNames)) { Add-UniqueSkillName -List $skills -Value $name }
        foreach ($name in @($parsed.CommandReadSkillNames)) { Add-UniqueSkillName -List $commandReadSkills -Value $name }

        $lookbackEnabled = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'currentTurnLookbackEnabled') -Default $true)
        [Int64]$lookbackBytes = [Int64](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'lookbackBytes') -Default 1048576)
        if ($lookbackBytes -lt 65536) { $lookbackBytes = 65536 }
        if ($lookbackBytes -gt 8388608) { $lookbackBytes = 8388608 }

        # A Codex client may write current-turn Skill injection metadata just
        # before UserPromptSubmit captures the transcript length. Read a bounded
        # range ending exactly at the baseline and accept only this turn_id.
        if ($lookbackEnabled -and $skills.Count -eq 0 -and $commandReadSkills.Count -eq 0 -and
            $BaselineBytes -gt 0 -and -not [string]::IsNullOrWhiteSpace($ExpectedTurnId)) {
            [Int64]$lookbackStart = [Math]::Max(0, $BaselineBytes - $lookbackBytes)
            if ($lookbackStart -lt $BaselineBytes) {
                $lookbackSlice = Read-TranscriptSlice -Path $pathText -StartOffset $lookbackStart -EndOffset $BaselineBytes
                $lookbackParsed = Parse-TranscriptSkillSlice -Text ([string]$lookbackSlice.Text) -ExpectedTurnId $ExpectedTurnId -RequireTurnMatch
                $result.LookbackUsed = $true
                $result.BytesRead += [int]$lookbackSlice.BytesRead
                $result.LinesParsed += [int]$lookbackParsed.LinesParsed
                $result.ParseErrors += [int]$lookbackParsed.ParseErrors
                $result.Truncated = [bool]$result.Truncated -or [bool]$lookbackSlice.Truncated
                foreach ($name in @($lookbackParsed.SkillNames)) { Add-UniqueSkillName -List $skills -Value $name }
                foreach ($name in @($lookbackParsed.CommandReadSkillNames)) { Add-UniqueSkillName -List $commandReadSkills -Value $name }
                if (@($lookbackParsed.SkillNames).Count -gt 0 -or @($lookbackParsed.CommandReadSkillNames).Count -gt 0) {
                    $result.Status = '已读取（含当前Turn回看）'
                }
            }
        }

        $result.SkillNames = @($skills)
        $result.CommandReadSkillNames = @($commandReadSkills)
        return [PSCustomObject]$result
    }
    catch {
        $result.Status = '读取失败'
        return [PSCustomObject]$result
    }
}


function Get-MainTranscriptSkillObservation {
    param(
        [object]$State,
        [object]$StopPayload
    )

    $readMain = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'readMain') -Default $true)
    if (-not $readMain) {
        return [PSCustomObject]@{ SkillNames = @(); CommandReadSkillNames = @(); Source = '主任务会话记录－实际注入'; Status = '已关闭'; ReadSucceeded = $false; Truncated = $false; LookbackUsed = $false; BytesRead = 0; LinesParsed = 0; ParseErrors = 0 }
    }

    if ($null -eq $State) {
        return [PSCustomObject]@{ SkillNames = @(); CommandReadSkillNames = @(); Source = '主任务会话记录－实际注入'; Status = '无起始基线'; ReadSucceeded = $false; Truncated = $false; LookbackUsed = $false; BytesRead = 0; LinesParsed = 0; ParseErrors = 0 }
    }

    $baselineAvailable = [bool](Get-PropertyValue -Object $State -Name 'transcriptBaselineCaptured' -Default $false)
    if (-not $baselineAvailable) {
        return [PSCustomObject]@{ SkillNames = @(); CommandReadSkillNames = @(); Source = '主任务会话记录－实际注入'; Status = '无起始基线'; ReadSucceeded = $false; Truncated = $false; LookbackUsed = $false; BytesRead = 0; LinesParsed = 0; ParseErrors = 0 }
    }

    [Int64]$baselineBytes = 0
    $baselineText = [string](Get-PropertyValue -Object $State -Name 'transcriptBaselineBytes' -Default '0')
    $null = [Int64]::TryParse($baselineText, [ref]$baselineBytes)
    $expectedHash = [string](Get-PropertyValue -Object $State -Name 'transcriptIdentityHash' -Default '')
    $pathValue = Get-PropertyValue -Object $StopPayload -Name 'transcript_path' -Default $null

    return Get-TranscriptSkillObservation -PathValue $pathValue -BaselineBytes $baselineBytes -ExpectedIdentityHash $expectedHash -Source '主任务会话记录－实际注入' -ExpectedTurnId ([string](Get-PropertyValue -Object $State -Name 'turnId' -Default ''))
}

function Get-SubagentTranscriptSkillObservation {
    param([object]$SubagentPayload)

    $readSubagents = [bool](Get-ConfigValue -Config $config -Path @('skillCollection', 'transcript', 'readSubagents') -Default $true)
    if (-not $readSubagents) {
        return [PSCustomObject]@{ SkillNames = @(); CommandReadSkillNames = @(); Source = '子Agent会话记录－实际注入'; Status = '已关闭'; ReadSucceeded = $false; Truncated = $false; LookbackUsed = $false; BytesRead = 0; LinesParsed = 0; ParseErrors = 0 }
    }

    $pathValue = Get-PropertyValue -Object $SubagentPayload -Name 'agent_transcript_path' -Default $null
    return Get-TranscriptSkillObservation -PathValue $pathValue -BaselineBytes 0 -ExpectedIdentityHash '' -Source '子Agent会话记录－实际注入' -ExpectedTurnId ([string](Get-PropertyValue -Object $SubagentPayload -Name 'turn_id' -Default ''))
}

function Merge-SkillNamesIntoState {
    param(
        [object]$State,
        [string]$PropertyName,
        [object[]]$SkillNames
    )

    $merged = [System.Collections.Generic.List[string]]::new()
    foreach ($existing in @((Get-PropertyValue -Object $State -Name $PropertyName -Default @()))) {
        Add-UniqueSkillName -List $merged -Value $existing
    }
    foreach ($incoming in @($SkillNames)) {
        Add-UniqueSkillName -List $merged -Value $incoming
    }

    Set-PropertyValue -Object $State -Name $PropertyName -Value @($merged)
    Set-PropertyValue -Object $State -Name 'skillCollectionMode' -Value '多源识别'
    Set-PropertyValue -Object $State -Name 'skillParserVersion' -Value 3
    return $State
}

function Add-SkillEvidence {
    param(
        [hashtable]$EvidenceByKey,
        [System.Collections.ArrayList]$EvidenceOrder,
        [object]$NameValue,
        [string]$ScopeKey,
        [string]$Source,
        [string]$Level,
        [int]$Priority
    )

    $name = Normalize-SkillName -Value $NameValue
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if ([string]::IsNullOrWhiteSpace($ScopeKey)) { $ScopeKey = 'root' }

    $key = $ScopeKey + "`n" + $name
    if (-not $EvidenceByKey.ContainsKey($key)) {
        $EvidenceByKey[$key] = [ordered]@{
            name = $name
            scope = $ScopeKey
            source = $Source
            level = $Level
            priority = $Priority
        }
        $null = $EvidenceOrder.Add($key)
        return
    }

    if ($Priority -gt [int]$EvidenceByKey[$key].priority) {
        $EvidenceByKey[$key].source = $Source
        $EvidenceByKey[$key].level = $Level
        $EvidenceByKey[$key].priority = $Priority
    }
}

function Convert-TranscriptStatusDisplay {
    param([object]$Observation)

    if ($null -eq $Observation) { return '不可用' }
    $status = [string](Get-PropertyValue -Object $Observation -Name 'Status' -Default '不可用')
    if ([string]::IsNullOrWhiteSpace($status)) { return '不可用' }
    return Sanitize-DisplayName -Value $status -Fallback '不可用'
}

function Resolve-TurnStatus {
    param([object]$StopPayload)

    $candidate = ''
    foreach ($fieldName in @('turn_status', 'final_status', 'status')) {
        $value = [string](Get-PropertyValue -Object $StopPayload -Name $fieldName -Default '')
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidate = $value.Trim().ToLowerInvariant()
            break
        }
    }

    $errorValue = Get-PropertyValue -Object $StopPayload -Name 'error' -Default $null
    if ($null -ne $errorValue -and [string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = 'failed'
    }

    switch -Regex ($candidate) {
        '^(completed|complete|success|succeeded|ok)$' {
            return [PSCustomObject]@{ Code = 'completed'; Display = '完成'; Source = 'Hook扩展字段' }
        }
        '^(interrupted|cancelled|canceled|aborted|stopped)$' {
            return [PSCustomObject]@{ Code = 'interrupted'; Display = '已中断'; Source = 'Hook扩展字段' }
        }
        '^(failed|failure|error)$' {
            return [PSCustomObject]@{ Code = 'failed'; Display = '失败'; Source = 'Hook扩展字段' }
        }
        '^(unknown)$' {
            return [PSCustomObject]@{ Code = 'unknown'; Display = '未知'; Source = 'Hook扩展字段' }
        }
        default {
            # The released Stop hook schema does not carry a final turn status.
            # Reaching the root Stop event is therefore treated as a successful
            # completion, and the log explicitly marks this as a hook inference.
            return [PSCustomObject]@{ Code = 'completed'; Display = '完成'; Source = 'Hook推定' }
        }
    }
}

function Get-HighlightStyle {
    $style = [string](Get-ConfigValue -Config $config -Path @('display', 'highlightStyle') -Default 'icon')
    $style = $style.Trim().ToLowerInvariant()
    if (@('icon', 'bracket', 'none') -notcontains $style) {
        return 'icon'
    }
    return $style
}

function Format-DisplayTime {
    param(
        [DateTimeOffset]$Time,
        [DateTimeOffset]$OtherTime
    )

    if ($Time.LocalDateTime.Date -eq $OtherTime.LocalDateTime.Date) {
        return $Time.ToLocalTime().ToString('HH:mm:ss')
    }

    return $Time.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
}

function Write-HookJsonOutput {
    param([string]$SystemMessage)

    $output = [ordered]@{
        continue = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($SystemMessage)) {
        $output.systemMessage = $SystemMessage
    }

    $json = $output | ConvertTo-Json -Compress -Depth 8
    [Console]::Out.WriteLine($json)
}

$RawInput = [Console]::In.ReadToEnd()
$readResult = Read-HookPayload -Raw $RawInput
$Payload = $readResult.Payload

$installRoot = $env:CODEX_TASK_STATS_HOME
if ([string]::IsNullOrWhiteSpace($installRoot)) {
    $installRoot = Split-Path -Parent $PSScriptRoot
}
$installRoot = [IO.Path]::GetFullPath($installRoot)

$configPath = Join-Path $installRoot 'config\config.json'
$dataRoot = Join-Path $installRoot 'data'
$stateRoot = Join-Path $dataRoot 'state'
$journalRoot = Join-Path $dataRoot 'journal'
$completedRoot = Join-Path $dataRoot 'completed'
$logsRoot = Join-Path $installRoot 'logs'
$debugRoot = Join-Path $installRoot 'debug'

foreach ($directory in @($stateRoot, $journalRoot, $completedRoot, $logsRoot, $debugRoot)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
}

$config = $null
try {
    $config = Read-JsonFile -Path $configPath
}
catch {
    $config = $null
}

$versionPath = Join-Path $installRoot 'VERSION'
$ProgramVersion = 'v0.0'
try {
    if (Test-Path -LiteralPath $versionPath) {
        $candidateVersion = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8).Trim()
        if ($candidateVersion -match '^v[0-9]+\.[0-9]$') {
            $ProgramVersion = $candidateVersion
        }
    }
}
catch {
    $ProgramVersion = 'v0.0'
}

$SessionId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'session_id' -Default '') -Fallback 'unknown-session'
$TurnId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'turn_id' -Default '') -Fallback 'unknown-turn'

$instanceHash = Get-Sha256Hex -Text $installRoot.ToLowerInvariant()
# v1.7+：在根任务 Stop 时归并子 turn；v2.1 保留 PowerShell 5.1 集合兼容并修复 Git dry-run 短选项判断。
$script:BootstrapPhase = 'load-subagent-correlation'
$subagentCorrelationLibrary = Join-Path $PSScriptRoot 'lib\SubagentCorrelation.ps1'
if (-not (Test-Path -LiteralPath $subagentCorrelationLibrary -PathType Leaf)) {
    throw [IO.FileNotFoundException]::new('缺少子Agent关联库。', $subagentCorrelationLibrary)
}
. $subagentCorrelationLibrary
$script:BootstrapPhase = 'event-processing'

$runHash = Get-Sha256Hex -Text ($SessionId + "`n" + $TurnId)
$runMutexName = 'Local\CodexTaskStats_' + $instanceHash.Substring(0, 12) + '_Run_' + $runHash.Substring(0, 24)
$dailyLogMutexName = 'Local\CodexTaskStats_' + $instanceHash.Substring(0, 12) + '_DailyLog'
$debugLogMutexName = 'Local\CodexTaskStats_' + $instanceHash.Substring(0, 12) + '_DebugLog'
$statePath = Join-Path $stateRoot ($runHash + '.json')
$journalPath = Join-Path $journalRoot ($runHash + '.jsonl')
$completedPath = Join-Path $completedRoot ($runHash + '.json')

function Write-DebugRecord {
    param(
        [string]$Message,
        [object]$ExceptionObject = $null
    )

    try {
        $debugEnabled = [bool](Get-ConfigValue -Config $config -Path @('debug', 'enabled') -Default $false)
        if (-not $debugEnabled) {
            return
        }

        $record = [ordered]@{
            at = [DateTimeOffset]::Now.ToString('o')
            event = $Event
            session_id = $SessionId
            turn_id = $TurnId
            message = $Message
        }
        if ($null -ne $ExceptionObject) {
            $errorType = $ExceptionObject.GetType().FullName
            $record.errorType = Sanitize-DisplayName -Value $errorType -Fallback 'unknown-error-type'
        }

        $line = $record | ConvertTo-Json -Compress -Depth 6
        $path = Join-Path $debugRoot ('codex-task-stats-' + [DateTimeOffset]::Now.ToString('yyyy-MM-dd') + '.jsonl')
        $null = Invoke-WithMutex -Name $debugLogMutexName -TimeoutMs 2000 -ScriptBlock {
            Append-Utf8Line -Path $path -Line $line
        }
    }
    catch {
        # Statistics and debug logging must never interrupt Codex.
    }
}

if ($readResult.Recovered) {
    Write-DebugRecord -Message ('Hook 输入 JSON 解析失败，已恢复必要字段；原始输入长度=' + $RawInput.Length)
}

$SubagentSkillObservation = $null
if ($Event -eq 'SubagentStop') {
    try {
        $SubagentSkillObservation = Get-SubagentTranscriptSkillObservation -SubagentPayload $Payload
    }
    catch {
        Write-DebugRecord -Message '子Agent transcript 中的 Skill 解析失败，仍会记录事件元数据。' -ExceptionObject $_.Exception
    }
}

function Get-TranscriptActivityObservation {
    param([string]$Text, [string]$ExpectedTurnId, [string]$Cwd, [string]$Scope='root', [DateTimeOffset]$From=[DateTimeOffset]::MinValue, [DateTimeOffset]$Until=[DateTimeOffset]::MaxValue)
    $paths = @{}
    $edits = @{}
    $calls = @{}
    $spawns = @{}
    $mcpCalls = @{}
    $agentStarts = [ordered]@{}
    $fileChanges = [Collections.Generic.List[object]]::new()
    $agentIds = @{}
    $currentTurn = $ExpectedTurnId
    $errors = 0
    $lineCount = 0
    foreach ($line in ([string]$Text -split '\r?\n')) {
        if (-not $line) { continue }
        if (++$lineCount -gt 10000) { $errors++; break }
        try {
            $r = $line | ConvertFrom-Json
            $p = Get-PropertyValue -Object $r -Name 'payload'
            $topType = [string](Get-PropertyValue -Object $r -Name 'type')
            $type = [string](Get-PropertyValue -Object $p -Name 'type')
            $turn = Get-TranscriptRecordTurnId -Record $r
            if ($topType -eq 'turn_context' -or ($topType -eq 'event_msg' -and $type -eq 'task_started')) { $currentTurn = $turn }
            if ($ExpectedTurnId -and (($turn -and $turn -ne $ExpectedTurnId) -or $currentTurn -ne $ExpectedTurnId)) { continue }
            $timeValue = Get-PropertyValue -Object $r -Name 'timestamp' -Default ''
            $at = [DateTimeOffset]::MinValue
            if ($timeValue) { $at = [DateTimeOffset]::Parse([string]$timeValue, [Globalization.CultureInfo]::InvariantCulture) }
            if (-not $timeValue -and ($From -ne [DateTimeOffset]::MinValue -or $Until -ne [DateTimeOffset]::MaxValue)) {
                $timedItem=Get-PropertyValue -Object $p -Name 'item'
                $timedType=Get-PropertyValue -Object $timedItem -Name 'type'
                if ($topType -eq 'event_msg' -and $type -eq 'item_completed' -and
                    (($timedType -eq 'SubAgentActivity' -and (Get-PropertyValue -Object $timedItem -Name 'kind') -eq 'started') -or
                    ($timedType -eq 'FileChange' -and (Get-PropertyValue -Object $timedItem -Name 'status') -eq 'completed'))) { $errors++ }
                continue
            }
            if ($at -lt $From -or $at -gt $Until) { continue }
            if ($topType -eq 'event_msg' -and $type -eq 'item_completed') {
                $item = Get-PropertyValue -Object $p -Name 'item'
                if ((Get-PropertyValue -Object $item -Name 'type') -eq 'McpToolCall' -and
                    (Get-PropertyValue -Object $item -Name 'status') -in @('completed', 'failed')) {
                    $id = Normalize-StableId -Value (Get-PropertyValue -Object $item -Name 'id') -Fallback ''
                    $server = [string](Get-PropertyValue -Object $item -Name 'server')
                    $tool = [string](Get-PropertyValue -Object $item -Name 'tool')
                    if ($id -and -not [string]::IsNullOrWhiteSpace($server) -and -not [string]::IsNullOrWhiteSpace($tool)) {
                        # Code-mode 内层 MCP 可能没有工具 Hook；用原生调用 ID 复用汇总去重，不保存参数和结果。
                        $mcpCalls[$id] = [pscustomobject]@{
                            event='PostToolUse'; toolName=('mcp__' + $server + '__' + $tool); toolUseId=$id
                            at=[string]$timeValue; skillScope=$(if ($Scope -eq 'root') { 'root' } else { 'agent:' + $Scope })
                        }
                    }
                }
                if ((Get-PropertyValue -Object $item -Name 'type') -eq 'SubAgentActivity' -and
                    (Get-PropertyValue -Object $item -Name 'kind') -eq 'started') {
                    # interacted 的目标可能是父任务；只有 started 能证明新建了子 Agent。
                    $childId = ConvertTo-V21SafeAgentId -Value (Get-PropertyValue -Object $item -Name 'agent_thread_id')
                    if ($childId -and -not $agentStarts.Contains($childId)) {
                        $metadata = Get-V21SafeSpawnMetadata -Payload ([pscustomobject]@{
                            tool_response=[pscustomobject]@{task_name=(Get-PropertyValue -Object $item -Name 'agent_path')}
                        })
                        $agentIds[$childId]=$true
                        $agentStarts[$childId] = [pscustomobject]@{
                            event='SubagentStart'; agentId=$childId; agentType=$(if ($metadata.DisplayName) { $metadata.DisplayName } else { 'default' })
                            at=[string]$timeValue; toolUseId=(Normalize-StableId -Value (Get-PropertyValue -Object $item -Name 'id') -Fallback '')
                        }
                    }
                }
                if ((Get-PropertyValue -Object $item -Name 'type') -eq 'FileChange' -and (Get-PropertyValue -Object $item -Name 'status') -eq 'completed') {
                    $id = [string](Get-PropertyValue -Object $item -Name 'id')
                    if (-not $id) { $errors++; continue }
                    if ($edits.ContainsKey($id)) { continue }
                    $edits[$id] = $true
                    $changes = Get-PropertyValue -Object $item -Name 'changes'
                    foreach ($property in $changes.PSObject.Properties) {
                        $pathId = Get-FileIdentityHash -PathValue $property.Name -Cwd $Cwd
                        if ($pathId) { $paths[$pathId] = $true }
                        $fileChanges.Add([pscustomobject]@{Path=$property.Name; Detail=$property.Value; At=$at; Scope=$Scope; EditId=$id; Order=$lineCount; Cwd=$Cwd})
                    }
                }
            }
            if ($topType -ne 'response_item') { continue }
            $callId = [string](Get-PropertyValue -Object $p -Name 'call_id')
            if (-not $callId) { continue }
            if ($type -eq 'function_call' -and (Test-V21SubagentSpawnToolName -ToolName ([string](Get-PropertyValue -Object $p -Name 'name')))) {
                $inputValue = Get-PropertyValue -Object $p -Name 'arguments'
                $metadata = Get-V21SafeSpawnMetadata -Payload ([pscustomobject]@{tool_input=$inputValue})
                $calls[$callId] = $metadata
            }
            elseif ($type -eq 'function_call_output' -and $calls.ContainsKey($callId)) {
                $outputValue = Get-PropertyValue -Object $p -Name 'output'
                if ($outputValue -is [string]) { $outputValue = $outputValue | ConvertFrom-Json }
                if ($null -eq $outputValue) { continue }
                $toolPayload = [pscustomobject]@{tool_response=$outputValue}
                if (-not (Test-V21SpawnPostSucceeded -Payload $toolPayload)) { continue }
                $metadata = Get-V21SafeSpawnMetadata -Payload $toolPayload
                # A parsable response alone is not proof of a successful spawn.
                if (-not $metadata.AgentId -and -not $metadata.DisplayName) { continue }
                $displayName = [string]$calls[$callId].DisplayName
                if (-not $displayName) { $displayName = [string]$metadata.DisplayName }
                $spawns[$callId] = [pscustomobject]@{
                    event='PostToolUse'; toolName='spawn_agent'; toolUseId=$callId; success=$true
                    at=[string](Get-PropertyValue -Object $r -Name 'timestamp')
                    spawnObservation=$true; spawnSucceeded=$true; spawnAgentId=[string]$metadata.AgentId
                    spawnDisplayName=$displayName; spawnDisplayNameSource='task_name'
                }
            }
        }
        catch { $errors++ }
    }
    foreach ($start in $agentStarts.Values) {
        if (-not $start.toolUseId) { continue }
        # 原生启动将调用 ID 与真实 Agent ID 绑定；补齐部分缺失的 Hook，并复用名称解析及去重。
        $spawns[$start.toolUseId] = [pscustomobject]@{
            event='PostToolUse'; toolName='spawn_agent'; toolUseId=$start.toolUseId; success=$true; at=$start.at
            spawnObservation=$true; spawnSucceeded=$true; spawnAgentId=$start.agentId
            spawnDisplayName=$start.agentType; spawnDisplayNameSource='task_name'
        }
    }
    return [pscustomobject]@{PathIds=@($paths.Keys); EditIds=@($edits.Keys); EditCount=$edits.Count; Events=(@($spawns.Values) + @($mcpCalls.Values) + @($agentStarts.Values)); ParseErrors=$errors; FileChanges=@($fileChanges); AgentIds=@($agentIds.Keys); Reasons=@()}
}

function Get-MainTranscriptActivityObservation {
    param([object]$State, [object]$StopPayload)
    $empty = [pscustomobject]@{PathIds=@(); EditCount=0; Events=@(); FileChanges=@(); AgentIds=@(); Reasons=@('主任务文件变更记录不可用'); Incomplete=$true}
    if (-not (Get-PropertyValue -Object $State -Name 'transcriptBaselineCaptured' -Default $false)) { return $empty }
    $path = [string](Get-PropertyValue -Object $StopPayload -Name 'transcript_path')
    if (-not $path -or (Get-FileIdentityHash -PathValue $path -Cwd '') -ne (Get-PropertyValue -Object $State -Name 'transcriptIdentityHash')) { return $empty }
    try {
        $slice = Read-TranscriptSlice -Path $path -StartOffset ([Int64](Get-PropertyValue -Object $State -Name 'transcriptBaselineBytes' -Default 0))
        # A rewritten file has no trusted implicit turn boundary.
        $text = [string]$slice.Text
        if ($slice.Rewritten) { return $empty }
        $result = Get-TranscriptActivityObservation -Text $text -ExpectedTurnId ([string](Get-PropertyValue -Object $State -Name 'turnId')) -Cwd ([string](Get-PropertyValue -Object $StopPayload -Name 'cwd'))
        $result | Add-Member -NotePropertyName Incomplete -NotePropertyValue ([bool]$slice.Truncated -or $result.ParseErrors -gt 0)
        if ($result.Incomplete) { $result.Reasons=@('主任务文件变更记录截断或解析失败') }
        return $result
    }
    catch { $empty.Incomplete = $true; return $empty }
}

function Add-ChildFileActivity {
    param([object]$Observation, [object[]]$Events, [object]$State, [object]$StopPayload, [DateTimeOffset]$EndedAt)
    $queue = [Collections.Generic.Queue[object]]::new()
    $parentId = [string](Get-PropertyValue -Object $State -Name 'sessionId')
    foreach ($id in @((Get-PropertyValue -Object $Observation -Name 'AgentIds' -Default @())) + @($Events | Where-Object { (Get-PropertyValue -Object $_ -Name 'event') -in @('SubagentStart','SubagentStop') } | ForEach-Object { Get-PropertyValue -Object $_ -Name 'agentId' })) {
        if ($id) { $queue.Enqueue(@{id=[string]$id; parent=$parentId}) }
    }
    if ($queue.Count -eq 0) { return $Observation }
    $changes = [Collections.Generic.List[object]]::new()
    foreach ($change in @((Get-PropertyValue -Object $Observation -Name 'FileChanges' -Default @()))) { $changes.Add($change) }
    $reasons = [Collections.Generic.List[string]]::new()
    foreach ($reason in @((Get-PropertyValue -Object $Observation -Name 'Reasons' -Default @()))) { $reasons.Add([string]$reason) }
    $seen = @{}; $childEdits = @{}
    $transcriptPath=[string](Get-PropertyValue -Object $StopPayload -Name 'transcript_path')
    $directory = if ($transcriptPath) { Split-Path -Parent $transcriptPath } else { '' }
    $start = [DateTimeOffset]::Parse([string](Get-PropertyValue -Object $State -Name 'startedAt'),[Globalization.CultureInfo]::InvariantCulture)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($queue.Count -gt 0) {
        $agent = $queue.Dequeue()
        if ($seen.ContainsKey($agent.id)) { continue }
        $seen[$agent.id]=$true
        if ($seen.Count -gt 16 -or $watch.ElapsedMilliseconds -gt 2000) { $reasons.Add('子Agent文件记录读取超出预算'); break }
        try {
            if ($agent.id -notmatch '^[A-Za-z0-9_-]{1,200}$' -or -not $directory) { throw 'unavailable-child-identity' }
            # Only the known transcript directory, never a workspace or session-tree scan.
            $matches = @(Get-ChildItem -LiteralPath $directory -Filter ('*-' + $agent.id + '.jsonl') -File)
            if ($matches.Count -ne 1) { throw 'child-transcript-unavailable' }
            $header = Read-TranscriptSlice -Path $matches[0].FullName -StartOffset 0 -EndOffset 65536
            $meta = (([string]$header.Text -split '\r?\n',2)[0] | ConvertFrom-Json)
            $identity = Get-PropertyValue -Object $meta -Name 'payload'
            $spawn = Get-PropertyValue -Object (Get-PropertyValue -Object (Get-PropertyValue -Object $identity -Name 'source') -Name 'subagent') -Name 'thread_spawn'
            if ((Get-PropertyValue -Object $meta -Name 'type') -ne 'session_meta' -or (Get-PropertyValue -Object $identity -Name 'id') -ne $agent.id -or (Get-PropertyValue -Object $spawn -Name 'parent_thread_id') -ne $agent.parent) { throw 'child-identity-mismatch' }
            $slice = Read-TranscriptSlice -Path $matches[0].FullName -StartOffset 0
            $childCwd = [string](Get-PropertyValue -Object $identity -Name 'cwd' -Default (Get-PropertyValue -Object $StopPayload -Name 'cwd'))
            $child = Get-TranscriptActivityObservation -Text $slice.Text -ExpectedTurnId '' -Cwd $childCwd -Scope $agent.id -From $start -Until $EndedAt
            foreach ($change in $child.FileChanges) { $changes.Add($change); $childEdits[$agent.id+"`n"+$change.EditId]=$true }
            foreach ($id in $child.AgentIds) { $queue.Enqueue(@{id=$id; parent=$agent.id}) }
            if ($slice.Truncated -or $child.ParseErrors -gt 0) { throw 'incomplete-child-transcript' }
        }
        catch { if (-not $reasons.Contains('子Agent文件记录缺失、身份不匹配、截断或解析失败')) { $reasons.Add('子Agent文件记录缺失、身份不匹配、截断或解析失败') } }
    }
    Set-PropertyValue -Object $Observation -Name 'FileChanges' -Value @($changes | Sort-Object At,Order)
    Set-PropertyValue -Object $Observation -Name 'Reasons' -Value @($reasons)
    Set-PropertyValue -Object $Observation -Name 'ChildEditCount' -Value $childEdits.Count
    if ($reasons.Count -gt 0) { Set-PropertyValue -Object $Observation -Name 'Incomplete' -Value $true }
    return $Observation
}

function Get-SubagentTranscriptDisplayName {
    param([object]$AgentPayload)
    $path = [string](Get-PropertyValue -Object $AgentPayload -Name 'agent_transcript_path' -Default '')
    if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    try {
        # A bounded metadata read avoids parsing/encrypting child conversation text.
        $slice = Read-TranscriptSlice -Path $path -StartOffset 0 -EndOffset 65536
        $firstLine = ([string]$slice.Text -split '\r?\n', 2)[0]
        $record = $firstLine | ConvertFrom-Json
        if ((Get-PropertyValue -Object $record -Name 'type') -ne 'session_meta') { return '' }
        $meta = Get-PropertyValue -Object $record -Name 'payload'
        $id = [string](Get-PropertyValue -Object $meta -Name 'id')
        $expectedId = [string](Get-PropertyValue -Object $AgentPayload -Name 'agent_id')
        if (-not $id -or -not $expectedId -or $id -ne $expectedId) { return '' }
        $source = Get-PropertyValue -Object $meta -Name 'source'
        $spawn = Get-PropertyValue -Object (Get-PropertyValue -Object $source -Name 'subagent') -Name 'thread_spawn'
        $parent = [string](Get-PropertyValue -Object $spawn -Name 'parent_thread_id')
        if ($parent -ne [string](Get-PropertyValue -Object $AgentPayload -Name 'session_id')) { return '' }
        $agentPath = [string](Get-PropertyValue -Object $spawn -Name 'agent_path')
        if ($agentPath -match '^/root/(?:[A-Za-z0-9_-]+/)*([A-Za-z0-9_-]+)$') {
            return ConvertTo-V21SafeSubagentDisplayName -Value $Matches[1] -Source 'task_name'
        }
    }
    catch { }
    return ''
}

function New-RunState {
    param(
        [DateTimeOffset]$StartedAt,
        [Int64]$StartMonotonicTicks,
        [string]$StartSource
    )

    $explicitSkills = @()
    $structuredSkills = @()
    if ($Event -eq 'UserPromptSubmit') {
        $explicitSkills = @(Get-ExplicitSkillNames -PromptValue (Get-PropertyValue -Object $Payload -Name 'prompt' -Default ''))
        $structuredSkills = @(Get-StructuredSkillNames -Value $Payload -Strict)
    }

    $transcriptBaseline = Get-TranscriptBaselineMetadata -PathValue (Get-PropertyValue -Object $Payload -Name 'transcript_path' -Default $null)
    $cwd = [string](Get-PropertyValue -Object $Payload -Name 'cwd' -Default '')

    return [ordered]@{
        schemaVersion = 11
        sessionId = $SessionId
        turnId = $TurnId
        startedAt = $StartedAt.ToString('o')
        startMonotonicTicks = $StartMonotonicTicks.ToString([Globalization.CultureInfo]::InvariantCulture)
        stopwatchFrequency = [Diagnostics.Stopwatch]::Frequency.ToString([Globalization.CultureInfo]::InvariantCulture)
        startSource = $StartSource
        model = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'model' -Default '') -Fallback ''
        permissionMode = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'permission_mode' -Default '') -Fallback ''
        explicitSkills = @($explicitSkills)
        structuredSkills = @($structuredSkills)
        skillCollectionMode = '多源识别'
        skillParserVersion = 3
        transcriptIdentityHash = [string]$transcriptBaseline.IdentityHash
        transcriptBaselineBytes = ([Int64]$transcriptBaseline.BaselineBytes).ToString([Globalization.CultureInfo]::InvariantCulture)
        transcriptBaselineCaptured = (-not [string]::IsNullOrWhiteSpace([string]$transcriptBaseline.IdentityHash))
        transcriptExistedAtStart = [bool]$transcriptBaseline.Available
        fileCollectionMode = '成功 FileChange 记录与涉及文件内容核验'
        commandLoggingMode = Get-CommandLoggingMode
        programVersion = $ProgramVersion
        createdAt = [DateTimeOffset]::Now.ToString('o')
    }
}

function Ensure-RunState {
    param([string]$Source)

    $state = Read-JsonFile -Path $statePath
    if ($null -ne $state) {
        return $state
    }

    $newState = New-RunState -StartedAt $eventReceivedAt -StartMonotonicTicks ([Diagnostics.Stopwatch]::GetTimestamp()) -StartSource $Source
    Write-Utf8FileAtomic -Path $statePath -Content ($newState | ConvertTo-Json -Compress -Depth 10)
    return Read-JsonFile -Path $statePath
}

function New-JournalEvent {
    $record = [ordered]@{
        event = $Event
        at = [DateTimeOffset]::Now.ToString('o')
        monotonicTicks = ([Diagnostics.Stopwatch]::GetTimestamp()).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $eventAgentId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'agent_id' -Default '') -Fallback ''
    if ($eventAgentId) { $record.skillScope = 'agent:' + $eventAgentId }

    switch ($Event) {
        'PreToolUse' {
            $record.toolName = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'tool_name' -Default '') -Fallback '未知工具'
            $record.toolUseId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'tool_use_id' -Default '') -Fallback ''
            if (Test-IsApplyPatchTool -ToolName ([string]$record.toolName)) {
                $record.fileOperations = @(Get-ApplyPatchFileOperations -ToolInput (Get-PropertyValue -Object $Payload -Name 'tool_input' -Default $null) -Cwd ([string](Get-PropertyValue -Object $Payload -Name 'cwd' -Default '')))
            }
            elseif (Test-IsCommandExecutionTool -ToolName ([string]$record.toolName)) {
                $record.fileOperations = @(Get-ShellMoveFileOperations -ToolInput (Get-PropertyValue -Object $Payload -Name 'tool_input' -Default $null) -Cwd ([string](Get-PropertyValue -Object $Payload -Name 'cwd' -Default '')))
            }
            $record.commandReadSkills = @(Get-CommandReadSkillNamesFromToolPayload -ToolPayload $Payload)
            $commandObservation = Get-SafeCommandObservation -ToolPayload $Payload
            $record.commandCategory = [string](Get-PropertyValue -Object $commandObservation -Name 'category' -Default '')
            $record.gitInstructionCount = [int](Get-PropertyValue -Object $commandObservation -Name 'gitInstructionCount' -Default 0)
            $record.gitChangeCount = [int](Get-PropertyValue -Object $commandObservation -Name 'gitChangeCount' -Default 0)
            $record.safeCommands = @((Get-PropertyValue -Object $commandObservation -Name 'safeCommands' -Default @()))
            $record.commandParseErrorCount = [int](Get-PropertyValue -Object $commandObservation -Name 'parseErrorCount' -Default 0)
        }
        'PostToolUse' {
            $record.toolName = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'tool_name' -Default '') -Fallback '未知工具'
            $record.toolUseId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'tool_use_id' -Default '') -Fallback ''
            if (Test-IsApplyPatchTool -ToolName ([string]$record.toolName)) {
                $record.fileOperations = @(Get-ApplyPatchFileOperations -ToolInput (Get-PropertyValue -Object $Payload -Name 'tool_input' -Default $null) -Cwd ([string](Get-PropertyValue -Object $Payload -Name 'cwd' -Default '')))
            }
            elseif (Test-IsCommandExecutionTool -ToolName ([string]$record.toolName)) {
                $record.fileOperations = @(Get-ShellMoveFileOperations -ToolInput (Get-PropertyValue -Object $Payload -Name 'tool_input' -Default $null) -Cwd ([string](Get-PropertyValue -Object $Payload -Name 'cwd' -Default '')))
            }
            $record.commandReadSkills = @(Get-CommandReadSkillNamesFromToolPayload -ToolPayload $Payload)
            $commandObservation = Get-SafeCommandObservation -ToolPayload $Payload
            $record.commandCategory = [string](Get-PropertyValue -Object $commandObservation -Name 'category' -Default '')
            $record.gitInstructionCount = [int](Get-PropertyValue -Object $commandObservation -Name 'gitInstructionCount' -Default 0)
            $record.gitChangeCount = [int](Get-PropertyValue -Object $commandObservation -Name 'gitChangeCount' -Default 0)
            $record.safeCommands = @((Get-PropertyValue -Object $commandObservation -Name 'safeCommands' -Default @()))
            $record.commandParseErrorCount = [int](Get-PropertyValue -Object $commandObservation -Name 'parseErrorCount' -Default 0)
        }
        'PermissionRequest' {
            $record.toolName = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'tool_name' -Default '') -Fallback '未知工具'
        }
        'PreCompact' {
            $record.trigger = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'trigger' -Default '') -Fallback 'unknown'
        }
        'PostCompact' {
            $record.trigger = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'trigger' -Default '') -Fallback 'unknown'
        }
        'SubagentStart' {
            $record.agentId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'agent_id' -Default '') -Fallback ''
            $record.agentType = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'agent_type' -Default '') -Fallback '未命名Agent'
        }
        'SubagentStop' {
            $record.agentId = Normalize-StableId -Value (Get-PropertyValue -Object $Payload -Name 'agent_id' -Default '') -Fallback ''
            $record.agentType = Sanitize-DisplayName -Value (Get-PropertyValue -Object $Payload -Name 'agent_type' -Default '') -Fallback '未命名Agent'
            $displayName = Get-SubagentTranscriptDisplayName -AgentPayload $Payload
            if ($displayName) { $record.agentType = $displayName; $record.agentDisplayNameSource = 'child-session-metadata' }
            $record.structuredSkills = @(Get-StructuredSkillNames -Value $Payload -Strict)
            if ($null -ne $SubagentSkillObservation) {
                $record.transcriptSkills = @((Get-PropertyValue -Object $SubagentSkillObservation -Name 'SkillNames' -Default @()))
                $record.commandReadSkills = @((Get-PropertyValue -Object $SubagentSkillObservation -Name 'CommandReadSkillNames' -Default @()))
                $record.skillTranscriptStatus = [string](Get-PropertyValue -Object $SubagentSkillObservation -Name 'Status' -Default '不可用')
                $record.skillTranscriptReadSucceeded = [bool](Get-PropertyValue -Object $SubagentSkillObservation -Name 'ReadSucceeded' -Default $false)
                $record.skillTranscriptTruncated = [bool](Get-PropertyValue -Object $SubagentSkillObservation -Name 'Truncated' -Default $false)
                $record.skillTranscriptParseErrors = [int](Get-PropertyValue -Object $SubagentSkillObservation -Name 'ParseErrors' -Default 0)
            }
        }
    }

    Add-V21SubagentSpawnMetadataToRecord `
    -Record $record `
    -Payload $Payload `
    -EventName $Event


    return $record
}

function Append-CurrentEvent {
    # Parse outside the lock. A missing prompt must not scan the workspace while
    # holding the same lock that a new prompt needs to acquire.
    if (Test-Path -LiteralPath $completedPath) { return }
    $journalEvent = New-JournalEvent
    $preparedState = $null
    if ($null -eq (Read-JsonFile -Path $statePath)) {
        $preparedState = New-RunState -StartedAt $eventReceivedAt -StartMonotonicTicks ([Diagnostics.Stopwatch]::GetTimestamp()) -StartSource 'inferred-from-intermediate-event'
    }
    $null = Invoke-WithMutex -Name $runMutexName -TimeoutMs 1000 -ScriptBlock {
        # A late asynchronous collector may start after Stop has finalized.
        # Ignore it instead of recreating orphaned state for an already completed turn.
        if (Test-Path -LiteralPath $completedPath) {
            return
        }

        if ($null -eq (Read-JsonFile -Path $statePath) -and $null -ne $preparedState) {
            Write-Utf8FileAtomic -Path $statePath -Content ($preparedState | ConvertTo-Json -Compress -Depth 10)
        }
        Append-Utf8Line -Path $journalPath -Line ($journalEvent | ConvertTo-Json -Compress -Depth 8)
    }
}

function Wait-ForJournalSettle {
    $initialMs = [int](Get-ConfigValue -Config $config -Path @('collection', 'settleInitialMs') -Default 350)
    $quietMs = [int](Get-ConfigValue -Config $config -Path @('collection', 'settleQuietMs') -Default 350)
    $maxMs = [int](Get-ConfigValue -Config $config -Path @('collection', 'settleMaxMs') -Default 2500)

    if ($initialMs -gt 0) {
        Start-Sleep -Milliseconds $initialMs
    }

    $started = [DateTime]::UtcNow
    $stableSince = [DateTime]::UtcNow
    $lastSignature = ''

    while (([DateTime]::UtcNow - $started).TotalMilliseconds -lt $maxMs) {
        $signature = 'missing'
        if (Test-Path -LiteralPath $journalPath) {
            $item = Get-Item -LiteralPath $journalPath
            $signature = $item.Length.ToString() + ':' + $item.LastWriteTimeUtc.Ticks.ToString()
        }

        if ($signature -ne $lastSignature) {
            $lastSignature = $signature
            $stableSince = [DateTime]::UtcNow
        }
        elseif (([DateTime]::UtcNow - $stableSince).TotalMilliseconds -ge $quietMs) {
            break
        }

        Start-Sleep -Milliseconds 50
    }
}

function Read-JournalEvents {
    $events = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $journalPath)) {
        return $events
    }

    $lines = [IO.File]::ReadAllLines($journalPath, [Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $events.Add(($line | ConvertFrom-Json))
        }
        catch {
            Write-DebugRecord -Message '已跳过一条格式错误的 Journal 记录。' -ExceptionObject $_.Exception
        }
    }

    return $events
}

function Get-ToolAlias {
    param([string]$ToolName)

    $aliases = Get-ConfigValue -Config $config -Path @('toolAliases') -Default $null
    if ($null -ne $aliases) {
        $property = $aliases.PSObject.Properties[$ToolName]
        if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return Sanitize-DisplayName -Value $property.Value
        }
    }

    switch -Regex ($ToolName) {
        '^Bash$' { return 'Shell命令' }
        '^update_plan$' { return '计划更新' }
        '^view_image$' { return '图片查看' }
        default { return '本地工具/' + (Sanitize-DisplayName -Value $ToolName -Fallback '未知工具') }
    }
}
function Test-IsAgentManagementTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false, Position = 0)]
        [Alias('Name', 'Tool', 'ToolId')]
        [AllowNull()]
        [object]$ToolName
    )

    return (Test-V17IsAgentManagementTool -ToolName $ToolName)
}

function Build-Summary {
    param(
        [object]$State,
        [object[]]$Events,
        [DateTimeOffset]$EndedAt,
        [Int64]$EndMonotonicTicks,
        [object]$StopPayload,
        [object]$MainSkillObservation,
        [object]$ActivityObservation = $null
    )

    $mcpCounts = @{}
    $mcpOrder = [System.Collections.ArrayList]::new()
    $skillCounts = @{}
    $skillOrder = [System.Collections.ArrayList]::new()
    $otherCounts = @{}
    $otherOrder = [System.Collections.ArrayList]::new()
    $agentCounts = @{}
    $agentOrder = [System.Collections.ArrayList]::new()
    $fileOperations = [System.Collections.Generic.List[object]]::new()
    $fileEditsByPath = @{}
    $gitRunCount = 0
    $gitInstructionCount = 0
    $gitChangeCount = 0
    $gitRuns = [System.Collections.Generic.List[object]]::new()
    $shellRuns = [System.Collections.Generic.List[object]]::new()
    $commandLoggingMode = Get-CommandLoggingMode
    $includeGitCommandDetails = $commandLoggingMode -eq 'safe' -and [bool](Get-ConfigValue -Config $config -Path @('commandLogging', 'includeGit') -Default $true)
    $includeShellCommandDetails = $commandLoggingMode -eq 'safe' -and [bool](Get-ConfigValue -Config $config -Path @('commandLogging', 'includeShell') -Default $true)
    $maxCommandRuns = [int](Get-ConfigValue -Config $config -Path @('commandLogging', 'maxRunsPerTask') -Default 200)
    if ($maxCommandRuns -lt 1) { $maxCommandRuns = 1 }

    $skillEvidenceByKey = @{}
    $skillEvidenceOrder = [System.Collections.ArrayList]::new()
    $skillSources = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @((Get-PropertyValue -Object $MainSkillObservation -Name 'SkillNames' -Default @()))) {
        Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey 'root' -Source '主任务会话记录－实际注入' -Level 'confirmed' -Priority 50
    }
    foreach ($name in @((Get-PropertyValue -Object $MainSkillObservation -Name 'CommandReadSkillNames' -Default @()))) {
        Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey 'root' -Source '主任务命令记录－读取 SKILL.md' -Level 'read' -Priority 30
    }
    foreach ($name in @((Get-PropertyValue -Object $State -Name 'structuredSkills' -Default @()))) {
        Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey 'root' -Source '结构化Skill输入' -Level 'confirmed' -Priority 40
    }
    foreach ($name in @(Get-StructuredSkillNames -Value $StopPayload -Strict)) {
        Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey 'root' -Source '结构化Skill输入' -Level 'confirmed' -Priority 40
    }

    $preToolById = @{}
    $completedToolIds = @{}
    $agentsById = @{}
    $agentIdOrder = [System.Collections.ArrayList]::new()
    $subagentTranscriptById = @{}
    $syntheticPreIndex = 0
    $syntheticPostIndex = 0
    $syntheticAgentIndex = 0
    $editOperationCount = 0
    $unparsedEditOperationCount = 0
    $rootEditIds = @{}
    $childEditIds = @{}

    foreach ($journalEvent in $Events) {
        $eventName = [string](Get-PropertyValue -Object $journalEvent -Name 'event' -Default '')
        if (-not [string]::Equals($eventName, 'PreToolUse', [StringComparison]::Ordinal)) {
            continue
        }

        $toolUseId = [string](Get-PropertyValue -Object $journalEvent -Name 'toolUseId' -Default '')
        if ([string]::IsNullOrWhiteSpace($toolUseId)) {
            $syntheticPreIndex++
            $toolUseId = 'pre-synthetic-' + $syntheticPreIndex
        }
        $eventScope = [string](Get-PropertyValue -Object $journalEvent -Name 'skillScope' -Default 'root')
        $toolUseId = $eventScope + "`n" + $toolUseId
        if (-not $preToolById.ContainsKey($toolUseId)) {
            $preToolById[$toolUseId] = $journalEvent
        }
    }

    foreach ($journalEvent in $Events) {
        $eventName = [string](Get-PropertyValue -Object $journalEvent -Name 'event' -Default '')
        switch ($eventName) {
            'PostToolUse' {
                $toolUseId = [string](Get-PropertyValue -Object $journalEvent -Name 'toolUseId' -Default '')
                if ([string]::IsNullOrWhiteSpace($toolUseId)) {
                    $syntheticPostIndex++
                    $toolUseId = 'post-synthetic-' + $syntheticPostIndex
                }
                $eventScope = [string](Get-PropertyValue -Object $journalEvent -Name 'skillScope' -Default 'root')
                $toolUseId = $eventScope + "`n" + $toolUseId
                if ($completedToolIds.ContainsKey($toolUseId)) { continue }
                $completedToolIds[$toolUseId] = $true

                $toolName = Sanitize-DisplayName -Value (Get-PropertyValue -Object $journalEvent -Name 'toolName' -Default '') -Fallback '未知工具'
                $commandReadSkills = @((Get-PropertyValue -Object $journalEvent -Name 'commandReadSkills' -Default @()))
                if ($commandReadSkills.Count -eq 0 -and $preToolById.ContainsKey($toolUseId)) {
                    $commandReadSkills = @((Get-PropertyValue -Object $preToolById[$toolUseId] -Name 'commandReadSkills' -Default @()))
                }
                foreach ($name in $commandReadSkills) {
                    $toolSkillScope = [string](Get-PropertyValue -Object $journalEvent -Name 'skillScope' -Default 'root')
                    Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey $toolSkillScope -Source 'Hook工具调用－读取 SKILL.md' -Level 'read' -Priority 30
                }

                if (Test-IsCommandExecutionTool -ToolName $toolName) {
                    $commandCategory = [string](Get-PropertyValue -Object $journalEvent -Name 'commandCategory' -Default '')
                    $gitInstructionValue = [int](Get-PropertyValue -Object $journalEvent -Name 'gitInstructionCount' -Default 0)
                    $gitChangeValue = [int](Get-PropertyValue -Object $journalEvent -Name 'gitChangeCount' -Default 0)
                    $safeCommandValues = @((Get-PropertyValue -Object $journalEvent -Name 'safeCommands' -Default @()))
                    if ($preToolById.ContainsKey($toolUseId)) {
                        $preEvent = $preToolById[$toolUseId]
                        if ([string]::IsNullOrWhiteSpace($commandCategory)) {
                            $commandCategory = [string](Get-PropertyValue -Object $preEvent -Name 'commandCategory' -Default '')
                        }
                        if ($gitInstructionValue -le 0) {
                            $gitInstructionValue = [int](Get-PropertyValue -Object $preEvent -Name 'gitInstructionCount' -Default 0)
                        }
                        if ($gitChangeValue -le 0) {
                            $gitChangeValue = [int](Get-PropertyValue -Object $preEvent -Name 'gitChangeCount' -Default 0)
                        }
                        if ($safeCommandValues.Count -eq 0) {
                            $safeCommandValues = @((Get-PropertyValue -Object $preEvent -Name 'safeCommands' -Default @()))
                        }
                    }

                    if ([string]::Equals($commandCategory, 'git', [StringComparison]::OrdinalIgnoreCase)) {
                        $gitRunCount++
                        if ($gitInstructionValue -le 0) {
                            $gitInstructionValue = 1
                        }
                        $gitInstructionCount += $gitInstructionValue
                        $gitChangeCount += $gitChangeValue

                        $commandFileOperations = @((Get-PropertyValue -Object $journalEvent -Name 'fileOperations' -Default @()))
                        if ($commandFileOperations.Count -eq 0 -and $preToolById.ContainsKey($toolUseId)) {
                            $commandFileOperations = @((Get-PropertyValue -Object $preToolById[$toolUseId] -Name 'fileOperations' -Default @()))
                        }
                        foreach ($operation in $commandFileOperations) { $fileOperations.Add($operation) }

                        if ($includeGitCommandDetails -and $gitRuns.Count -lt $maxCommandRuns -and $safeCommandValues.Count -gt 0) {
                            $gitRuns.Add([PSCustomObject][ordered]@{
                                instructionCount = $gitInstructionValue
                                commands = @($safeCommandValues)
                            })
                        }
                    }
                    else {
                        $commandFileOperations = @((Get-PropertyValue -Object $journalEvent -Name 'fileOperations' -Default @()))
                        if ($commandFileOperations.Count -eq 0 -and $preToolById.ContainsKey($toolUseId)) {
                            $commandFileOperations = @((Get-PropertyValue -Object $preToolById[$toolUseId] -Name 'fileOperations' -Default @()))
                        }
                        foreach ($operation in $commandFileOperations) { $fileOperations.Add($operation) }

                        Add-OrderedCount -Counts $otherCounts -Order $otherOrder -Name 'Shell命令'
                        if ($includeShellCommandDetails -and $shellRuns.Count -lt $maxCommandRuns -and $safeCommandValues.Count -gt 0) {
                            $shellRuns.Add([PSCustomObject][ordered]@{
                                commands = @($safeCommandValues)
                            })
                        }
                    }
                    continue
                }

                if (Test-IsApplyPatchTool -ToolName $toolName) {
                    $editOperationCount++
                    if ($eventScope -eq 'root') { $rootEditIds[$toolUseId] = $true } else { $childEditIds[$toolUseId] = $true }
                    $operations = @((Get-PropertyValue -Object $journalEvent -Name 'fileOperations' -Default @()))
                    if ($operations.Count -eq 0 -and $preToolById.ContainsKey($toolUseId)) {
                        $operations = @((Get-PropertyValue -Object $preToolById[$toolUseId] -Name 'fileOperations' -Default @()))
                    }
                    if ($operations.Count -eq 0) {
                        $unparsedEditOperationCount++
                    }
                    elseif ($false -ne (Get-PropertyValue -Object $journalEvent -Name 'success' -Default $true)) {
                        foreach ($operation in $operations) {
                            $fileOperations.Add($operation)
                            foreach ($property in @('pathId','sourceId','targetId')) {
                                $pathId=[string](Get-PropertyValue -Object $operation -Name $property -Default '')
                                if (-not $pathId) { continue }
                                $key=$eventScope+"`n"+$pathId
                                if (-not $fileEditsByPath.ContainsKey($key)) { $fileEditsByPath[$key]=@{scope=$eventScope;pathId=$pathId;ids=@{}} }
                                $fileEditsByPath[$key].ids[$toolUseId]=$true
                            }
                        }
                    }
                    continue
                }

                if ($toolName.StartsWith('mcp__', [StringComparison]::OrdinalIgnoreCase)) {
                    Add-OrderedCount -Counts $mcpCounts -Order $mcpOrder -Name (Convert-McpToolName -ToolName $toolName)
                }
                elseif (-not (Test-IsAgentManagementTool -ToolName $toolName)) {
                    Add-OrderedCount -Counts $otherCounts -Order $otherOrder -Name (Get-ToolAlias -ToolName $toolName)
                }
            }
            'PermissionRequest' {
                if ([bool](Get-ConfigValue -Config $config -Path @('collection', 'includePermissionRequests') -Default $true)) {
                    Add-OrderedCount -Counts $otherCounts -Order $otherOrder -Name '权限请求'
                }
            }
            'PostCompact' {
                if ([bool](Get-ConfigValue -Config $config -Path @('collection', 'includeCompaction') -Default $true)) {
                    Add-OrderedCount -Counts $otherCounts -Order $otherOrder -Name '上下文压缩'
                }
            }
            'SubagentStart' {
                $agentId = [string](Get-PropertyValue -Object $journalEvent -Name 'agentId' -Default '')
                if ([string]::IsNullOrWhiteSpace($agentId)) {
                    $syntheticAgentIndex++
                    $agentId = 'agent-synthetic-' + $syntheticAgentIndex
                }
                if (-not $agentsById.ContainsKey($agentId)) {
                    $agentsById[$agentId] = [ordered]@{
                        type = Sanitize-DisplayName -Value (Get-PropertyValue -Object $journalEvent -Name 'agentType' -Default '') -Fallback '未命名Agent'
                        started = $true
                        stopped = $false
                    }
                    $null = $agentIdOrder.Add($agentId)
                }
                else {
                    $agentsById[$agentId].started = $true
                }
            }
            'SubagentStop' {
                $agentId = [string](Get-PropertyValue -Object $journalEvent -Name 'agentId' -Default '')
                if ([string]::IsNullOrWhiteSpace($agentId)) {
                    $syntheticAgentIndex++
                    $agentId = 'agent-synthetic-' + $syntheticAgentIndex
                }
                if (-not $agentsById.ContainsKey($agentId)) {
                    $agentsById[$agentId] = [ordered]@{
                        type = Sanitize-DisplayName -Value (Get-PropertyValue -Object $journalEvent -Name 'agentType' -Default '') -Fallback '未命名Agent'
                        started = $false
                        stopped = $true
                    }
                    $null = $agentIdOrder.Add($agentId)
                }
                else {
                    $agentsById[$agentId].stopped = $true
                    $incomingType = Sanitize-DisplayName -Value (Get-PropertyValue -Object $journalEvent -Name 'agentType' -Default '') -Fallback '未命名Agent'
                    if (((Test-V21WeakAgentType -Value $agentsById[$agentId].type) -or
                        (Get-PropertyValue -Object $journalEvent -Name 'agentDisplayNameSource') -eq 'child-session-metadata') -and
                        -not (Test-V21WeakAgentType -Value $incomingType)) {
                        $agentsById[$agentId].type = $incomingType
                    }
                }

                $scopeKey = 'agent:' + $agentId
                foreach ($name in @((Get-PropertyValue -Object $journalEvent -Name 'transcriptSkills' -Default @()))) {
                    Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey $scopeKey -Source '子Agent会话记录－实际注入' -Level 'confirmed' -Priority 50
                }
                foreach ($name in @((Get-PropertyValue -Object $journalEvent -Name 'commandReadSkills' -Default @()))) {
                    Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey $scopeKey -Source '子Agent命令记录－读取 SKILL.md' -Level 'read' -Priority 30
                }
                foreach ($name in @((Get-PropertyValue -Object $journalEvent -Name 'structuredSkills' -Default @()))) {
                    Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey $scopeKey -Source '子Agent结构化Skill输入' -Level 'confirmed' -Priority 40
                }
                if (-not $subagentTranscriptById.ContainsKey($agentId)) {
                    $subagentTranscriptById[$agentId] = [ordered]@{
                        status = [string](Get-PropertyValue -Object $journalEvent -Name 'skillTranscriptStatus' -Default '不可用')
                        readSucceeded = [bool](Get-PropertyValue -Object $journalEvent -Name 'skillTranscriptReadSucceeded' -Default $false)
                    }
                }
            }
        }
    }

    foreach ($name in @((Get-PropertyValue -Object $State -Name 'explicitSkills' -Default @()))) {
        Add-SkillEvidence -EvidenceByKey $skillEvidenceByKey -EvidenceOrder $skillEvidenceOrder -NameValue $name -ScopeKey 'root' -Source '显式标记回退' -Level 'requested' -Priority 10
    }

    $confirmedEvidence = 0
    $readEvidence = 0
    $requestedEvidence = 0
    foreach ($key in $skillEvidenceOrder) {
        $evidence = $skillEvidenceByKey[$key]
        Add-OrderedCount -Counts $skillCounts -Order $skillOrder -Name ([string]$evidence.name)
        if (-not $skillSources.Contains([string]$evidence.source)) { $skillSources.Add([string]$evidence.source) }
        switch ([string]$evidence.level) {
            'confirmed' { $confirmedEvidence++ }
            'read' { $readEvidence++ }
            default { $requestedEvidence++ }
        }
    }

    foreach ($toolUseId in $preToolById.Keys) {
        if (-not $completedToolIds.ContainsKey($toolUseId)) {
            Add-OrderedCount -Counts $otherCounts -Order $otherOrder -Name '未确认调用'
        }
    }

    $unfinishedAgents = 0
    foreach ($agentId in $agentIdOrder) {
        $agent = $agentsById[$agentId]
        Add-OrderedCount -Counts $agentCounts -Order $agentOrder -Name ([string]$agent.type)
        if (-not [bool]$agent.stopped) { $unfinishedAgents++ }
    }
    # v1.7+：缺少 SubagentStop 不再视为未完成；SubagentStart 即为计数依据。

    $fileTrackingEnabled = [bool](Get-ConfigValue -Config $config -Path @('fileTracking','enabled') -Default $true)
    $nativeChanges = if ($fileTrackingEnabled) { @((Get-PropertyValue -Object $ActivityObservation -Name 'FileChanges' -Default @())) } else { @() }
    $requiredEdits=@($fileEditsByPath.Values | ForEach-Object { [pscustomobject]@{scope=$_.scope;pathId=$_.pathId;count=$_.ids.Count} })
    $fileSummary = Get-NativeFileChangeSummary -Changes @($nativeChanges) -Cwd ([string](Get-PropertyValue -Object $StopPayload -Name 'cwd' -Default '')) -RequiredEdits $requiredEdits

    $fileCounts = @{}
    $fileOrder = [System.Collections.ArrayList]::new()
    if ([int]$fileSummary.Added -gt 0) { Add-OrderedCount -Counts $fileCounts -Order $fileOrder -Name '新增' -Increment ([int]$fileSummary.Added) }
    if ([int]$fileSummary.Modified -gt 0) { Add-OrderedCount -Counts $fileCounts -Order $fileOrder -Name '修改' -Increment ([int]$fileSummary.Modified) }
    if ([int]$fileSummary.Deleted -gt 0) { Add-OrderedCount -Counts $fileCounts -Order $fileOrder -Name '删除' -Increment ([int]$fileSummary.Deleted) }

    $fileSources = [System.Collections.Generic.List[string]]::new()
    $fileSources.Add('成功 FileChange 记录与涉及文件内容核验')
    $fileReasons = [Collections.Generic.List[string]]::new()
    foreach ($reason in @($fileSummary.Reasons) + @((Get-PropertyValue -Object $ActivityObservation -Name 'Reasons' -Default @()))) { if ($reason -and -not $fileReasons.Contains([string]$reason)) { $fileReasons.Add([string]$reason) } }
    if ($null -eq $ActivityObservation) { $fileReasons.Add('文件变更记录不可用') }
    # 压缩可能先创建状态；后到的用户输入已有计数，不能仅凭创建来源判断缺失。
    if ([int](Get-PropertyValue -Object $State -Name 'promptCount' -Default 0) -le 0 -and
        [string](Get-PropertyValue -Object $State -Name 'startSource') -ne 'UserPromptSubmit') { $fileReasons.Add('缺少本次回答的起始记录') }
    $knownPaths = @{}; foreach ($id in $fileSummary.PathIds) { $knownPaths[$id]=$true }
    foreach ($operation in $fileOperations) {
        foreach ($property in @('pathId','sourceId','targetId')) {
            $id=[string](Get-PropertyValue -Object $operation -Name $property -Default '')
            if ($id -and -not $knownPaths.ContainsKey($id) -and -not $fileReasons.Contains('存在未匹配原生记录的编辑或移动事件')) { $fileReasons.Add('存在未匹配原生记录的编辑或移动事件') }
        }
    }
    $fileIncomplete = $fileReasons.Count -gt 0 -or $fileSummary.Unknown -gt 0
    $transcriptEdits = [int](Get-PropertyValue -Object $ActivityObservation -Name 'EditCount' -Default 0)
    $editOperationCount = $childEditIds.Count + [Math]::Max($rootEditIds.Count, $transcriptEdits)
    $editOperationLowerBound = $false
    if ($rootEditIds.Count -gt 0 -and $transcriptEdits -gt 0) {
        $matchedEdits = 0
        foreach ($id in @((Get-PropertyValue -Object $ActivityObservation -Name 'EditIds' -Default @()))) {
            if ($rootEditIds.ContainsKey("root`n" + $id)) { $matchedEdits++ }
        }
        $editOperationLowerBound = $matchedEdits -ne $rootEditIds.Count -or $matchedEdits -ne $transcriptEdits
    }
    if (Get-PropertyValue -Object $ActivityObservation -Name 'Incomplete' -Default $false) {
        $fileIncomplete = $true
        if ($fileReasons.Count -eq 0) { $fileReasons.Add('原生文件变更记录不完整') }
    }
    if (-not $fileTrackingEnabled) { $fileIncomplete=$false; $fileReasons.Clear() }

    $startText = [string](Get-PropertyValue -Object $State -Name 'startedAt' -Default '')
    $startedAt = $EndedAt
    $hasReliableStart = $false
    if (-not [string]::IsNullOrWhiteSpace($startText)) {
        try {
            $startedAt = [DateTimeOffset]::Parse($startText, [Globalization.CultureInfo]::InvariantCulture)
            $hasReliableStart = $true
        }
        catch { }
    }

    $durationMs = -1.0
    $startTicksText = [string](Get-PropertyValue -Object $State -Name 'startMonotonicTicks' -Default '')
    $frequencyText = [string](Get-PropertyValue -Object $State -Name 'stopwatchFrequency' -Default '')
    [Int64]$startTicks = 0
    [Int64]$frequency = 0
    if ([Int64]::TryParse($startTicksText, [ref]$startTicks) -and [Int64]::TryParse($frequencyText, [ref]$frequency) -and $frequency -gt 0) {
        $durationMs = (($EndMonotonicTicks - $startTicks) * 1000.0) / $frequency
    }
    elseif ($hasReliableStart) {
        $durationMs = ($EndedAt - $startedAt).TotalMilliseconds
    }
    if ($hasReliableStart) {
        $durationMs = [Math]::Max(0, ($EndedAt - $startedAt).TotalMilliseconds)
    }
    if ($TestDurationMilliseconds -ge 0) { $durationMs = $TestDurationMilliseconds }

    $labels = Get-ConfigValue -Config $config -Path @('display', 'labels') -Default $null
    $labelMcp = 'MCP'; $labelSkill = 'Skill'; $labelAgent = '子Agent'; $labelFile = '文件'; $labelGit = 'Git'; $labelOther = '其他'
    if ($null -ne $labels) {
        $labelMcp = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'mcp' -Default $labelMcp) -Fallback $labelMcp
        $labelSkill = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'skill' -Default $labelSkill) -Fallback $labelSkill
        $labelAgent = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'subagent' -Default $labelAgent) -Fallback $labelAgent
        $labelFile = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'file' -Default $labelFile) -Fallback $labelFile
        $labelGit = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'git' -Default $labelGit) -Fallback $labelGit
        $labelOther = Sanitize-DisplayName -Value (Get-PropertyValue -Object $labels -Name 'other' -Default $labelOther) -Fallback $labelOther
    }

    $emptyValue = Sanitize-DisplayName -Value (Get-ConfigValue -Config $config -Path @('display', 'emptyValue') -Default '无') -Fallback '无'
    $highlightStyle = Get-HighlightStyle
    $icons = Get-ConfigValue -Config $config -Path @('display', 'icons') -Default $null
    $iconMcp = '🔌'; $iconSkill = '🧩'; $iconAgent = '🤖'; $iconFile = '📝'; $iconGit = '🌿'; $iconOther = '⚙️'
    if ($null -ne $icons) {
        $iconMcp = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'mcp' -Default $iconMcp) -Fallback $iconMcp
        $iconSkill = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'skill' -Default $iconSkill) -Fallback $iconSkill
        $iconAgent = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'subagent' -Default $iconAgent) -Fallback $iconAgent
        $iconFile = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'file' -Default $iconFile) -Fallback $iconFile
        $iconGit = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'git' -Default $iconGit) -Fallback $iconGit
        $iconOther = Sanitize-DisplayName -Value (Get-PropertyValue -Object $icons -Name 'other' -Default $iconOther) -Fallback $iconOther
    }

    $status = Resolve-TurnStatus -StopPayload $StopPayload
    $endDisplay = Format-DisplayTime -Time $EndedAt -OtherTime $startedAt
    $durationDisplay = Format-Duration -Milliseconds $durationMs
    $firstLine = "🔴 结束：$endDisplay（用时：$durationDisplay）"
    $showSuccessStatus = [bool](Get-ConfigValue -Config $config -Path @('display', 'showSuccessStatus') -Default $false)
    if ($status.Code -ne 'completed' -or $showSuccessStatus) { $firstLine += '｜状态：' + $status.Display }

    $mcpClientLine = Format-CountLine -Label $labelMcp -Counts $mcpCounts -Order $mcpOrder -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconMcp
    $skillClientLine = Format-CountLine -Label $labelSkill -Counts $skillCounts -Order $skillOrder -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconSkill
    $agentClientLine = Format-CountLine -Label $labelAgent -Counts $agentCounts -Order $agentOrder -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconAgent
    $fileClientLine = Format-CountLine -Label $labelFile -Counts $fileCounts -Order $fileOrder -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconFile
    $gitClientLine = Format-GitLine -Label $labelGit -RunCount $gitRunCount -InstructionCount $gitInstructionCount -ChangeCount $gitChangeCount -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconGit
    $otherClientLine = Format-CountLine -Label $labelOther -Counts $otherCounts -Order $otherOrder -EmptyValue $emptyValue -HighlightStyle $highlightStyle -Icon $iconOther

    $mcpLogLine = Format-CountLine -Label $labelMcp -Counts $mcpCounts -Order $mcpOrder -EmptyValue $emptyValue
    $skillLogLine = Format-CountLine -Label $labelSkill -Counts $skillCounts -Order $skillOrder -EmptyValue $emptyValue
    $agentLogLine = Format-CountLine -Label $labelAgent -Counts $agentCounts -Order $agentOrder -EmptyValue $emptyValue
    $fileLogLine = Format-CountLine -Label $labelFile -Counts $fileCounts -Order $fileOrder -EmptyValue $emptyValue
    $gitLogLine = Format-GitLine -Label $labelGit -RunCount $gitRunCount -InstructionCount $gitInstructionCount -ChangeCount $gitChangeCount -EmptyValue $emptyValue
    $otherLogLine = Format-CountLine -Label $labelOther -Counts $otherCounts -Order $otherOrder -EmptyValue $emptyValue

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($fileIncomplete) {
        if ($fileOrder.Count -eq 0) { $fileClientLine = Format-CountLine -Label $labelFile -Counts $fileCounts -Order $fileOrder -EmptyValue '未确认' -HighlightStyle $highlightStyle -Icon $iconFile }
        $fileClientLine += '（统计不完整）'
    }
    $lines.Add($firstLine)
    $hideEmptyCategories = [bool](Get-ConfigValue -Config $config -Path @('display', 'hideEmptyCategories') -Default $true)
    if (-not $hideEmptyCategories -or $mcpOrder.Count -gt 0) { $lines.Add($mcpClientLine) }
    if (-not $hideEmptyCategories -or $skillOrder.Count -gt 0) { $lines.Add($skillClientLine) }
    if (-not $hideEmptyCategories -or $agentOrder.Count -gt 0) { $lines.Add($agentClientLine) }
    if (-not $hideEmptyCategories -or $fileOrder.Count -gt 0 -or $fileIncomplete) { $lines.Add($fileClientLine) }
    if (-not $hideEmptyCategories -or $gitRunCount -gt 0) { $lines.Add($gitClientLine) }
    if (-not $hideEmptyCategories -or $otherOrder.Count -gt 0) { $lines.Add($otherClientLine) }

    $coverageLimitations = @(
        'Skill 依赖结构化注入、transcript 或 SKILL.md 读取证据，格式变化或缺失可能导致遗漏',
        '托管工具可能没有完整的标准 Hook 事件',
        '文件仅统计成功 FileChange 记录；未报告变更的工具可能遗漏，文本比较统一 CRLF/LF，不保存原文或补丁',
        '命令日志只保存安全处理后的内容，疑似敏感或无法安全解析的参数会被隐藏'
    )
    $coverageText = '部分｜' + ($coverageLimitations -join '；')
    if ([bool](Get-ConfigValue -Config $config -Path @('display', 'showCoverageNotice') -Default $false)) {
        $lines.Add('统计范围：' + $coverageText)
    }

    $summary = if ([bool](Get-ConfigValue -Config $config -Path @('display', 'multiline') -Default $true)) { $lines -join "`n" } else { $lines -join '｜' }

    $skillEvidenceLevel = '无'
    $evidenceLabels = [System.Collections.Generic.List[string]]::new()
    if ($confirmedEvidence -gt 0) { $evidenceLabels.Add('已确认') }
    if ($readEvidence -gt 0) { $evidenceLabels.Add('已读取') }
    if ($requestedEvidence -gt 0) { $evidenceLabels.Add('已请求') }
    if ($evidenceLabels.Count -eq 1) {
        $skillEvidenceLevel = [string]$evidenceLabels[0]
        if ([string]::Equals($skillEvidenceLevel, '已请求', [StringComparison]::Ordinal)) {
            $skillEvidenceLevel = '已请求，未确认注入'
        }
    }
    elseif ($evidenceLabels.Count -gt 1) {
        $skillEvidenceLevel = '混合（' + ($evidenceLabels -join ' + ') + '）'
    }

    $skillCollectionSource = if ($skillSources.Count -gt 0) { $skillSources -join ' + ' } else { '未发现实际注入、SKILL.md读取或有效显式标记' }
    $mainTranscriptStatus = Convert-TranscriptStatusDisplay -Observation $MainSkillObservation
    $subagentTranscriptTotal = $subagentTranscriptById.Count
    $subagentTranscriptRead = 0
    foreach ($agentId in $subagentTranscriptById.Keys) {
        if ([bool]$subagentTranscriptById[$agentId].readSucceeded) { $subagentTranscriptRead++ }
    }
    $subagentTranscriptText = if ($subagentTranscriptTotal -eq 0) { '无' } else { "已读取 $subagentTranscriptRead/$subagentTranscriptTotal" }
    $skillTranscriptStatus = "主任务=$mainTranscriptStatus；子Agent=$subagentTranscriptText"

    return [PSCustomObject]@{
        Summary = $summary
        StartedAt = $startedAt
        EndedAt = $EndedAt
        DurationDisplay = $durationDisplay
        DurationMilliseconds = $durationMs
        Status = $status.Display
        StatusCode = $status.Code
        StatusSource = $status.Source
        McpLine = $mcpLogLine
        SkillLine = $skillLogLine
        AgentLine = $agentLogLine
        FileLine = $fileLogLine
        GitLine = $gitLogLine
        OtherLine = $otherLogLine
        McpItems = @(Get-CountItems -Counts $mcpCounts -Order $mcpOrder)
        SkillItems = @(Get-CountItems -Counts $skillCounts -Order $skillOrder)
        AgentItems = @(Get-CountItems -Counts $agentCounts -Order $agentOrder)
        FileItems = @(Get-CountItems -Counts $fileCounts -Order $fileOrder)
        GitRunCount = $gitRunCount
        GitInstructionCount = $gitInstructionCount
        GitChangeCount = $gitChangeCount
        GitRuns = @($gitRuns)
        OtherItems = @(Get-CountItems -Counts $otherCounts -Order $otherOrder)
        ShellRuns = @($shellRuns)
        CommandLoggingMode = $commandLoggingMode
        EmptyValue = $emptyValue
        FileChangeCount = [int]$fileSummary.Total
        InputCount = [int](Get-PropertyValue -Object $State -Name 'promptCount' -Default 0)
        PromptPreparationMs = [long](Get-PropertyValue -Object $State -Name 'promptPreparationMs' -Default 0)
        PromptLockWaitMs = [long](Get-PropertyValue -Object $State -Name 'promptLockWaitMs' -Default 0)
        EditOperationCount = $editOperationCount
        EditOperationLowerBound = $editOperationLowerBound
        UnparsedEditOperationCount = $unparsedEditOperationCount
        FileCollectionSource = ($fileSources -join ' + ')
        FileCoverage = $(if ($fileIncomplete) { '部分' } else { '已采集原生记录范围内已核验' })
        FileCoverageReasons = @($fileReasons)
        SkillCollectionMode = '多源识别'
        SkillCollectionSource = $skillCollectionSource
        SkillEvidenceLevel = $skillEvidenceLevel
        SkillParserVersion = 3
        SkillTranscriptStatus = $skillTranscriptStatus
        SkillCoverage = '部分'
        Coverage = '部分'
        CoverageText = $coverageText
        CoverageLimitations = @($coverageLimitations)
        ProgramVersion = $ProgramVersion
    }
}

function Complete-PendingSummary {
    param([object]$Completed, [switch]$Retry)

    if (-not [bool](Get-PropertyValue -Object $Completed -Name 'logPending' -Default $false)) {
        return [pscustomobject]@{Summary=[string]$Completed.summary}
    }
    $built = Get-PropertyValue -Object $Completed -Name 'pendingSummary' -Default $null
    foreach ($name in @('StartedAt', 'EndedAt')) {
        Set-PropertyValue -Object $built -Name $name -Value ([DateTimeOffset]::Parse([string](Get-PropertyValue -Object $built -Name $name), [Globalization.CultureInfo]::InvariantCulture))
    }
    try {
        $logPath = Write-DailyLog -SummaryObject $built -Retry:$Retry
    }
    catch {
        Write-DebugRecord -Message '每日日志写入失败，已保留待补写汇总。' -ExceptionObject $_.Exception
        return [pscustomobject]@{Summary=([string]$Completed.summary + '｜日志写入失败，统计已保留，等待重试')}
    }

    $done = [ordered]@{}
    foreach ($name in @('schemaVersion', 'programVersion', 'sessionId', 'turnId', 'completedAt', 'status', 'statusSource', 'summary')) {
        $done[$name] = Get-PropertyValue -Object $Completed -Name $name
    }
    $done.logFileName = if ($logPath) { [IO.Path]::GetFileName($logPath) } else { $null }
    Write-Utf8FileAtomic -Path $completedPath -Content ($done | ConvertTo-Json -Compress -Depth 10)
    Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
    foreach ($hash in @((Get-PropertyValue -Object $Completed -Name 'mergedRunHashes' -Default @()))) {
        if ([string]$hash -notmatch '^[a-f0-9]{64}$') { continue }
        Remove-Item -LiteralPath (Join-Path $stateRoot ($hash + '.json')) -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $journalRoot ($hash + '.jsonl')) -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{Summary=[string]$done.summary}
}


function Write-DailyLog {
    param([object]$SummaryObject, [switch]$Retry)

    if (-not [bool](Get-ConfigValue -Config $config -Path @('logging', 'enabled') -Default $true)) {
        return $null
    }

    $prefix = Sanitize-FileNameComponent -Value (Get-ConfigValue -Config $config -Path @('logging', 'filePrefix') -Default 'codex-task') -Fallback 'codex-task'
    $fileName = $prefix + '-' + $SummaryObject.EndedAt.ToLocalTime().ToString('yyyy-MM-dd') + '.log'
    $logPath = Join-Path $logsRoot $fileName
    $completionMarker = '记录完成：' + $runHash

    $startFull = $SummaryObject.StartedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    $endFull = $SummaryObject.EndedAt.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    $recordedAt = [DateTimeOffset]::Now.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    $durationMillisecondsText = [Math]::Round([double]$SummaryObject.DurationMilliseconds, 0, [MidpointRounding]::AwayFromZero).ToString('0', [Globalization.CultureInfo]::InvariantCulture)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('================================================================================')
    $lines.Add('【任务信息】')
    $lines.Add('程序版本：' + $SummaryObject.ProgramVersion)
    $lines.Add('记录时间：' + $recordedAt)
    $lines.Add('session_id：' + $SessionId)
    $lines.Add('turn_id：' + $TurnId)
    $lines.Add('开始时间：' + $startFull)
    $lines.Add('结束时间：' + $endFull)
    $lines.Add('原始用时毫秒：' + $durationMillisecondsText)
    $lines.Add('用时：' + $SummaryObject.DurationDisplay)
    if ([int](Get-PropertyValue -Object $SummaryObject -Name 'InputCount' -Default 0) -gt 0) {
        $lines.Add('本次回答输入次数：' + $SummaryObject.InputCount)
        $lines.Add('末次输入准备/锁等待毫秒：' + $SummaryObject.PromptPreparationMs + '/' + $SummaryObject.PromptLockWaitMs)
    }
    $lines.Add('')

    $lines.Add('【执行结果】')
    $lines.Add('状态：' + $SummaryObject.Status)
    $lines.Add('状态来源：' + $SummaryObject.StatusSource)
    $lines.Add('恢复补记：否')
    $lines.Add('')

    $lines.Add('【调用统计】')
    Add-LogCountCategory -Lines $lines -Label 'MCP' -Items @($SummaryObject.McpItems) -EmptyValue $SummaryObject.EmptyValue
    $lines.Add('')
    Add-LogCountCategory -Lines $lines -Label 'Skill' -Items @($SummaryObject.SkillItems) -EmptyValue $SummaryObject.EmptyValue
    $lines.Add('')
    Add-LogCountCategory -Lines $lines -Label '子Agent' -Items @($SummaryObject.AgentItems) -EmptyValue $SummaryObject.EmptyValue
    $lines.Add('')
    Add-LogGitCategory -Lines $lines -Label 'Git' -ChangeCount ([int]$SummaryObject.GitChangeCount) -RunCount ([int]$SummaryObject.GitRunCount) -InstructionCount ([int]$SummaryObject.GitInstructionCount) -Runs @($SummaryObject.GitRuns) -EmptyValue $SummaryObject.EmptyValue
    $lines.Add('')
    Add-LogCountCategory -Lines $lines -Label '其他' -Items @($SummaryObject.OtherItems) -EmptyValue $SummaryObject.EmptyValue
    Add-LogShellCommandDetails -Lines $lines -Runs @($SummaryObject.ShellRuns)
    if ([string]::Equals([string]$SummaryObject.CommandLoggingMode, 'off', [StringComparison]::OrdinalIgnoreCase)) {
        $lines.Add('命令记录策略：off（不保存命令明细，原始命令不落盘）')
    }
    else {
        $lines.Add('命令记录策略：safe（仅保存安全处理后的内容，原始命令不落盘）')
    }
    $lines.Add('')

    $lines.Add('【文件变更】')
    Add-LogCountCategory -Lines $lines -Label '文件' -Items @($SummaryObject.FileItems) -EmptyValue $SummaryObject.EmptyValue
    $lines.Add('文件变更总数：' + $SummaryObject.FileChangeCount)
    if (Get-PropertyValue -Object $SummaryObject -Name 'EditOperationLowerBound' -Default $false) {
        $lines.Add('编辑操作次数：至少 ' + $SummaryObject.EditOperationCount + '（跨来源去重证据不足）')
    } else { $lines.Add('编辑操作次数：' + $SummaryObject.EditOperationCount) }
    $lines.Add('未解析编辑操作：' + $SummaryObject.UnparsedEditOperationCount)
    $lines.Add('文件采集来源：' + $SummaryObject.FileCollectionSource)
    $lines.Add('文件统计完整性：' + $SummaryObject.FileCoverage)
    foreach ($reason in @((Get-PropertyValue -Object $SummaryObject -Name 'FileCoverageReasons' -Default @()))) { $lines.Add('文件统计限制：' + [string]$reason) }
    $lines.Add('')

    $lines.Add('【Skill采集】')
    $lines.Add('采集模式：' + $SummaryObject.SkillCollectionMode)
    $lines.Add('采集来源：' + $SummaryObject.SkillCollectionSource)
    $lines.Add('证据等级：' + $SummaryObject.SkillEvidenceLevel)
    $lines.Add('解析器版本：' + $SummaryObject.SkillParserVersion)
    $lines.Add('会话记录解析：' + $SummaryObject.SkillTranscriptStatus)
    $lines.Add('统计完整性：' + $SummaryObject.SkillCoverage)
    $lines.Add('')

    $lines.Add('【统计完整性】')
    $lines.Add('总体完整性：' + $SummaryObject.Coverage)
    $lines.Add('限制说明：')
    foreach ($limitation in @($SummaryObject.CoverageLimitations)) {
        $lines.Add('  - ' + [string]$limitation)
    }
    $lines.Add('================================================================================')
    $lines.Add($completionMarker)
    $lines.Add('')

    $block = $lines -join [Environment]::NewLine
    $null = Invoke-WithMutex -Name $dailyLogMutexName -TimeoutMs 5000 -ScriptBlock {
        if ($Retry -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            $reader = [IO.StreamReader]::new($logPath, [Text.Encoding]::UTF8)
            try {
                while ($null -ne ($line = $reader.ReadLine())) {
                    if ($line -eq $completionMarker) { return }
                }
            }
            finally { $reader.Dispose() }
        }
        $stream = [IO.FileStream]::new($logPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $initialLength = $stream.Length
        try {
            $writer = [IO.StreamWriter]::new($stream, $Utf8NoBom, 1024, $true)
            try {
                $writer.Write($block)
                $writer.Flush()
                $stream.Flush($true)
            }
            finally { $writer.Dispose() }
        }
        catch {
            # Roll back a partial append so a later retry writes one full block.
            try { $stream.SetLength($initialLength) } catch { }
            throw
        }
        finally { $stream.Dispose() }
    }

    return $logPath
}

try {
    switch ($Event) {
        'UserPromptSubmit' {
            $preparedState = $null
            if ($null -eq (Read-JsonFile -Path $statePath)) {
                $preparedState = New-RunState -StartedAt $eventReceivedAt -StartMonotonicTicks ([Diagnostics.Stopwatch]::GetTimestamp()) -StartSource 'UserPromptSubmit'
            }
            $preparedAtMs = $eventWatch.ElapsedMilliseconds
            $skills = @(Get-ExplicitSkillNames -PromptValue (Get-PropertyValue -Object $Payload -Name 'prompt' -Default ''))
            $structuredSkills = @(Get-StructuredSkillNames -Value $Payload -Strict)
            $state = Invoke-WithMutex -Name $runMutexName -TimeoutMs 1000 -ScriptBlock {
                $existing = Read-JsonFile -Path $statePath
                if ($null -eq $existing) {
                    $existing = [pscustomobject]$preparedState
                }
                # Count only prompts in this turn, atomically with the existing baseline.
                # A separate name prevents importing the old session-wide inputCount.
                Set-PropertyValue -Object $existing -Name 'promptCount' -Value (1 + [int](Get-PropertyValue -Object $existing -Name 'promptCount' -Default 0))
                Set-PropertyValue -Object $existing -Name 'promptPreparationMs' -Value $preparedAtMs
                Set-PropertyValue -Object $existing -Name 'promptLockWaitMs' -Value ($eventWatch.ElapsedMilliseconds - $preparedAtMs)
                $existing = Merge-SkillNamesIntoState -State $existing -PropertyName 'explicitSkills' -SkillNames $skills
                $existing = Merge-SkillNamesIntoState -State $existing -PropertyName 'structuredSkills' -SkillNames $structuredSkills
                if ([string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $existing -Name 'transcriptIdentityHash' -Default ''))) {
                    $baseline = Get-TranscriptBaselineMetadata -PathValue (Get-PropertyValue -Object $Payload -Name 'transcript_path' -Default $null)
                    Set-PropertyValue -Object $existing -Name 'transcriptIdentityHash' -Value ([string]$baseline.IdentityHash)
                    Set-PropertyValue -Object $existing -Name 'transcriptBaselineBytes' -Value (([Int64]$baseline.BaselineBytes).ToString([Globalization.CultureInfo]::InvariantCulture))
                    Set-PropertyValue -Object $existing -Name 'transcriptBaselineCaptured' -Value (-not [string]::IsNullOrWhiteSpace([string]$baseline.IdentityHash))
                    Set-PropertyValue -Object $existing -Name 'transcriptExistedAtStart' -Value ([bool]$baseline.Available)
                }
                Set-PropertyValue -Object $existing -Name 'programVersion' -Value $ProgramVersion
                Set-PropertyValue -Object $existing -Name 'schemaVersion' -Value 11
                Write-Utf8FileAtomic -Path $statePath -Content ($existing | ConvertTo-Json -Compress -Depth 10)
                return Read-JsonFile -Path $statePath
            }

            Write-DebugRecord -Message ('输入处理阶段用时毫秒：准备=' + $preparedAtMs + '；加锁及写入=' + ($eventWatch.ElapsedMilliseconds - $preparedAtMs))
            $inputMessage = if ([int]$state.promptCount -eq 1) { '🟢 开始：' } else { '第 ' + $state.promptCount + ' 次输入：' }
            Write-HookJsonOutput -SystemMessage ($inputMessage + $eventReceivedAt.ToLocalTime().ToString('HH:mm:ss'))
            exit 0
        }

        'Stop' {
            $existingCompleted = $null
            try { $existingCompleted = Read-JsonFile -Path $completedPath } catch { }
            if ($null -ne $existingCompleted) {
                $result = Invoke-WithMutex -Name $runMutexName -TimeoutMs 10000 -ScriptBlock {
                    Complete-PendingSummary -Completed (Read-JsonFile -Path $completedPath) -Retry
                }
                Write-HookJsonOutput -SystemMessage ([string]$result.Summary)
                exit 0
            }

            Wait-ForJournalSettle
            $summaryObject = $null
            $stateForSkillObservation = $null
            try { $stateForSkillObservation = Read-JsonFile -Path $statePath } catch { }
            $mainSkillObservation = Get-MainTranscriptSkillObservation -State $stateForSkillObservation -StopPayload $Payload
            $activityObservation = Get-MainTranscriptActivityObservation -State $stateForSkillObservation -StopPayload $Payload

            $summaryObject = Invoke-WithMutex -Name $runMutexName -TimeoutMs 10000 -ScriptBlock {
                $done = $null
                try { $done = Read-JsonFile -Path $completedPath } catch { }
                if ($null -ne $done) {
                    return Complete-PendingSummary -Completed $done -Retry
                }

                $state = Ensure-RunState -Source 'inferred-from-stop'
                $events = Read-JournalEvents
                $events = @($events) + @($activityObservation.Events)
                # v1.7+：SubagentStart/child tool events use a child turn_id. The original
                # run key split them into orphan journals, so merge only same-session
                # child journals whose SubagentStart falls inside this root task window.
                $v17RelatedSubagentData = Get-V17RelatedSubagentJournalData `
                    -JournalDirectory ([System.IO.Path]::GetDirectoryName($journalPath)) `
                    -StateDirectory ([System.IO.Path]::GetDirectoryName($statePath)) `
                    -CompletedDirectory ([System.IO.Path]::GetDirectoryName($completedPath)) `
                    -RootJournalPath $journalPath `
                    -SessionId $SessionId `
                    -RootTurnId $TurnId `
                    -RootEvents @($events) `
                    -StopTimeUtc ([DateTime]::UtcNow)
                if ($null -ne $v17RelatedSubagentData -and @($v17RelatedSubagentData.Events).Count -gt 0) {
                    $events = Sort-V17JournalEvents -Events (@($events) + @($v17RelatedSubagentData.Events))
                }
                # v1.7+ fallback is used only when no lifecycle SubagentStart exists and
                # a successful Collaboration spawn has explicit success evidence.
                $events = Add-V17SpawnFallbackSubagentEvents -Events @($events)

                $endedAt = $eventReceivedAt
                $endTicks = [Diagnostics.Stopwatch]::GetTimestamp()
                $activityObservation = Add-ChildFileActivity -Observation $activityObservation -Events $events -State $state -StopPayload $Payload -EndedAt $endedAt
                $built = Build-Summary -State $state -Events $events -EndedAt $endedAt -EndMonotonicTicks $endTicks -StopPayload $Payload -MainSkillObservation $mainSkillObservation -ActivityObservation $activityObservation

                $completed = [ordered]@{
                    schemaVersion = 11
                    programVersion = $ProgramVersion
                    sessionId = $SessionId
                    turnId = $TurnId
                    completedAt = $endedAt.ToString('o')
                    status = $built.Status
                    statusSource = $built.StatusSource
                    summary = $built.Summary
                    logPending = $true
                    pendingSummary = $built
                    mergedRunHashes = @($v17RelatedSubagentData.RunHashes)
                }
                # PS5.1 otherwise serializes DateTimeOffset as /Date(...)/ and
                # loses the original offset on ConvertFrom-Json during recovery.
                Set-PropertyValue -Object $built -Name 'StartedAt' -Value ($built.StartedAt.ToString('o'))
                Set-PropertyValue -Object $built -Name 'EndedAt' -Value ($built.EndedAt.ToString('o'))
                # Freeze the final snapshot before attempting the fallible log write.
                Write-Utf8FileAtomic -Path $completedPath -Content ($completed | ConvertTo-Json -Compress -Depth 15)
                return Complete-PendingSummary -Completed (Read-JsonFile -Path $completedPath)
            }

            Write-HookJsonOutput -SystemMessage ([string]$summaryObject.Summary)
            exit 0
        }

        default {
            Append-CurrentEvent
            if ($Event -eq 'SubagentStop') {
                [Console]::Out.WriteLine('{}')
            }
            exit 0
        }
    }
}
catch {
    Write-DebugRecord -Message 'Hook 出现未处理异常，Codex 任务已继续执行。' -ExceptionObject $_.Exception

    if ($Event -eq 'UserPromptSubmit') {
        Write-HookJsonOutput -SystemMessage ('输入 ' + $eventReceivedAt.ToLocalTime().ToString('HH:mm:ss') + '（统计初始化未完成）')
    }
    elseif ($Event -eq 'Stop') {
        Write-HookJsonOutput -SystemMessage '任务统计生成失败，已跳过；Codex 任务不受影响。'
    }
    elseif ($Event -eq 'SubagentStop') {
        [Console]::Out.WriteLine('{}')
    }

    exit 0
}
