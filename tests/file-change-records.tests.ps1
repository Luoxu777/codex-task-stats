[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$main=Join-Path $project 'src\codex-task-stats.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($main,[ref]$null,[ref]$null)
foreach($definition in $ast.EndBlock.Statements){if($definition -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($definition.Extent.Text))}}
. (Join-Path $project 'src\lib\SubagentCorrelation.ps1')
$config=Get-Content (Join-Path $project 'config\config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$utf8=[Text.UTF8Encoding]::new($false)
$root=Join-Path $env:TEMP ('codex-file-records-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function Check {param([bool]$Condition,[string]$Message) if(-not $Condition){throw $Message}}
function FullDiff {
    param([AllowEmptyString()][string]$Before,[AllowEmptyString()][string]$After)
    $old=@([regex]::Matches($Before,'[^\n]*\n|[^\n]+$')|ForEach-Object{$_.Value})
    $new=@([regex]::Matches($After,'[^\n]*\n|[^\n]+$')|ForEach-Object{$_.Value})
    $lines=@('@@ -'+$(if($old.Count){1}else{0})+','+$old.Count+' +'+$(if($new.Count){1}else{0})+','+$new.Count+' @@')
    foreach($side in @(@{prefix='-';tokens=$old},@{prefix='+';tokens=$new})){
        foreach($token in $side.tokens){$lines += $side.prefix+$token.TrimEnd([char]10);if(-not $token.EndsWith("`n")){$lines+='\ No newline at end of file'}}
    }
    return ($lines -join "`n")+"`n"
}
function Case {
    param([string]$Name,[hashtable]$Initial,[object[]]$Actions,[int[]]$Expected)
    $work=Join-Path $root $Name;$null=New-Item -ItemType Directory -Path $work
    foreach($name in $Initial.Keys){[IO.File]::WriteAllText((Join-Path $work $name),$Initial[$name],$utf8)}
    $changes=@();$index=0
    foreach($action in $Actions){
        $path=Join-Path $work $action.path;$detail=[ordered]@{type=$action.kind}
        switch($action.kind){
            'add' {$detail.content=$action.text;[IO.File]::WriteAllText($path,$action.text,$utf8)}
            'delete' {$detail.content=[IO.File]::ReadAllText($path);Remove-Item -LiteralPath $path}
            'update' {
                $before=[IO.File]::ReadAllText($path);$detail.unified_diff=FullDiff $before $action.text
                if($action.move){$detail.move_path=Join-Path $work $action.move;Remove-Item -LiteralPath $path;$path=$detail.move_path}
                [IO.File]::WriteAllText($path,$action.text,$utf8)
            }
        }
        $changes += [pscustomobject]@{Path=(Join-Path $work $action.path);Detail=([pscustomobject]$detail);EditId=('edit-'+$index);Scope='root';At=[DateTimeOffset]::Now;Order=$index++}
    }
    $summary=Get-NativeFileChangeSummary -Changes $changes -Cwd $work
    Check ($summary.Added-eq$Expected[0]-and$summary.Modified-eq$Expected[1]-and$summary.Deleted-eq$Expected[2]-and$summary.Unknown-eq0) ($Name+': '+($summary|ConvertTo-Json -Compress))
    return [pscustomobject]@{Summary=$summary;Changes=$changes;Work=$work}
}
try {
    $null=Case 'repeat' @{a="old`n"} @(@{kind='update';path='a';text="new`n";move=$null},@{kind='update';path='a';text="newer`n";move=$null}) @(0,1,0)
    $revert=Case 'revert' @{a="old`n"} @(@{kind='update';path='a';text="new`n";move=$null},@{kind='update';path='a';text="old`n";move=$null}) @(0,0,0)
    $required=@([pscustomobject]@{scope='root';pathId=(Get-FileIdentityHash -PathValue (Join-Path $revert.Work 'a') -Cwd $revert.Work);count=2})
    $missing=Get-NativeFileChangeSummary -Changes @($revert.Changes[1]) -Cwd $revert.Work -RequiredEdits $required
    Check ($missing.Total-eq0-and$missing.Unknown-eq1-and$missing.Reasons -contains '存在未匹配原生记录的成功编辑') '同路径缺失一次成功编辑不能误报净修改'
    $null=Case 'add-edit' @{} @(@{kind='add';path='a';text='old'},@{kind='update';path='a';text='new';move=$null}) @(1,0,0)
    $null=Case 'add-delete' @{} @(@{kind='add';path='a';text='new'},@{kind='delete';path='a'}) @(0,0,0)
    $null=Case 'edit-delete' @{a='old'} @(@{kind='update';path='a';text='new';move=$null},@{kind='delete';path='a'}) @(0,0,1)
    $null=Case 'delete-rebuild-same' @{a='old'} @(@{kind='delete';path='a'},@{kind='add';path='a';text='old'}) @(0,0,0)
    $null=Case 'delete-rebuild-changed' @{a='old'} @(@{kind='delete';path='a'},@{kind='add';path='a';text='new'}) @(0,1,0)
    $null=Case 'rename' @{a="old`n"} @(@{kind='update';path='a';move='b';text="old`n"}) @(1,0,1)
    $null=Case 'rename-edit-chain' @{a='old'} @(@{kind='update';path='a';move='b';text='new'},@{kind='update';path='b';move='c';text='last'}) @(1,0,1)
    $null=Case 'rename-back' @{a='old'} @(@{kind='update';path='a';move='b';text='new'},@{kind='update';path='b';move='a';text='old'}) @(0,0,0)
    $null=Case 'empty-add' @{} @(@{kind='add';path='a';text=''}) @(1,0,0)
    $null=Case 'remove-last-newline' @{a="same`n"} @(@{kind='update';path='a';text='same';move=$null}) @(0,1,0)
    $null=Case 'dirty-file' @{a='already dirty'} @(@{kind='update';path='a';text='this turn';move=$null}) @(0,1,0)
    $null=Case 'no-edit-commit-only' @{a='dirty'} @() @(0,0,0)
    $partial=Case 'partial' @{a='before'} @(@{kind='update';path='a';text='after';move=$null},@{kind='add';path='b';text='confirmed'}) @(1,1,0)
    $partial.Changes[0].Detail.unified_diff='not a diff'
    $summary=Get-NativeFileChangeSummary $partial.Changes $partial.Work
    Check ($summary.Added-eq1-and$summary.Modified-eq0-and$summary.Unknown-eq1-and$summary.Reasons.Count-gt0) '证据不足不能污染其他已确认文件'
    $mismatch=Case 'external-after-edit' @{a='before'} @(@{kind='update';path='a';text='after';move=$null}) @(0,1,0)
    [IO.File]::WriteAllText((Join-Path $mismatch.Work 'a'),'external edit',$utf8)
    $summary=Get-NativeFileChangeSummary $mismatch.Changes $mismatch.Work
    Check ($summary.Total-eq0-and$summary.Unknown-eq1) '结束内容不匹配必须未确认'
    $multi="@@ -1 +1 @@`n-a`n+A`n@@ -3 +3 @@`n-c`n+C`n"
    Check ((Undo-FileChangeDiff "A`nb`nC`n" $multi) -ceq "a`nb`nc`n") '多段补丁反推失败'
    Check ((Undo-FileChangeDiff "a`nb`n" "@@ -1,3 +1,2 @@`n a`n b`n-c`n") -ceq "a`nb`nc`n") '文件尾部删除反推失败'

    # Native event IDs are deduplicated, failed edits and neighbouring turns ignored.
    $native=@{type='event_msg';payload=@{type='item_completed';turn_id='turn';item=@{type='FileChange';status='completed';id='one';changes=@{a=@{type='add';content='one'}}}}}
    $line=$native|ConvertTo-Json -Depth 10 -Compress
    $failed=$native|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json;$failed.payload.item.status='failed';$failed.payload.item.id='two'
    $other=$native|ConvertTo-Json -Depth 10 -Compress|ConvertFrom-Json;$other.payload.turn_id='other'
    $obs=Get-TranscriptActivityObservation -Text (@($line,$line,($failed|ConvertTo-Json -Depth 10 -Compress),($other|ConvertTo-Json -Depth 10 -Compress))-join"`n") -ExpectedTurnId 'turn' -Cwd $root
    Check ($obs.EditCount-eq1-and$obs.FileChanges.Count-eq1) '原生记录去重或轮次隔离错误'

    # A verified child edits the same file between two root edits, then both are reduced together.
    $interleave=Case 'interleave' @{a="0`n"} @(@{kind='update';path='a';text="1`n";move=$null},@{kind='update';path='a';text="2`n";move=$null},@{kind='update';path='a';text="0`n";move=$null}) @(0,0,0)
    $childId='child-verified';$childPath=Join-Path $root ('rollout-'+$childId+'.jsonl');$base=[DateTimeOffset]::Now.AddMinutes(-1)
    for($i=0;$i-lt3;$i++){$interleave.Changes[$i].At=$base.AddSeconds($i+1)}
    $metadata=@{type='session_meta';payload=@{id=$childId;cwd=$interleave.Work;source=@{subagent=@{thread_spawn=@{parent_thread_id='parent'}}}}}
    $childRecord=@{timestamp=$base.AddSeconds(2).ToString('o');type='event_msg';payload=@{type='item_completed';turn_id='child-turn';item=@{type='FileChange';status='completed';id='child-edit';changes=@{a=$interleave.Changes[1].Detail}}}}
    [IO.File]::WriteAllText($childPath,(@(($metadata|ConvertTo-Json -Depth 12 -Compress),($childRecord|ConvertTo-Json -Depth 12 -Compress))-join"`n")+"`n",$utf8)
    $observation=[pscustomobject]@{FileChanges=@($interleave.Changes[0],$interleave.Changes[2]);AgentIds=@($childId);Reasons=@();Incomplete=$false}
    $state=[pscustomobject]@{sessionId='parent';startedAt=$base.ToString('o')}
    $payload=[pscustomobject]@{transcript_path=(Join-Path $root 'parent.jsonl');cwd=$interleave.Work}
    $combined=Add-ChildFileActivity $observation @() $state $payload ($base.AddSeconds(5))
    $summary=Get-NativeFileChangeSummary $combined.FileChanges $interleave.Work
    Check ($combined.FileChanges.Count-eq3-and$summary.Total-eq0-and$summary.Unknown-eq0) '主子Agent交错修改后恢复必须归零'
    $state.sessionId='unrelated'
    $untrusted=Add-ChildFileActivity ([pscustomobject]@{FileChanges=@();AgentIds=@($childId);Reasons=@();Incomplete=$false}) @() $state $payload ($base.AddSeconds(5))
    Check ($untrusted.FileChanges.Count-eq0-and$untrusted.Incomplete) '不得采纳其他父任务的子Agent文件记录'
    $childRecord.Remove('timestamp')
    $withoutTime=Get-TranscriptActivityObservation -Text ($childRecord|ConvertTo-Json -Depth 12 -Compress) -ExpectedTurnId '' -Cwd $interleave.Work -Scope $childId -From $base -Until ($base.AddSeconds(5))
    Check ($withoutTime.FileChanges.Count-eq0-and$withoutTime.ParseErrors-gt0) '子Agent缺少时间戳必须标记记录不完整'
    $withoutPath=Add-ChildFileActivity ([pscustomobject]@{FileChanges=@();AgentIds=@($childId);Reasons=@();Incomplete=$false}) @() $state ([pscustomobject]@{cwd=$root}) ($base.AddSeconds(5))
    Check ($withoutPath.Incomplete-and$withoutPath.FileChanges.Count-eq0) '缺少会话路径只能降级文件统计，不能中断Stop'
    Check (([IO.File]::ReadAllText($main)) -notmatch 'Get-GitWorkspaceSnapshot|Get-GitSnapshotDeltaOperations|EnumerateFileSystemEntries') '生产代码不得恢复全量工作区扫描'
    Write-Host 'FileChange 最终归类、补丁反推、记录去重及主子Agent交错回归通过。'
} finally {
    $full=[IO.Path]::GetFullPath($root)
    if($full.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($full).StartsWith('codex-file-records-')){Remove-Item -LiteralPath $full -Recurse -Force}
}
