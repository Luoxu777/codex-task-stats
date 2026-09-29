[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$version = [IO.File]::ReadAllText((Join-Path $project 'VERSION')).Trim()
$defaultConfig = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$expected = $defaultConfig.tokenStatistics | ConvertTo-Json -Compress -Depth 5

function Get-HeadingIds {
    param([string]$Text)
    # 仓库文档使用 ATX 标题；排除代码示例中的注释与伪标题。
    $body = [regex]::Replace($Text, '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*$', '')
    $seen = @{}
    foreach ($heading in [regex]::Matches($body, '(?m)^#{1,6}\s+(.+?)\r?$')) {
        $id = $heading.Groups[1].Value.ToLowerInvariant()
        $id = [regex]::Replace($id, '[^\p{L}\p{N}\p{M}_\-\s]', '')
        $id = [regex]::Replace($id, '\s', '-')
        if ($seen.ContainsKey($id)) {
            $seen[$id]++
            $id + '-' + $seen[$id]
        }
        else {
            $seen[$id] = 0
            $id
        }
    }
}

function Assert-LocalReference {
    param([string]$Source, [string]$Reference)
    if ($Reference -match '^[a-z][a-z0-9+.-]*:') { return }
    $parts = $Reference -split '#', 2
    $target = if ($parts[0]) { Join-Path (Split-Path -Parent $Source) ([Uri]::UnescapeDataString($parts[0])) } else { $Source }
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "$Source 包含不存在的本地引用：$Reference" }
    if ($parts.Count -eq 2 -and $parts[1]) {
        $ids = @(Get-HeadingIds ([IO.File]::ReadAllText($target)))
        if ([Uri]::UnescapeDataString($parts[1]) -cnotin $ids) { throw "$Source 包含不存在的标题锚点：$Reference" }
    }
}

foreach ($doc in @(Get-ChildItem -LiteralPath $project -Filter '*.md' -File | Where-Object { $_.Name -ne 'AGENTS.md' })) {
    $text = [IO.File]::ReadAllText($doc.FullName)
    if (([regex]::Matches($text,'(?m)^```')).Count % 2 -ne 0) { throw "$($doc.Name) 的代码围栏不成对" }
    if ([regex]::IsMatch($text,'(?m)[ \t]+$')) { throw "$($doc.Name) 含行尾空白" }
    foreach ($link in [regex]::Matches($text, '\]\(([^)]+)\)')) {
        Assert-LocalReference $doc.FullName $link.Groups[1].Value
    }
    foreach ($asset in [regex]::Matches($text, '<img\s+[^>]*src="([^"]+)"')) {
        Assert-LocalReference $doc.FullName $asset.Groups[1].Value
    }
}

function Get-ConfigLeafPaths {
    param([object]$Value, [string]$Prefix = '')
    foreach ($property in $Value.PSObject.Properties) {
        $path = if ($Prefix) { $Prefix + '.' + $property.Name } else { $property.Name }
        if ($property.Value -is [PSCustomObject]) { Get-ConfigLeafPaths $property.Value $path }
        else { $path }
    }
}

foreach ($name in @('CONFIGURATION.md', 'CONFIGURATION_EN.md')) {
    $configReference = [IO.File]::ReadAllText((Join-Path $project $name))
    foreach ($path in @(Get-ConfigLeafPaths $defaultConfig)) {
        $parentWildcard = ($path -replace '\.[^.]+$', '.*')
        if (-not $configReference.Contains('`' + $path + '`') -and -not $configReference.Contains('`' + $parentWildcard + '`')) {
            throw "$name 配置参考遗漏字段：$path"
        }
    }
}

foreach ($stem in @('CHANGELOG', 'CONTRIBUTING', 'SECURITY', 'CONFIGURATION')) {
    $zh = [IO.File]::ReadAllText((Join-Path $project ($stem + '.md')))
    $en = [IO.File]::ReadAllText((Join-Path $project ($stem + '_EN.md')))
    if (-not $zh.Contains('**简体中文** · [English](' + $stem + '_EN.md)') -or
        -not $en.Contains('[简体中文](' + $stem + '.md) · **English**')) {
        throw "$stem 缺少对应的语言切换入口。"
    }
    $outlines = @($zh, $en) | ForEach-Object {
        $body = [regex]::Replace($_, '(?ms)^```[^\r\n]*\r?\n.*?^```[^\r\n]*$', '')
        ([regex]::Matches($body, '(?m)^(#{1,6})\s+') | ForEach-Object { $_.Groups[1].Value }) -join ','
    }
    if ($outlines[0] -cne $outlines[1]) { throw "$stem 中英文章节层级不一致。" }
    if ($stem -eq 'CHANGELOG') {
        $versions = @($zh, $en) | ForEach-Object {
            ([regex]::Matches($_, '(?m)^## (v[^\r\n]+)') | ForEach-Object { $_.Groups[1].Value }) -join ','
        }
        if ($versions[0] -cne $versions[1] -or ($versions[0] -split ',') -cnotcontains $version) {
            throw '中英文变更记录的版本不一致或缺少当前版本。'
        }
    }
    if ($stem -eq 'CONFIGURATION') {
        # 配置表的字段顺序和以代码标记的默认值应一致，类型与解释允许翻译。
        $tables = @($zh, $en) | ForEach-Object {
            $rows = [regex]::Matches($_, '(?m)^\| `([^`]+)` \| ([^|]+) \|')
            ($rows | ForEach-Object {
                $defaults = ([regex]::Matches($_.Groups[2].Value, '`([^`]+)`') | ForEach-Object { $_.Groups[1].Value }) -join ','
                $_.Groups[1].Value + '=' + $defaults
            }) -join "`n"
        }
        if ($tables[0] -cne $tables[1]) { throw '中英文配置表的字段或默认值不一致。' }
    }
}
$uninstallHelp = Get-Help (Join-Path $project 'scripts\uninstall.ps1') -Full
if (-not ([string]$uninstallHelp.Synopsis).Contains('Codex Task Stats')) { throw '卸载脚本缺少可读取的帮助。' }
foreach ($parameter in @('CodexHome', 'RemoveProgram', 'RemoveLogs')) {
    $entry = @($uninstallHelp.parameters.parameter | Where-Object { $_.name -eq $parameter })
    if ($entry.Count -ne 1 -or -not $entry[0].description) { throw "卸载参数缺少帮助：$parameter" }
}

foreach ($name in @('README.md','README_EN.md','HOOK_DISPLAY.md','CONFIGURATION.md','CONFIGURATION_EN.md')) {
    $text = [IO.File]::ReadAllText((Join-Path $project $name), [Text.Encoding]::UTF8)
    if ($name -notin @('README.md', 'README_EN.md')) {
        if ($text.IndexOf(('**'+$version+'**'),[StringComparison]::Ordinal) -lt 0) { throw "$name 当前版本未同步" }
        continue
    }
    if (-not $text.Contains('assets/preview4.png')) { throw "$name 未使用当前预览图片。" }
    $found = $false
    foreach ($block in [regex]::Matches($text,'(?s)```json\r?\n(?<json>.*?)\r?\n```')) {
        $value = $block.Groups['json'].Value | ConvertFrom-Json
        if ($null -eq $value.PSObject.Properties['tokenStatistics']) { continue }
        $found = $true
        if (($value.tokenStatistics | ConvertTo-Json -Compress -Depth 5) -cne $expected) { throw "$name 的 Token 配置示例与默认配置不一致" }
    }
    if (-not $found) { throw "$name 缺少完整 Token 配置示例" }
    foreach ($field in $defaultConfig.tokenStatistics.fields) {
        if (-not [regex]::IsMatch($text,('(?m)^\| `'+[regex]::Escape($field)+'` \|'))) { throw "$name 缺少指标说明：$field" }
    }
    foreach ($display in @('136,000','816,000','75%','63%','读取时快照','未提供','未确认','不适用')) {
        if (-not $text.Contains($display)) { throw "$name 缺少已约定的示例或状态：$display" }
    }
}
Write-Host '双语文档结构、语言切换、配置字段与默认值、Token 示例、版本、本地链接与锚点、图片及卸载帮助检查通过。'
