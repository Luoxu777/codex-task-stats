[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$main = Join-Path $project 'src\codex-task-stats.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
$config = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-tokens-' + [Guid]::NewGuid().ToString('N'))
$transcript = Join-Path $root 'main.jsonl'
$stats = Join-Path $root 'stats'
$oldStats = $env:CODEX_TASK_STATS_HOME
$session = 'token-session'
$script:checks = 0
function Check { param([bool]$Condition,[string]$Message) $script:checks++; if (-not $Condition) { throw $Message } }
function Write-DebugRecord { param([string]$Message) }
function Append-Record { param([object]$Record) [IO.File]::AppendAllText($transcript, ($Record | ConvertTo-Json -Depth 15 -Compress) + "`n", $utf8) }
function Start-Turn { param([string]$Turn='turn') Append-Record @{type='event_msg';payload=@{type='task_started';turn_id=$Turn}} }
function Reset-Transcript {
    [IO.File]::WriteAllText($transcript,'',$utf8)
    Append-Record @{type='session_meta';payload=@{id=$session}}
}
function Usage {
    param([long]$InputCount=768000,[long]$OutputCount=48000,[long]$Cached=576000,[long]$Reasoning=30000)
    return @{ input_tokens=$InputCount; output_tokens=$OutputCount; cached_input_tokens=$Cached; cache_write_input_tokens=[long]0; reasoning_output_tokens=$Reasoning; total_tokens=($InputCount+$OutputCount) }
}
function Add-Usage { param([object]$Value=(Usage)) Append-Record @{type='event_msg';payload=@{type='token_count';info=@{total_token_usage=$Value;last_token_usage=(Usage 1 1 0 0)}}} }
function Capture { param([string]$Turn='turn') return (Read-TokenObservation $transcript $session $Turn -CaptureBaseline).Baseline }
function Observe { param([object]$Baseline=$null,[string]$Turn='turn') return Read-TokenObservation $transcript $session $Turn -Baseline $Baseline }
function Save-Config { [IO.File]::WriteAllText((Join-Path $stats 'config\config.json'),($config | ConvertTo-Json -Depth 30),$utf8) }
function Hook {
    param([string]$Event,[string]$Turn='turn',[hashtable]$Fields=@{})
    $payload=@{session_id=$session;turn_id=$Turn;cwd=$root;transcript_path=$transcript;hook_event_name=$Event}
    foreach($key in $Fields.Keys){$payload[$key]=$Fields[$key]}
    $p=[Diagnostics.Process]::new()
    $p.StartInfo=[Diagnostics.ProcessStartInfo]::new('powershell.exe',('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$main+'" -Event '+$Event))
    $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardInput=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
    $p.StartInfo.StandardOutputEncoding=$utf8; $p.StartInfo.StandardErrorEncoding=$utf8
    try {
        $null=$p.Start(); $p.StandardInput.WriteLine(($payload | ConvertTo-Json -Compress -Depth 10)); $p.StandardInput.Close()
        $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit(15000)){ $p.Kill(); throw 'Token Hook 超过 15 秒' }
        Check ($p.ExitCode -eq 0 -and -not $err.Result) ('Hook 执行失败：'+$err.Result)
        if($out.Result.Trim()){return ($out.Result | ConvertFrom-Json)}
    } finally { $p.Dispose() }
}
function Completed { param([string]$Turn='turn') return Get-Content (Join-Path $stats ('data\completed\'+(Get-Sha256Hex ($session+"`n"+$Turn))+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json }
try {
    $null=New-Item -ItemType Directory -Path $root,(Join-Path $stats 'config') -Force
    Reset-Transcript; Start-Turn 'previous'; Add-Usage (Usage 640000 40000 480000 25000); Start-Turn
    $baseline=Capture
    Check $baseline.Valid '应保存首次输入前累计基线'
    $noUsage=Observe $baseline
    Check ($noUsage.Turn.Unknown -and $null -eq $noUsage.Session.Usage) '仅有本轮开始标记时，不能把上一轮用量当作本轮零值'
    Add-Usage (Usage 700000 45000 520000 28000); Add-Usage; Add-Usage
    $observation=Observe $baseline
    Check (-not $observation.Turn.Unknown -and $observation.Turn.Usage.total -eq 136000) '多请求和重复快照应只计算累计差值'
    Check ($observation.Session.Usage.total -eq 816000) '当前会话累计错误'
    $lines=@(Get-TokenLines $observation)
    Check (($lines -join "`n") -match '总量 +： +136,000' -and ($lines -join "`n") -match '推理占比 +： +63%') '千分位及 62.5% 四舍五入错误'
    Check (($lines -join "`n") -notmatch '\d+\.\d+%') '百分比不得保留小数'
    $logLines=@(Get-TokenLines $observation -ForLog)
    Check ($logLines -contains '总量：136,000' -and ($logLines -join '') -notmatch '📊|📈|总量 +：') '日志不应包含 UI 填充或图标'

    foreach($mode in @('center','left','right','none')) {
        $config.display.labelAlignment=$mode
        $formatted=@(Get-TokenLines $observation)
        Check ($formatted.Count -eq 23) ('Token 字段数量错误：'+$mode)
        if($mode -ne 'none') {
            $widths=@($formatted | Where-Object {$_ -match '：'} | ForEach-Object {Get-LabelDisplayWidth ($_.Substring(0,$_.IndexOf('：')))})
            $range=$widths | Measure-Object -Minimum -Maximum
            Check (($range.Maximum-$range.Minimum) -le 1.1) ('Token 冒号宽度偏差过大：'+$mode)
            $valueWidths=@($formatted | Where-Object {$_ -match '：'} | ForEach-Object {Get-LabelDisplayWidth ($_.Substring($_.IndexOf('：')+1))})
            $valueRange=$valueWidths | Measure-Object -Minimum -Maximum
            Check (($valueRange.Maximum-$valueRange.Minimum) -le 1.1) ('两组数字和百分比必须共用右边界：'+$mode)
            Check (@($formatted | Where-Object {$_ -match '：\S'}).Count -eq 0) '数值列与冒号之间至少一个空格'
        }
        else { Check (($formatted -join '') -match '总量：136,000' -and ($formatted -join '') -notmatch '： +') 'none 必须保持紧凑格式' }
    }
    $config.display.labelAlignment='center'
    $wideUsage=Usage 1234567890 48000 576000 30000; $wideUsage.Remove('cache_write_input_tokens')
    $wideObservation=[pscustomobject]@{Turn=$observation.Turn;Session=[pscustomobject]@{Usage=(ConvertTo-TokenUsage ([pscustomobject]$wideUsage));Unknown=$false;Reasons=@()}}
    $wideLines=@(Get-TokenLines $wideObservation)
    $wideValues=@($wideLines | Where-Object {$_ -match '：'} | ForEach-Object {Get-LabelDisplayWidth ($_.Substring($_.IndexOf('：')+1))}) | Measure-Object -Minimum -Maximum
    Check (($wideValues.Maximum-$wideValues.Minimum) -le 1.1 -and ($wideLines -join '') -match '： +未提供') '不同数量级、零值与缺失提示应共用数值列宽'
    $config.tokenStatistics.showSession=$false
    $turnOnly=@(Get-TokenLines $wideObservation)
    Check ((Get-LabelDisplayWidth $turnOnly[1]) -lt (Get-LabelDisplayWidth $wideLines[1])) '隐藏会话范围后不能继续保留其较宽数值列'
    $config.tokenStatistics.showSession=$true; $config.tokenStatistics.fields=@('output')
    $outputOnly=@(Get-TokenLines $wideObservation)
    Check ((Get-LabelDisplayWidth ($outputOnly[1].Split('：')[1])) -lt $wideValues.Minimum) '隐藏字段不能继续占用数值列宽'
    $config.tokenStatistics.fields=@(Get-TokenMetrics | ForEach-Object {$_.Key})
    $config.display.labelAlignment='center'; $config.display.labels.skill='非常长的自定义 Skill 标签'; $config.display.icons.end='END'
    $aligned=Get-DisplayAlignmentOptions
    $endPrefix=Format-LabelPrefix -Label '结束' -HighlightStyle 'icon' -Icon 'END' @aligned
    $tokenTotalLine=@(Get-TokenLines $observation)[1]
    Check ([Math]::Abs((Get-LabelDisplayWidth $endPrefix)-(Get-LabelDisplayWidth ($tokenTotalLine.Substring(0,$tokenTotalLine.IndexOf('：')+1)))) -le 1.1) '自定义图标、长标签与 Token 应共享冒号位置'
    $config.display.labels.skill='Skill'; $config.display.icons.end='🔴'
    function New-Object { throw '测试字体不可用' }
    try {
        $fallbackLines=@(Get-TokenLines $wideObservation)
        Check (($fallbackLines -join '') -match '136,000') '字体测量不可用时 Token 仍应可读'
        $fallbackWidths=@($fallbackLines | Where-Object {$_ -match '：'} | ForEach-Object {Get-LabelDisplayWidth ($_.Substring($_.IndexOf('：')+1))}) | Measure-Object -Minimum -Maximum
        Check ($fallbackWidths.Minimum -eq $fallbackWidths.Maximum) '字体测量不可用时中文占位与数字仍应按估算列宽右对齐'
    }
    finally { Remove-Item Function:\New-Object }
    $config.display.multiline=$false
    Check ((@(Get-TokenLines $observation) -join '｜') -notmatch "`n|： +") '单行 Token 不应含换行或数值填充'
    $config.display.multiline=$true; $config.display.highlightStyle='bracket'
    Check ((@(Get-TokenLines $observation) -join '') -match '【总量】136,000') 'Token 括号样式错误'
    $config.display.highlightStyle='none'
    Check ((@(Get-TokenLines $observation) -join '') -notmatch '📊|📈') '关闭图标后不应保留 Token 图标'
    $config.display.highlightStyle='icon'; $config.display.labelAlignment='center'
    $config.tokenStatistics.showSession=$false; $config.tokenStatistics.fields=@('total','total','not-a-field')
    Check (@(Get-TokenLines $observation).Count -eq 2) '范围开关、字段白名单或去重错误'
    Check (@(Get-TokenLines $observation -ForLog).Count -gt 20) '客户端字段开关不能裁剪日志数据'
    $config.tokenStatistics.fields=@()
    Check (@(Get-TokenLines $observation).Count -eq 0) '空字段数组应隐藏两个区块'
    $config.tokenStatistics.enabled=$false
    Check (@(Get-TokenLines $observation).Count -eq 0) '总关闭应隐藏 Token'
    $config.tokenStatistics.enabled='false'; $config.tokenStatistics.fields='total'
    Check ((Get-TokenOptions).Enabled -and (Get-TokenOptions).Fields.Count -eq 10) '无效类型应回退默认值'
    $config.PSObject.Properties.Remove('tokenStatistics')
    Check ((Get-TokenOptions).Enabled -and (Get-TokenOptions).ShowSession) '旧配置应默认开启两个范围'
    $config=Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $zeroRange=[pscustomobject]@{Usage=(ConvertTo-TokenUsage -Zero);Unknown=$false;Reasons=@()}
    foreach($metric in Get-TokenMetrics) {
        $value=Format-TokenValue $zeroRange $metric
        if($metric.Key -in @('cacheHitRate','reasoningShare')){Check ($value -eq '不适用') '零分母应不适用'}
        else {Check ($value -eq '0') '真实零值应保留'}
    }
    $bad=Usage 10 5 11 6; $bad.Remove('cache_write_input_tokens')
    $badRange=[pscustomobject]@{Usage=(ConvertTo-TokenUsage ([pscustomobject]$bad));Unknown=$false;Reasons=@()}
    $values=@{}; foreach($metric in Get-TokenMetrics){$values[$metric.Key]=Format-TokenValue $badRange $metric}
    Check ($values.cacheWrite -eq '未提供' -and $values.uncachedInput -eq '未确认' -and $values.reasoningShare -eq '未确认') '缺失和矛盾细分应区别显示'
    $bad.input_tokens=-1; $badRange.Usage=ConvertTo-TokenUsage ([pscustomobject]$bad)
    Check ((Format-TokenValue $badRange (@(Get-TokenMetrics)[1])) -eq '未确认') '负数不能展示为零'
    $large=Usage 3000000000 1000 2000000000 0
    Check ((ConvertTo-TokenUsage ([pscustomobject]$large)).input -eq 3000000000) '计数必须支持 Int64'
    $missing=Usage 10 5 0 0; $missing.Remove('cached_input_tokens')
    $missingRange=[pscustomobject]@{Usage=(ConvertTo-TokenUsage ([pscustomobject]$missing));Unknown=$false;Reasons=@()}
    $values=@{}; foreach($metric in Get-TokenMetrics){$values[$metric.Key]=Format-TokenValue $missingRange $metric}
    Check ($values.cachedInput -eq '未提供' -and $values.uncachedInput -eq '未确认' -and $values.cacheHitRate -eq '未确认') '推导项缺操作数应未确认，原始字段应未提供'

    Start-Turn 'next'; Add-Usage (Usage 999999 99999 1 1)
    Check ((Observe $baseline).Session.Usage.total -eq 816000) '下一轮不能污染上一轮截止值'
    Check (-not (Observe $baseline).Turn.Unknown) '下一轮的计数变化不能改变已截止轮次的完整性'
    $wrong=Read-TokenObservation $transcript 'another-session' 'turn'
    Check $wrong.Session.Unknown '必须校验 session_meta 身份'
    $original=[IO.File]::ReadAllText($transcript)
    [IO.File]::WriteAllText($transcript,($original.Replace('640000','640001')+' '),$utf8)
    Check ((Observe $baseline).Turn.Unknown -and (Observe $baseline).Session.Unknown) '同路径更长替换必须拒绝旧基线'
    [IO.File]::WriteAllText($transcript,$original.Replace('640000','640001'),$utf8)
    Check (Observe $baseline).Turn.Unknown '同路径等长替换必须拒绝旧基线'
    [IO.File]::WriteAllText($transcript,$original.Substring(0,30),$utf8)
    Check (Observe $baseline).Turn.Unknown '截断不能作差'
    Reset-Transcript; Start-Turn 'previous'; Add-Usage (Usage 100 0 0 0)
    Append-Record @{type='response_item';payload=@{text=('保持不变的填充'*400)}}
    Start-Turn; $distantBaseline=Capture
    $distantText=[IO.File]::ReadAllText($transcript)
    [IO.File]::WriteAllText($transcript,($distantText.Replace(':100',':200')),$utf8)
    Add-Usage (Usage 300 0 0 0)
    Check (Observe $distantBaseline).Turn.Unknown '起始累计记录在末尾指纹之外时仍须核验，不能错误计算300减100'
    [IO.File]::WriteAllText($transcript,$original,$utf8)
    [IO.File]::AppendAllText($transcript,'{"type":"event_msg","payload":{"type":"token_count"',$utf8)
    Check ((Observe $baseline).Session.Reasons -contains '末尾记录尚未完整') 'EOF 半行必须忽略并标记'
    Reset-Transcript; Start-Turn; $first=Capture; Add-Usage (Usage 10 5 0 0)
    Check ((Observe $first).Turn.Usage.total -eq 15) '新会话可信零起点错误'
    Add-Usage $missing
    Check ((Observe $first).Session.Reasons -contains '缓存推导项缺少输入或缓存读取计数') '推导项缺失原因必须保存在观测结果'
    Add-Usage (Usage 1 1 0 0)
    Check ((Observe $first).Turn.Unknown -and (Observe $first).Session.Reasons -contains '累计计数回退') '计数回退不能作差'
    Reset-Transcript; Start-Turn; $first=Capture
    $padding=(@{type='response_item';payload=@{text=('x'*1024)}} | ConvertTo-Json -Depth 4 -Compress)+"`n"
    [IO.File]::AppendAllText($transcript,(-join (1..4300 | ForEach-Object {$padding})),$utf8)
    Add-Usage
    $bounded=Observe $first
    Check ($bounded.BytesRead -le 4194304 -and $bounded.LinesRead -le 10000 -and $bounded.Turn.Unknown) '多个切片不能突破读取额度'
    Check ($bounded.Session.Reasons -contains '用量缺少轮次边界') '尾读起点不可默认归属当前轮'
    Reset-Transcript; Start-Turn; $first=Capture
    [IO.File]::AppendAllText($transcript,(-join (1..10020 | ForEach-Object {'{"type":"response_item"}'+"`n"})),$utf8)
    Add-Usage
    Check ((Observe $first).Session.Reasons -contains '记录行数超出读取额度') '行数额度必须生效'
    Reset-Transcript; Start-Turn; Add-Usage (Usage 10 5 0 0)
    $withBom=[IO.File]::ReadAllText($transcript)
    [IO.File]::WriteAllText($transcript,$withBom,[Text.UTF8Encoding]::new($true))
    $bomBaseline=Capture; Add-Usage (Usage 20 10 0 0)
    Check ($bomBaseline.Valid -and (Observe $bomBaseline).Turn.Usage.total -eq 30) 'UTF-8 BOM 不能改变基线记录偏移或指纹'

    # 通过真实 Hook 子进程验证基线持久化、冻结与日志补写。
    Reset-Transcript; Start-Turn 'previous'; Add-Usage (Usage 640000 40000 480000 25000); Start-Turn
    $config.skillCollection.transcript.enabled=$false; $config.skillCollection.transcript.readMain=$false
    $config.collection.settleInitialMs=0; $config.collection.settleQuietMs=0; $config.collection.settleMaxMs=0
    Save-Config; Copy-Item (Join-Path $project 'VERSION') $stats; $env:CODEX_TASK_STATS_HOME=$stats
    $null=Hook 'UserPromptSubmit'
    Add-Usage (Usage 700000 45000 520000 28000)
    $null=Hook 'UserPromptSubmit'
    Add-Usage
    $blockedLog=Join-Path $stats ('logs\codex-task-'+(Get-Date -Format 'yyyy-MM-dd')+'.log')
    $null=New-Item -ItemType Directory -Path $blockedLog -Force
    $pending=Hook 'Stop'
    Check ($pending.systemMessage -match '日志写入失败' -and $pending.systemMessage -match '136,000') 'Skill 关闭、追加输入或日志失败不应改变 Token'
    Add-Usage (Usage 999999 99999 1 1)
    Remove-Item -LiteralPath $blockedLog -Force
    $done=Hook 'Stop'; $duplicate=Hook 'Stop'
    Check ($done.systemMessage -ceq $duplicate.systemMessage -and $done.systemMessage -match '136,000') '重复 Stop 必须复用冻结结果'
    $record=Completed
    Check ($record.tokenStatistics.Turn.Usage.total -eq 136000 -and $record.tokenStatistics.Session.Usage.total -eq 816000) 'completed 必须保留冻结原始数值'
    $log=[IO.File]::ReadAllText($blockedLog)
    Check (([regex]::Matches($log,'【本轮 Token】')).Count -eq 1 -and $log.Contains('总量：136,000')) '日志补写不能重复或改值'
    Reset-Transcript; Start-Turn 'stop-only'; Add-Usage
    $null=Hook 'Stop' 'stop-only'
    Check ((Completed 'stop-only').tokenStatistics.Turn.Unknown -and (Completed 'stop-only').tokenStatistics.Session.Usage.total -eq 816000) 'Stop 补建状态不能产生虚假零基线'
    Reset-Transcript; Start-Turn 'recover'; Add-Usage (Usage 10 5 0 0)
    $null=Hook 'PreCompact' 'recover'; $null=Hook 'UserPromptSubmit' 'recover'; Add-Usage
    $null=Hook 'Stop' 'recover'
    Check (Completed 'recover').tokenStatistics.Turn.Unknown 'PreCompact 恢复快照不能冒充首次输入前起点'
    Reset-Transcript; Start-Turn 'old-state'
    $null=Hook 'UserPromptSubmit' 'old-state'
    $oldStatePath=Join-Path $stats ('data\state\'+(Get-Sha256Hex ($session+"`n"+'old-state'))+'.json')
    $oldState=Get-Content $oldStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $oldState.PSObject.Properties.Remove('tokenBaseline')
    [IO.File]::WriteAllText($oldStatePath,($oldState | ConvertTo-Json -Depth 20),$utf8)
    Add-Usage; $null=Hook 'Stop' 'old-state'
    Check (Completed 'old-state').tokenStatistics.Turn.Unknown '升级后的旧状态不能假定零起点'
    Reset-Transcript; Start-Turn 'no-log'
    $config.logging.enabled=$false; Save-Config
    $null=Hook 'UserPromptSubmit' 'no-log'; Add-Usage
    Check ((Hook 'Stop' 'no-log').systemMessage -match '816,000') '关闭日志仍须生成 Token 摘要'
    Check ($null -eq (Completed 'no-log').logFileName) '关闭日志不应生成日志文件名'
    Reset-Transcript; Start-Turn 'disabled'
    $config.tokenStatistics.enabled=$false; Save-Config
    $null=Hook 'UserPromptSubmit' 'disabled'
    $stateFile=Join-Path $stats ('data\state\'+(Get-Sha256Hex ($session+"`n"+'disabled'))+'.json')
    $state=Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($null -eq $state.PSObject.Properties['tokenBaseline']) '关闭采集不能写 Token 起点'
    $off=Hook 'Stop' 'disabled'
    Check ($off.systemMessage -notmatch 'Token' -and $null -eq (Completed 'disabled').PSObject.Properties['tokenStatistics']) '关闭采集不能输出或保存 Token'
    Write-Host ("Token 统计、边界、配置、排版与 Hook 冻结检查通过（$script:checks 项）。")
}
finally {
    $env:CODEX_TASK_STATS_HOME=$oldStats
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('codex-tokens-')) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
