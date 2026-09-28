[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Quiet', 'Strict')]
    [string]$IntermediateMode = 'Quiet',

    [AllowNull()]
    [AllowEmptyString()]
    [string]$CodexHome,

    [switch]$Force
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

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$SourceScript = Join-Path $ProjectRoot 'src\codex-task-stats.ps1'
$SourceSubagentCorrelationLibrary = Join-Path $ProjectRoot 'src\lib\SubagentCorrelation.ps1'
$SourceConfig = Join-Path $ProjectRoot 'config\config.example.json'
$SourceVersionPath = Join-Path $ProjectRoot 'VERSION'
$ExpectedSchemaVersion = 11
$InstallRoot = Join-Path $CodexHome 'task-stats'
$InstallBin = Join-Path $InstallRoot 'bin'
$InstallLib = Join-Path $InstallBin 'lib'
$InstallConfig = Join-Path $InstallRoot 'config'
$InstallBackups = Join-Path $InstallRoot 'backups'
$InstalledScript = Join-Path $InstallBin 'codex-task-stats.ps1'
$InstalledSubagentCorrelationLibrary = Join-Path $InstallLib 'SubagentCorrelation.ps1'
$InstalledConfig = Join-Path $InstallConfig 'config.json'
$InstalledVersionPath = Join-Path $InstallRoot 'VERSION'
$HooksPath = Join-Path $CodexHome 'hooks.json'
$SingleHookPath = Join-Path $CodexHome 'hook.json'
$ConfigTomlPath = Join-Path $CodexHome 'config.toml'
$InstallLogs = Join-Path $InstallRoot 'logs'

Write-CodexHomeSelection -ResolvedInfo $CodexHomeInfo -HooksPath $HooksPath -InstallRoot $InstallRoot -LogsPath $InstallLogs
Write-Host ''

function Write-Utf8FileAtomic {
    param([string]$Path, [string]$Content)

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

function Get-FileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PowerShellSyntax {
    param(
        [string]$Path,
        [string]$Label
    )

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if (@($parseErrors).Count -gt 0) {
        $details = @($parseErrors | ForEach-Object {
            $_.Message + '（行 ' + $_.Extent.StartLineNumber + '，列 ' + $_.Extent.StartColumnNumber + '）'
        }) -join '；'
        throw "$Label PowerShell 语法检查失败：$details"
    }
}

function Assert-NoUnsafeGenericListConstruction {
    param(
        [string]$Path,
        [string]$Label
    )

    $sourceText = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($sourceText -match '(?im)New-Object[^\r\n]*System\.Collections\.Generic\.List\s*\[') {
        throw "$Label 包含 Windows PowerShell 5.1 不兼容的 New-Object Generic.List 构造。"
    }
}

function Copy-FileAtomicVerified {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "$Label 源文件不存在：$Source"
    }

    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }

    $sourceHash = Get-FileSha256 -Path $Source
    $tempPath = "$Destination.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $tempPath -Force
        $tempHash = Get-FileSha256 -Path $tempPath
        if (-not [string]::Equals($sourceHash, $tempHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label 暂存副本 SHA-256 不一致。"
        }

        $null = Move-Item -LiteralPath $tempPath -Destination $Destination -Force
        $destinationHash = Get-FileSha256 -Path $Destination
        if (-not [string]::Equals($sourceHash, $destinationHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Label 安装后 SHA-256 不一致。"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-InstalledFile {
    param(
        [string]$TargetPath,
        [string]$BackupPath,
        [bool]$ExistedBefore
    )

    if ($ExistedBefore) {
        if (-not (Test-Path -LiteralPath $BackupPath -PathType Leaf)) {
            throw "无法恢复文件，备份不存在：$BackupPath"
        }
        $directory = Split-Path -Parent $TargetPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            $null = New-Item -ItemType Directory -Path $directory -Force
        }
        Copy-Item -LiteralPath $BackupPath -Destination $TargetPath -Force
    }
    elseif (Test-Path -LiteralPath $TargetPath) {
        Remove-Item -LiteralPath $TargetPath -Force -ErrorAction Stop
    }
}

function Assert-SubagentCorrelationRuntimeCompatibility {
    param(
        [string]$LibraryPath,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $LibraryPath -PathType Leaf)) {
        throw "$Label 不存在：$LibraryPath"
    }

    $powerShellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($null -eq $powerShellCommand) {
        throw "$Label 无法执行 Windows PowerShell 5.1 兼容探针：找不到 powershell.exe。"
    }

    $powerShellExe = [string]$powerShellCommand.Source
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
        $probeOutput = & $powerShellExe `
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
            throw "$Label Windows PowerShell 5.1 运行时兼容性检查失败（Code=NO_RESULT；ExceptionType=）。"
        }

        $actualVersion = $null
        try {
            $actualVersion = [Version]([string]$probeResult.PowerShellVersion)
        }
        catch {
            throw "$Label 兼容探针返回了无效 PowerShell 版本。"
        }
        if ($actualVersion.Major -ne 5 -or $actualVersion.Minor -ne 1) {
            throw "$Label 兼容探针未使用 Windows PowerShell 5.1（实际版本：$actualVersion）。"
        }

        if ($probeExitCode -ne 0 -or -not [bool]$probeResult.Passed) {
            $code = if ([string]::IsNullOrWhiteSpace([string]$probeResult.Code)) { 'PROBE_PROCESS_FAILED' } else { [string]$probeResult.Code }
            $exceptionType = if ($null -eq $probeResult.PSObject.Properties['ExceptionType']) { '' } else { [string]$probeResult.ExceptionType }
            throw "$Label Windows PowerShell 5.1 运行时兼容性检查失败（Code=$code；ExceptionType=$exceptionType）。"
        }

        if (-not [string]::Equals([string]$probeResult.Code, 'OK', [StringComparison]::Ordinal)) {
            throw "$Label 运行时兼容性检查返回了无效成功代码：$([string]$probeResult.Code)。"
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
                throw "$Label 运行时兼容性检查结果无效：$($entry.Key)。"
            }
        }
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

function Invoke-RuntimeSmokeTest {
    param(
        [string]$ProgramPath,
        [string]$PackageVersion,
        [string]$ConfigJson,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $ProgramPath -PathType Leaf)) {
        throw "$Label 主处理器不存在：$ProgramPath"
    }

    $powerShellCommand = Get-Command powershell.exe -CommandType Application -ErrorAction Stop
    $powerShellExe = [string]$powerShellCommand.Source
    $smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-stats-install-smoke-' + [Guid]::NewGuid().ToString('N'))
    $smokeConfigRoot = Join-Path $smokeRoot 'config'
    $smokeWorkspace = Join-Path $smokeRoot 'workspace'
    $smokeTranscript = Join-Path $smokeRoot 'transcript.jsonl'
    $oldTaskStatsHome = $env:CODEX_TASK_STATS_HOME

    try {
        $null = New-Item -ItemType Directory -Path $smokeConfigRoot -Force
        $null = New-Item -ItemType Directory -Path $smokeWorkspace -Force
        Write-Utf8FileAtomic -Path (Join-Path $smokeConfigRoot 'config.json') -Content $ConfigJson
        Write-Utf8FileAtomic -Path (Join-Path $smokeRoot 'VERSION') -Content ($PackageVersion + [Environment]::NewLine)
        [IO.File]::WriteAllText($smokeTranscript, '', $Utf8NoBom)

        $env:CODEX_TASK_STATS_HOME = $smokeRoot
        $sessionId = 'install-smoke-session-' + [Guid]::NewGuid().ToString('N')
        $turnId = 'install-smoke-turn-' + [Guid]::NewGuid().ToString('N')

        $common = [ordered]@{
            session_id = $sessionId
            turn_id = $turnId
            transcript_path = $smokeTranscript
            cwd = $smokeWorkspace
            model = 'install-smoke-model'
            permission_mode = 'default'
        }

        $startPayload = [ordered]@{}
        foreach ($entry in $common.GetEnumerator()) { $startPayload[$entry.Key] = $entry.Value }
        $startPayload['hook_event_name'] = 'UserPromptSubmit'
        $startPayload['prompt'] = 'install-smoke'
        $startJson = $startPayload | ConvertTo-Json -Compress -Depth 10
        $arguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ProgramPath, '-Event', 'UserPromptSubmit'
        )
        $startOutput = $startJson | & $powerShellExe @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label UserPromptSubmit 烟雾测试退出码为 $LASTEXITCODE。"
        }
        $startText = @($startOutput) -join "`n"
        $startObject = $startText | ConvertFrom-Json
        $startMessage = [string]$startObject.systemMessage
        if ($startMessage -notmatch '^🟢 +开始 *：[0-9]{2}:[0-9]{2}:[0-9]{2}$') {
            throw "$Label UserPromptSubmit 烟雾测试输出无效。"
        }

        # Create a root journal event and a real child-turn SubagentStart. This
        # exercises the exact v1.8 failure path instead of only testing an empty task.
        $compactPayload = [ordered]@{}
        foreach ($entry in $common.GetEnumerator()) { $compactPayload[$entry.Key] = $entry.Value }
        $compactPayload['hook_event_name'] = 'PreCompact'
        $compactPayload['trigger'] = 'install-smoke'
        $compactJson = $compactPayload | ConvertTo-Json -Compress -Depth 10
        $compactArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ProgramPath, '-Event', 'PreCompact'
        )
        $null = $compactJson | & $powerShellExe @compactArguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label PreCompact 烟雾测试退出码为 $LASTEXITCODE。"
        }

        # Exercise the parameter-sensitive Git path that regressed in v1.9:
        # dry-run clean must remain read-only while clean -fd counts as a change.
        $gitToolUseId = 'install-smoke-git-' + [Guid]::NewGuid().ToString('N')
        $gitCommand = "git clean -n`ngit clean -fd"
        foreach ($gitEvent in @('PreToolUse', 'PostToolUse')) {
            $gitPayload = [ordered]@{}
            foreach ($entry in $common.GetEnumerator()) { $gitPayload[$entry.Key] = $entry.Value }
            $gitPayload['hook_event_name'] = $gitEvent
            $gitPayload['tool_name'] = 'Bash'
            $gitPayload['tool_use_id'] = $gitToolUseId
            $gitPayload['tool_input'] = [ordered]@{ command = $gitCommand }
            if ([string]::Equals($gitEvent, 'PostToolUse', [StringComparison]::Ordinal)) {
                $gitPayload['tool_response'] = [ordered]@{}
            }
            $gitJson = $gitPayload | ConvertTo-Json -Compress -Depth 10
            $gitArguments = @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                '-File', $ProgramPath, '-Event', $gitEvent
            )
            $null = $gitJson | & $powerShellExe @gitArguments
            if ($LASTEXITCODE -ne 0) {
                throw "$Label $gitEvent Git 分类烟雾测试退出码为 $LASTEXITCODE。"
            }
        }

        $childPayload = [ordered]@{}
        foreach ($entry in $common.GetEnumerator()) { $childPayload[$entry.Key] = $entry.Value }
        $childPayload['turn_id'] = 'install-smoke-child-' + [Guid]::NewGuid().ToString('N')
        $childPayload['hook_event_name'] = 'SubagentStart'
        $childPayload['agent_id'] = 'install-smoke-agent-' + [Guid]::NewGuid().ToString('N')
        $childPayload['agent_type'] = 'default'
        $childJson = $childPayload | ConvertTo-Json -Compress -Depth 10
        $childArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ProgramPath, '-Event', 'SubagentStart'
        )
        $null = $childJson | & $powerShellExe @childArguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label SubagentStart 烟雾测试退出码为 $LASTEXITCODE。"
        }

        $stopPayload = [ordered]@{}
        foreach ($entry in $common.GetEnumerator()) { $stopPayload[$entry.Key] = $entry.Value }
        $stopPayload['hook_event_name'] = 'Stop'
        $stopPayload['stop_hook_active'] = $false
        $stopPayload['status'] = 'completed'
        $stopJson = $stopPayload | ConvertTo-Json -Compress -Depth 10
        $stopArguments = @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', $ProgramPath, '-Event', 'Stop', '-TestDurationMilliseconds', '0'
        )
        $stopOutput = $stopJson | & $powerShellExe @stopArguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Label Stop 烟雾测试退出码为 $LASTEXITCODE。"
        }
        $stopText = @($stopOutput) -join "`n"
        $stopObject = $stopText | ConvertFrom-Json
        $stopMessage = [string]$stopObject.systemMessage
        if ($stopMessage -match '任务统计生成失败' -or $stopMessage -notmatch '^🔴 +结束 *：') {
            throw "$Label Stop 烟雾测试未生成正常摘要。"
        }
        if ($stopMessage -notmatch '子Agent *：default ×1') {
            throw "$Label Stop 烟雾测试未归并子 turn 的 SubagentStart。"
        }
        if ($stopMessage -notmatch 'Git *：运行 ×1，指令 ×2，变更 ×1') {
            throw "$Label Stop 烟雾测试未正确区分 git clean dry-run 与真实清理。"
        }

        $remainingChildArtifacts = @(
            Get-ChildItem -LiteralPath (Join-Path $smokeRoot 'data\journal') -Filter '*.jsonl' -File -ErrorAction SilentlyContinue
        ).Count + @(
            Get-ChildItem -LiteralPath (Join-Path $smokeRoot 'data\state') -Filter '*.json' -File -ErrorAction SilentlyContinue
        ).Count
        if ($remainingChildArtifacts -ne 0) {
            throw "$Label 烟雾测试完成后仍残留根或子 turn 的 state/journal。"
        }

        $smokeLog = Get-ChildItem -LiteralPath (Join-Path $smokeRoot 'logs') -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $smokeLog) {
            throw "$Label 烟雾测试没有生成每日日志。"
        }
        $smokeLogText = [IO.File]::ReadAllText($smokeLog.FullName, [Text.Encoding]::UTF8)
        if ($smokeLogText.IndexOf(('程序版本：' + $PackageVersion), [StringComparison]::Ordinal) -lt 0) {
            throw "$Label 烟雾测试日志版本不正确。"
        }
        if ($smokeLogText.IndexOf('default ×1', [StringComparison]::Ordinal) -lt 0) {
            throw "$Label 烟雾测试日志没有记录归并后的子Agent。"
        }
        if ($smokeLogText.IndexOf('指令 ×2', [StringComparison]::Ordinal) -lt 0 -or
            $smokeLogText.IndexOf('变更 ×1', [StringComparison]::Ordinal) -lt 0) {
            throw "$Label 烟雾测试日志没有正确记录 Git dry-run 分类。"
        }
    }
    finally {
        $env:CODEX_TASK_STATS_HOME = $oldTaskStatsHome
        if (Test-Path -LiteralPath $smokeRoot) {
            Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

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

function Copy-JsonValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [Array]) {
        $copy = @($Value)
        return ,$copy
    }

    if ($Value -is [PSCustomObject]) {
        return (($Value | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json)
    }

    return $Value
}

function Merge-MissingProperties {
    param(
        [object]$Target,
        [object]$Defaults
    )

    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $targetProperty = $Target.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $targetProperty) {
            $Target | Add-Member -NotePropertyName $defaultProperty.Name -NotePropertyValue (Copy-JsonValue -Value $defaultProperty.Value)
            continue
        }

        if ($null -eq $targetProperty.Value) {
            Set-PropertyValue -Object $Target -Name $defaultProperty.Name -Value (Copy-JsonValue -Value $defaultProperty.Value)
            continue
        }

        if ($targetProperty.Value -is [PSCustomObject] -and
            $defaultProperty.Value -is [PSCustomObject]) {
            Merge-MissingProperties -Target $targetProperty.Value -Defaults $defaultProperty.Value
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

function Test-IsTaskStatsHandler {
    param([object]$Handler)
    return (Get-HandlerCommandText -Handler $Handler) -match '(?i)codex-task-stats\.ps1'
}

function Get-NonTaskStatsHandlerCount {
    param(
        [object]$HooksObject,
        [string]$EventName
    )

    $eventProperty = $HooksObject.PSObject.Properties[$EventName]
    if ($null -eq $eventProperty) {
        return 0
    }

    $count = 0
    foreach ($group in @($eventProperty.Value)) {
        if ($null -eq $group) { continue }
        $hooksProperty = $group.PSObject.Properties['hooks']
        if ($null -eq $hooksProperty) { continue }
        foreach ($handler in @($hooksProperty.Value)) {
            if ($null -ne $handler -and -not (Test-IsTaskStatsHandler -Handler $handler)) {
                $count++
            }
        }
    }
    return $count
}

function Remove-TaskStatsHandlers {
    param(
        [object]$HooksObject,
        [string]$EventName
    )

    $eventProperty = $HooksObject.PSObject.Properties[$EventName]
    if ($null -eq $eventProperty) {
        return
    }

    $newGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($group in @($eventProperty.Value)) {
        if ($null -eq $group) { continue }
        $hooksProperty = $group.PSObject.Properties['hooks']
        if ($null -eq $hooksProperty) {
            $newGroups.Add($group)
            continue
        }

        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($handler in @($hooksProperty.Value)) {
            if ($null -ne $handler -and -not (Test-IsTaskStatsHandler -Handler $handler)) {
                $remaining.Add($handler)
            }
        }

        if ($remaining.Count -gt 0) {
            $group.hooks = @($remaining)
            $newGroups.Add($group)
        }
    }

    if ($newGroups.Count -eq 0) {
        $HooksObject.PSObject.Properties.Remove($EventName)
    }
    else {
        $HooksObject.$EventName = @($newGroups)
    }
}

function Add-TaskStatsHandler {
    param(
        [object]$HooksObject,
        [string]$EventName,
        [bool]$Async,
        [int]$Timeout,
        [bool]$UseMatcher
    )

    Remove-TaskStatsHandlers -HooksObject $HooksObject -EventName $EventName

    $quotedScript = '"' + $InstalledScript + '"'
    $command = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $quotedScript + ' -Event "' + $EventName + '"'

    $handler = [PSCustomObject][ordered]@{
        type = 'command'
        command = $command
        commandWindows = $command
        timeout = $Timeout
        async = $Async
    }

    if ($UseMatcher) {
        $group = [PSCustomObject][ordered]@{
            matcher = '*'
            hooks = @($handler)
        }
    }
    else {
        $group = [PSCustomObject][ordered]@{
            hooks = @($handler)
        }
    }

    $eventProperty = $HooksObject.PSObject.Properties[$EventName]
    if ($null -eq $eventProperty) {
        $HooksObject | Add-Member -NotePropertyName $EventName -NotePropertyValue @($group)
    }
    else {
        $HooksObject.$EventName = @(@($eventProperty.Value) + $group)
    }
}

if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw '需要 PowerShell 5.1 或更高版本。'
}
if (-not (Test-Path -LiteralPath $SourceScript -PathType Leaf)) {
    throw "缺少源程序：$SourceScript"
}
if (-not (Test-Path -LiteralPath $SourceSubagentCorrelationLibrary -PathType Leaf)) {
    throw "缺少源运行时依赖：$SourceSubagentCorrelationLibrary"
}
if (-not (Test-Path -LiteralPath $SourceConfig -PathType Leaf)) {
    throw "缺少源配置：$SourceConfig"
}
if (-not (Test-Path -LiteralPath $SourceVersionPath -PathType Leaf)) {
    throw "缺少 VERSION 文件：$SourceVersionPath"
}

Assert-PowerShellSyntax -Path $SourceScript -Label '主处理器'
Assert-PowerShellSyntax -Path $SourceSubagentCorrelationLibrary -Label '子Agent关联库'
Assert-NoUnsafeGenericListConstruction -Path $SourceSubagentCorrelationLibrary -Label '源子Agent关联库'
Assert-SubagentCorrelationRuntimeCompatibility -LibraryPath $SourceSubagentCorrelationLibrary -Label '源子Agent关联库'

$PackageVersion = [IO.File]::ReadAllText($SourceVersionPath, [Text.Encoding]::UTF8).Trim()
if ($PackageVersion -notmatch '^v[0-9]+\.[0-9]$') {
    throw "VERSION 值无效：$PackageVersion。预期格式为 v<主版本>.<更新号>，例如 v3.0。"
}

try {
    $DefaultConfigObject = [IO.File]::ReadAllText($SourceConfig, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
catch {
    throw "源配置不是有效 JSON：$($_.Exception.Message)"
}
if ($null -eq $DefaultConfigObject -or $DefaultConfigObject -isnot [PSCustomObject]) {
    throw '源配置顶层必须是 JSON 对象。'
}
if ($null -eq $DefaultConfigObject.PSObject.Properties['schemaVersion'] -or
    [int]$DefaultConfigObject.schemaVersion -ne $ExpectedSchemaVersion) {
    throw "源配置 schemaVersion 必须为 $ExpectedSchemaVersion。"
}
$DefaultConfigJson = $DefaultConfigObject | ConvertTo-Json -Depth 50
$null = $DefaultConfigJson | ConvertFrom-Json

if (Test-Path -LiteralPath $SingleHookPath) {
    Write-Warning "发现单数文件 hook.json：$SingleHookPath。Codex 使用 hooks.json；安装程序不会删除或重命名 hook.json。"
}

if (Test-Path -LiteralPath $ConfigTomlPath) {
    $toml = [IO.File]::ReadAllText($ConfigTomlPath, [Text.Encoding]::UTF8)
    if ($toml -match '(?im)^\s*(?:hooks|codex_hooks)\s*=\s*false\s*$') {
        if (-not $Force) {
            throw 'config.toml 似乎禁用了 hooks。确认这是预期行为后可使用 -Force 重新执行，或启用 [features] hooks = true。'
        }
        Write-Warning 'config.toml 似乎禁用了 hooks；由于已指定 -Force，安装将继续。'
    }
    if ($toml -match '(?im)^\s*\[\[?hooks(?:\.|\])') {
        Write-Warning 'config.toml 已包含内联 [hooks]。Codex 会将其与 hooks.json 合并，并可能显示启动警告；现有内联 hooks 不会被修改。'
    }
    if ($toml -match '(?i)codex-task-stats\.ps1') {
        throw 'config.toml 中已存在 codex-task-stats 处理器。请先移除重复配置，再安装到 hooks.json。'
    }
}

$rootObject = $null
if (Test-Path -LiteralPath $HooksPath) {
    try {
        $rootObject = [IO.File]::ReadAllText($HooksPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw "现有 hooks.json 不是有效 JSON，未进行任何修改。错误：$($_.Exception.Message)"
    }
}
else {
    $rootObject = [PSCustomObject][ordered]@{
        description = '用户级 Codex hooks。codex-task-stats 条目由 scripts/install.ps1 管理。'
        hooks = [PSCustomObject]@{}
    }
}

if ($null -eq $rootObject -or $rootObject -isnot [PSCustomObject]) {
    throw '现有 hooks.json 顶层必须是 JSON 对象，未进行任何修改。'
}

if ($null -eq $rootObject.PSObject.Properties['hooks']) {
    $rootObject | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{})
}
elseif ($null -eq $rootObject.hooks) {
    $rootObject.hooks = [PSCustomObject]@{}
}
elseif ($rootObject.hooks -isnot [PSCustomObject]) {
    throw '现有 hooks.json 的 "hooks" 值无效，必须是 JSON 对象；未进行任何修改。'
}

$existingStopHandlers = Get-NonTaskStatsHandlerCount -HooksObject $rootObject.hooks -EventName 'Stop'
if ($existingStopHandlers -gt 0) {
    Write-Warning ("发现 {0} 个现有 Stop Hook 处理器，将予以保留。如果其他 Stop Hook 要求继续执行，本程序可能汇总第一次 Stop 周期，而不是后续最终周期。" -f $existingStopHandlers)
}

$intermediateAsync = $IntermediateMode -eq 'Quiet'
$events = @(
    [PSCustomObject]@{ Name = 'UserPromptSubmit'; Async = $false; Timeout = 10; Matcher = $false },
    [PSCustomObject]@{ Name = 'PreToolUse'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'PermissionRequest'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'PostToolUse'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'PreCompact'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'PostCompact'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'SubagentStart'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'SubagentStop'; Async = $intermediateAsync; Timeout = 5; Matcher = $true },
    [PSCustomObject]@{ Name = 'Stop'; Async = $false; Timeout = 15; Matcher = $false }
)

foreach ($event in $events) {
    Add-TaskStatsHandler -HooksObject $rootObject.hooks -EventName $event.Name -Async $event.Async -Timeout $event.Timeout -UseMatcher $event.Matcher
}

$json = $rootObject | ConvertTo-Json -Depth 100
# Validate the exact serialized form before touching the user's file.
$null = $json | ConvertFrom-Json

$applyInstallation = $PSCmdlet.ShouldProcess(
    $CodexHome,
    "以 $IntermediateMode 模式安装 codex-task-stats，并合并用户级 hooks.json"
)

if ($applyInstallation) {
    $null = New-Item -ItemType Directory -Path $CodexHome -Force
    $null = New-Item -ItemType Directory -Path $InstallBin -Force
    $null = New-Item -ItemType Directory -Path $InstallLib -Force
    $null = New-Item -ItemType Directory -Path $InstallConfig -Force
    $null = New-Item -ItemType Directory -Path $InstallBackups -Force
    $null = New-Item -ItemType Directory -Path $InstallLogs -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'debug') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'data') -Force

    # Prepare and validate the merged config before replacing the runtime.
    $configExisted = Test-Path -LiteralPath $InstalledConfig -PathType Leaf
    try {
        if ($configExisted) {
            $installedConfigObject = [IO.File]::ReadAllText($InstalledConfig, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        else {
            $installedConfigObject = ($DefaultConfigObject | ConvertTo-Json -Depth 50) | ConvertFrom-Json
        }

        if ($null -eq $installedConfigObject -or $installedConfigObject -isnot [PSCustomObject]) {
            throw '已安装配置的顶层必须是 JSON 对象。'
        }

        Merge-MissingProperties -Target $installedConfigObject -Defaults $DefaultConfigObject
        Set-PropertyValue -Object $installedConfigObject -Name 'schemaVersion' -Value $ExpectedSchemaVersion

        if ($null -eq $installedConfigObject.PSObject.Properties['skillCollection'] -or $null -eq $installedConfigObject.skillCollection) {
            Set-PropertyValue -Object $installedConfigObject -Name 'skillCollection' -Value ([PSCustomObject]@{})
        }
        # v2.1 保留既有多源 Skill 采集和安全命令日志。
        Set-PropertyValue -Object $installedConfigObject.skillCollection -Name 'mode' -Value 'multi-source'

        if ($null -eq $installedConfigObject.PSObject.Properties['commandLogging'] -or $null -eq $installedConfigObject.commandLogging) {
            Set-PropertyValue -Object $installedConfigObject -Name 'commandLogging' -Value ([PSCustomObject]@{})
        }
        elseif ($installedConfigObject.commandLogging -isnot [PSCustomObject]) {
            throw '已安装配置中的 commandLogging 必须是 JSON 对象。'
        }
        $existingCommandMode = [string](Get-PropertyValue -Object $installedConfigObject.commandLogging -Name 'mode' -Default 'safe')
        if ([string]::Equals($existingCommandMode.Trim(), 'off', [StringComparison]::OrdinalIgnoreCase)) {
            Set-PropertyValue -Object $installedConfigObject.commandLogging -Name 'mode' -Value 'off'
        }
        else {
            Set-PropertyValue -Object $installedConfigObject.commandLogging -Name 'mode' -Value 'safe'
        }

        if ($null -eq $installedConfigObject.PSObject.Properties['collection'] -or $null -eq $installedConfigObject.collection) {
            Set-PropertyValue -Object $installedConfigObject -Name 'collection' -Value ([PSCustomObject]@{})
        }
        Set-PropertyValue -Object $installedConfigObject.collection -Name 'intermediateMode' -Value $IntermediateMode.ToLowerInvariant()

        $updatedConfigJson = $installedConfigObject | ConvertTo-Json -Depth 50
        $validatedInstalledConfig = $updatedConfigJson | ConvertFrom-Json
        if ([int]$validatedInstalledConfig.schemaVersion -ne $ExpectedSchemaVersion) {
            throw "配置迁移后 schemaVersion 不是 $ExpectedSchemaVersion。"
        }
    }
    catch {
        throw "无法安全准备已安装配置，运行程序和 hooks.json 均未修改。错误：$($_.Exception.Message)"
    }

    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $stagingRoot = Join-Path $InstallRoot ('.install-staging-' + [Guid]::NewGuid().ToString('N'))
    $stagingBin = Join-Path $stagingRoot 'bin'
    $stagingLib = Join-Path $stagingBin 'lib'
    $stagingProgram = Join-Path $stagingBin 'codex-task-stats.ps1'
    $stagingLibrary = Join-Path $stagingLib 'SubagentCorrelation.ps1'

    $runtimeBackupRoot = Join-Path $InstallBackups ('runtime.before-' + $PackageVersion + '-' + $timestamp)
    $programBackupPath = Join-Path $runtimeBackupRoot 'codex-task-stats.ps1'
    $libraryBackupPath = Join-Path $runtimeBackupRoot 'SubagentCorrelation.ps1'
    $versionBackupPath = Join-Path $runtimeBackupRoot 'VERSION'
    $configBackupPath = Join-Path $InstallBackups ('config.json.backup-' + $timestamp)
    $hooksBackupPath = Join-Path $InstallBackups ('hooks.json.backup-' + $timestamp)

    $programExisted = Test-Path -LiteralPath $InstalledScript -PathType Leaf
    $libraryExisted = Test-Path -LiteralPath $InstalledSubagentCorrelationLibrary -PathType Leaf
    $versionExisted = Test-Path -LiteralPath $InstalledVersionPath -PathType Leaf
    $hooksExisted = Test-Path -LiteralPath $HooksPath -PathType Leaf
    $runtimeTouched = $false
    $configTouched = $false
    $hooksTouched = $false

    try {
        $null = New-Item -ItemType Directory -Path $stagingLib -Force
        Copy-FileAtomicVerified -Source $SourceSubagentCorrelationLibrary -Destination $stagingLibrary -Label '暂存子Agent关联库'
        Copy-FileAtomicVerified -Source $SourceScript -Destination $stagingProgram -Label '暂存主处理器'
        Assert-NoUnsafeGenericListConstruction -Path $stagingLibrary -Label '暂存子Agent关联库'
        Assert-SubagentCorrelationRuntimeCompatibility -LibraryPath $stagingLibrary -Label '暂存子Agent关联库'
        Invoke-RuntimeSmokeTest -ProgramPath $stagingProgram -PackageVersion $PackageVersion -ConfigJson $DefaultConfigJson -Label '暂存运行时'

        $null = New-Item -ItemType Directory -Path $runtimeBackupRoot -Force
        if ($programExisted) { Copy-Item -LiteralPath $InstalledScript -Destination $programBackupPath -Force }
        if ($libraryExisted) { Copy-Item -LiteralPath $InstalledSubagentCorrelationLibrary -Destination $libraryBackupPath -Force }
        if ($versionExisted) { Copy-Item -LiteralPath $InstalledVersionPath -Destination $versionBackupPath -Force }
        if ($configExisted) {
            Copy-Item -LiteralPath $InstalledConfig -Destination $configBackupPath -Force
            Write-Host "已创建配置备份：$configBackupPath"
        }
        if ($hooksExisted) {
            Copy-Item -LiteralPath $HooksPath -Destination $hooksBackupPath -Force
            Write-Host "已创建 hooks.json 备份：$hooksBackupPath"
        }

        # Dependency first: an older main program remains usable while the new
        # library is installed; VERSION and hooks are committed only after smoke tests.
        $runtimeTouched = $true
        Copy-FileAtomicVerified -Source $SourceSubagentCorrelationLibrary -Destination $InstalledSubagentCorrelationLibrary -Label '子Agent关联库'
        Copy-FileAtomicVerified -Source $SourceScript -Destination $InstalledScript -Label '主处理器'

        $configTouched = $true
        Write-Utf8FileAtomic -Path $InstalledConfig -Content $updatedConfigJson
        $installedConfigCheck = [IO.File]::ReadAllText($InstalledConfig, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ([int]$installedConfigCheck.schemaVersion -ne $ExpectedSchemaVersion) {
            throw "已安装配置 schemaVersion 不是 $ExpectedSchemaVersion。"
        }

        Copy-FileAtomicVerified -Source $SourceVersionPath -Destination $InstalledVersionPath -Label 'VERSION'
        $installedVersionCheck = [IO.File]::ReadAllText($InstalledVersionPath, [Text.Encoding]::UTF8).Trim()
        if (-not [string]::Equals($installedVersionCheck, $PackageVersion, [StringComparison]::Ordinal)) {
            throw "已安装 VERSION 不正确：$installedVersionCheck"
        }

        Assert-PowerShellSyntax -Path $InstalledScript -Label '已安装主处理器'
        Assert-PowerShellSyntax -Path $InstalledSubagentCorrelationLibrary -Label '已安装子Agent关联库'
        Assert-NoUnsafeGenericListConstruction -Path $InstalledSubagentCorrelationLibrary -Label '已安装子Agent关联库'
        Assert-SubagentCorrelationRuntimeCompatibility -LibraryPath $InstalledSubagentCorrelationLibrary -Label '已安装子Agent关联库'
        Invoke-RuntimeSmokeTest -ProgramPath $InstalledScript -PackageVersion $PackageVersion -ConfigJson $DefaultConfigJson -Label '已安装运行时'

        $hooksTouched = $true
        Write-Utf8FileAtomic -Path $HooksPath -Content $json
        $null = [IO.File]::ReadAllText($HooksPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        $installError = $_
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()

        if ($runtimeTouched) {
            try { Restore-InstalledFile -TargetPath $InstalledScript -BackupPath $programBackupPath -ExistedBefore $programExisted }
            catch { $rollbackErrors.Add('主处理器：' + $_.Exception.Message) }
            try { Restore-InstalledFile -TargetPath $InstalledSubagentCorrelationLibrary -BackupPath $libraryBackupPath -ExistedBefore $libraryExisted }
            catch { $rollbackErrors.Add('子Agent关联库：' + $_.Exception.Message) }
            try { Restore-InstalledFile -TargetPath $InstalledVersionPath -BackupPath $versionBackupPath -ExistedBefore $versionExisted }
            catch { $rollbackErrors.Add('VERSION：' + $_.Exception.Message) }
        }
        if ($configTouched) {
            try { Restore-InstalledFile -TargetPath $InstalledConfig -BackupPath $configBackupPath -ExistedBefore $configExisted }
            catch { $rollbackErrors.Add('config.json：' + $_.Exception.Message) }
        }
        if ($hooksTouched) {
            try { Restore-InstalledFile -TargetPath $HooksPath -BackupPath $hooksBackupPath -ExistedBefore $hooksExisted }
            catch { $rollbackErrors.Add('hooks.json：' + $_.Exception.Message) }
        }

        $rollbackText = '回滚已完成。'
        if ($rollbackErrors.Count -gt 0) {
            $rollbackText = '回滚存在错误：' + (@($rollbackErrors) -join '；')
        }
        throw "安装失败，未保留部分升级状态。$rollbackText 原因：$($installError.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $stagingRoot) {
            Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
if ($applyInstallation) {
    Write-Host 'codex-task-stats 安装成功。' -ForegroundColor Green
}
else {
    Write-Host '安装预览完成，未修改任何文件。' -ForegroundColor Yellow
}
Write-Host "版本：$PackageVersion"
Write-Host "模式：$IntermediateMode"
Write-Host "程序：$InstalledScript"
Write-Host "运行时库：$InstalledSubagentCorrelationLibrary"
Write-Host "配置：$InstalledConfig"
Write-Host ''
if ($IntermediateMode -eq 'Quiet') {
    Write-Host 'Quiet 模式将中间 Hook 设为异步，界面通常只显示 UserPromptSubmit 和 Stop。'
    Write-Host 'Stop 会短暂等待晚到事件；该模式优先保持界面简洁，不保证绝对事件顺序。'
}
else {
    Write-Host 'Strict 模式同步执行中间处理器，顺序更强，但 Codex 可能在界面显示这些 Hook 运行记录。'
}
Write-Host '请完全重启 Codex/ChatGPT，在支持时打开 /hooks，并信任新增或变化的 Hook 定义。'
if ($applyInstallation) {
    Write-Host '安装程序已执行源／暂存／已安装关联库兼容性检查，以及包含子 turn 的运行时烟雾测试。运行 scripts\status.ps1，确认 OverallHealthy 为 True。'
}
else {
    Write-Host '预览模式未复制文件、未写入 Hook，也未执行运行时烟雾测试。'
}
