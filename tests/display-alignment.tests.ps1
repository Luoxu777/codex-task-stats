[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'src\codex-task-stats.ps1'), [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
. (Join-Path $project 'src\lib\SubagentCorrelation.ps1')
$config = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
# 保留原分类的精确排版契约；Token 组合排版由 token-statistics.tests.ps1 覆盖。
$config.tokenStatistics.enabled = $false
$ProgramVersion = 'v4.0'
$TestDurationMilliseconds = 1000
$state = [pscustomobject]@{ startedAt='2026-09-28T10:00:00+08:00'; startSource='UserPromptSubmit'; promptCount=1 }
$events = @([pscustomobject]@{ event='PostToolUse'; toolName='mcp__test__read'; toolUseId='one' })
$observation = Get-TranscriptActivityObservation -Text '' -ExpectedTurnId 'alignment' -Cwd $project
function Check { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Summary {
    Build-Summary -State $state -Events $events -EndedAt ([DateTimeOffset]::Parse('2026-09-28T10:00:01+08:00')) -EndMonotonicTicks 0 -StopPayload ([pscustomobject]@{status='completed'}) -MainSkillObservation $null -ActivityObservation $observation
}
Check ($config.display.labelAlignment -eq 'center') '默认配置必须居中'
$expected = @{
    center = @('🔴    结束    ：', '🔌    MCP    ：test/read ×1')
    left = @('🔴 结束       ：', '🔌 MCP       ：test/read ×1')
    right = @('🔴       结束 ：', '🔌       MCP ：test/read ×1')
    none = @('🔴 结束：', '🔌 MCP：test/read ×1')
}
foreach ($mode in @('center','left','right','none')) {
    $config.display.labelAlignment = $mode
    $summary = Summary
    $lines = @($summary.Summary -split "`n")
    Check ($lines.Count -eq 2) ('空分类应隐藏：' + $summary.Summary)
    Check ($lines[0].StartsWith($expected[$mode][0]) -and $lines[0].EndsWith('10:00:01（用时：1秒）')) ('结束行格式错误：' + $mode + '；' + $lines[0])
    Check ($lines[1] -ceq $expected[$mode][1]) ('分类行格式错误：' + $mode)
    Check ($summary.McpLine -ceq 'MCP：test/read ×1') '日志不能加入对齐空格'
}
$config.display.PSObject.Properties.Remove('labelAlignment')
Check ((Summary).Summary.StartsWith($expected.center[0])) '旧配置缺失字段应居中'
$config.display | Add-Member -NotePropertyName labelAlignment -NotePropertyValue 'invalid'
Check ((Summary).Summary.StartsWith($expected.center[0])) '无效配置应居中'
$config.display.labelAlignment = 'center'
$config.display.hideEmptyCategories = $false
$lines = @((Summary).Summary -split "`n")
Check ($lines.Count -eq 7 -and $lines[3] -ceq '🤖 子Agent ：无' -and $lines[5] -ceq '🌿     Git      ：无') '空分类必须使用统一标签区'
$config.display.hideEmptyCategories = $true
$config.display.labels.subagent = '更长的子Agent'
$lines = @((Summary).Summary -split "`n")
Check ($lines[1] -ceq '🔌         MCP          ：test/read ×1') '隐藏分类的自定义长标签仍应决定宽度'
$config.display.labels.subagent = '子Agent'
$config.display.multiline = $false
Check ((Summary).Summary -match '^🔴 结束：[^\n]+｜🔌 MCP：test/read ×1$') '单行应保持紧凑格式'
$config.display.multiline = $true
$config.display.highlightStyle = 'bracket'
Check ((Summary).Summary.Contains('【MCP】test/read ×1')) '括号样式不应对齐'
$config.display.highlightStyle = 'none'
$lines = @((Summary).Summary -split "`n")
Check ($lines[0].StartsWith('    结束    ：') -and $lines[1] -ceq '    MCP    ：test/read ×1') '无图标样式应对齐且不显示结束图标'
$config.display.highlightStyle = 'icon'
$config.display.labels.mcp = '接口：MCP'
$lines = @((Summary).Summary -split "`n")
Check ($lines[1] -ceq '🔌 接口：MCP ：test/read ×1') '标签内的冒号不能被拆分或替换'
# 通过真实入口验证输入提示与 Stop 共用配置、宽度和紧凑模式规则。
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-display-' + [guid]::NewGuid().ToString('N'))
$oldStatsHome = $env:CODEX_TASK_STATS_HOME
$savedConfig = $config | ConvertTo-Json -Depth 20
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $testRoot 'config'),(Join-Path $testRoot 'work') -Force
    $env:CODEX_TASK_STATS_HOME = $testRoot
    foreach ($case in @('center','left','right','none','missing','invalid','long-label','single-line','bracket','no-icon','custom-icon')) {
        $config = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $config.tokenStatistics.enabled = $false
        switch ($case) {
            'missing' { $config.display.PSObject.Properties.Remove('labelAlignment') }
            'long-label' { $config.display.labels.subagent = '更长的子Agent' }
            'single-line' { $config.display.multiline = $false }
            'bracket' { $config.display.highlightStyle = 'bracket' }
            'no-icon' { $config.display.highlightStyle = 'none' }
            'custom-icon' { $config.display.icons.start = '▶' }
            default { $config.display.labelAlignment = $case }
        }
        [IO.File]::WriteAllText((Join-Path $testRoot 'config\config.json'), ($config | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $payload = @{ session_id='display-test'; turn_id=$case; cwd=(Join-Path $testRoot 'work'); prompt='alignment' } | ConvertTo-Json -Compress
        $raw = $payload | & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'src\codex-task-stats.ps1') -Event UserPromptSubmit
        Check ($LASTEXITCODE -eq 0) ('输入 Hook 执行失败：' + $case)
        $message = ($raw | ConvertFrom-Json).systemMessage
        $stopPrefix = ((Summary).Summary -split '\d{2}:\d{2}:\d{2}', 2)[0]
        $startPrefix = $stopPrefix.Replace('结束','开始').Replace('🔴',[string]$config.display.icons.start)
        Check ($message -cmatch ('^' + [regex]::Escape($startPrefix) + '\d{2}:\d{2}:\d{2}$')) ('输入与结束对齐不一致：' + $case + '；' + $message)
    }
    $raw = $payload | & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'src\codex-task-stats.ps1') -Event UserPromptSubmit
    Check ($LASTEXITCODE -eq 0) '追加输入 Hook 执行失败'
    Check (($raw | ConvertFrom-Json).systemMessage -match '^ 第 2 次输入 ：\d{2}:\d{2}:\d{2}$') '追加输入应保留次数并应用标签间距'
}
finally {
    $env:CODEX_TASK_STATS_HOME = $oldStatsHome
    $config = $savedConfig | ConvertFrom-Json
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
# 字体测量应区分等长但不同字宽的英文标签。
Check ((Get-LabelDisplayWidth 'WWW') -gt 2 * (Get-LabelDisplayWidth 'iii')) '不能再将所有英文字符视为等宽'
# 在参考字体中，三个模式的冒号偏差都不应超过一个空格。
foreach ($mode in @('center','left','right')) {
    $widths = foreach ($tag in @('结束','MCP','Skill','子Agent','文件','Git','其他')) {
        Get-LabelDisplayWidth (Format-LabelPrefix -Label $tag -LabelWidth (Get-LabelDisplayWidth '子Agent') -Alignment $mode)
    }
    $range = $widths | Measure-Object -Minimum -Maximum
    Check (($range.Maximum - $range.Minimum) -le 1) ('参考字体冒号偏差过大：' + $mode)
}
# 字体 API 不可用时仍能生成原来的估算列宽，不能阻断 Hook。
function New-Object { throw '测试：字体 API 不可用' }
try {
    Check ((Get-LabelDisplayWidth '子Agent') -eq 7) '字体测量失败应回退'
    Check ((Format-LabelPrefix -Label '结束' -LabelWidth 7 -Alignment 'center') -ceq '  结束   ：') '回退后仍应正常补空格'
}
finally { Remove-Item Function:\New-Object }
Write-Host '字体宽度、四种对齐、配置回退、自定义标签及日志兼容检查通过。'
