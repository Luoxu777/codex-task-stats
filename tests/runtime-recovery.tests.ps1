[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $Utf8NoBom
[Console]::InputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom
$project = Split-Path -Parent $PSScriptRoot
$main = Join-Path $project 'src\codex-task-stats.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
foreach ($definition in $ast.EndBlock.Statements) {
    if ($definition -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($definition.Extent.Text)) }
}
. (Join-Path $project 'src\lib\SubagentCorrelation.ps1')
$config = Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-runtime-' + [Guid]::NewGuid().ToString('N'))
$work = Join-Path $root 'outer\task'
$stats = Join-Path $root 'stats'
$oldStats = $env:CODEX_TASK_STATS_HOME
$transcript = Join-Path $root 'turn.jsonl'
$session = 'runtime-session'
function Assert-Runtime { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Start-RuntimeHook {
    param([string]$Event,[string]$Turn='runtime-turn',[hashtable]$Fields=@{})
    $payload = @{session_id=$session;turn_id=$Turn;cwd=$work;transcript_path=$transcript;hook_event_name=$Event}
    foreach ($key in $Fields.Keys) { $payload[$key]=$Fields[$key] }
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = [Diagnostics.ProcessStartInfo]::new('powershell.exe', ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $main + '" -Event ' + $Event))
    $p.StartInfo.UseShellExecute=$false; $p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardInput=$true; $p.StartInfo.RedirectStandardOutput=$true; $p.StartInfo.RedirectStandardError=$true
    $p.StartInfo.StandardOutputEncoding=$Utf8NoBom; $p.StartInfo.StandardErrorEncoding=$Utf8NoBom
    $null=$p.Start()
    $p.StandardInput.WriteLine(($payload | ConvertTo-Json -Compress -Depth 12)); $p.StandardInput.Close()
    return $p
}
function Finish-RuntimeHook {
    param($Process)
    try {
        $stdout=$Process.StandardOutput.ReadToEndAsync(); $stderr=$Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit(10000)) { $Process.Kill(); throw 'Hook 超过 10 秒' }
        $output=$stdout.Result; $errorText=$stderr.Result
        Assert-Runtime ($Process.ExitCode -eq 0 -and -not $errorText) ('Hook 失败：' + $errorText)
        return ($output | ConvertFrom-Json)
    } finally { $Process.Dispose() }
}
function Hook { param([string]$Event,[string]$Turn='runtime-turn',[hashtable]$Fields=@{}) return Finish-RuntimeHook (Start-RuntimeHook $Event $Turn $Fields) }
try {
    $null=New-Item -ItemType Directory -Path $work,(Join-Path $work 'backend'),(Join-Path $work 'frontend'),(Join-Path $stats 'config') -Force
    $null=git -C (Split-Path -Parent $work) init --quiet
    $null=git -C (Join-Path $work 'backend') init --quiet
    [IO.File]::WriteAllText((Join-Path (Split-Path -Parent $work) 'outside.txt'),'outside',$Utf8NoBom)
    for($i=0;$i -lt 7;$i++){[IO.File]::WriteAllText((Join-Path $work ('backend\file'+$i+'.txt')),'before',$Utf8NoBom)}
    [IO.File]::WriteAllText($transcript,'',$Utf8NoBom)
    Copy-Item (Join-Path $project 'config\config.example.json') (Join-Path $stats 'config\config.json')
    Copy-Item (Join-Path $project 'VERSION') $stats
    $env:CODEX_TASK_STATS_HOME=$stats
    # An old session clock must not influence any new response.
    $legacyClockPath=Join-Path $stats ('data\timing\'+(Get-Sha256Hex $session)+'.json')
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $legacyClockPath) -Force
    [IO.File]::WriteAllText($legacyClockPath,'{"startedAt":"2020-01-01T00:00:00+08:00","inputCount":99}',$Utf8NoBom)
    $first=Hook 'UserPromptSubmit' 'runtime-turn' @{prompt='$analyze'}
    Assert-Runtime ($first.systemMessage -match '^🟢 +开始 +：') '首次输入提示错误'
    $statePath=Join-Path $stats ('data\state\'+(Get-Sha256Hex ($session+"`n"+'runtime-turn'))+'.json')
    $firstState=Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $null=Hook 'PostToolUse' 'runtime-turn' @{tool_name='mcp__filesystem__read_file';tool_use_id='mcp-before'}
    $null=Hook 'PostToolUse' 'runtime-turn' @{tool_name='Bash';tool_use_id='git-before';tool_input=@{command='git status'}}
    $null=Hook 'SubagentStart' 'runtime-turn' @{agent_id='review-child';agent_type='code_reviewer'}
    for($i=0;$i -lt 7;$i++){[IO.File]::WriteAllText((Join-Path $work ('backend\file'+$i+'.txt')),'after',$Utf8NoBom)}
    $a=Start-RuntimeHook 'UserPromptSubmit'; $b=Start-RuntimeHook 'UserPromptSubmit'
    $messages=@((Finish-RuntimeHook $a).systemMessage,(Finish-RuntimeHook $b).systemMessage)
    Assert-Runtime (@($messages -match '^ +第 2 次输入 +：').Count -eq 1 -and @($messages -match '^ +第 3 次输入 +：').Count -eq 1) '并发追加输入次数必须唯一'
    $laterState=Get-Content $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Runtime ($laterState.startedAt -eq $firstState.startedAt -and ($laterState.transcriptBaselineBytes -eq $firstState.transcriptBaselineBytes)) '追加输入不得覆盖文件基线或首次时间'
    Assert-Runtime ($laterState.promptCount -eq 3 -and $laterState.transcriptBaselineBytes -eq $firstState.transcriptBaselineBytes) '追加输入必须累加本轮次数，保留会话补采起点'
    $null=Hook 'PostToolUse' 'runtime-turn' @{tool_name='mcp__filesystem__read_file';tool_use_id='mcp-after'}
    $null=Hook 'PostToolUse' 'runtime-turn' @{tool_name='Bash';tool_use_id='shell-after';tool_input=@{command='echo ok'}}
    $null=Hook 'SubagentStop' 'runtime-turn' @{agent_id='review-child';agent_type='code_reviewer'}
    $records=@()
    foreach($group in @(@(0),@(1,2,3,4),@(5,6),@(0))) {
                $changes=@{}; foreach($i in $group){
            $previous=if($records.Count -eq 3){'after'}else{'before'}
            $changes[(Join-Path $work ('backend\file'+$i+'.txt'))]=@{type='update';unified_diff=("@@ -1 +1 @@`n-"+$previous+"`n\ No newline at end of file`n+after`n\ No newline at end of file`n")}
        }
        $records+=@{type='event_msg';payload=@{type='item_completed';turn_id='runtime-turn';item=@{type='FileChange';status='completed';id=('edit-'+$records.Count);changes=$changes}}}|ConvertTo-Json -Compress -Depth 10
    }
    [IO.File]::WriteAllText($transcript,($records -join "`n")+"`n",$Utf8NoBom)
    $stop=Hook 'Stop'
    Assert-Runtime ($stop.systemMessage -match '修改 ×7' -and $stop.systemMessage -match '用时') '缺少编辑 Hook 时仍应确认 7 个文件'
    foreach($expected in @('filesystem/read_file ×2','analyze ×1','code_reviewer ×1','运行 ×1，指令 ×1','Shell命令 ×1')) {
        Assert-Runtime ($stop.systemMessage.Contains($expected)) ('追加输入不得清空或重复累计 Stop 统计：'+$expected+'；实际：'+$stop.systemMessage)
    }
    $daily=Get-Content (Get-ChildItem (Join-Path $stats 'logs') -Filter '*.log' | Select-Object -First 1).FullName -Raw -Encoding UTF8
    Assert-Runtime ($daily -match '编辑操作次数：4') '会话记录应补充 4 次成功编辑事件'
    Assert-Runtime ($daily.Contains('本次回答输入次数：3') -and $daily.Contains('开始时间：'+([DateTimeOffset]::Parse($firstState.startedAt).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')))) 'Stop 日志必须保留本轮首次输入时间及输入次数'
    $retry=Hook 'Stop'
    Assert-Runtime ($retry.systemMessage -eq $stop.systemMessage) '重复 Stop 必须保留已冻结的全部统计'
    $next=Hook 'UserPromptSubmit' 'next-turn'
    Assert-Runtime ($next.systemMessage -match '^🟢 +开始 +：') 'Stop 后的新回答必须重新显示开始'
    $nextState=Get-Content (Join-Path $stats ('data\state\'+(Get-Sha256Hex ($session+"`n"+'next-turn'))+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Runtime ([DateTimeOffset]::Parse($nextState.startedAt) -gt [DateTimeOffset]::Parse($firstState.startedAt) -and $nextState.promptCount -eq 1) '新回答必须有独立的开始时间和输入次数'
    $nextExtra=Hook 'UserPromptSubmit' 'next-turn'
    Assert-Runtime ($nextExtra.systemMessage -match '^ +第 2 次输入 +：') '新回答中的追加输入应从第 2 次开始'
    $null=Hook 'Stop' 'next-turn'
    $netSummary=Get-Content (Join-Path $stats ('data\completed\'+(Get-Sha256Hex ($session+"`n"+'next-turn'))+'.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Runtime ($netSummary.summary -notmatch '修改 ×7|filesystem/read_file|analyze ×|code_reviewer ×|Shell命令 ×1|Git *：运行 ×1') '新回答不能重复累计前一轮的文件、工具、Skill及子Agent统计'

    # Reproduce the real spawn response shape: task path, no agent_id.
    $spawnText=@(
        @{type='response_item';payload=@{type='function_call';name='spawn_agent';call_id='spawn1';arguments=(@{task_name='response_code_review';message='PRIVATE_PROMPT'}|ConvertTo-Json -Compress)}},
        @{type='response_item';payload=@{type='function_call_output';call_id='spawn1';output='{"task_name":"/root/response_code_review"}'}}
    ) | ForEach-Object {$_|ConvertTo-Json -Compress -Depth 8}
    $activity=Get-TranscriptActivityObservation -Text ($spawnText -join "`n") -ExpectedTurnId 'runtime-turn' -Cwd $work
    Assert-Runtime ($activity.Events.Count -eq 1 -and $activity.Events[0].spawnDisplayName -eq 'response_code_review') '必须支持真实 spawn 返回结构'
    Assert-Runtime (($activity|ConvertTo-Json -Compress -Depth 8) -notmatch 'PRIVATE_PROMPT') '不能保留子 Agent 提示词'
    $childPath=Join-Path $root 'child.jsonl'
    $child=@{type='session_meta';payload=@{id='child-1';source=@{subagent=@{thread_spawn=@{parent_thread_id=$session;agent_path='/root/response_arch_review'}}}}}
    [IO.File]::WriteAllText($childPath,($child|ConvertTo-Json -Compress -Depth 8)+"`n",$Utf8NoBom)
    $name=Get-SubagentTranscriptDisplayName ([pscustomobject]@{session_id=$session;agent_id='child-1';agent_transcript_path=$childPath})
    Assert-Runtime ($name -eq 'response_arch_review') '子会话元数据应按真实身份补充名称'
    $badName=Get-SubagentTranscriptDisplayName ([pscustomobject]@{session_id='other-session';agent_id='child-1';agent_transcript_path=$childPath})
    Assert-Runtime (-not $badName) '不能跨父任务关联名称'
    $null=Hook 'UserPromptSubmit' 'agent-turn'
    $null=Hook 'SubagentStart' 'agent-turn' @{agent_id='child-1';agent_type='default'}
    $null=Hook 'SubagentStop' 'agent-turn' @{agent_id='child-1';agent_type='default';agent_transcript_path=$childPath}
    $agentSummary=Hook 'Stop' 'agent-turn'
    Assert-Runtime ($agentSummary.systemMessage -match 'response_arch_review ×1' -and $agentSummary.systemMessage -notmatch 'default ×') '最终汇总必须用验证后的名称替换 default'
    $missing=Hook 'Stop' 'missing-start'
    Assert-Runtime ($missing.systemMessage -match '未确认（统计不完整）') '缺起点不能在 Stop 伪造完整基线'
    # 压缩先创建状态，用户输入后到；保留原始读取起点和已采集事件。
    foreach ($scenario in @('readonly','edits','missing-prompt','invalid-transcript')) {
        $turn='compact-'+$scenario
        $null=Hook 'PreCompact' $turn
        $compactStatePath=Join-Path $stats ('data\state\'+(Get-Sha256Hex ($session+"`n"+$turn))+'.json')
        $compactState=Get-Content $compactStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $null=Hook 'PostCompact' $turn
        foreach ($phase in @('before-prompt','after-prompt')) {
            if ($phase -eq 'after-prompt' -and $scenario -ne 'missing-prompt') {
                $null=Hook 'UserPromptSubmit' $turn
                $promptState=Get-Content $compactStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                Assert-Runtime ($promptState.promptCount -eq 1 -and $promptState.startSource -eq 'inferred-from-intermediate-event') '后到输入必须记录次数，保留状态来源'
                Assert-Runtime ($promptState.startedAt -eq $compactState.startedAt -and $promptState.transcriptBaselineBytes -eq $compactState.transcriptBaselineBytes) '后到输入不能重置计时或会话读取起点'
            }
            if ($scenario -eq 'edits') {
                $file=Join-Path $work ($turn+'-'+$phase+'.txt')
                [IO.File]::WriteAllText($file,'confirmed',$Utf8NoBom)
                $record=@{type='event_msg';payload=@{type='item_completed';turn_id=$turn;item=@{type='FileChange';status='completed';id=$phase;changes=@{$file=@{type='add';content='confirmed'}}}}}
                [IO.File]::AppendAllText($transcript,($record|ConvertTo-Json -Compress -Depth 10)+"`n",$Utf8NoBom)
            }
        }
        if ($scenario -eq 'invalid-transcript') { [IO.File]::AppendAllText($transcript,"{invalid`n",$Utf8NoBom) }
        $compactStop=Hook 'Stop' $turn
        Assert-Runtime ($compactStop.systemMessage -match '上下文压缩 ×1') '后到输入不能清空压缩事件'
        if ($scenario -in @('missing-prompt','invalid-transcript')) {
            Assert-Runtime ($compactStop.systemMessage -match '未确认（统计不完整）') ('真实缺失记录仍应提示不完整：'+$scenario)
        } else {
            Assert-Runtime ($compactStop.systemMessage -notmatch '统计不完整') ('已有用户输入不能误报缺少起始记录：'+$scenario+'；'+$compactStop.systemMessage)
            if ($scenario -eq 'edits') { Assert-Runtime ($compactStop.systemMessage -match '新增 ×2') '用户输入前后的已采集文件变更都必须计入' }
            else { Assert-Runtime ($compactStop.systemMessage -notmatch '新增|修改|删除|未确认') '只读回答不能产生文件变更' }
        }
    }
    $null=Hook 'UserPromptSubmit' 'lock-turn'
    $instance=(Get-Sha256Hex -Text $stats.ToLowerInvariant()).Substring(0,12)
    $lockHash=(Get-Sha256Hex -Text ($session+"`n"+'lock-turn')).Substring(0,24)
    $mutex=[Threading.Mutex]::new($false,('Local\CodexTaskStats_'+$instance+'_Run_'+$lockHash))
    $null=$mutex.WaitOne()
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        $locked=Hook 'UserPromptSubmit' 'lock-turn'
        Assert-Runtime ($timer.ElapsedMilliseconds -lt 5000 -and $locked.systemMessage -match '统计初始化未完成') '锁竞争应在外层期限前明确降级，不能假报已开始'
    } finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
    $afterLock=Hook 'UserPromptSubmit' 'lock-turn'
    Assert-Runtime ($afterLock.systemMessage -match '^ +第 2 次输入 +：') '未成功保存的输入不能提前消耗序号'
    $ProgramVersion='v3.0'; $TestDurationMilliseconds=0
    $fakeState=[pscustomobject]@{startedAt=[DateTimeOffset]::Now.ToString('o');startSource='UserPromptSubmit'}
    # Exact elapsed time uses this response's first input, never the legacy session start.
    $TestDurationMilliseconds=-1
    $timingState=[pscustomobject]@{startedAt='2026-09-09T10:00:00+08:00';timingStartedAt='2026-09-01T10:00:00+08:00';startSource='UserPromptSubmit';promptCount=3}
    $timingSummary=Build-Summary -State $timingState -Events @() -EndedAt ([DateTimeOffset]::Parse('2026-09-09T10:04:00+08:00')) -EndMonotonicTicks 0 -StopPayload ([pscustomobject]@{}) -MainSkillObservation $null
    Assert-Runtime ($timingSummary.DurationMilliseconds -eq 240000 -and $timingSummary.InputCount -eq 3) 'Stop 必须从本次回答首次输入计时到结束，不读取旧版全会话起点'
    $TestDurationMilliseconds=0
    $editEvents=@(
        [pscustomobject]@{event='PostToolUse';toolName='apply_patch';toolUseId='same-id';skillScope='agent:one'},
        [pscustomobject]@{event='PostToolUse';toolName='apply_patch';toolUseId='same-id';skillScope='agent:two'}
    )
    $activityEdits=[pscustomobject]@{EditCount=1;EditIds=@('native-id');PathIds=@();Incomplete=$false}
    $editSummary=Build-Summary -State $fakeState -Events $editEvents -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload ([pscustomobject]@{}) -MainSkillObservation $null -ActivityObservation $activityEdits
    Assert-Runtime ($editSummary.EditOperationCount -eq 3) '主会话编辑与两个子Agent同ID编辑必须按scope独立计数'
    $rootEdit=[pscustomobject]@{event='PostToolUse';toolName='apply_patch';toolUseId='native-id';skillScope='root'}
    $editSummary=Build-Summary -State $fakeState -Events ($editEvents+@($rootEdit)) -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload ([pscustomobject]@{}) -MainSkillObservation $null -ActivityObservation $activityEdits
    Assert-Runtime ($editSummary.EditOperationCount -eq 3 -and -not $editSummary.EditOperationLowerBound) '同一主任务编辑ID应跨来源去重'
    $rootEdit.toolUseId='unknown-mapping'
    $editSummary=Build-Summary -State $fakeState -Events ($editEvents+@($rootEdit)) -EndedAt ([DateTimeOffset]::Now) -EndMonotonicTicks 0 -StopPayload ([pscustomobject]@{}) -MainSkillObservation $null -ActivityObservation $activityEdits
    Assert-Runtime ($editSummary.EditOperationCount -eq 3 -and $editSummary.EditOperationLowerBound) '无法关联的两来源只能声明操作次数下界'
    Write-Host '输入计时、并发、嵌套仓库七文件、会话补采及名称身份回归通过。'
} finally {
    $env:CODEX_TASK_STATS_HOME=$oldStats
    $full=[IO.Path]::GetFullPath($root)
    if ($full.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'codex-runtime-*') { Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue }
}
