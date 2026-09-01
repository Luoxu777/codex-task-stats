[CmdletBinding()]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$CodexHome
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$CodexPathLibrary = Join-Path $PSScriptRoot 'lib\CodexPath.ps1'
if (-not (Test-Path -LiteralPath $CodexPathLibrary -PathType Leaf)) {
    throw "缺少 Codex 路径辅助脚本：$CodexPathLibrary"
}
. $CodexPathLibrary
$CodexHomeInfo = Resolve-CodexHome -ExplicitPath $CodexHome -ExplicitlyProvided ($PSBoundParameters.ContainsKey('CodexHome'))
$CodexHome = [string]$CodexHomeInfo.Path

$ExpectedSchemaVersion = 11
$ExpectedEvents = @(
    'UserPromptSubmit',
    'PreToolUse',
    'PermissionRequest',
    'PostToolUse',
    'PreCompact',
    'PostCompact',
    'SubagentStart',
    'SubagentStop',
    'Stop'
)

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceVersionPath = Join-Path $ProjectRoot 'VERSION'
$SourceProgramPath = Join-Path $ProjectRoot 'src\codex-task-stats.ps1'
$SourceLibraryPath = Join-Path $ProjectRoot 'src\lib\SubagentCorrelation.ps1'
$InstallRoot = Join-Path $CodexHome 'task-stats'
$HooksPath = Join-Path $CodexHome 'hooks.json'
$ConfigPath = Join-Path $InstallRoot 'config\config.json'
$LogsPath = Join-Path $InstallRoot 'logs'
$DebugPath = Join-Path $InstallRoot 'debug'
$ProgramPath = Join-Path $InstallRoot 'bin\codex-task-stats.ps1'
$LibraryPath = Join-Path $InstallRoot 'bin\lib\SubagentCorrelation.ps1'
$InstalledVersionPath = Join-Path $InstallRoot 'VERSION'

function Read-VersionFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $value = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8).Trim()
        if ($value -match '^v[0-9]+\.[0-9]$') {
            return $value
        }
    }
    catch { }

    return $null
}

function Get-FileSha256Safe {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        return $null
    }
}

function Get-NormalizedTextSha256Safe {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($text)
            return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Test-HashEquals {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    return (
        -not [string]::IsNullOrWhiteSpace($Left) -and
        -not [string]::IsNullOrWhiteSpace($Right) -and
        [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
    )
}

function Test-PowerShellSyntax {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [PSCustomObject]@{
            Valid = $false
            ErrorCount = 0
        }
    }

    try {
        $tokens = $null
        $parseErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile(
            $Path,
            [ref]$tokens,
            [ref]$parseErrors
        )
        return [PSCustomObject]@{
            Valid = (@($parseErrors).Count -eq 0)
            ErrorCount = @($parseErrors).Count
        }
    }
    catch {
        return [PSCustomObject]@{
            Valid = $false
            ErrorCount = 1
        }
    }
}

function Test-UnsafeGenericListConstruction {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $sourceText = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        return [bool]($sourceText -match '(?im)New-Object[^\r\n]*System\.Collections\.Generic\.List\s*\[')
    }
    catch {
        return $true
    }
}

function Test-SubagentCorrelationRuntimeCompatibility {
    param([string]$LibraryPath)

    $engine = 'Windows PowerShell 5.1'
    $emptyResult = [ordered]@{
        Passed = $false
        Code = ''
        ExceptionType = ''
        Engine = $engine
        PowerShellVersion = ''
        ProbeVersion = $null
        ReadEventCount = $null
        MergedRunCount = $null
        MergedEventCount = $null
        FallbackStartCount = $null
    }

    if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) {
        $emptyResult.Code = 'LIBRARY_MISSING'
        return [pscustomobject]$emptyResult
    }

    $powerShellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        $emptyResult.Code = 'POWERSHELL_EXE_NOT_FOUND'
        return [pscustomobject]$emptyResult
    }

    $oldProbeLibrary = $env:CODEX_TASK_STATS_PROBE_LIBRARY
    $probeCommandText = @'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Get-ProbePropertyValue {
    param([AllowNull()][object]$Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

try {
    . $env:CODEX_TASK_STATS_PROBE_LIBRARY
    $probeCommand = Get-Command Invoke-V19SubagentCorrelationCompatibilityProbe -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $probeCommand) {
        $probeResult = [pscustomobject]@{
            Passed = $false
            Code = 'PROBE_FUNCTION_MISSING'
            ExceptionType = ''
        }
    }
    else {
        $probeResult = Invoke-V19SubagentCorrelationCompatibilityProbe
    }

    $output = [ordered]@{
        Passed = ($null -ne $probeResult -and [bool](Get-ProbePropertyValue -Object $probeResult -Name 'Passed'))
        Code = if ($null -eq $probeResult) { 'NO_RESULT' } else { [string](Get-ProbePropertyValue -Object $probeResult -Name 'Code') }
        ExceptionType = [string](Get-ProbePropertyValue -Object $probeResult -Name 'ExceptionType')
        ProbeVersion = Get-ProbePropertyValue -Object $probeResult -Name 'ProbeVersion'
        ReadEventCount = Get-ProbePropertyValue -Object $probeResult -Name 'ReadEventCount'
        MergedRunCount = Get-ProbePropertyValue -Object $probeResult -Name 'MergedRunCount'
        MergedEventCount = Get-ProbePropertyValue -Object $probeResult -Name 'MergedEventCount'
        FallbackStartCount = Get-ProbePropertyValue -Object $probeResult -Name 'FallbackStartCount'
        Engine = 'Windows PowerShell 5.1'
        PowerShellVersion = [string]$PSVersionTable.PSVersion
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 8))
    if ([bool]$output.Passed) { exit 0 } else { exit 1 }
}
catch {
    $output = [ordered]@{
        Passed = $false
        Code = 'PROBE_EXECUTION_FAILED'
        ExceptionType = if ($null -eq $_.Exception) { 'unknown' } else { [string]$_.Exception.GetType().FullName }
        ProbeVersion = $null
        ReadEventCount = $null
        MergedRunCount = $null
        MergedEventCount = $null
        FallbackStartCount = $null
        Engine = 'Windows PowerShell 5.1'
        PowerShellVersion = [string]$PSVersionTable.PSVersion
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 8))
    exit 1
}
'@

    try {
        $env:CODEX_TASK_STATS_PROBE_LIBRARY = $LibraryPath
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommandText))
        $probeOutput = & ([string]$powerShellCommand.Source) `
            -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -EncodedCommand $encodedCommand 2>$null
        $probeExitCode = $LASTEXITCODE
        $probeLines = @($probeOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $probeResult = $null
        if ($probeLines.Count -gt 0) {
            try {
                $probeResult = $probeLines[$probeLines.Count - 1] | ConvertFrom-Json -ErrorAction Stop
            }
            catch { }
        }

        if ($null -eq $probeResult) {
            $emptyResult.Code = if ($probeExitCode -eq 0) { 'NO_RESULT' } else { 'PROBE_PROCESS_FAILED' }
            return [pscustomobject]$emptyResult
        }

        $powerShellVersion = [string]$probeResult.PowerShellVersion
        $actualVersion = $null
        try { $actualVersion = [Version]$powerShellVersion } catch { }
        if ($null -eq $actualVersion -or $actualVersion.Major -ne 5 -or $actualVersion.Minor -ne 1) {
            $emptyResult.Code = 'WRONG_POWERSHELL_VERSION'
            $emptyResult.PowerShellVersion = $powerShellVersion
            return [pscustomobject]$emptyResult
        }

        $emptyResult.PowerShellVersion = $powerShellVersion
        $emptyResult.ExceptionType = if ($null -eq $probeResult.PSObject.Properties['ExceptionType']) { '' } else { [string]$probeResult.ExceptionType }
        foreach ($name in @('ProbeVersion', 'ReadEventCount', 'MergedRunCount', 'MergedEventCount', 'FallbackStartCount')) {
            $property = $probeResult.PSObject.Properties[$name]
            if ($null -ne $property) { $emptyResult[$name] = $property.Value }
        }

        if ($probeExitCode -ne 0 -or -not [bool]$probeResult.Passed) {
            $emptyResult.Code = if ([string]::IsNullOrWhiteSpace([string]$probeResult.Code)) { 'PROBE_PROCESS_FAILED' } else { [string]$probeResult.Code }
            return [pscustomobject]$emptyResult
        }

        if (-not [string]::Equals([string]$probeResult.Code, 'OK', [StringComparison]::Ordinal)) {
            $emptyResult.Code = 'PROBE_RESULT_INVALID'
            return [pscustomobject]$emptyResult
        }

        $expectedProbeValues = [ordered]@{
            ProbeVersion = 1
            ReadEventCount = 2
            MergedRunCount = 1
            MergedEventCount = 2
            FallbackStartCount = 1
        }
        foreach ($entry in $expectedProbeValues.GetEnumerator()) {
            $property = $probeResult.PSObject.Properties[$entry.Key]
            $actualValue = [int]0
            if ($null -eq $property -or
                -not [int]::TryParse([string]$property.Value, [ref]$actualValue) -or
                $actualValue -ne [int]$entry.Value) {
                $emptyResult.Code = 'PROBE_RESULT_INVALID'
                return [pscustomobject]$emptyResult
            }
        }

        $emptyResult.Passed = $true
        $emptyResult.Code = 'OK'
        return [pscustomobject]$emptyResult
    }
    catch {
        $emptyResult.Code = 'PROBE_PROCESS_FAILED'
        $emptyResult.ExceptionType = if ($null -eq $_.Exception) { 'unknown' } else { [string]$_.Exception.GetType().FullName }
        return [pscustomobject]$emptyResult
    }
    finally {
        if ($null -eq $oldProbeLibrary) {
            Remove-Item Env:CODEX_TASK_STATS_PROBE_LIBRARY -ErrorAction SilentlyContinue
        }
        else {
            $env:CODEX_TASK_STATS_PROBE_LIBRARY = $oldProbeLibrary
        }
    }
}

function Get-HandlerCommandText {
    param([object]$Handler)

    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('command', 'commandWindows', 'command_windows')) {
        $property = $Handler.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $values.Add([string]$property.Value)
        }
    }
    return ($values -join "`n")
}

function Get-HookProgramTarget {
    param([string]$CommandText)

    $match = [Regex]::Match(
        $CommandText,
        '(?i)-File\s+(?:"(?<double>[^"]+)"|''(?<single>[^'']+)''|(?<bare>\S+))'
    )
    if (-not $match.Success) {
        return $null
    }

    foreach ($name in @('double', 'single', 'bare')) {
        if ($match.Groups[$name].Success) {
            try {
                $value = [Environment]::ExpandEnvironmentVariables($match.Groups[$name].Value)
                return [IO.Path]::GetFullPath($value)
            }
            catch {
                return $null
            }
        }
    }

    return $null
}

$handlerCount = 0
$events = [System.Collections.Generic.List[string]]::new()
$hooksParseSucceeded = $false
$hookTargetParseFailureCount = 0
$hookTargetMismatchCount = 0
if (Test-Path -LiteralPath $HooksPath -PathType Leaf) {
    try {
        $root = [IO.File]::ReadAllText($HooksPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $hooksParseSucceeded = $true
        if ($null -ne $root.PSObject.Properties['hooks']) {
            foreach ($eventProperty in $root.hooks.PSObject.Properties) {
                foreach ($group in @($eventProperty.Value)) {
                    if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) { continue }
                    foreach ($handler in @($group.hooks)) {
                        if ($null -eq $handler) { continue }
                        $commandText = Get-HandlerCommandText -Handler $handler
                        if ($commandText -notmatch '(?i)codex-task-stats\.ps1') { continue }

                        $handlerCount++
                        if (-not $events.Contains($eventProperty.Name)) {
                            $events.Add($eventProperty.Name)
                        }

                        $target = Get-HookProgramTarget -CommandText $commandText
                        if ([string]::IsNullOrWhiteSpace([string]$target)) {
                            $hookTargetParseFailureCount++
                        }
                        elseif (-not [string]::Equals(
                            $target,
                            [IO.Path]::GetFullPath($ProgramPath),
                            [StringComparison]::OrdinalIgnoreCase
                        )) {
                            $hookTargetMismatchCount++
                        }
                    }
                }
            }
        }
    }
    catch {
        $hooksParseSucceeded = $false
        $handlerCount = 0
        $events.Clear()
        $hookTargetParseFailureCount = 0
        $hookTargetMismatchCount = 0
        Write-Warning "无法解析 hooks.json：$($_.Exception.Message)"
    }
}

$missingEvents = @($ExpectedEvents | Where-Object { -not $events.Contains($_) })
$hookTargetsMatchInstalledProgram = (
    $handlerCount -gt 0 -and
    $hookTargetParseFailureCount -eq 0 -and
    $hookTargetMismatchCount -eq 0
)
$hookRegistrationComplete = (
    $hooksParseSucceeded -and
    $handlerCount -eq $ExpectedEvents.Count -and
    $missingEvents.Count -eq 0 -and
    $hookTargetsMatchInstalledProgram
)

$latestLog = $null
if (Test-Path -LiteralPath $LogsPath -PathType Container) {
    $latestLog = Get-ChildItem -LiteralPath $LogsPath -Filter '*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

$latestLogPath = $null
$latestLogVersion = $null
if ($null -ne $latestLog) {
    $latestLogPath = $latestLog.FullName
    try {
        $latestLogText = [IO.File]::ReadAllText($latestLog.FullName, [Text.Encoding]::UTF8)
        $versionMatches = [Regex]::Matches($latestLogText, '(?m)^程序版本：(?<version>v[0-9]+\.[0-9])\s*$')
        if ($versionMatches.Count -gt 0) {
            $latestLogVersion = $versionMatches[$versionMatches.Count - 1].Groups['version'].Value
        }
    }
    catch { }
}

$latestBootstrapLog = $null
if (Test-Path -LiteralPath $DebugPath -PathType Container) {
    $latestBootstrapLog = Get-ChildItem -LiteralPath $DebugPath -Filter 'codex-task-stats-bootstrap-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

$sourceVersion = Read-VersionFile -Path $SourceVersionPath
$installedVersion = Read-VersionFile -Path $InstalledVersionPath
$sourceProgramSha256 = Get-FileSha256Safe -Path $SourceProgramPath
$programSha256 = Get-FileSha256Safe -Path $ProgramPath
$sourceProgramNormalizedSha256 = Get-NormalizedTextSha256Safe -Path $SourceProgramPath
$programNormalizedSha256 = Get-NormalizedTextSha256Safe -Path $ProgramPath
$sourceLibrarySha256 = Get-FileSha256Safe -Path $SourceLibraryPath
$librarySha256 = Get-FileSha256Safe -Path $LibraryPath
$sourceLibraryNormalizedSha256 = Get-NormalizedTextSha256Safe -Path $SourceLibraryPath
$libraryNormalizedSha256 = Get-NormalizedTextSha256Safe -Path $LibraryPath

$programByteMatchesSource = Test-HashEquals -Left $sourceProgramSha256 -Right $programSha256
$programMatchesSource = Test-HashEquals -Left $sourceProgramNormalizedSha256 -Right $programNormalizedSha256
$libraryByteMatchesSource = Test-HashEquals -Left $sourceLibrarySha256 -Right $librarySha256
$libraryMatchesSource = Test-HashEquals -Left $sourceLibraryNormalizedSha256 -Right $libraryNormalizedSha256

$sourceProgramSyntax = Test-PowerShellSyntax -Path $SourceProgramPath
$programSyntax = Test-PowerShellSyntax -Path $ProgramPath
$sourceLibrarySyntax = Test-PowerShellSyntax -Path $SourceLibraryPath
$librarySyntax = Test-PowerShellSyntax -Path $LibraryPath
$sourceUnsafeGenericListConstruction = Test-UnsafeGenericListConstruction -Path $SourceLibraryPath
$unsafeGenericListConstruction = Test-UnsafeGenericListConstruction -Path $LibraryPath
$sourceRuntimeCompatibility = Test-SubagentCorrelationRuntimeCompatibility -LibraryPath $SourceLibraryPath
$runtimeCompatibility = Test-SubagentCorrelationRuntimeCompatibility -LibraryPath $LibraryPath
$sourceRuntimeCompatibilityPassed = (
    $sourceLibrarySyntax.Valid -and
    -not $sourceUnsafeGenericListConstruction -and
    [bool]$sourceRuntimeCompatibility.Passed
)
$runtimeCompatibilityPassed = (
    $librarySyntax.Valid -and
    -not $unsafeGenericListConstruction -and
    [bool]$runtimeCompatibility.Passed
)

$requiredRuntimeFilesComplete = (
    (Test-Path -LiteralPath $ProgramPath -PathType Leaf) -and
    (Test-Path -LiteralPath $LibraryPath -PathType Leaf)
)
$runtimeSyntaxValid = ($programSyntax.Valid -and $librarySyntax.Valid)
$sourceRuntimeValid = ($sourceProgramSyntax.Valid -and $sourceLibrarySyntax.Valid)

$versionMatchesSource = $false
if (-not [string]::IsNullOrWhiteSpace($sourceVersion) -and -not [string]::IsNullOrWhiteSpace($installedVersion)) {
    $versionMatchesSource = [string]::Equals($sourceVersion, $installedVersion, [StringComparison]::Ordinal)
}

$latestLogMatchesInstalled = $null
if (-not [string]::IsNullOrWhiteSpace($latestLogVersion) -and -not [string]::IsNullOrWhiteSpace($installedVersion)) {
    $latestLogMatchesInstalled = [string]::Equals($latestLogVersion, $installedVersion, [StringComparison]::Ordinal)
}

$configSchemaVersion = $null
$hideEmptyCategories = $null
$fileTrackingEnabled = $null
$gitStatusSupplement = $null
$skillCollectionMode = $null
$skillTranscriptEnabled = $null
$skillTranscriptReadMain = $null
$skillTranscriptReadSubagents = $null
$skillTranscriptLookbackEnabled = $null
$skillCommandReadEnabled = $null
$skillPreferParsedCommand = $null
$skillRawCommandFallback = $null
$skillRequireCompletedExecution = $null
$commandLoggingMode = $null
$commandLoggingIncludeGit = $null
$commandLoggingIncludeShell = $null
$commandLoggingMaxCommandChars = $null
$commandLoggingMaxRunsPerTask = $null
$gitDisplayIcon = $null
$gitDisplayLabel = $null
$configParseSucceeded = $false
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $installedConfig = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $configParseSucceeded = $true
        if ($null -ne $installedConfig.PSObject.Properties['schemaVersion']) {
            $configSchemaVersion = [int]$installedConfig.schemaVersion
        }
        if ($null -ne $installedConfig.PSObject.Properties['display'] -and $null -ne $installedConfig.display) {
            if ($null -ne $installedConfig.display.PSObject.Properties['hideEmptyCategories']) {
                $hideEmptyCategories = [bool]$installedConfig.display.hideEmptyCategories
            }
            if ($null -ne $installedConfig.display.PSObject.Properties['icons'] -and $null -ne $installedConfig.display.icons -and
                $null -ne $installedConfig.display.icons.PSObject.Properties['git']) {
                $gitDisplayIcon = [string]$installedConfig.display.icons.git
            }
            if ($null -ne $installedConfig.display.PSObject.Properties['labels'] -and $null -ne $installedConfig.display.labels -and
                $null -ne $installedConfig.display.labels.PSObject.Properties['git']) {
                $gitDisplayLabel = [string]$installedConfig.display.labels.git
            }
        }
        if ($null -ne $installedConfig.PSObject.Properties['commandLogging'] -and $null -ne $installedConfig.commandLogging) {
            if ($null -ne $installedConfig.commandLogging.PSObject.Properties['mode']) {
                $commandLoggingMode = [string]$installedConfig.commandLogging.mode
            }
            if ($null -ne $installedConfig.commandLogging.PSObject.Properties['includeGit']) {
                $commandLoggingIncludeGit = [bool]$installedConfig.commandLogging.includeGit
            }
            if ($null -ne $installedConfig.commandLogging.PSObject.Properties['includeShell']) {
                $commandLoggingIncludeShell = [bool]$installedConfig.commandLogging.includeShell
            }
            if ($null -ne $installedConfig.commandLogging.PSObject.Properties['maxCommandChars']) {
                $commandLoggingMaxCommandChars = [int]$installedConfig.commandLogging.maxCommandChars
            }
            if ($null -ne $installedConfig.commandLogging.PSObject.Properties['maxRunsPerTask']) {
                $commandLoggingMaxRunsPerTask = [int]$installedConfig.commandLogging.maxRunsPerTask
            }
        }
        if ($null -ne $installedConfig.PSObject.Properties['fileTracking'] -and $null -ne $installedConfig.fileTracking) {
            if ($null -ne $installedConfig.fileTracking.PSObject.Properties['enabled']) {
                $fileTrackingEnabled = [bool]$installedConfig.fileTracking.enabled
            }
            if ($null -ne $installedConfig.fileTracking.PSObject.Properties['gitStatusSupplement']) {
                $gitStatusSupplement = [bool]$installedConfig.fileTracking.gitStatusSupplement
            }
        }
        if ($null -ne $installedConfig.PSObject.Properties['skillCollection'] -and $null -ne $installedConfig.skillCollection) {
            if ($null -ne $installedConfig.skillCollection.PSObject.Properties['mode']) {
                $skillCollectionMode = [string]$installedConfig.skillCollection.mode
            }
            if ($null -ne $installedConfig.skillCollection.PSObject.Properties['commandRead'] -and $null -ne $installedConfig.skillCollection.commandRead) {
                if ($null -ne $installedConfig.skillCollection.commandRead.PSObject.Properties['enabled']) {
                    $skillCommandReadEnabled = [bool]$installedConfig.skillCollection.commandRead.enabled
                }
                if ($null -ne $installedConfig.skillCollection.commandRead.PSObject.Properties['preferParsedCommand']) {
                    $skillPreferParsedCommand = [bool]$installedConfig.skillCollection.commandRead.preferParsedCommand
                }
                if ($null -ne $installedConfig.skillCollection.commandRead.PSObject.Properties['rawCommandFallback']) {
                    $skillRawCommandFallback = [bool]$installedConfig.skillCollection.commandRead.rawCommandFallback
                }
                if ($null -ne $installedConfig.skillCollection.commandRead.PSObject.Properties['requireCompletedExecution']) {
                    $skillRequireCompletedExecution = [bool]$installedConfig.skillCollection.commandRead.requireCompletedExecution
                }
            }
            if ($null -ne $installedConfig.skillCollection.PSObject.Properties['transcript'] -and $null -ne $installedConfig.skillCollection.transcript) {
                if ($null -ne $installedConfig.skillCollection.transcript.PSObject.Properties['enabled']) {
                    $skillTranscriptEnabled = [bool]$installedConfig.skillCollection.transcript.enabled
                }
                if ($null -ne $installedConfig.skillCollection.transcript.PSObject.Properties['readMain']) {
                    $skillTranscriptReadMain = [bool]$installedConfig.skillCollection.transcript.readMain
                }
                if ($null -ne $installedConfig.skillCollection.transcript.PSObject.Properties['readSubagents']) {
                    $skillTranscriptReadSubagents = [bool]$installedConfig.skillCollection.transcript.readSubagents
                }
                if ($null -ne $installedConfig.skillCollection.transcript.PSObject.Properties['currentTurnLookbackEnabled']) {
                    $skillTranscriptLookbackEnabled = [bool]$installedConfig.skillCollection.transcript.currentTurnLookbackEnabled
                }
            }
        }
    }
    catch {
        $configParseSucceeded = $false
        $configSchemaVersion = $null
        Write-Warning "无法解析 config.json：$($_.Exception.Message)"
    }
}

$configSchemaMatchesExpected = ($configParseSucceeded -and $configSchemaVersion -eq $ExpectedSchemaVersion)
$latestBootstrapDiagnostic = $null
$latestBootstrapDiagnosticModifiedAt = $null
if ($null -ne $latestBootstrapLog) {
    $latestBootstrapDiagnostic = $latestBootstrapLog.FullName
    $latestBootstrapDiagnosticModifiedAt = $latestBootstrapLog.LastWriteTime
}
$overallHealthy = (
    $sourceRuntimeValid -and
    -not $sourceUnsafeGenericListConstruction -and
    $sourceRuntimeCompatibilityPassed -and
    $requiredRuntimeFilesComplete -and
    $runtimeSyntaxValid -and
    -not $unsafeGenericListConstruction -and
    $runtimeCompatibilityPassed -and
    $versionMatchesSource -and
    $programMatchesSource -and
    $libraryMatchesSource -and
    $configSchemaMatchesExpected -and
    $hookRegistrationComplete
)

Write-CodexHomeWarnings -ResolvedInfo $CodexHomeInfo

[PSCustomObject]@{
    OverallHealthy = $overallHealthy
    CodexHomeSource = $CodexHomeInfo.Source
    CodexHomeSourceDisplay = $CodexHomeInfo.SourceDisplay
    CodexHome = $CodexHome
    HooksPath = $HooksPath
    InstallRoot = $InstallRoot
    ExpectedSchemaVersion = $ExpectedSchemaVersion
    SourceVersion = $sourceVersion
    InstalledVersion = $installedVersion
    VersionMatchesSource = $versionMatchesSource
    InstalledVersionPath = $InstalledVersionPath
    HooksJsonExists = (Test-Path -LiteralPath $HooksPath -PathType Leaf)
    HooksJsonParseSucceeded = $hooksParseSucceeded
    HookRegistrationComplete = $hookRegistrationComplete
    HookTargetsMatchInstalledProgram = $hookTargetsMatchInstalledProgram
    HookTargetParseFailureCount = $hookTargetParseFailureCount
    HookTargetMismatchCount = $hookTargetMismatchCount
    MissingRegisteredEvents = ($missingEvents -join ', ')
    ProgramInstalled = (Test-Path -LiteralPath $ProgramPath -PathType Leaf)
    LibraryInstalled = (Test-Path -LiteralPath $LibraryPath -PathType Leaf)
    RequiredRuntimeFilesComplete = $requiredRuntimeFilesComplete
    RuntimeSyntaxValid = $runtimeSyntaxValid
    SourceRuntimeValid = $sourceRuntimeValid
    SourceUnsafeGenericListConstruction = $sourceUnsafeGenericListConstruction
    UnsafeGenericListConstruction = $unsafeGenericListConstruction
    SourceRuntimeCompatibilityPassed = $sourceRuntimeCompatibilityPassed
    SourceRuntimeCompatibilityCode = [string]$sourceRuntimeCompatibility.Code
    SourceRuntimeCompatibilityExceptionType = [string]$sourceRuntimeCompatibility.ExceptionType
    SourceRuntimeCompatibilityEngine = [string]$sourceRuntimeCompatibility.Engine
    SourceRuntimeCompatibilityPowerShellVersion = [string]$sourceRuntimeCompatibility.PowerShellVersion
    SourceRuntimeCompatibilityProbeVersion = $sourceRuntimeCompatibility.ProbeVersion
    SourceRuntimeCompatibilityReadEventCount = $sourceRuntimeCompatibility.ReadEventCount
    SourceRuntimeCompatibilityMergedRunCount = $sourceRuntimeCompatibility.MergedRunCount
    SourceRuntimeCompatibilityMergedEventCount = $sourceRuntimeCompatibility.MergedEventCount
    SourceRuntimeCompatibilityFallbackStartCount = $sourceRuntimeCompatibility.FallbackStartCount
    RuntimeCompatibilityPassed = $runtimeCompatibilityPassed
    RuntimeCompatibilityCode = [string]$runtimeCompatibility.Code
    RuntimeCompatibilityExceptionType = [string]$runtimeCompatibility.ExceptionType
    RuntimeCompatibilityEngine = [string]$runtimeCompatibility.Engine
    RuntimeCompatibilityPowerShellVersion = [string]$runtimeCompatibility.PowerShellVersion
    RuntimeCompatibilityProbeVersion = $runtimeCompatibility.ProbeVersion
    RuntimeCompatibilityReadEventCount = $runtimeCompatibility.ReadEventCount
    RuntimeCompatibilityMergedRunCount = $runtimeCompatibility.MergedRunCount
    RuntimeCompatibilityMergedEventCount = $runtimeCompatibility.MergedEventCount
    RuntimeCompatibilityFallbackStartCount = $runtimeCompatibility.FallbackStartCount
    SourceProgramPath = $SourceProgramPath
    ProgramPath = $ProgramPath
    SourceProgramSha256 = $sourceProgramSha256
    ProgramSha256 = $programSha256
    ProgramByteMatchesSource = $programByteMatchesSource
    SourceProgramNormalizedSha256 = $sourceProgramNormalizedSha256
    ProgramNormalizedSha256 = $programNormalizedSha256
    ProgramMatchesSource = $programMatchesSource
    SourceLibraryPath = $SourceLibraryPath
    LibraryPath = $LibraryPath
    SourceLibrarySha256 = $sourceLibrarySha256
    LibrarySha256 = $librarySha256
    LibraryByteMatchesSource = $libraryByteMatchesSource
    SourceLibraryNormalizedSha256 = $sourceLibraryNormalizedSha256
    LibraryNormalizedSha256 = $libraryNormalizedSha256
    LibraryMatchesSource = $libraryMatchesSource
    ProgramSyntaxErrorCount = $programSyntax.ErrorCount
    LibrarySyntaxErrorCount = $librarySyntax.ErrorCount
    ConfigExists = (Test-Path -LiteralPath $ConfigPath -PathType Leaf)
    ConfigParseSucceeded = $configParseSucceeded
    ConfigSchemaVersion = $configSchemaVersion
    ConfigSchemaMatchesExpected = $configSchemaMatchesExpected
    HideEmptyCategories = $hideEmptyCategories
    GitDisplayIcon = $gitDisplayIcon
    GitDisplayLabel = $gitDisplayLabel
    CommandLoggingMode = $commandLoggingMode
    CommandLoggingIncludeGit = $commandLoggingIncludeGit
    CommandLoggingIncludeShell = $commandLoggingIncludeShell
    CommandLoggingMaxCommandChars = $commandLoggingMaxCommandChars
    CommandLoggingMaxRunsPerTask = $commandLoggingMaxRunsPerTask
    FileTrackingEnabled = $fileTrackingEnabled
    GitStatusSupplement = $gitStatusSupplement
    SkillCollectionMode = $skillCollectionMode
    SkillTranscriptEnabled = $skillTranscriptEnabled
    SkillTranscriptReadMain = $skillTranscriptReadMain
    SkillTranscriptReadSubagents = $skillTranscriptReadSubagents
    SkillTranscriptLookbackEnabled = $skillTranscriptLookbackEnabled
    SkillCommandReadEnabled = $skillCommandReadEnabled
    SkillPreferParsedCommand = $skillPreferParsedCommand
    SkillRawCommandFallback = $skillRawCommandFallback
    SkillRequireCompletedExecution = $skillRequireCompletedExecution
    RegisteredHandlerCount = $handlerCount
    RegisteredEvents = (($events | Sort-Object) -join ', ')
    LogsDirectory = $LogsPath
    LatestLog = $latestLogPath
    LatestLogVersion = $latestLogVersion
    LatestLogMatchesInstalled = $latestLogMatchesInstalled
    LatestBootstrapDiagnostic = $latestBootstrapDiagnostic
    LatestBootstrapDiagnosticModifiedAt = $latestBootstrapDiagnosticModifiedAt
} | Format-List
