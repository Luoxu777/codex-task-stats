[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
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

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$InstallRoot = Join-Path $CodexHome 'task-stats'
$ConfigPath = Join-Path $InstallRoot 'config\config.json'
$BackupRoot = Join-Path $InstallRoot 'backups'
$HooksPath = Join-Path $CodexHome 'hooks.json'
$LogsPath = Join-Path $InstallRoot 'logs'

Write-CodexHomeSelection -ResolvedInfo $CodexHomeInfo -HooksPath $HooksPath -InstallRoot $InstallRoot -LogsPath $LogsPath
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

function Ensure-ObjectProperty {
    param(
        [object]$Object,
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        if ($null -eq $property) {
            $Object | Add-Member -NotePropertyName $Name -NotePropertyValue ([PSCustomObject]@{})
        }
        else {
            $Object.$Name = [PSCustomObject]@{}
        }
        return $true
    }
    if ($property.Value -isnot [PSCustomObject]) {
        throw "已安装配置中的 '$Name' 值无效，必须是 JSON 对象；未进行任何修改。"
    }
    return $false
}

function Set-RecommendedValue {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
        return $true
    }

    if (-not [object]::Equals($property.Value, $Value)) {
        $Object.$Name = $Value
        return $true
    }

    return $false
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "未找到已安装配置：$ConfigPath。请先安装 codex-task-stats。"
}

try {
    $config = [IO.File]::ReadAllText($ConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
}
catch {
    throw "已安装配置不是有效 JSON，未进行任何修改。错误：$($_.Exception.Message)"
}

if ($null -eq $config -or $config -isnot [PSCustomObject]) {
    throw '已安装配置的顶层必须是 JSON 对象，未进行任何修改。'
}

$changed = $false
if (Ensure-ObjectProperty -Object $config -Name 'tokenStatistics') { $changed = $true }
foreach ($name in @('enabled','showTurn','showSession')) {
    if (Set-RecommendedValue -Object $config.tokenStatistics -Name $name -Value $true) { $changed = $true }
}
$tokenFields = @('total','input','output','cachedInput','uncachedInput','cacheWrite','cacheHitRate','reasoningOutput','nonReasoningOutput','reasoningShare')
if (($config.tokenStatistics.PSObject.Properties.Name -notcontains 'fields') -or
    (($config.tokenStatistics.fields | ConvertTo-Json -Compress) -cne ($tokenFields | ConvertTo-Json -Compress))) {
    $null = Set-RecommendedValue -Object $config.tokenStatistics -Name 'fields' -Value $tokenFields
    $changed = $true
}
if (Ensure-ObjectProperty -Object $config -Name 'display') { $changed = $true }
if (Set-RecommendedValue -Object $config -Name 'schemaVersion' -Value 11) { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'multiline' -Value $true) { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'labelAlignment' -Value 'center') { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'showCoverageNotice' -Value $false) { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'showSuccessStatus' -Value $false) { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'hideEmptyCategories' -Value $true) { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'emptyValue' -Value '无') { $changed = $true }
if (Set-RecommendedValue -Object $config.display -Name 'highlightStyle' -Value 'icon') { $changed = $true }

if (Ensure-ObjectProperty -Object $config.display -Name 'icons') { $changed = $true }
foreach ($icon in @(
    [PSCustomObject]@{ Name = 'start'; Value = '🟢' },
    [PSCustomObject]@{ Name = 'end'; Value = '🔴' },
    [PSCustomObject]@{ Name = 'mcp'; Value = '🔌' },
    [PSCustomObject]@{ Name = 'skill'; Value = '🧩' },
    [PSCustomObject]@{ Name = 'subagent'; Value = '🤖' },
    [PSCustomObject]@{ Name = 'file'; Value = '📝' },
    [PSCustomObject]@{ Name = 'git'; Value = '🌿' },
    [PSCustomObject]@{ Name = 'other'; Value = '⚙️' }
)) {
    if (Set-RecommendedValue -Object $config.display.icons -Name $icon.Name -Value $icon.Value) { $changed = $true }
}


if (Ensure-ObjectProperty -Object $config.display -Name 'labels') { $changed = $true }
foreach ($label in @(
    [PSCustomObject]@{ Name = 'mcp'; Value = 'MCP' },
    [PSCustomObject]@{ Name = 'skill'; Value = 'Skill' },
    [PSCustomObject]@{ Name = 'subagent'; Value = '子Agent' },
    [PSCustomObject]@{ Name = 'file'; Value = '文件' },
    [PSCustomObject]@{ Name = 'git'; Value = 'Git' },
    [PSCustomObject]@{ Name = 'other'; Value = '其他' }
)) {
    if (Set-RecommendedValue -Object $config.display.labels -Name $label.Name -Value $label.Value) { $changed = $true }
}

if (Ensure-ObjectProperty -Object $config -Name 'commandLogging') { $changed = $true }
$currentCommandMode = 'safe'
$modeProperty = $config.commandLogging.PSObject.Properties['mode']
if ($null -ne $modeProperty -and $null -ne $modeProperty.Value) {
    $currentCommandMode = [string]$modeProperty.Value
}
if (-not [string]::Equals($currentCommandMode, 'off', [StringComparison]::OrdinalIgnoreCase)) {
    if (Set-RecommendedValue -Object $config.commandLogging -Name 'mode' -Value 'safe') { $changed = $true }
}
else {
    if (Set-RecommendedValue -Object $config.commandLogging -Name 'mode' -Value 'off') { $changed = $true }
}
foreach ($setting in @(
    [PSCustomObject]@{ Name = 'includeGit'; Value = $true },
    [PSCustomObject]@{ Name = 'includeShell'; Value = $true },
    [PSCustomObject]@{ Name = 'maxCommandChars'; Value = 4096 },
    [PSCustomObject]@{ Name = 'maxRunsPerTask'; Value = 200 }
)) {
    if (Set-RecommendedValue -Object $config.commandLogging -Name $setting.Name -Value $setting.Value) { $changed = $true }
}

if (Ensure-ObjectProperty -Object $config -Name 'fileTracking') { $changed = $true }
if (Set-RecommendedValue -Object $config.fileTracking -Name 'enabled' -Value $true) { $changed = $true }
if (Set-RecommendedValue -Object $config.fileTracking -Name 'parseApplyPatch' -Value $true) { $changed = $true }
if (Set-RecommendedValue -Object $config.fileTracking -Name 'gitStatusSupplement' -Value $true) { $changed = $true }
if ($null -eq $config.fileTracking.PSObject.Properties['gitStatusTimeoutMs']) {
    $config.fileTracking | Add-Member -NotePropertyName 'gitStatusTimeoutMs' -NotePropertyValue 1500
    $changed = $true
}
if ($null -eq $config.fileTracking.PSObject.Properties['maxGitStatusEntries']) {
    $config.fileTracking | Add-Member -NotePropertyName 'maxGitStatusEntries' -NotePropertyValue 5000
    $changed = $true
}

# v1.0 使用该别名统计 apply_patch 调用次数。v1.5 将文件变更
# in a dedicated category. Remove only the old default value; preserve a
# different user-defined value even though the runtime no longer uses it.
if ($null -ne $config.PSObject.Properties['toolAliases'] -and $null -ne $config.toolAliases) {
    $legacyAlias = $config.toolAliases.PSObject.Properties['apply_patch']
    if ($null -ne $legacyAlias -and [string]::Equals([string]$legacyAlias.Value, '文件修改', [StringComparison]::Ordinal)) {
        $config.toolAliases.PSObject.Properties.Remove('apply_patch')
        $changed = $true
    }
}

if (Ensure-ObjectProperty -Object $config -Name 'skillCollection') { $changed = $true }
if (Set-RecommendedValue -Object $config.skillCollection -Name 'mode' -Value 'multi-source') { $changed = $true }
if ($null -eq $config.skillCollection.PSObject.Properties['explicitMarkers']) {
    $config.skillCollection | Add-Member -NotePropertyName 'explicitMarkers' -NotePropertyValue @('$')
    $changed = $true
}
if (Set-RecommendedValue -Object $config.skillCollection -Name 'deduplicateWithinTurn' -Value $true) { $changed = $true }
if (Set-RecommendedValue -Object $config.skillCollection -Name 'maxStructuredNodes' -Value 2000) { $changed = $true }
if (Ensure-ObjectProperty -Object $config.skillCollection -Name 'commandRead') { $changed = $true }
foreach ($setting in @(
    [PSCustomObject]@{ Name = 'enabled'; Value = $true },
    [PSCustomObject]@{ Name = 'preferParsedCommand'; Value = $true },
    [PSCustomObject]@{ Name = 'rawCommandFallback'; Value = $true },
    [PSCustomObject]@{ Name = 'requireCompletedExecution'; Value = $true }
)) {
    if (Set-RecommendedValue -Object $config.skillCollection.commandRead -Name $setting.Name -Value $setting.Value) { $changed = $true }
}
if (Ensure-ObjectProperty -Object $config.skillCollection -Name 'transcript') { $changed = $true }
foreach ($setting in @(
    [PSCustomObject]@{ Name = 'enabled'; Value = $true },
    [PSCustomObject]@{ Name = 'readMain'; Value = $true },
    [PSCustomObject]@{ Name = 'readSubagents'; Value = $true },
    [PSCustomObject]@{ Name = 'requireSkillPathInXml'; Value = $true },
    [PSCustomObject]@{ Name = 'currentTurnLookbackEnabled'; Value = $true },
    [PSCustomObject]@{ Name = 'lookbackBytes'; Value = 1048576 },
    [PSCustomObject]@{ Name = 'settleInitialMs'; Value = 100 },
    [PSCustomObject]@{ Name = 'settleQuietMs'; Value = 100 },
    [PSCustomObject]@{ Name = 'settleMaxMs'; Value = 600 },
    [PSCustomObject]@{ Name = 'maxBytes'; Value = 4194304 },
    [PSCustomObject]@{ Name = 'maxLines'; Value = 10000 }
)) {
    if (Set-RecommendedValue -Object $config.skillCollection.transcript -Name $setting.Name -Value $setting.Value) { $changed = $true }
}

if (-not $changed) {
    Write-Host 'v4.0 推荐显示与采集配置已经生效。' -ForegroundColor Green
    Write-Host '成功状态：客户端中隐藏'
    Write-Host '耗时：按整数秒显示'
    Write-Host '空分类：客户端中隐藏'
    Write-Host '非空分类：使用图标突出显示，Git 位于“其他”之前'
    Write-Host 'Skill 统计：结构化/transcript 证据、SKILL.md 读取以及 $skill 回退'
    Write-Host '文件统计：根据成功 FileChange 记录与最终内容核验，证据不足时提示统计不完整'
    Write-Host 'Git 统计：分别显示运行、指令与实际变更数量，位置在“其他”之前'
    Write-Host '命令日志：仅保存 safe 模式处理后的内容，原始命令和敏感信息不落盘'
    exit 0
}

$json = $config | ConvertTo-Json -Depth 50
$null = $json | ConvertFrom-Json

if ($PSCmdlet.ShouldProcess($ConfigPath, '应用 v4.0 推荐显示与采集配置')) {
    $null = New-Item -ItemType Directory -Path $BackupRoot -Force
    $timestamp = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff')
    $backupPath = Join-Path $BackupRoot ('config.json.backup-' + $timestamp)
    Copy-Item -LiteralPath $ConfigPath -Destination $backupPath -Force
    Write-Utf8FileAtomic -Path $ConfigPath -Content $json

    Write-Host 'v4.0 推荐配置已应用。' -ForegroundColor Green
    Write-Host "备份：$backupPath"
    Write-Host '成功状态：客户端中隐藏；非成功状态继续显示'
    Write-Host '耗时：四舍五入到整数秒'
    Write-Host '空分类：客户端中隐藏'
    Write-Host '非空 MCP/Skill/子Agent/文件/Git/其他分类：使用图标突出显示'
    Write-Host 'Skill 统计：多源识别并包含 SKILL.md 读取证据；不校验已安装 Skill 名称'
    Write-Host '文件重命名：原路径计为删除，新路径计为新增'
    Write-Host '每日日志：保留固定空字段、文件统计、Git 变更统计和安全命令明细'
    Write-Host '命令日志：仅允许 safe 或 off；疑似敏感信息和无法安全解析的参数会被隐藏'
    Write-Host '本脚本未修改 hooks.json，因此无需重新信任 Hook。'
    Write-Host '下一条新任务应使用新格式；仅在客户端仍显示缓存内容时再完全重启。'
}
