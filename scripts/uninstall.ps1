<#
.SYNOPSIS
移除 Codex Task Stats Hook，并按选项清理本项目的数据。
.DESCRIPTION
默认只移除本项目 Hook。实际修改 hooks.json 前在 task-stats/backups 中备份。
RemoveProgram 保留每日日志和备份；同时指定 RemoveLogs 删除整个安装目录，包含卸载备份。
清理前请将需要保留的备份复制到安装目录之外。卸载后完全重启客户端。
.PARAMETER CodexHome
安装时使用的 Codex Home。未指定时依次使用 CODEX_HOME 环境变量和当前用户目录下的 .codex。
.PARAMETER RemoveProgram
删除程序、配置、统计状态、调试日志和版本文件，保留每日日志及备份。
.PARAMETER RemoveLogs
仅与 RemoveProgram 同时指定时生效，删除整个 task-stats 目录，包括日志及备份。
单独指定本参数不清理数据。
.EXAMPLE
.\scripts\uninstall.ps1 -CodexHome 'E:\.codex' -WhatIf
预览移除本项目 Hook，不修改文件。
.EXAMPLE
.\scripts\uninstall.ps1 -CodexHome 'E:\.codex' -RemoveProgram
移除本项目 Hook 和程序数据，保留每日日志及备份；执行前请求确认。
.EXAMPLE
.\scripts\uninstall.ps1 -CodexHome 'E:\.codex' -RemoveProgram -RemoveLogs -WhatIf
预览完整清理。确认范围并另行保存所需备份后，去掉 WhatIf 执行。
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [AllowNull()]
    [AllowEmptyString()]
    [string]$CodexHome,
    [switch]$RemoveProgram,
    [switch]$RemoveLogs
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
$BackupsRoot = Join-Path $InstallRoot 'backups'
$HooksPath = Join-Path $CodexHome 'hooks.json'

Write-CodexHomeSelection -ResolvedInfo $CodexHomeInfo -HooksPath $HooksPath -InstallRoot $InstallRoot -LogsPath (Join-Path $InstallRoot 'logs')
Write-Host ''

function Write-Utf8FileAtomic {
    param([string]$Path, [string]$Content)
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

function Test-IsTaskStatsHandler {
    param([object]$Handler)
    $text = ''
    foreach ($name in @('command', 'commandWindows', 'command_windows')) {
        $property = $Handler.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $text += [string]$property.Value + "`n"
        }
    }
    return $text -match '(?i)codex-task-stats\.ps1'
}

if (Test-Path -LiteralPath $HooksPath) {
    try {
        $root = [IO.File]::ReadAllText($HooksPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        throw "hooks.json 无效，卸载程序未修改该文件。错误：$($_.Exception.Message)"
    }

    if ($null -ne $root.PSObject.Properties['hooks']) {
        $eventNames = @($root.hooks.PSObject.Properties.Name)
        $removed = 0

        foreach ($eventName in $eventNames) {
            $groups = @($root.hooks.$eventName)
            $newGroups = [System.Collections.Generic.List[object]]::new()

            foreach ($group in $groups) {
                if ($null -eq $group) { continue }
                $hooksProperty = $group.PSObject.Properties['hooks']
                if ($null -eq $hooksProperty) {
                    $newGroups.Add($group)
                    continue
                }

                $remaining = [System.Collections.Generic.List[object]]::new()
                foreach ($handler in @($hooksProperty.Value)) {
                    if ($null -ne $handler -and (Test-IsTaskStatsHandler -Handler $handler)) {
                        $removed++
                    }
                    else {
                        $remaining.Add($handler)
                    }
                }

                if ($remaining.Count -gt 0) {
                    $group.hooks = @($remaining)
                    $newGroups.Add($group)
                }
            }

            if ($newGroups.Count -eq 0) {
                $root.hooks.PSObject.Properties.Remove($eventName)
            }
            else {
                $root.hooks.$eventName = @($newGroups)
            }
        }

        if ($removed -gt 0 -and $PSCmdlet.ShouldProcess($HooksPath, "移除 $removed 个 codex-task-stats 处理器")) {
            $null = New-Item -ItemType Directory -Path $BackupsRoot -Force
            $backupPath = Join-Path $BackupsRoot ('hooks.json.before-uninstall-' + [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss-fff'))
            Copy-Item -LiteralPath $HooksPath -Destination $backupPath -Force

            $json = $root | ConvertTo-Json -Depth 100
            $null = $json | ConvertFrom-Json
            Write-Utf8FileAtomic -Path $HooksPath -Content $json
            Write-Host "已移除 $removed 个处理器。备份：$backupPath" -ForegroundColor Green
        }
        elseif ($removed -eq 0) {
            Write-Host 'hooks.json 中未找到 codex-task-stats 处理器。'
        }
    }
}
else {
    Write-Host "未找到 hooks.json：$HooksPath"
}

if ($RemoveProgram) {
    if ($RemoveLogs) {
        if ((Test-Path -LiteralPath $InstallRoot) -and $PSCmdlet.ShouldProcess($InstallRoot, '删除程序、状态、备份、调试日志和每日日志')) {
            Remove-Item -LiteralPath $InstallRoot -Recurse -Force
        }
    }
    else {
        foreach ($path in @(
            (Join-Path $InstallRoot 'bin'),
            (Join-Path $InstallRoot 'config'),
            (Join-Path $InstallRoot 'data'),
            (Join-Path $InstallRoot 'debug'),
            (Join-Path $InstallRoot 'VERSION')
        )) {
            if ((Test-Path -LiteralPath $path) -and $PSCmdlet.ShouldProcess($path, '删除 task-stats 程序数据，并保留日志和备份')) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        }
    }
}

Write-Host '卸载或修改 Hook 定义后，请完全重启 Codex/ChatGPT。'
