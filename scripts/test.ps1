[CmdletBinding()]
param(
    [switch]$KeepTemp
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$global:OutputEncoding = $Utf8NoBom

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MainScript = Join-Path $ProjectRoot 'src\codex-task-stats.ps1'
$SourceSubagentCorrelationLibrary = Join-Path $ProjectRoot 'src\lib\SubagentCorrelation.ps1'
$InstallScript = Join-Path $ProjectRoot 'scripts\install.ps1'
$UninstallScript = Join-Path $ProjectRoot 'scripts\uninstall.ps1'
$ApplyDisplayScript = Join-Path $ProjectRoot 'scripts\apply-recommended-display.ps1'
$StatusScript = Join-Path $ProjectRoot 'scripts\status.ps1'
$CodexPathLibrary = Join-Path $ProjectRoot 'scripts\lib\CodexPath.ps1'
$ConfigSource = Join-Path $ProjectRoot 'config\config.example.json'
$VersionSource = Join-Path $ProjectRoot 'VERSION'
$OpenAiDocsTranscriptSample = Join-Path $ProjectRoot 'tests\samples\transcript-openai-docs-command-read.jsonl'
$CustomToolTranscriptSample = Join-Path $ProjectRoot 'tests\samples\transcript-command-read-skill.jsonl'
$SubagentCorrelationTestScript = Join-Path $ProjectRoot 'tests\subagent-correlation.tests.ps1'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-task-stats-test-' + [Guid]::NewGuid().ToString('N'))
$ConfigRoot = Join-Path $TestRoot 'config'
$WorkspaceRoot = Join-Path $TestRoot 'workspace'
$MainTranscript = Join-Path $TestRoot 'main-transcript.jsonl'
$LookbackTranscript = Join-Path $TestRoot 'lookback-transcript.jsonl'
$oldHome = $env:CODEX_TASK_STATS_HOME
$oldCodexHome = $env:CODEX_HOME

# Windows PowerShell 5.1 reads non-ASCII script literals reliably when source
# files carry a UTF-8 BOM. Verify the distributed scripts before running tests.
foreach ($scriptFile in Get-ChildItem -LiteralPath $ProjectRoot -Recurse -Filter '*.ps1' -File) {
    $bytes = [IO.File]::ReadAllBytes($scriptFile.FullName)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        throw "PowerShell 源文件不是带 BOM 的 UTF-8： $($scriptFile.FullName)"
    }

    $scriptText = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    if ([Regex]::IsMatch($scriptText, '(?<!\r)\n')) {
        throw "PowerShell 源文件包含单独 LF，而不是 CRLF： $($scriptFile.FullName)"
    }

    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptFile.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        $details = ($parseErrors | ForEach-Object { $_.Message + ' at ' + $_.Extent.StartLineNumber }) -join '; '
        throw "PowerShell 语法错误： $($scriptFile.FullName): $details"
    }
}

$subagentCorrelationTestOutput = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $SubagentCorrelationTestScript
if ($LASTEXITCODE -ne 0) {
    throw "子Agent关联回归测试退出码为 $LASTEXITCODE"
}
$subagentCorrelationTestText = @($subagentCorrelationTestOutput) -join "`n"
if ($subagentCorrelationTestText.IndexOf('子Agent关联与 PowerShell 5.1 兼容回归测试通过。', [StringComparison]::Ordinal) -lt 0) {
    throw "子Agent关联回归测试缺少成功标记。实际输出：`n$subagentCorrelationTestText"
}
Write-Host $subagentCorrelationTestText

# v2.1 static release guards for the three target-runtime regressions.
$mainSourceForStaticChecks = [IO.File]::ReadAllText($MainScript, [Text.Encoding]::UTF8)
if ($mainSourceForStaticChecks -match '\.IndexOf\(\$Flag\)') {
    throw 'Git 短选项检测不得重新使用 String.IndexOf($Flag)。'
}
if ($mainSourceForStaticChecks -notmatch 'ToCharArray\(\)') {
    throw 'Git 短选项检测缺少确定性的逐字符比较。'
}
$testSourceForStaticChecks = [IO.File]::ReadAllText($MyInvocation.MyCommand.Path, [Text.Encoding]::UTF8)
if ($testSourceForStaticChecks -match '\[Nullable\[double\]\]\$DurationMilliseconds' -or
    $testSourceForStaticChecks -match '\$DurationMilliseconds\.Value') {
    throw '测试耗时参数不得依赖 Nullable[double].Value。'
}
if ([Regex]::IsMatch(
    $testSourceForStaticChecks,
    'Assert-Contains\s+-Text\s+\$journalText\s+-Expected\s+''<'
)) {
    throw 'Journal 占位符测试必须解析 JSONL 后验证语义，不得断言原始转义文本。'
}

function Invoke-TestHook {
    param(
        [string]$Event,
        [hashtable]$Fields,
        [double]$DurationMilliseconds = -1
    )

    $base = [ordered]@{
        session_id = 'thr_test_001'
        turn_id = 'turn_test_001'
        transcript_path = $MainTranscript
        cwd = $WorkspaceRoot
        hook_event_name = $Event
        model = 'test-model'
        permission_mode = 'default'
    }
    foreach ($key in $Fields.Keys) {
        $base[$key] = $Fields[$key]
    }

    $json = $base | ConvertTo-Json -Compress -Depth 30
    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $MainScript,
        '-Event', $Event
    )
    if ($DurationMilliseconds -ge 0) {
        $arguments += @('-TestDurationMilliseconds', $DurationMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture))
    }

    $output = $json | & powershell.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Event 退出码为 $LASTEXITCODE"
    }
    return ($output -join "`n")
}

function Invoke-InstallerExpectingFailure {
    param(
        [string]$Installer,
        [string]$CodexHome
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        # Windows PowerShell 5.1 converts redirected native stderr into
        # non-terminating ErrorRecord objects. Keep those records as assertion
        # input instead of letting the suite's Stop preference abort the test.
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $Installer -CodexHome $CodexHome -IntermediateMode Quiet 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [PSCustomObject]@{
        Output = $output
        ExitCode = $exitCode
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if ($Text.IndexOf($Expected, [StringComparison]::Ordinal) -lt 0) {
        throw "断言失败。缺少文本： $Expected`n实际文本：`n$Text"
    }
}

function Assert-NotContains {
    param([string]$Text, [string]$Unexpected)
    if ($Text.IndexOf($Unexpected, [StringComparison]::Ordinal) -ge 0) {
        throw "断言失败。出现了不应包含的文本： $Unexpected`n实际文本：`n$Text"
    }
}

function Assert-Matches {
    param([string]$Text, [string]$Pattern)
    if (-not [Regex]::IsMatch($Text, $Pattern)) {
        throw "断言失败。未匹配正则表达式： $Pattern`n实际文本：`n$Text"
    }
}

# Windows PowerShell 5.1 may serialize '<' and '>' as Unicode escapes.
# Confirm the regression checks parsed JSON semantics, not raw byte spelling.
$escapedPlaceholderRecord = '{"safeCommands":["\u003c远程地址已隐藏\u003e","\u003c内容已隐藏\u003e"]}' |
    ConvertFrom-Json -ErrorAction Stop
$escapedPlaceholderText = @($escapedPlaceholderRecord.safeCommands) -join "`n"
Assert-Contains -Text $escapedPlaceholderText -Expected '<远程地址已隐藏>'
Assert-Contains -Text $escapedPlaceholderText -Expected '<内容已隐藏>'

function Assert-GitCommandClassification {
    param(
        [string]$TurnId,
        [string]$Command,
        [int]$ExpectedChangeCount
    )

    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{
        turn_id = $TurnId
        prompt = 'git classification case'
    }
    $toolUseId = 'git-case-' + $TurnId
    $toolFields = @{
        turn_id = $TurnId
        tool_name = 'Bash'
        tool_use_id = $toolUseId
        tool_input = @{ command = $Command }
    }
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields $toolFields
    $postFields = @{}
    foreach ($key in $toolFields.Keys) { $postFields[$key] = $toolFields[$key] }
    $postFields['tool_response'] = @{}
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields $postFields
    $stopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 1000 -Fields @{
        turn_id = $TurnId
        stop_hook_active = $false
    }
    $message = [string](($stopRaw | ConvertFrom-Json).systemMessage)
    $baseText = '🌿 Git：运行 ×1，指令 ×1'
    Assert-Contains -Text $message -Expected $baseText
    if ($ExpectedChangeCount -gt 0) {
        Assert-Contains -Text $message -Expected ($baseText + '，变更 ×' + $ExpectedChangeCount)
    }
    else {
        Assert-NotContains -Text $message -Unexpected ($baseText + '，变更 ×')
    }
}

function Get-TaskStatsHandlerCount {
    param([object]$HooksRoot)

    $count = 0
    foreach ($eventProperty in $HooksRoot.hooks.PSObject.Properties) {
        foreach ($group in @($eventProperty.Value)) {
            if ($null -eq $group -or $null -eq $group.PSObject.Properties['hooks']) { continue }
            foreach ($handler in @($group.hooks)) {
                if ($null -eq $handler) { continue }
                $commandText = ''
                foreach ($propertyName in @('command', 'commandWindows', 'command_windows')) {
                    $property = $handler.PSObject.Properties[$propertyName]
                    if ($null -ne $property -and $null -ne $property.Value) {
                        $commandText += [string]$property.Value
                    }
                }
                if ($commandText -match '(?i)codex-task-stats\.ps1') {
                    $count++
                }
            }
        }
    }
    return $count
}

try {
    $null = New-Item -ItemType Directory -Path $ConfigRoot -Force
    $null = New-Item -ItemType Directory -Path $WorkspaceRoot -Force
    Copy-Item -LiteralPath $ConfigSource -Destination (Join-Path $ConfigRoot 'config.json') -Force
    Copy-Item -LiteralPath $VersionSource -Destination (Join-Path $TestRoot 'VERSION') -Force
    $env:CODEX_TASK_STATS_HOME = $TestRoot

    # Codex Home resolution is shared by install/status/update/uninstall:
    # explicit parameter > CODEX_HOME > current Windows user profile\.codex.
    . $CodexPathLibrary
    $env:CODEX_HOME = $null
    $defaultHomeInfo = Resolve-CodexHome -ExplicitlyProvided $false
    $expectedDefaultHome = [IO.Path]::GetFullPath((Join-Path ([System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)) '.codex'))
    if (-not [string]::Equals([string]$defaultHomeInfo.Path, $expectedDefaultHome, [StringComparison]::OrdinalIgnoreCase)) {
        throw "默认 Codex Home 解析错误： $($defaultHomeInfo.Path)"
    }
    if (-not [string]::Equals([string]$defaultHomeInfo.Source, 'UserProfileDefault', [StringComparison]::Ordinal)) {
        throw "默认 Codex Home 来源错误： $($defaultHomeInfo.Source)"
    }

    $environmentHome = Join-Path $TestRoot '环境 Codex Home'
    $explicitHome = Join-Path $TestRoot '显式 Codex Home'
    $env:CODEX_HOME = $environmentHome
    $environmentHomeInfo = Resolve-CodexHome -ExplicitlyProvided $false
    if (-not [string]::Equals([string]$environmentHomeInfo.Path, [IO.Path]::GetFullPath($environmentHome), [StringComparison]::OrdinalIgnoreCase)) {
        throw "CODEX_HOME 解析错误： $($environmentHomeInfo.Path)"
    }
    if (-not [string]::Equals([string]$environmentHomeInfo.Source, 'EnvironmentVariable', [StringComparison]::Ordinal)) {
        throw "CODEX_HOME 来源错误： $($environmentHomeInfo.Source)"
    }

    $explicitHomeInfo = Resolve-CodexHome -ExplicitPath $explicitHome -ExplicitlyProvided $true
    if (-not [string]::Equals([string]$explicitHomeInfo.Path, [IO.Path]::GetFullPath($explicitHome), [StringComparison]::OrdinalIgnoreCase)) {
        throw "-CodexHome 未覆盖 CODEX_HOME： $($explicitHomeInfo.Path)"
    }
    if (-not [string]::Equals([string]$explicitHomeInfo.Source, 'Parameter', [StringComparison]::Ordinal)) {
        throw "显式 Codex Home 来源错误： $($explicitHomeInfo.Source)"
    }
    $env:CODEX_HOME = ([IO.Path]::GetPathRoot($environmentHome))
    $explicitOverInvalidEnvironment = Resolve-CodexHome -ExplicitPath $explicitHome -ExplicitlyProvided $true
    if (-not [string]::Equals([string]$explicitOverInvalidEnvironment.Path, [IO.Path]::GetFullPath($explicitHome), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'CODEX_HOME 无效时，-CodexHome 未保持最高优先级。'
    }
    $env:CODEX_HOME = $environmentHome
    $rootWasRejected = $false
    try {
        $null = Resolve-CodexHome -ExplicitPath ([IO.Path]::GetPathRoot($explicitHome)) -ExplicitlyProvided $true
    }
    catch {
        $rootWasRejected = $true
    }
    if (-not $rootWasRejected) {
        throw '不能将文件系统根目录作为 Codex Home。'
    }

    # The main hook tests do not depend on CODEX_HOME; clear it until the
    # installer integration block deliberately verifies environment selection.
    $env:CODEX_HOME = $null

    # Main successful turn: actual transcript injection, structured Skill input,
    # explicit $skill fallback, subagent transcripts, MCP, file operations, and
    # other tools. The workspace is deliberately not a Git repository here, so
    # this block validates the privacy-safe apply_patch parser by itself.
    $availableOnlyRecord = [ordered]@{
        type = 'context'
        skills = @(
            [ordered]@{
                name = 'available-only'
                path = 'C:\AVAILABLE_ONLY_SECRET\SKILL.md'
                description = 'This is only an available-Skill list entry.'
            }
        )
    } | ConvertTo-Json -Compress -Depth 10
    [IO.File]::WriteAllText($MainTranscript, $availableOnlyRecord + [Environment]::NewLine, $Utf8NoBom)

    $startRaw = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{
        prompt = 'PROMPT_SECRET_SHOULD_NOT_BE_STORED $analyze $pdfs $pdfs @plain-person'
        input_items = @(
            [ordered]@{
                type = 'skill'
                name = '@slides'
                path = 'C:\STRUCTURED_SKILL_PATH_SECRET\SKILL.md'
            }
        )
    }
    $start = $startRaw | ConvertFrom-Json
    Assert-Contains -Text ([string]$start.systemMessage) -Expected '开始 '

    $initialStateFile = Get-ChildItem -LiteralPath (Join-Path $TestRoot 'data\state') -Filter '*.json' -File | Select-Object -First 1
    if ($null -eq $initialStateFile) {
        throw 'UserPromptSubmit 后未生成 state 文件。'
    }
    $initialState = [IO.File]::ReadAllText($initialStateFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$initialState.schemaVersion -ne 11) {
        throw "UserPromptSubmit 生成的 state schemaVersion 不是 11：$($initialState.schemaVersion)"
    }

    # Append records only after UserPromptSubmit captured the transcript baseline.
    # The XML record represents an actual Skill injection. A generic top-level
    # skills list is also appended and must not be treated as an invocation.
    $injectedSkillRecord = [ordered]@{
        timestamp = '2026-08-25T06:27:35.000Z'
        type = 'response_item'
        payload = [ordered]@{
            type = 'message'
            role = 'developer'
            content = @(
                [ordered]@{
                    type = 'input_text'
                    text = '<skill><name>analyze</name><path>C:\ACTUAL_ANALYZE_PATH_SECRET\SKILL.md</path><instructions>TRANSCRIPT_SKILL_BODY_SECRET_SHOULD_NOT_BE_STORED</instructions></skill>'
                }
            )
        }
    } | ConvertTo-Json -Compress -Depth 10
    $ignoredAvailableRecord = [ordered]@{
        type = 'context'
        skills = @(
            [ordered]@{
                type = 'skill'
                name = 'available-after-baseline'
                path = 'C:\AVAILABLE_AFTER_BASELINE_SECRET\SKILL.md'
            }
        )
        catalog = '<skills_instructions><skill><name>catalog-only</name><path>C:\CATALOG_ONLY_SECRET\SKILL.md</path></skill></skills_instructions>'
    } | ConvertTo-Json -Compress -Depth 10
    $commandReadSkillRecord = [IO.File]::ReadAllText($OpenAiDocsTranscriptSample, [Text.Encoding]::UTF8).TrimEnd([char[]]@(13, 10))
    $customToolSkillRecord = [IO.File]::ReadAllText($CustomToolTranscriptSample, [Text.Encoding]::UTF8).TrimEnd([char[]]@(13, 10))
    $pendingCustomToolRecord = [ordered]@{
        timestamp = '2026-08-25T06:27:35.200Z'
        type = 'response_item'
        payload = [ordered]@{
            type = 'custom_tool_call'
            status = 'in_progress'
            name = 'exec'
            input = "Get-Content -LiteralPath 'Y:\pending-runtime\pending-call-skill\SKILL.md' -Raw"
            internal_chat_message_metadata_passthrough = [ordered]@{ turn_id = 'turn_test_001' }
        }
    } | ConvertTo-Json -Compress -Depth 20
    [IO.File]::AppendAllText($MainTranscript, $injectedSkillRecord + [Environment]::NewLine, $Utf8NoBom)
    [IO.File]::AppendAllText($MainTranscript, $ignoredAvailableRecord + [Environment]::NewLine, $Utf8NoBom)
    [IO.File]::AppendAllText($MainTranscript, $commandReadSkillRecord + [Environment]::NewLine, $Utf8NoBom)
    [IO.File]::AppendAllText($MainTranscript, $customToolSkillRecord + [Environment]::NewLine, $Utf8NoBom)
    [IO.File]::AppendAllText($MainTranscript, $pendingCustomToolRecord + [Environment]::NewLine, $Utf8NoBom)

    for ($i = 1; $i -le 3; $i++) {
        $id = 'mcp-file-' + $i
        $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'mcp__filesystem__read_file'; tool_use_id = $id; tool_input = @{ secret = 'MCP_INPUT_SECRET_SHOULD_NOT_BE_STORED' } }
        $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'mcp__filesystem__read_file'; tool_use_id = $id; tool_input = @{ secret = 'MCP_INPUT_SECRET_SHOULD_NOT_BE_STORED' }; tool_response = @{ result = 'MCP_OUTPUT_SECRET_SHOULD_NOT_BE_STORED' } }
    }

    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'mcp__browser__open'; tool_use_id = 'mcp-browser-1'; tool_input = @{} }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'mcp__browser__open'; tool_use_id = 'mcp-browser-1'; tool_input = @{}; tool_response = @{} }
    # Duplicate completion event must not increment the same tool_use_id twice.
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'mcp__browser__open'; tool_use_id = 'mcp-browser-1'; tool_input = @{}; tool_response = @{} }

    for ($i = 1; $i -le 2; $i++) {
        $id = 'bash-' + $i
        $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = $id; tool_input = @{ command = 'echo hidden' } }
        $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = $id; tool_input = @{ command = 'echo hidden' }; tool_response = @{} }
    }

    # Git 统计只汇总会产生变化的 Git 指令；只读指令仍可保留在安全详细日志中。
    $gitRunOne = 'git reset --mixed HEAD~1; git status --short --branch; git log --oneline --decorate -4; git diff --stat'
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'git-run-1'; tool_input = @{ command = $gitRunOne } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'git-run-1'; tool_input = @{ command = $gitRunOne }; tool_response = @{} }

    $gitRunTwo = 'git clone https://user:SUPER_SECRET_TOKEN@example.com/private.git; git commit -m "CUSTOMER_SECRET_MESSAGE"'
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'git-run-2'; tool_input = @{ command = $gitRunTwo } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'git-run-2'; tool_input = @{ command = $gitRunTwo }; tool_response = @{} }

    $sensitiveShellCommand = "Select-String -Path src/views/amazon/listing/products/index.vue -Pattern 'CUSTOMER_SECRET_PATTERN'"
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'shell-safe-log'; tool_input = @{ command = $sensitiveShellCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'shell-safe-log'; tool_input = @{ command = $sensitiveShellCommand }; tool_response = @{} }

    # The same openai-docs read is observable through both the transcript and
    # Hook tool events. Root-scope evidence must still count the Skill once.
    $duplicateOpenAiDocsRead = "Get-Content -LiteralPath 'E:\custom-codex-home\skills\.system\openai-docs\SKILL.md' -Raw"
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-openai-docs'; tool_input = @{ command = $duplicateOpenAiDocsRead } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-openai-docs'; tool_input = @{ command = $duplicateOpenAiDocsRead }; tool_response = @{} }

    # Some client versions do not emit parsed_cmd in Hook payloads. Raw command
    # fallback must still identify a successful read of an arbitrary Skill path.
    $rawSkillReadCommand = "Get-Content -LiteralPath 'D:\任意 Skill 根目录\runtime-helper\SKILL.md' -Raw"
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-skill-read'; tool_input = @{ command = $rawSkillReadCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-skill-read'; tool_input = @{ command = $rawSkillReadCommand }; tool_response = @{} }

    # Merely writing a file named SKILL.md is not evidence that the Skill was
    # read. This guards against broad path-only matching.
    $nonReadSkillCommand = "Set-Content -LiteralPath 'D:\任意 Skill 根目录\not-a-skill\SKILL.md' -Value hidden"
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-skill-write'; tool_input = @{ command = $nonReadSkillCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'bash-skill-write'; tool_input = @{ command = $nonReadSkillCommand }; tool_response = @{} }

    $patchCommandOne = @'
*** Begin Patch
*** Add File: FILE_ADDED_SECRET.txt
+PATCH_CONTENT_SECRET_SHOULD_NOT_BE_STORED
+Get-Content 'D:\patch-mentioned-skill\SKILL.md'
*** Update File: FILE_MODIFIED_SECRET.txt
@@
-old
+new
*** Update File: FILE_RENAME_SOURCE_SECRET.txt
*** Move to: FILE_RENAME_TARGET_SECRET.txt
@@
-old
+new
*** Delete File: FILE_DELETED_SECRET.txt
*** End Patch
'@
    $patchCommandTwo = @'
*** Begin Patch
*** Update File: FILE_MODIFIED_RENAMED_SECRET.txt
@@
-new
+newer
*** End Patch
'@

    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'apply_patch'; tool_use_id = 'patch-1'; tool_input = @{ command = $patchCommandOne } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'apply_patch'; tool_use_id = 'patch-1'; tool_input = @{ command = $patchCommandOne }; tool_response = @{ result = 'PATCH_RESPONSE_SECRET_SHOULD_NOT_BE_STORED' } }
    # Duplicate PostToolUse must not duplicate file identities or edit operations.
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'apply_patch'; tool_use_id = 'patch-1'; tool_input = @{ command = $patchCommandOne }; tool_response = @{} }

    # 修改旧路径后再通过 PowerShell Move-Item 重命名，随后继续修改新路径。
    # 三次操作必须仍然只算同一个逻辑文件。
    $moveModifiedFile = @'
$old='FILE_MODIFIED_SECRET.txt'
$new='FILE_MODIFIED_RENAMED_SECRET.txt'
Move-Item -LiteralPath $old -Destination $new
'@
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'shell-move-modified'; tool_input = @{ command = $moveModifiedFile } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'Bash'; tool_use_id = 'shell-move-modified'; tool_input = @{ command = $moveModifiedFile }; tool_response = @{} }

    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ tool_name = 'ApplyPatch'; tool_use_id = 'patch-2'; tool_input = @{ command = $patchCommandTwo } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'ApplyPatch'; tool_use_id = 'patch-2'; tool_input = @{ command = $patchCommandTwo }; tool_response = @{} }

    $null = Invoke-TestHook -Event 'PermissionRequest' -Fields @{ tool_name = 'Bash'; tool_input = @{ description = 'test' } }
    $null = Invoke-TestHook -Event 'PostCompact' -Fields @{ trigger = 'auto' }

    foreach ($agentNumber in 1..2) {
        $agentId = 'agent-' + $agentNumber
        $agentTranscript = Join-Path $TestRoot ('agent-transcript-' + $agentNumber + '.jsonl')
        $agentRecord = [ordered]@{
            timestamp = '2026-08-25T06:27:36.000Z'
            type = 'response_item'
            payload = [ordered]@{
                type = 'message'
                role = 'developer'
                content = @(
                    [ordered]@{
                        type = 'input_text'
                        text = '<skill><name>agent-skill</name><path>C:\AGENT_SKILL_PATH_SECRET_' + $agentNumber + '\SKILL.md</path></skill>'
                    }
                )
            }
        } | ConvertTo-Json -Compress -Depth 10
        $agentCommandReadRecord = [ordered]@{
            timestamp = '2026-08-25T06:27:36.100Z'
            type = 'event_msg'
            payload = [ordered]@{
                type = 'item_completed'
                turn_id = 'turn_test_001'
                item = [ordered]@{
                    type = 'CommandExecution'
                    status = 'completed'
                    parsed_cmd = @(
                        [ordered]@{
                            type = 'read'
                            name = 'SKILL.md'
                            path = 'Z:/agent-skill-root/agent-command-skill/SKILL.md'
                        }
                    )
                }
            }
        } | ConvertTo-Json -Compress -Depth 20
        [IO.File]::WriteAllText(
            $agentTranscript,
            $agentRecord + [Environment]::NewLine + $agentCommandReadRecord + [Environment]::NewLine,
            $Utf8NoBom
        )

        $null = Invoke-TestHook -Event 'SubagentStart' -Fields @{ agent_id = $agentId; agent_type = 'researcher' }
        $null = Invoke-TestHook -Event 'SubagentStart' -Fields @{ agent_id = $agentId; agent_type = 'researcher' }
        $null = Invoke-TestHook -Event 'SubagentStop' -Fields @{
            agent_id = $agentId
            agent_type = 'researcher'
            agent_transcript_path = $agentTranscript
            stop_hook_active = $false
            last_assistant_message = 'ASSISTANT_SECRET_SHOULD_NOT_BE_STORED'
        }
    }

    # Stop 前直接检查 Journal：原始命令和敏感值不得落盘，只允许安全版本。
    $journalFile = Get-ChildItem -LiteralPath (Join-Path $TestRoot 'data\journal') -Filter '*.jsonl' -File | Select-Object -First 1
    if ($null -eq $journalFile) {
        throw '未生成测试 Journal。'
    }
    $journalText = [IO.File]::ReadAllText($journalFile.FullName, [Text.Encoding]::UTF8)
    foreach ($journalSecret in @(
        'SUPER_SECRET_TOKEN',
        'CUSTOMER_SECRET_MESSAGE',
        'CUSTOMER_SECRET_PATTERN',
        'https://user:SUPER_SECRET_TOKEN@example.com/private.git',
        'echo hidden'
    )) {
        Assert-NotContains -Text $journalText -Unexpected $journalSecret
    }
    # JSON serializers may represent '<' and '>' either literally or as
    # \u003c/\u003e. Validate the parsed Journal semantics rather than the
    # serializer's byte-level escape choice.
    $journalRecords = @(
        foreach ($journalLine in [IO.File]::ReadAllLines($journalFile.FullName, [Text.Encoding]::UTF8)) {
            if (-not [string]::IsNullOrWhiteSpace($journalLine)) {
                $journalLine | ConvertFrom-Json
            }
        }
    )
    if ($journalRecords.Count -eq 0) {
        throw '测试 Journal 没有可解析记录。'
    }
    $journalSafeCommandText = @(
        foreach ($journalRecord in $journalRecords) {
            $safeCommandsProperty = $journalRecord.PSObject.Properties['safeCommands']
            if ($null -eq $safeCommandsProperty) { continue }
            foreach ($safeCommand in @($safeCommandsProperty.Value)) {
                [string]$safeCommand
            }
        }
    ) -join "`n"
    Assert-Contains -Text $journalSafeCommandText -Expected '<远程地址已隐藏>'
    Assert-Contains -Text $journalSafeCommandText -Expected '<内容已隐藏>'

    $stopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 3700 -Fields @{ stop_hook_active = $false; last_assistant_message = 'ASSISTANT_SECRET_SHOULD_NOT_BE_STORED' }
    $stop = $stopRaw | ConvertFrom-Json
    $message = [string]$stop.systemMessage

    $completedFile = Get-ChildItem -LiteralPath (Join-Path $TestRoot 'data\completed') -Filter '*.json' -File | Select-Object -First 1
    if ($null -eq $completedFile) {
        throw 'Stop 后未生成 completed 文件。'
    }
    $completedRecord = [IO.File]::ReadAllText($completedFile.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$completedRecord.schemaVersion -ne 11) {
        throw "Stop 生成的 completed schemaVersion 不是 11：$($completedRecord.schemaVersion)"
    }

    Assert-Contains -Text $message -Expected '耗时 4秒'
    Assert-NotContains -Text $message -Unexpected '状态：完成'
    Assert-Contains -Text $message -Expected '🔌 MCP：filesystem/read_file ×3，browser/open ×1'
    Assert-Contains -Text $message -Expected '🧩 Skill：analyze ×1，openai-docs ×1，custom-call-skill ×1，slides ×1，runtime-helper ×1，agent-skill ×2，agent-command-skill ×2，pdfs ×1'
    Assert-NotContains -Text $message -Unexpected 'available-only'
    Assert-NotContains -Text $message -Unexpected 'available-after-baseline'
    Assert-NotContains -Text $message -Unexpected 'catalog-only'
    Assert-NotContains -Text $message -Unexpected 'plain-person'
    Assert-NotContains -Text $message -Unexpected 'not-a-skill'
    Assert-NotContains -Text $message -Unexpected 'patch-mentioned-skill'
    Assert-NotContains -Text $message -Unexpected 'pending-call-skill'
    Assert-Contains -Text $message -Expected '🤖 子Agent：researcher ×2'
    Assert-Contains -Text $message -Expected '📝 文件：新增 ×1，修改 ×2，删除 ×1'
    Assert-Contains -Text $message -Expected '🌿 Git：运行 ×2，指令 ×6，变更 ×3'
    Assert-Contains -Text $message -Expected '⚙️ 其他：Shell命令 ×7，权限请求 ×1，上下文压缩 ×1'
    $gitPosition = $message.IndexOf('🌿 Git：', [StringComparison]::Ordinal)
    $otherPosition = $message.IndexOf('⚙️ 其他：', [StringComparison]::Ordinal)
    if ($gitPosition -lt 0 -or $otherPosition -lt 0 -or $gitPosition -ge $otherPosition) {
        throw '客户端摘要中的 Git 必须位于“其他”之前。'
    }
    Assert-NotContains -Text $message -Unexpected '文件修改'
    if ($message.IndexOf("`r", [StringComparison]::Ordinal) -ge 0 -or $message.IndexOf("`n", [StringComparison]::Ordinal) -ge 0) {
        throw '默认 Stop 输出必须是逻辑单行。'
    }
    Assert-NotContains -Text $message -Unexpected '统计范围：'

    $log = Get-ChildItem -LiteralPath (Join-Path $TestRoot 'logs') -Filter '*.log' -File | Select-Object -First 1
    if ($null -eq $log) {
        throw '未创建每日日志。'
    }
    $logText = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    foreach ($section in @('【任务信息】', '【执行结果】', '【调用统计】', '【文件变更】', '【Skill采集】', '【统计完整性】')) {
        Assert-Contains -Text $logText -Expected $section
    }
    Assert-Contains -Text $logText -Expected '程序版本：v2.1'
    Assert-NotContains -Text $logText -Unexpected '日志格式版本'
    Assert-Contains -Text $logText -Expected '状态：完成'
    Assert-Contains -Text $logText -Expected '状态来源：Hook推定'
    Assert-Matches -Text $logText -Pattern '(?s)MCP：\s*\r?\n\s*- filesystem/read_file ×3\s*\r?\n\s*- browser/open ×1'
    Assert-Matches -Text $logText -Pattern '(?s)Skill：\s*\r?\n\s*- analyze ×1\s*\r?\n\s*- openai-docs ×1\s*\r?\n\s*- custom-call-skill ×1\s*\r?\n\s*- slides ×1\s*\r?\n\s*- runtime-helper ×1\s*\r?\n\s*- agent-skill ×2\s*\r?\n\s*- agent-command-skill ×2\s*\r?\n\s*- pdfs ×1'
    Assert-Matches -Text $logText -Pattern '(?s)子Agent：\s*\r?\n\s*- researcher ×2'
    Assert-Matches -Text $logText -Pattern '(?s)Git：\s*\r?\n\s*运行 ×2\s*\r?\n\s*指令 ×6\s*\r?\n\s*变更 ×3'
    Assert-Contains -Text $logText -Expected '运行 1（指令 ×4）：'
    Assert-Contains -Text $logText -Expected '运行 2（指令 ×2）：'
    Assert-Contains -Text $logText -Expected 'git reset --mixed HEAD~1'
    Assert-Contains -Text $logText -Expected 'git status --short --branch'
    Assert-Contains -Text $logText -Expected 'git log --oneline --decorate -4'
    Assert-Contains -Text $logText -Expected 'git diff --stat'
    Assert-Contains -Text $logText -Expected 'git clone <远程地址已隐藏>'
    Assert-Contains -Text $logText -Expected 'git commit -m <内容已隐藏>'
    Assert-Contains -Text $logText -Expected "Select-String -Path src/views/amazon/listing/products/index.vue -Pattern <内容已隐藏>"
    Assert-Contains -Text $logText -Expected '命令记录策略：safe（仅保存安全处理后的内容，原始命令不落盘）'
    Assert-Matches -Text $logText -Pattern '(?s)文件：\s*\r?\n\s*- 新增 ×1\s*\r?\n\s*- 修改 ×2\s*\r?\n\s*- 删除 ×1'
    Assert-Contains -Text $logText -Expected '文件变更总数：4'
    Assert-Contains -Text $logText -Expected '编辑操作次数：2'
    Assert-Contains -Text $logText -Expected '未解析编辑操作：0'
    Assert-Contains -Text $logText -Expected '文件采集来源：apply_patch + 命令重命名/移动'
    Assert-Contains -Text $logText -Expected '文件统计完整性：部分'
    Assert-Matches -Text $logText -Pattern '(?s)其他：\s*\r?\n\s*- Shell命令 ×7\s*\r?\n\s*- 权限请求 ×1\s*\r?\n\s*- 上下文压缩 ×1'
    Assert-Contains -Text $logText -Expected '采集模式：多源识别'
    Assert-Contains -Text $logText -Expected '采集来源：主任务会话记录－实际注入 + 主任务命令记录－读取 SKILL.md + 结构化Skill输入 + Hook工具调用－读取 SKILL.md + 子Agent会话记录－实际注入 + 子Agent命令记录－读取 SKILL.md + 显式标记回退'
    Assert-Contains -Text $logText -Expected '证据等级：混合（已确认 + 已读取 + 已请求）'
    Assert-Contains -Text $logText -Expected '解析器版本：3'
    Assert-Contains -Text $logText -Expected '会话记录解析：主任务=已读取；子Agent=已读取 2/2'
    Assert-Contains -Text $logText -Expected '总体完整性：部分'
    foreach ($icon in @('🔌', '🧩', '🤖', '📝', '🌿', '⚙️')) {
        Assert-NotContains -Text $logText -Unexpected $icon
    }

    $privacySentinels = @(
        'PROMPT_SECRET_SHOULD_NOT_BE_STORED',
        'ASSISTANT_SECRET_SHOULD_NOT_BE_STORED',
        'MCP_INPUT_SECRET_SHOULD_NOT_BE_STORED',
        'MCP_OUTPUT_SECRET_SHOULD_NOT_BE_STORED',
        'PATCH_CONTENT_SECRET_SHOULD_NOT_BE_STORED',
        'patch-mentioned-skill',
        'PATCH_RESPONSE_SECRET_SHOULD_NOT_BE_STORED',
        'TRANSCRIPT_SKILL_BODY_SECRET_SHOULD_NOT_BE_STORED',
        'ACTUAL_ANALYZE_PATH_SECRET',
        'STRUCTURED_SKILL_PATH_SECRET',
        'AGENT_SKILL_PATH_SECRET',
        'agent-skill-root',
        'AVAILABLE_ONLY_SECRET',
        'AVAILABLE_AFTER_BASELINE_SECRET',
        'CATALOG_ONLY_SECRET',
        'custom-codex-home',
        'custom-runtime',
        'pending-runtime',
        '动态 Codex 根目录',
        '任意 Skill 根目录',
        'FILE_ADDED_SECRET.txt',
        'FILE_MODIFIED_SECRET.txt',
        'FILE_MODIFIED_RENAMED_SECRET.txt',
        'FILE_RENAME_SOURCE_SECRET.txt',
        'FILE_RENAME_TARGET_SECRET.txt',
        'FILE_DELETED_SECRET.txt',
        'echo hidden',
        'SUPER_SECRET_TOKEN',
        'CUSTOMER_SECRET_MESSAGE',
        'CUSTOMER_SECRET_PATTERN',
        'https://user:SUPER_SECRET_TOKEN@example.com/private.git'
    )
    foreach ($sentinel in $privacySentinels) {
        Assert-NotContains -Text $logText -Unexpected $sentinel
    }

    # Late events after completion must be ignored, and a duplicate Stop must not
    # append a second daily-log block.
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ tool_name = 'mcp__browser__open'; tool_use_id = 'late-after-stop'; tool_input = @{}; tool_response = @{} }
    $secondStopRaw = Invoke-TestHook -Event 'Stop' -Fields @{ stop_hook_active = $false; last_assistant_message = 'ASSISTANT_SECRET_SHOULD_NOT_BE_STORED' }
    $secondStop = $secondStopRaw | ConvertFrom-Json
    if (-not [string]::Equals([string]$secondStop.systemMessage, $message, [StringComparison]::Ordinal)) {
        throw '重复 Stop 未返回原始幂等摘要。'
    }
    $logTextAfterSecondStop = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    $recordCount = ([Regex]::Matches($logTextAfterSecondStop, '(?m)^记录时间：')).Count
    if ($recordCount -ne 1) {
        throw "重复 Stop 追加了 $recordCount 条每日日志记录；预期为 1 条。"
    }

    # commandLogging.mode=off 不影响 Git 汇总；纯只读 Git 仍展示运行/指令，不展示“变更 ×0”。
    $runtimeConfigPath = Join-Path $ConfigRoot 'config.json'
    $runtimeConfig = [IO.File]::ReadAllText($runtimeConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $runtimeConfig.commandLogging.mode = 'off'
    [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 50), $Utf8NoBom)

    $offStartRaw = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{
        turn_id = 'turn_command_logging_off'
        prompt = 'command logging off test'
    }
    $offGitCommand = 'git status --short --branch; git diff --stat'
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{
        turn_id = 'turn_command_logging_off'
        tool_name = 'Bash'
        tool_use_id = 'git-off-1'
        tool_input = @{ command = $offGitCommand }
    }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{
        turn_id = 'turn_command_logging_off'
        tool_name = 'Bash'
        tool_use_id = 'git-off-1'
        tool_input = @{ command = $offGitCommand }
        tool_response = @{}
    }
    $offStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 2200 -Fields @{
        turn_id = 'turn_command_logging_off'
        stop_hook_active = $false
        last_assistant_message = 'not persisted'
    }
    $offMessage = [string](($offStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $offMessage -Expected '🌿 Git：运行 ×1，指令 ×2'
    Assert-NotContains -Text $offMessage -Unexpected '变更 ×0'

    $offLogText = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    $taskParts = [Regex]::Split($offLogText, [Regex]::Escape('【任务信息】'))
    $offTaskBlock = '【任务信息】' + [string]$taskParts[$taskParts.Count - 1]
    Assert-Contains -Text $offTaskBlock -Expected '命令记录策略：off（不保存命令明细，原始命令不落盘）'
    Assert-Matches -Text $offTaskBlock -Pattern '(?s)Git：\s*\r?\n\s*运行 ×1\s*\r?\n\s*指令 ×2'
    Assert-NotContains -Text $offTaskBlock -Unexpected '变更 ×0'
    Assert-NotContains -Text $offTaskBlock -Unexpected '  命令：'
    Assert-NotContains -Text $offTaskBlock -Unexpected 'git status --short --branch'

    $runtimeConfig.commandLogging.mode = 'safe'
    [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 50), $Utf8NoBom)

    # 仅重命名/移动也必须归入“文件：修改 ×1”，且不能同时计入新增或删除。
    $moveOnlyTurn = 'turn_move_only'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $moveOnlyTurn; prompt = 'move only test' }
    $moveOnlyCommand = @'
$old='A.md'
$new='B.md'
Move-Item -LiteralPath $old -Destination $new
'@
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ turn_id = $moveOnlyTurn; tool_name = 'Bash'; tool_use_id = 'move-only'; tool_input = @{ command = $moveOnlyCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ turn_id = $moveOnlyTurn; tool_name = 'Bash'; tool_use_id = 'move-only'; tool_input = @{ command = $moveOnlyCommand }; tool_response = @{} }
    $moveOnlyStop = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 1000 -Fields @{ turn_id = $moveOnlyTurn; stop_hook_active = $false }
    $moveOnlyMessage = [string](($moveOnlyStop | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $moveOnlyMessage -Expected '📝 文件：修改 ×1'
    Assert-NotContains -Text $moveOnlyMessage -Unexpected '文件：新增'
    Assert-NotContains -Text $moveOnlyMessage -Unexpected '文件：删除'

    # Rename-Item 使用相对 NewName 时，新路径应落在旧文件同一目录。
    $renameOnlyTurn = 'turn_rename_only'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $renameOnlyTurn; prompt = 'rename only test' }
    $renameOnlyCommand = "Rename-Item -LiteralPath 'folder\A.md' -NewName 'B.md'"
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ turn_id = $renameOnlyTurn; tool_name = 'Bash'; tool_use_id = 'rename-only'; tool_input = @{ command = $renameOnlyCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ turn_id = $renameOnlyTurn; tool_name = 'Bash'; tool_use_id = 'rename-only'; tool_input = @{ command = $renameOnlyCommand }; tool_response = @{} }
    $renameOnlyStop = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 1000 -Fields @{ turn_id = $renameOnlyTurn; stop_hook_active = $false }
    $renameOnlyMessage = [string](($renameOnlyStop | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $renameOnlyMessage -Expected '📝 文件：修改 ×1'

    # Git 参数敏感判断：只读命令不计变更，真正产生变化的命令逐条 +1。
    $gitClassificationTurn = 'turn_git_change_classification'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $gitClassificationTurn; prompt = 'git classification test' }
    $gitClassificationCommand = @'
git status
git diff --check
git branch
git branch feature-a
git tag
git tag v1.0
git clean -n
git clean -fd
git apply --check test.patch
git apply test.patch
git remote -v
git remote add origin https://user:TOP_SECRET@example.invalid/repo.git
git config user.email
git config user.email private@example.invalid
git add .
git commit -m "PRIVATE_COMMIT_MESSAGE"
git push
'@
    $null = Invoke-TestHook -Event 'PreToolUse' -Fields @{ turn_id = $gitClassificationTurn; tool_name = 'Bash'; tool_use_id = 'git-classification'; tool_input = @{ command = $gitClassificationCommand } }
    $null = Invoke-TestHook -Event 'PostToolUse' -Fields @{ turn_id = $gitClassificationTurn; tool_name = 'Bash'; tool_use_id = 'git-classification'; tool_input = @{ command = $gitClassificationCommand }; tool_response = @{} }
    $gitClassificationStop = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 1500 -Fields @{ turn_id = $gitClassificationTurn; stop_hook_active = $false }
    $gitClassificationMessage = [string](($gitClassificationStop | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $gitClassificationMessage -Expected '🌿 Git：运行 ×1，指令 ×17，变更 ×9'

    # v2.1: assert each dry-run spelling independently. Aggregate-only testing
    # previously reported 10 changes without identifying which command was wrong.
    foreach ($gitCleanCase in @(
        [ordered]@{ Suffix = 'short-n'; Command = 'git clean -n'; ChangeCount = 0 },
        [ordered]@{ Suffix = 'long-dry-run'; Command = 'git clean --dry-run'; ChangeCount = 0 },
        [ordered]@{ Suffix = 'combined-nd'; Command = 'git clean -nd'; ChangeCount = 0 },
        [ordered]@{ Suffix = 'combined-dn'; Command = 'git clean -dn'; ChangeCount = 0 },
        [ordered]@{ Suffix = 'combined-nfd'; Command = 'git clean -nfd'; ChangeCount = 0 },
        [ordered]@{ Suffix = 'destructive-fd'; Command = 'git clean -fd'; ChangeCount = 1 }
    )) {
        Assert-GitCommandClassification `
            -TurnId ('turn_git_clean_' + [string]$gitCleanCase.Suffix) `
            -Command ([string]$gitCleanCase.Command) `
            -ExpectedChangeCount ([int]$gitCleanCase.ChangeCount)
    }

    $classificationLogText = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    foreach ($sensitiveValue in @('TOP_SECRET', 'private@example.invalid', 'PRIVATE_COMMIT_MESSAGE')) {
        Assert-NotContains -Text $classificationLogText -Unexpected $sensitiveValue
    }

    # Some Codex builds can write the Skill-read event immediately before the
    # UserPromptSubmit baseline. v2.1 preserves the bounded current-turn lookback
    # and must ignore a similar record from another turn.
    $lookbackTurn = 'turn_test_lookback'
    $wrongTurnRecord = [ordered]@{
        timestamp = '2026-08-25T06:28:00.000Z'
        type = 'event_msg'
        payload = [ordered]@{
            type = 'item_completed'
            turn_id = 'turn_other'
            item = [ordered]@{
                type = 'CommandExecution'
                status = 'completed'
                parsed_cmd = @([ordered]@{ type = 'read'; name = 'SKILL.md'; path = 'Q:/wrong-turn/SKILL.md' })
            }
        }
    } | ConvertTo-Json -Compress -Depth 20
    $lookbackSkillRecord = [ordered]@{
        timestamp = '2026-08-25T06:28:00.100Z'
        type = 'event_msg'
        payload = [ordered]@{
            type = 'item_completed'
            turn_id = $lookbackTurn
            item = [ordered]@{
                type = 'CommandExecution'
                status = 'completed'
                parsed_cmd = @([ordered]@{ type = 'read'; name = 'SKILL.md'; path = 'Q:/before-baseline/lookback-skill/SKILL.md' })
            }
        }
    } | ConvertTo-Json -Compress -Depth 20
    [IO.File]::WriteAllText(
        $LookbackTranscript,
        $wrongTurnRecord + [Environment]::NewLine + $lookbackSkillRecord + [Environment]::NewLine,
        $Utf8NoBom
    )
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{
        turn_id = $lookbackTurn
        transcript_path = $LookbackTranscript
        prompt = 'LOOKBACK_PROMPT_SECRET_SHOULD_NOT_BE_STORED'
    }
    [IO.File]::AppendAllText(
        $LookbackTranscript,
        (([ordered]@{ type = 'event_msg'; payload = [ordered]@{ type = 'task_progress'; turn_id = $lookbackTurn } } | ConvertTo-Json -Compress -Depth 10) + [Environment]::NewLine),
        $Utf8NoBom
    )
    $lookbackStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 900 -Fields @{
        turn_id = $lookbackTurn
        transcript_path = $LookbackTranscript
        stop_hook_active = $false
    }
    $lookbackMessage = [string](($lookbackStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $lookbackMessage -Expected '🧩 Skill：lookback-skill ×1'
    Assert-NotContains -Text $lookbackMessage -Unexpected 'wrong-turn'
    $logAfterLookback = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    Assert-Matches -Text $logAfterLookback -Pattern '(?s)turn_id：turn_test_lookback.*?Skill：\s*\r?\n\s*- lookback-skill ×1.*?采集来源：主任务命令记录－读取 SKILL\.md.*?证据等级：已读取.*?解析器版本：3.*?会话记录解析：主任务=已读取（含当前Turn回看）'
    Assert-NotContains -Text $logAfterLookback -Unexpected 'LOOKBACK_PROMPT_SECRET_SHOULD_NOT_BE_STORED'

    # Empty turn: all empty categories are omitted from the client summary.
    $emptyTurn = 'turn_test_empty'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $emptyTurn; prompt = 'NO_SKILL_SECRET_SHOULD_NOT_BE_STORED' }
    $emptyStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 400 -Fields @{ turn_id = $emptyTurn; stop_hook_active = $false }
    $emptyMessage = [string](($emptyStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Matches -Text $emptyMessage -Pattern '^结束 .+（耗时 不足1秒）$'
    Assert-NotContains -Text $emptyMessage -Unexpected '状态：完成'
    foreach ($category in @('MCP：', 'Skill：', '子Agent：', '文件：', '其他：')) {
        Assert-NotContains -Text $emptyMessage -Unexpected $category
    }
    foreach ($icon in @('🔌', '🧩', '🤖', '📝', '🌿', '⚙️')) {
        Assert-NotContains -Text $emptyMessage -Unexpected $icon
    }
    $logAfterEmptyTurn = [IO.File]::ReadAllText($log.FullName, [Text.Encoding]::UTF8)
    Assert-Matches -Text $logAfterEmptyTurn -Pattern '(?s)turn_id：turn_test_empty.*?MCP：无.*?Skill：无.*?子Agent：无.*?其他：无.*?文件：无'

    # Non-success statuses remain visible, while empty categories remain hidden.
    $failedTurn = 'turn_test_failed'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $failedTurn; prompt = 'FAILED_TURN_SECRET_SHOULD_NOT_BE_STORED' }
    $failedStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 1500 -Fields @{ turn_id = $failedTurn; stop_hook_active = $false; status = 'failed' }
    $failedMessage = [string](($failedStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $failedMessage -Expected '耗时 2秒'
    Assert-Contains -Text $failedMessage -Expected '状态：失败'
    Assert-NotContains -Text $failedMessage -Unexpected 'MCP：'

    $interruptedTurn = 'turn_test_interrupted'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $interruptedTurn; prompt = 'INTERRUPTED_TURN_SECRET_SHOULD_NOT_BE_STORED' }
    $interruptedStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 500 -Fields @{ turn_id = $interruptedTurn; stop_hook_active = $false; status = 'interrupted' }
    $interruptedMessage = [string](($interruptedStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $interruptedMessage -Expected '耗时 1秒'
    Assert-Contains -Text $interruptedMessage -Expected '状态：已中断'

    $unknownTurn = 'turn_test_unknown'
    $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $unknownTurn; prompt = 'UNKNOWN_TURN_SECRET_SHOULD_NOT_BE_STORED' }
    $unknownStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 0 -Fields @{ turn_id = $unknownTurn; stop_hook_active = $false; status = 'unknown' }
    $unknownMessage = [string](($unknownStopRaw | ConvertFrom-Json).systemMessage)
    Assert-Contains -Text $unknownMessage -Expected '耗时 不足1秒'
    Assert-Contains -Text $unknownMessage -Expected '状态：未知'

    # Optional Git integration verifies Shell/external file changes and the
    # critical rename rule: one rename contributes exactly one 修改, while its
    # source and destination do not also contribute to 新增/删除.
    $gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction SilentlyContinue }
    if ($null -ne $gitCommand) {
        $gitExe = [string]$gitCommand.Source
        $gitWorkspace = Join-Path $TestRoot 'git-workspace'
        $null = New-Item -ItemType Directory -Path $gitWorkspace -Force
        & $gitExe -C $gitWorkspace init -q
        & $gitExe -C $gitWorkspace config user.email 'codex-task-stats-test@example.invalid'
        & $gitExe -C $gitWorkspace config user.name 'Codex Task Stats Test'
        [IO.File]::WriteAllText((Join-Path $gitWorkspace 'tracked.txt'), 'original', $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $gitWorkspace 'rename-source.txt'), 'rename', $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $gitWorkspace 'delete-me.txt'), 'delete', $Utf8NoBom)
        & $gitExe -C $gitWorkspace add --all
        & $gitExe -C $gitWorkspace commit -q -m 'baseline'
        if ($LASTEXITCODE -ne 0) { throw '无法创建 Git 集成测试基线。' }

        $gitTurn = 'turn_test_git_delta'
        $null = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $gitTurn; cwd = $gitWorkspace; prompt = 'GIT_DELTA_SECRET_SHOULD_NOT_BE_STORED' }
        [IO.File]::WriteAllText((Join-Path $gitWorkspace 'tracked.txt'), 'modified', $Utf8NoBom)
        [IO.File]::WriteAllText((Join-Path $gitWorkspace 'added.txt'), 'added', $Utf8NoBom)
        Remove-Item -LiteralPath (Join-Path $gitWorkspace 'delete-me.txt') -Force
        & $gitExe -C $gitWorkspace mv -- 'rename-source.txt' 'rename-target.txt'
        if ($LASTEXITCODE -ne 0) { throw 'Git 重命名测试准备失败。' }

        $gitStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 2100 -Fields @{ turn_id = $gitTurn; cwd = $gitWorkspace; stop_hook_active = $false }
        $gitMessage = [string](($gitStopRaw | ConvertFrom-Json).systemMessage)
        Assert-Contains -Text $gitMessage -Expected '📝 文件：新增 ×1，修改 ×2，删除 ×1'
        Assert-NotContains -Text $gitMessage -Unexpected '新增 ×2'
        Assert-NotContains -Text $gitMessage -Unexpected '删除 ×2'
    }
    else {
        Write-Warning '未找到 Git，已跳过可选的 Git 差异集成测试。'
    }

    # Bootstrap failure diagnostics must work even before the dependency library
    # is available, while persisting no input, IDs, paths, or exception message.
    $bootstrapRoot = Join-Path $TestRoot 'bootstrap-failure-runtime'
    $bootstrapBin = Join-Path $bootstrapRoot 'bin'
    $null = New-Item -ItemType Directory -Path $bootstrapBin -Force
    $bootstrapProgram = Join-Path $bootstrapBin 'codex-task-stats.ps1'
    Copy-Item -LiteralPath $MainScript -Destination $bootstrapProgram -Force
    $sourceMainBeforeBootstrapTest = $MainScript
    $oldTaskStatsHomeBeforeBootstrapTest = $env:CODEX_TASK_STATS_HOME
    try {
        $MainScript = $bootstrapProgram
        $env:CODEX_TASK_STATS_HOME = $bootstrapRoot
        $bootstrapSentinel = 'BOOTSTRAP_SECRET_MUST_NOT_BE_STORED'
        $bootstrapRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 0 -Fields @{
            turn_id = 'turn_bootstrap_failure'
            prompt = $bootstrapSentinel
            stop_hook_active = $false
        }
        $bootstrapMessage = [string](($bootstrapRaw | ConvertFrom-Json).systemMessage)
        Assert-Contains -Text $bootstrapMessage -Expected '任务统计生成失败'
        $bootstrapLog = Get-ChildItem -LiteralPath (Join-Path $bootstrapRoot 'debug') -Filter 'codex-task-stats-bootstrap-*.jsonl' -File |
            Select-Object -First 1
        if ($null -eq $bootstrapLog) { throw '初始化失败未生成 bootstrap 诊断日志。' }
        $bootstrapText = [IO.File]::ReadAllText($bootstrapLog.FullName, [Text.Encoding]::UTF8)
        Assert-Contains -Text $bootstrapText -Expected 'load-subagent-correlation'
        Assert-Contains -Text $bootstrapText -Expected 'System.IO.FileNotFoundException'
        Assert-NotContains -Text $bootstrapText -Unexpected $bootstrapSentinel
        Assert-NotContains -Text $bootstrapText -Unexpected 'SubagentCorrelation.ps1'
        Assert-NotContains -Text $bootstrapText -Unexpected 'turn_bootstrap_failure'
        Assert-NotContains -Text $bootstrapText -Unexpected $bootstrapProgram
    }
    finally {
        $MainScript = $sourceMainBeforeBootstrapTest
        $env:CODEX_TASK_STATS_HOME = $oldTaskStatsHomeBeforeBootstrapTest
    }

    # A package that omits the required runtime library must fail before modifying
    # any existing runtime, VERSION, config, or hooks.json.
    $missingLibraryPackageRoot = Join-Path $TestRoot 'missing-library-package'
    $missingLibraryPackageScripts = Join-Path $missingLibraryPackageRoot 'scripts'
    $missingLibraryPackageScriptLib = Join-Path $missingLibraryPackageScripts 'lib'
    $missingLibraryPackageSrc = Join-Path $missingLibraryPackageRoot 'src'
    $missingLibraryPackageConfig = Join-Path $missingLibraryPackageRoot 'config'
    foreach ($directory in @(
        $missingLibraryPackageScripts,
        $missingLibraryPackageScriptLib,
        $missingLibraryPackageSrc,
        $missingLibraryPackageConfig
    )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Copy-Item -LiteralPath $InstallScript -Destination (Join-Path $missingLibraryPackageScripts 'install.ps1') -Force
    Copy-Item -LiteralPath $CodexPathLibrary -Destination (Join-Path $missingLibraryPackageScriptLib 'CodexPath.ps1') -Force
    Copy-Item -LiteralPath $MainScript -Destination (Join-Path $missingLibraryPackageSrc 'codex-task-stats.ps1') -Force
    Copy-Item -LiteralPath $ConfigSource -Destination (Join-Path $missingLibraryPackageConfig 'config.example.json') -Force
    Copy-Item -LiteralPath $VersionSource -Destination (Join-Path $missingLibraryPackageRoot 'VERSION') -Force

    $missingLibraryCodexHome = Join-Path $TestRoot 'missing-library-codex-home'
    $missingLibraryInstallRoot = Join-Path $missingLibraryCodexHome 'task-stats'
    $missingLibraryBin = Join-Path $missingLibraryInstallRoot 'bin'
    $missingLibraryConfigRoot = Join-Path $missingLibraryInstallRoot 'config'
    $null = New-Item -ItemType Directory -Path $missingLibraryBin, $missingLibraryConfigRoot -Force
    $preflightProgram = Join-Path $missingLibraryBin 'codex-task-stats.ps1'
    $preflightVersion = Join-Path $missingLibraryInstallRoot 'VERSION'
    $preflightConfig = Join-Path $missingLibraryConfigRoot 'config.json'
    $preflightHooks = Join-Path $missingLibraryCodexHome 'hooks.json'
    [IO.File]::WriteAllText($preflightProgram, "param()`r`n'preflight-runtime'`r`n", [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($preflightVersion, "v1.7`r`n", $Utf8NoBom)
    [IO.File]::WriteAllText($preflightConfig, '{"schemaVersion":6,"sentinel":"config"}', $Utf8NoBom)
    [IO.File]::WriteAllText($preflightHooks, '{"description":"hooks-sentinel","hooks":{}}', $Utf8NoBom)
    $preflightBefore = [ordered]@{
        program = (Get-FileHash -LiteralPath $preflightProgram -Algorithm SHA256).Hash
        version = (Get-FileHash -LiteralPath $preflightVersion -Algorithm SHA256).Hash
        config = (Get-FileHash -LiteralPath $preflightConfig -Algorithm SHA256).Hash
        hooks = (Get-FileHash -LiteralPath $preflightHooks -Algorithm SHA256).Hash
    }
    $missingLibraryInstaller = Join-Path $missingLibraryPackageScripts 'install.ps1'
    $missingLibraryResult = Invoke-InstallerExpectingFailure `
        -Installer $missingLibraryInstaller `
        -CodexHome $missingLibraryCodexHome
    $missingLibraryOutput = [string]$missingLibraryResult.Output
    if ([int]$missingLibraryResult.ExitCode -eq 0) {
        throw '缺少源运行时库时安装器不应成功。'
    }
    Assert-Contains -Text $missingLibraryOutput -Expected '缺少源运行时依赖'
    foreach ($entry in $preflightBefore.GetEnumerator()) {
        $path = switch ($entry.Key) {
            'program' { $preflightProgram }
            'version' { $preflightVersion }
            'config' { $preflightConfig }
            'hooks' { $preflightHooks }
        }
        $afterHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if (-not [string]::Equals([string]$entry.Value, $afterHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "源依赖预检失败后修改了 $($entry.Key)。"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $missingLibraryBin 'lib\SubagentCorrelation.ps1') -PathType Leaf) {
        throw '源依赖预检失败后不应创建运行时库。'
    }

    # The installer must reject a syntactically valid library that reproduces
    # the Windows PowerShell 5.1 Generic.List materialization failure before it
    # creates runtime files or edits hooks.json.
    $preflightPackageRoot = Join-Path $TestRoot 'compat-preflight-package'
    $preflightPackageScripts = Join-Path $preflightPackageRoot 'scripts'
    $preflightPackageScriptLib = Join-Path $preflightPackageScripts 'lib'
    $preflightPackageSrc = Join-Path $preflightPackageRoot 'src'
    $preflightPackageSrcLib = Join-Path $preflightPackageSrc 'lib'
    $preflightPackageConfig = Join-Path $preflightPackageRoot 'config'
    foreach ($directory in @(
        $preflightPackageScripts,
        $preflightPackageScriptLib,
        $preflightPackageSrc,
        $preflightPackageSrcLib,
        $preflightPackageConfig
    )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Copy-Item -LiteralPath $InstallScript -Destination (Join-Path $preflightPackageScripts 'install.ps1') -Force
    Copy-Item -LiteralPath $CodexPathLibrary -Destination (Join-Path $preflightPackageScriptLib 'CodexPath.ps1') -Force
    Copy-Item -LiteralPath $MainScript -Destination (Join-Path $preflightPackageSrc 'codex-task-stats.ps1') -Force
    Copy-Item -LiteralPath $ConfigSource -Destination (Join-Path $preflightPackageConfig 'config.example.json') -Force
    Copy-Item -LiteralPath $VersionSource -Destination (Join-Path $preflightPackageRoot 'VERSION') -Force

    $brokenCompatibilityLibrary = @'
function Invoke-V19SubagentCorrelationCompatibilityProbe {
    $items = New-Object 'System.Collections.Generic.List[object]'
    $items.Add([pscustomobject]@{ Value = 1 })
    $materialized = @($items)
    return [pscustomobject]@{ Passed = ($materialized.Count -eq 1) }
}
'@
    $brokenCompatibilityLibrary = $brokenCompatibilityLibrary.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText(
        (Join-Path $preflightPackageSrcLib 'SubagentCorrelation.ps1'),
        $brokenCompatibilityLibrary,
        [Text.UTF8Encoding]::new($true)
    )

    $preflightCodexHome = Join-Path $TestRoot 'compat-preflight-codex-home'
    $null = New-Item -ItemType Directory -Path $preflightCodexHome -Force
    $preflightHooksPath = Join-Path $preflightCodexHome 'hooks.json'
    $preflightHooksJson = [ordered]@{
        description = 'compat preflight sentinel'
        hooks = [ordered]@{
            Stop = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'powershell.exe -NoProfile -Command "exit 0"'
                            timeout = 5
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($preflightHooksPath, $preflightHooksJson, $Utf8NoBom)
    $preflightHooksHashBefore = (Get-FileHash -LiteralPath $preflightHooksPath -Algorithm SHA256).Hash
    $preflightInstaller = Join-Path $preflightPackageScripts 'install.ps1'
    $preflightResult = Invoke-InstallerExpectingFailure `
        -Installer $preflightInstaller `
        -CodexHome $preflightCodexHome
    $preflightOutput = [string]$preflightResult.Output
    $preflightExitCode = [int]$preflightResult.ExitCode
    if ($preflightExitCode -eq 0) {
        throw "兼容预检应拒绝有缺陷的关联库，但安装器返回成功。输出：`n$preflightOutput"
    }
    Assert-Contains -Text $preflightOutput -Expected '不兼容的 New-Object Generic.List 构造'
    $preflightHooksHashAfter = (Get-FileHash -LiteralPath $preflightHooksPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($preflightHooksHashBefore, $preflightHooksHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw '兼容预检失败后 hooks.json 被修改。'
    }
    $unexpectedPreflightPaths = @(
        (Join-Path $preflightCodexHome 'task-stats\bin\codex-task-stats.ps1'),
        (Join-Path $preflightCodexHome 'task-stats\bin\lib\SubagentCorrelation.ps1'),
        (Join-Path $preflightCodexHome 'task-stats\config\config.json'),
        (Join-Path $preflightCodexHome 'task-stats\VERSION')
    )
    foreach ($unexpectedPath in $unexpectedPreflightPaths) {
        if (Test-Path -LiteralPath $unexpectedPath -PathType Leaf) {
            throw "兼容预检失败后仍创建了用户文件：$unexpectedPath"
        }
    }

    # Static matching is only an early guard. A dynamically constructed type
    # name bypasses that pattern and must still be rejected by the actual
    # Windows PowerShell 5.1 compatibility probe before any user file changes.
    $runtimeOnlyCompatibilityLibrary = @'
function Invoke-V19SubagentCorrelationCompatibilityProbe {
    $typeName = 'System.Collections.Generic.List' + '[object]'
    $items = New-Object -TypeName $typeName
    $materialized = @($items)
    return [pscustomobject]@{
        Passed = ($materialized.Count -eq 0)
        Code = 'OK'
        ExceptionType = ''
    }
}
'@
    $runtimeOnlyCompatibilityLibrary = $runtimeOnlyCompatibilityLibrary.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText(
        (Join-Path $preflightPackageSrcLib 'SubagentCorrelation.ps1'),
        $runtimeOnlyCompatibilityLibrary,
        [Text.UTF8Encoding]::new($true)
    )

    $runtimePreflightCodexHome = Join-Path $TestRoot 'runtime-compat-preflight-codex-home'
    $null = New-Item -ItemType Directory -Path $runtimePreflightCodexHome -Force
    $runtimePreflightHooksPath = Join-Path $runtimePreflightCodexHome 'hooks.json'
    [IO.File]::WriteAllText($runtimePreflightHooksPath, $preflightHooksJson, $Utf8NoBom)
    $runtimePreflightHooksHashBefore = (Get-FileHash -LiteralPath $runtimePreflightHooksPath -Algorithm SHA256).Hash
    $runtimePreflightResult = Invoke-InstallerExpectingFailure `
        -Installer $preflightInstaller `
        -CodexHome $runtimePreflightCodexHome
    $runtimePreflightOutput = [string]$runtimePreflightResult.Output
    $runtimePreflightExitCode = [int]$runtimePreflightResult.ExitCode
    if ($runtimePreflightExitCode -eq 0) {
        throw "运行时兼容探针应拒绝动态 Generic.List 缺陷库，但安装器返回成功。输出：`n$runtimePreflightOutput"
    }
    Assert-Contains -Text $runtimePreflightOutput -Expected 'Windows PowerShell 5.1 运行时兼容性检查失败'
    $runtimePreflightHooksHashAfter = (Get-FileHash -LiteralPath $runtimePreflightHooksPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($runtimePreflightHooksHashBefore, $runtimePreflightHooksHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw '运行时兼容预检失败后 hooks.json 被修改。'
    }
    $unexpectedRuntimePreflightPaths = @(
        (Join-Path $runtimePreflightCodexHome 'task-stats\bin\codex-task-stats.ps1'),
        (Join-Path $runtimePreflightCodexHome 'task-stats\bin\lib\SubagentCorrelation.ps1'),
        (Join-Path $runtimePreflightCodexHome 'task-stats\config\config.json'),
        (Join-Path $runtimePreflightCodexHome 'task-stats\VERSION')
    )
    foreach ($unexpectedPath in $unexpectedRuntimePreflightPaths) {
        if (Test-Path -LiteralPath $unexpectedPath -PathType Leaf) {
            throw "运行时兼容预检失败后仍创建了用户文件：$unexpectedPath"
        }
    }

    # A probe that claims success but omits the expected evidence must also be
    # rejected before user files change. This prevents a stub or incomplete probe
    # from bypassing the compatibility gate.
    $invalidResultCompatibilityLibrary = @'
function Invoke-V19SubagentCorrelationCompatibilityProbe {
    return [pscustomobject]@{
        Passed = $true
        Code = 'OK'
        ExceptionType = ''
        ProbeVersion = 1
        ReadEventCount = 0
        MergedRunCount = 0
        MergedEventCount = 0
        FallbackStartCount = 0
    }
}
'@
    $invalidResultCompatibilityLibrary = $invalidResultCompatibilityLibrary.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText(
        (Join-Path $preflightPackageSrcLib 'SubagentCorrelation.ps1'),
        $invalidResultCompatibilityLibrary,
        [Text.UTF8Encoding]::new($true)
    )

    $invalidResultCodexHome = Join-Path $TestRoot 'invalid-probe-result-codex-home'
    $null = New-Item -ItemType Directory -Path $invalidResultCodexHome -Force
    $invalidResultHooksPath = Join-Path $invalidResultCodexHome 'hooks.json'
    [IO.File]::WriteAllText($invalidResultHooksPath, $preflightHooksJson, $Utf8NoBom)
    $invalidResultHooksHashBefore = (Get-FileHash -LiteralPath $invalidResultHooksPath -Algorithm SHA256).Hash
    $invalidResult = Invoke-InstallerExpectingFailure `
        -Installer $preflightInstaller `
        -CodexHome $invalidResultCodexHome
    $invalidResultOutput = [string]$invalidResult.Output
    $invalidResultExitCode = [int]$invalidResult.ExitCode
    if ($invalidResultExitCode -eq 0) {
        throw "兼容探针结果校验应拒绝缺少预期证据的库，但安装器返回成功。输出：`n$invalidResultOutput"
    }
    Assert-Contains -Text $invalidResultOutput -Expected '运行时兼容性检查结果无效：ReadEventCount'
    $invalidResultHooksHashAfter = (Get-FileHash -LiteralPath $invalidResultHooksPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($invalidResultHooksHashBefore, $invalidResultHooksHashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw '兼容探针结果无效后 hooks.json 被修改。'
    }
    foreach ($unexpectedPath in @(
        (Join-Path $invalidResultCodexHome 'task-stats\bin\codex-task-stats.ps1'),
        (Join-Path $invalidResultCodexHome 'task-stats\bin\lib\SubagentCorrelation.ps1'),
        (Join-Path $invalidResultCodexHome 'task-stats\config\config.json'),
        (Join-Path $invalidResultCodexHome 'task-stats\VERSION')
    )) {
        if (Test-Path -LiteralPath $unexpectedPath -PathType Leaf) {
            throw "兼容探针结果无效后仍创建了用户文件：$unexpectedPath"
        }
    }

    # Restore the real source library for all subsequent installation tests.
    Copy-Item -LiteralPath $SourceSubagentCorrelationLibrary -Destination (Join-Path $preflightPackageSrcLib 'SubagentCorrelation.ps1') -Force

    # Verify that installation preserves unrelated handlers in an existing hooks.json.
    $fakeCodexHome = $environmentHome
    $env:CODEX_HOME = $fakeCodexHome
    $null = New-Item -ItemType Directory -Path $fakeCodexHome -Force
    $brokenV17Bin = Join-Path $fakeCodexHome 'task-stats\bin'
    $brokenV17ProgramPath = Join-Path $brokenV17Bin 'codex-task-stats.ps1'
    $oldTaskStatsCommand = 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $brokenV17ProgramPath + '" -Event "{0}"'
    $existingHooks = [ordered]@{
        description = 'Existing user hooks used by the isolated test.'
        hooks = [ordered]@{
            PostToolUse = @(
                [ordered]@{
                    matcher = '^Bash$'
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'powershell.exe -NoProfile -Command "exit 0"'
                            timeout = 5
                        }
                    )
                }
            )
        }
    }
    $oldTaskStatsEvents = @(
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
    foreach ($oldEvent in $oldTaskStatsEvents) {
        $oldHandler = [ordered]@{
            type = 'command'
            command = ($oldTaskStatsCommand -f $oldEvent)
            commandWindows = ($oldTaskStatsCommand -f $oldEvent)
            timeout = 5
            async = ($oldEvent -notin @('UserPromptSubmit', 'Stop'))
        }
        $oldGroup = if ($oldEvent -in @('UserPromptSubmit', 'Stop')) {
            [ordered]@{ hooks = @($oldHandler) }
        }
        else {
            [ordered]@{ matcher = '*'; hooks = @($oldHandler) }
        }

        if ($existingHooks.hooks.Contains($oldEvent)) {
            $existingHooks.hooks[$oldEvent] = @(@($existingHooks.hooks[$oldEvent]) + $oldGroup)
        }
        else {
            $existingHooks.hooks[$oldEvent] = @($oldGroup)
        }
    }
    $existingHooksJson = $existingHooks | ConvertTo-Json -Depth 20
    $existingHooksObject = $existingHooksJson | ConvertFrom-Json
    if ((Get-TaskStatsHandlerCount -HooksRoot $existingHooksObject) -ne 9) {
        throw '损坏 v1.7 前置条件无效：应包含 9 个旧 task-stats Hook。'
    }
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexHome 'hooks.json'),
        $existingHooksJson,
        $Utf8NoBom
    )

    # Simulate the structurally equivalent broken v1.7 layout: main program and VERSION exist,
    # bin\lib\SubagentCorrelation.ps1 is missing, and config still uses schema 6.
    # v2.1 must repair this directly, replace the old handlers, preserve unrelated values,
    # and create backups.
    $legacyConfigRoot = Join-Path $fakeCodexHome 'task-stats\config'
    $null = New-Item -ItemType Directory -Path $legacyConfigRoot -Force
    $legacyConfig = [ordered]@{
        schemaVersion = 6
        display = [ordered]@{
            multiline = $true
            showCoverageNotice = $true
            emptyValue = '无'
            icons = $null
        }
        collection = [ordered]@{
            intermediateMode = 'quiet'
        }
        logging = [ordered]@{
            enabled = $true
            filePrefix = 'codex-task'
        }
        toolAliases = [ordered]@{
            Bash = 'Shell命令'
            apply_patch = '文件修改'
        }
        legacyPreserveValue = 'keep-after-install'
    }
    $null = New-Item -ItemType Directory -Path $brokenV17Bin -Force
    Copy-Item -LiteralPath $MainScript -Destination $brokenV17ProgramPath -Force
    [IO.File]::WriteAllText(
        (Join-Path $fakeCodexHome 'task-stats\VERSION'),
        ('v1.7' + [Environment]::NewLine),
        $Utf8NoBom
    )
    if (Test-Path -LiteralPath (Join-Path $brokenV17Bin 'lib\SubagentCorrelation.ps1')) {
        throw '损坏 v1.7 前置条件无效：运行时库不应存在。'
    }

    [IO.File]::WriteAllText(
        (Join-Path $legacyConfigRoot 'config.json'),
        ($legacyConfig | ConvertTo-Json -Depth 20),
        $Utf8NoBom
    )

    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $InstallScript -IntermediateMode Quiet | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "安装程序集成测试 退出码为 $LASTEXITCODE"
    }

    $mergedHooks = [IO.File]::ReadAllText((Join-Path $fakeCodexHome 'hooks.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ((Get-TaskStatsHandlerCount -HooksRoot $mergedHooks) -ne 9) {
        throw '安装程序未注册恰好 9 个 codex-task-stats 处理器。'
    }
    Assert-Contains -Text ($mergedHooks | ConvertTo-Json -Depth 50) -Expected 'powershell.exe -NoProfile -Command'
    $backup = Get-ChildItem -LiteralPath (Join-Path $fakeCodexHome 'task-stats\backups') -Filter 'hooks.json.backup-*' -File | Select-Object -First 1
    if ($null -eq $backup) {
        throw '安装程序未创建 hooks.json 备份。'
    }

    $installedVersionPath = Join-Path $fakeCodexHome 'task-stats\VERSION'
    if (-not (Test-Path -LiteralPath $installedVersionPath)) {
        throw '安装程序未复制 VERSION 文件。'
    }
    $installedVersion = [IO.File]::ReadAllText($installedVersionPath, [Text.Encoding]::UTF8).Trim()
    if (-not [string]::Equals($installedVersion, 'v2.1', [StringComparison]::Ordinal)) {
        throw "已安装 VERSION 不正确： $installedVersion"
    }

    $installedProgramPath = Join-Path $fakeCodexHome 'task-stats\bin\codex-task-stats.ps1'
    $installedLibraryPath = Join-Path $fakeCodexHome 'task-stats\bin\lib\SubagentCorrelation.ps1'
    if (-not (Test-Path -LiteralPath $installedProgramPath -PathType Leaf)) {
        throw '安装程序未复制主处理器。'
    }
    if (-not (Test-Path -LiteralPath $installedLibraryPath -PathType Leaf)) {
        throw '安装程序未复制 SubagentCorrelation.ps1。'
    }
    $sourceProgramHash = (Get-FileHash -LiteralPath $MainScript -Algorithm SHA256).Hash
    $installedProgramHash = (Get-FileHash -LiteralPath $installedProgramPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($sourceProgramHash, $installedProgramHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw '安装后的主处理器 SHA-256 与源码不一致。'
    }
    $sourceLibraryHash = (Get-FileHash -LiteralPath $SourceSubagentCorrelationLibrary -Algorithm SHA256).Hash
    $installedLibraryHash = (Get-FileHash -LiteralPath $installedLibraryPath -Algorithm SHA256).Hash
    if (-not [string]::Equals($sourceLibraryHash, $installedLibraryHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw '安装后的子Agent关联库 SHA-256 与源码不一致。'
    }

    # Run the exact installed runtime, not the source tree. This catches missing
    # relative dependencies such as bin\lib\SubagentCorrelation.ps1.
    $sourceMainScriptForTests = $MainScript
    $oldTaskStatsHomeForInstalledSmoke = $env:CODEX_TASK_STATS_HOME
    try {
        $MainScript = $installedProgramPath
        $env:CODEX_TASK_STATS_HOME = Join-Path $fakeCodexHome 'task-stats'
        $installedSmokeTurn = 'turn_installed_runtime_smoke'
        $installedStartRaw = Invoke-TestHook -Event 'UserPromptSubmit' -Fields @{ turn_id = $installedSmokeTurn; prompt = 'INSTALL_RUNTIME_SMOKE' }
        $installedStartMessage = [string](($installedStartRaw | ConvertFrom-Json).systemMessage)
        Assert-Matches -Text $installedStartMessage -Pattern '^开始 [0-9]{2}:[0-9]{2}:[0-9]{2}$'
        $installedStopRaw = Invoke-TestHook -Event 'Stop' -DurationMilliseconds 0 -Fields @{ turn_id = $installedSmokeTurn; stop_hook_active = $false; status = 'completed' }
        $installedStopMessage = [string](($installedStopRaw | ConvertFrom-Json).systemMessage)
        Assert-Contains -Text $installedStopMessage -Expected '结束 '
        Assert-NotContains -Text $installedStopMessage -Unexpected '任务统计生成失败'
        $installedLog = Get-ChildItem -LiteralPath (Join-Path $fakeCodexHome 'task-stats\logs') -Filter '*.log' -File |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($null -eq $installedLog) { throw '已安装运行时烟雾测试没有生成日志。' }
        $installedLogText = [IO.File]::ReadAllText($installedLog.FullName, [Text.Encoding]::UTF8)
        Assert-Contains -Text $installedLogText -Expected '程序版本：v2.1'
    }
    finally {
        $MainScript = $sourceMainScriptForTests
        $env:CODEX_TASK_STATS_HOME = $oldTaskStatsHomeForInstalledSmoke
    }

    $installedConfigPath = Join-Path $fakeCodexHome 'task-stats\config\config.json'
    $installedAfterMerge = [IO.File]::ReadAllText($installedConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$installedAfterMerge.schemaVersion -ne 11) { throw '安装程序未将 schemaVersion 迁移为 11。' }
    if (-not [string]::Equals([string]$installedAfterMerge.legacyPreserveValue, 'keep-after-install', [StringComparison]::Ordinal)) { throw '安装程序未保留旧配置值。' }
    if ($null -eq $installedAfterMerge.display.showSuccessStatus) { throw '安装程序未添加 display.showSuccessStatus。' }
    if ($null -eq $installedAfterMerge.display.hideEmptyCategories) { throw '安装程序未添加 display.hideEmptyCategories。' }
    if ($null -eq $installedAfterMerge.display.icons -or $null -eq $installedAfterMerge.display.icons.file) { throw '安装程序未添加文件图标。' }
    if ($null -eq $installedAfterMerge.display.labels -or $null -eq $installedAfterMerge.display.labels.file) { throw '安装程序未添加文件标签。' }
    if (-not [string]::Equals([string]$installedAfterMerge.display.icons.git, '🌿', [StringComparison]::Ordinal)) { throw '安装程序未添加 Git 图标。' }
    if (-not [string]::Equals([string]$installedAfterMerge.display.labels.git, 'Git', [StringComparison]::Ordinal)) { throw '安装程序未添加 Git 标签。' }
    if ($null -eq $installedAfterMerge.commandLogging) { throw '安装程序未添加 commandLogging。' }
    if (-not [string]::Equals([string]$installedAfterMerge.commandLogging.mode, 'safe', [StringComparison]::Ordinal)) { throw '安装程序未启用安全命令日志。' }
    if ([bool]$installedAfterMerge.commandLogging.includeGit -ne $true) { throw '安装程序未启用 Git 命令明细。' }
    if ([bool]$installedAfterMerge.commandLogging.includeShell -ne $true) { throw '安装程序未启用 Shell 命令明细。' }
    if ($null -eq $installedAfterMerge.skillCollection) { throw '安装程序未添加 skillCollection。' }
    if (-not [string]::Equals([string]$installedAfterMerge.skillCollection.mode, 'multi-source', [StringComparison]::Ordinal)) { throw '安装程序未启用多源 Skill 采集。' }
    if ($null -eq $installedAfterMerge.skillCollection.transcript -or [bool]$installedAfterMerge.skillCollection.transcript.enabled -ne $true) { throw '安装程序未添加 transcript Skill 采集。' }
    if ([bool]$installedAfterMerge.skillCollection.transcript.currentTurnLookbackEnabled -ne $true) { throw '安装程序未添加当前 Turn transcript 回看。' }
    if ([int64]$installedAfterMerge.skillCollection.transcript.lookbackBytes -le 0) { throw '安装程序未添加 transcript 回看大小。' }
    if ($null -eq $installedAfterMerge.skillCollection.commandRead -or [bool]$installedAfterMerge.skillCollection.commandRead.enabled -ne $true) { throw '安装程序未添加 SKILL.md 命令读取采集。' }
    if ([bool]$installedAfterMerge.skillCollection.commandRead.preferParsedCommand -ne $true) { throw '安装程序未优先使用结构化命令证据。' }
    if ([bool]$installedAfterMerge.skillCollection.commandRead.rawCommandFallback -ne $true) { throw '安装程序未启用原始命令内存回退解析。' }
    if ([bool]$installedAfterMerge.skillCollection.commandRead.requireCompletedExecution -ne $true) { throw '安装程序未要求已完成的命令执行证据。' }
    if ($null -eq $installedAfterMerge.fileTracking) { throw '安装程序未添加 fileTracking。' }
    if ([bool]$installedAfterMerge.display.multiline -ne $true) { throw '安装程序意外覆盖了现有 display.multiline 值。' }
    if (-not [string]::Equals([string]$installedAfterMerge.toolAliases.apply_patch, '文件修改', [StringComparison]::Ordinal)) { throw '安装程序意外删除了应保留的旧别名。' }
    $installConfigBackup = Get-ChildItem -LiteralPath (Join-Path $fakeCodexHome 'task-stats\backups') -Filter 'config.json.backup-*' -File | Select-Object -First 1
    if ($null -eq $installConfigBackup) { throw '安装程序未备份现有 config.json。' }
    $runtimeBackup = Get-ChildItem -LiteralPath (Join-Path $fakeCodexHome 'task-stats\backups') -Directory -Filter 'runtime.before-v2.1-*' | Select-Object -First 1
    if ($null -eq $runtimeBackup) { throw '安装程序未创建升级前运行时备份。' }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeBackup.FullName 'codex-task-stats.ps1') -PathType Leaf)) {
        throw '运行时备份缺少升级前主处理器。'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeBackup.FullName 'VERSION') -PathType Leaf)) {
        throw '运行时备份缺少升级前 VERSION。'
    }
    if (Test-Path -LiteralPath (Join-Path $runtimeBackup.FullName 'SubagentCorrelation.ps1')) {
        throw '损坏 v1.7 原本没有运行时库，备份不应伪造该文件。'
    }

    # Verify the migration helper applies all v2.1 recommendations, creates a
    # backup, removes only the obsolete default alias, and preserves unrelated settings.
    $installedConfig = [IO.File]::ReadAllText($installedConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $installedConfig.display.multiline = $true
    $installedConfig.display.showCoverageNotice = $true
    $installedConfig.display.showSuccessStatus = $true
    $installedConfig.display.hideEmptyCategories = $false
    $installedConfig.display.highlightStyle = 'none'
    $installedConfig.display.emptyValue = 'EMPTY'
    $installedConfig.commandLogging.mode = 'full'
    $installedConfig | Add-Member -NotePropertyName 'testPreserveValue' -NotePropertyValue 'keep-me' -Force
    [IO.File]::WriteAllText(
        $installedConfigPath,
        ($installedConfig | ConvertTo-Json -Depth 50),
        $Utf8NoBom
    )

    & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ApplyDisplayScript | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "推荐配置脚本集成测试 退出码为 $LASTEXITCODE"
    }
    $updatedConfig = [IO.File]::ReadAllText($installedConfigPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ([int]$updatedConfig.schemaVersion -ne 11) { throw '推荐配置脚本未设置 schemaVersion 11。' }
    if ([bool]$updatedConfig.display.multiline -ne $false) { throw '推荐配置脚本未关闭 multiline 输出。' }
    if ([bool]$updatedConfig.display.showCoverageNotice -ne $false) { throw '推荐配置脚本未隐藏客户端统计范围说明。' }
    if ([bool]$updatedConfig.display.showSuccessStatus -ne $false) { throw '推荐配置脚本未隐藏成功状态。' }
    if ([bool]$updatedConfig.display.hideEmptyCategories -ne $true) { throw '推荐配置脚本未隐藏空分类。' }
    if (-not [string]::Equals([string]$updatedConfig.display.highlightStyle, 'icon', [StringComparison]::Ordinal)) { throw '推荐配置脚本未启用图标突出显示。' }
    if (-not [string]::Equals([string]$updatedConfig.display.emptyValue, '无', [StringComparison]::Ordinal)) { throw '推荐配置脚本未统一空值。' }
    if (-not [string]::Equals([string]$updatedConfig.display.icons.file, '📝', [StringComparison]::Ordinal)) { throw '推荐配置脚本未设置文件图标。' }
    if (-not [string]::Equals([string]$updatedConfig.display.labels.file, '文件', [StringComparison]::Ordinal)) { throw '推荐配置脚本未设置文件标签。' }
    if (-not [string]::Equals([string]$updatedConfig.display.icons.git, '🌿', [StringComparison]::Ordinal)) { throw '推荐配置脚本未设置 Git 图标。' }
    if (-not [string]::Equals([string]$updatedConfig.display.labels.git, 'Git', [StringComparison]::Ordinal)) { throw '推荐配置脚本未设置 Git 标签。' }
    if (-not [string]::Equals([string]$updatedConfig.commandLogging.mode, 'safe', [StringComparison]::Ordinal)) { throw '推荐配置脚本未启用安全命令日志。' }
    if ([bool]$updatedConfig.commandLogging.includeGit -ne $true -or [bool]$updatedConfig.commandLogging.includeShell -ne $true) { throw '推荐配置脚本未启用 Git/Shell 安全命令明细。' }
    if ([bool]$updatedConfig.fileTracking.enabled -ne $true) { throw '推荐配置脚本未启用文件统计。' }
    if (-not [string]::Equals([string]$updatedConfig.skillCollection.mode, 'multi-source', [StringComparison]::Ordinal)) { throw '推荐配置脚本未启用多源 Skill 采集。' }
    if ([bool]$updatedConfig.skillCollection.transcript.enabled -ne $true) { throw '推荐配置脚本未启用 transcript Skill 采集。' }
    if ([bool]$updatedConfig.skillCollection.transcript.readMain -ne $true -or [bool]$updatedConfig.skillCollection.transcript.readSubagents -ne $true) { throw '推荐配置脚本未启用主任务/子Agent transcript 读取。' }
    if ([bool]$updatedConfig.skillCollection.transcript.currentTurnLookbackEnabled -ne $true) { throw '推荐配置脚本未启用当前 Turn 回看。' }
    if ([bool]$updatedConfig.skillCollection.commandRead.enabled -ne $true) { throw '推荐配置脚本未启用 SKILL.md 命令读取采集。' }
    if ([bool]$updatedConfig.skillCollection.commandRead.preferParsedCommand -ne $true) { throw '推荐配置脚本未优先使用结构化命令证据。' }
    if ([bool]$updatedConfig.skillCollection.commandRead.rawCommandFallback -ne $true) { throw '推荐配置脚本未启用原始命令内存回退解析。' }
    if ([bool]$updatedConfig.skillCollection.commandRead.requireCompletedExecution -ne $true) { throw '推荐配置脚本未要求已完成的命令执行证据。' }
    if ($null -ne $updatedConfig.toolAliases.PSObject.Properties['apply_patch']) { throw '推荐配置脚本未移除过时的默认 apply_patch 别名。' }
    if (-not [string]::Equals([string]$updatedConfig.testPreserveValue, 'keep-me', [StringComparison]::Ordinal)) { throw '推荐配置脚本未保留无关配置值。' }
    $configBackup = Get-ChildItem -LiteralPath (Join-Path $fakeCodexHome 'task-stats\backups') -Filter 'config.json.backup-*' -File | Select-Object -First 1
    if ($null -eq $configBackup) {
        throw '推荐配置脚本未创建 config.json 备份。'
    }

    $statusOutput = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $StatusScript | Out-String
    Assert-Contains -Text $statusOutput -Expected 'SourceVersion'
    Assert-Contains -Text $statusOutput -Expected 'v2.1'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^CodexHomeSource\s*:\s*EnvironmentVariable\s*$'
    $statusOutputWithoutWrappedLines = [Regex]::Replace($statusOutput, "\r?\n\s+", '')
    Assert-Contains -Text $statusOutputWithoutWrappedLines -Expected $fakeCodexHome
    Assert-Matches -Text $statusOutput -Pattern '(?m)^VersionMatchesSource\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^ProgramMatchesSource\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^ConfigSchemaVersion\s*:\s*11\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^HideEmptyCategories\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^FileTrackingEnabled\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^GitDisplayIcon\s*:\s*🌿\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^GitDisplayLabel\s*:\s*Git\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^CommandLoggingMode\s*:\s*safe\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^CommandLoggingIncludeGit\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^CommandLoggingIncludeShell\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillCollectionMode\s*:\s*multi-source\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillTranscriptEnabled\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillTranscriptReadMain\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillTranscriptReadSubagents\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillTranscriptLookbackEnabled\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillCommandReadEnabled\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillPreferParsedCommand\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillRawCommandFallback\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SkillRequireCompletedExecution\s*:\s*True\s*$'
    Assert-Contains -Text $statusOutput -Expected 'RegisteredHandlerCount'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^OverallHealthy\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RequiredRuntimeFilesComplete\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeSyntaxValid\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceUnsafeGenericListConstruction\s*:\s*False\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^UnsafeGenericListConstruction\s*:\s*False\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityPassed\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityCode\s*:\s*OK\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityEngine\s*:\s*Windows PowerShell 5\.1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityPowerShellVersion\s*:\s*5\.1(?:\.[0-9]+){0,2}\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityProbeVersion\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityReadEventCount\s*:\s*2\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityMergedRunCount\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityMergedEventCount\s*:\s*2\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^SourceRuntimeCompatibilityFallbackStartCount\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityPassed\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityCode\s*:\s*OK\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityEngine\s*:\s*Windows PowerShell 5\.1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityPowerShellVersion\s*:\s*5\.1(?:\.[0-9]+){0,2}\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityProbeVersion\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityReadEventCount\s*:\s*2\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityMergedRunCount\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityMergedEventCount\s*:\s*2\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^RuntimeCompatibilityFallbackStartCount\s*:\s*1\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^LibraryInstalled\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^LibraryMatchesSource\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^HookRegistrationComplete\s*:\s*True\s*$'
    Assert-Matches -Text $statusOutput -Pattern '(?m)^ConfigSchemaMatchesExpected\s*:\s*True\s*$'

    # Byte-level hashes change when a text file is rewritten with another valid
    # BOM/newline convention. status.ps1 must report the byte difference while
    # retaining normalized-content health, avoiding the v1.7 false warning.
    $installedProgramText = [IO.File]::ReadAllText($installedProgramPath, [Text.Encoding]::UTF8)
    $installedLibraryText = [IO.File]::ReadAllText($installedLibraryPath, [Text.Encoding]::UTF8)
    $installedProgramLf = $installedProgramText.Replace("`r`n", "`n").Replace("`r", "`n")
    $installedLibraryLf = $installedLibraryText.Replace("`r`n", "`n").Replace("`r", "`n")
    $Utf8WithBom = [Text.UTF8Encoding]::new($true)
    try {
        [IO.File]::WriteAllText($installedProgramPath, $installedProgramLf, $Utf8WithBom)
        [IO.File]::WriteAllText($installedLibraryPath, $installedLibraryLf, $Utf8WithBom)

        $normalizedStatus = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $StatusScript | Out-String
        Assert-Matches -Text $normalizedStatus -Pattern '(?m)^ProgramByteMatchesSource\s*:\s*False\s*$'
        Assert-Matches -Text $normalizedStatus -Pattern '(?m)^LibraryByteMatchesSource\s*:\s*False\s*$'
        Assert-Matches -Text $normalizedStatus -Pattern '(?m)^ProgramMatchesSource\s*:\s*True\s*$'
        Assert-Matches -Text $normalizedStatus -Pattern '(?m)^LibraryMatchesSource\s*:\s*True\s*$'
        Assert-Matches -Text $normalizedStatus -Pattern '(?m)^OverallHealthy\s*:\s*True\s*$'
    }
    finally {
        Copy-Item -LiteralPath $MainScript -Destination $installedProgramPath -Force
        Copy-Item -LiteralPath $SourceSubagentCorrelationLibrary -Destination $installedLibraryPath -Force
    }

    if (-not [string]::Equals(
        (Get-FileHash -LiteralPath $installedProgramPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $MainScript -Algorithm SHA256).Hash,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '规范化哈希测试后未恢复已安装主处理器。'
    }
    if (-not [string]::Equals(
        (Get-FileHash -LiteralPath $installedLibraryPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $SourceSubagentCorrelationLibrary -Algorithm SHA256).Hash,
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw '规范化哈希测试后未恢复已安装关联库。'
    }

    # status.ps1 must detect the exact v1.7 failure mode without throwing.
    $temporarilyMissingLibrary = $installedLibraryPath + '.status-missing-test'
    Move-Item -LiteralPath $installedLibraryPath -Destination $temporarilyMissingLibrary -Force
    try {
        $missingLibraryStatus = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $StatusScript | Out-String
        Assert-Matches -Text $missingLibraryStatus -Pattern '(?m)^OverallHealthy\s*:\s*False\s*$'
        Assert-Matches -Text $missingLibraryStatus -Pattern '(?m)^RequiredRuntimeFilesComplete\s*:\s*False\s*$'
        Assert-Matches -Text $missingLibraryStatus -Pattern '(?m)^RuntimeCompatibilityPassed\s*:\s*False\s*$'
        Assert-Matches -Text $missingLibraryStatus -Pattern '(?m)^RuntimeCompatibilityEngine\s*:\s*Windows PowerShell 5\.1\s*$'
        Assert-Matches -Text $missingLibraryStatus -Pattern '(?m)^LibraryInstalled\s*:\s*False\s*$'
    }
    finally {
        Move-Item -LiteralPath $temporarilyMissingLibrary -Destination $installedLibraryPath -Force
    }

    # Temporarily recreate the v1.8 runtime defect in the installed copy. Keep
    # the full library intact so status.ps1 exercises the real compatibility probe.
    $compatibilityBackup = $installedLibraryPath + '.compatibility-status-test'
    Copy-Item -LiteralPath $installedLibraryPath -Destination $compatibilityBackup -Force
    try {
        $unsafeInstalledText = [IO.File]::ReadAllText($installedLibraryPath, [Text.Encoding]::UTF8)
        $safeInstalledConstructor = '$result = [System.Collections.Generic.List[object]]::new()'
        $unsafeInstalledConstructor = '$result = New-Object ''System.Collections.Generic.List[object]'''
        $safeInstalledReturn = 'return $result.ToArray()'
        $unsafeInstalledReturn = 'return @($result)'
        if ($unsafeInstalledText.IndexOf($safeInstalledConstructor, [StringComparison]::Ordinal) -lt 0 -or
            $unsafeInstalledText.IndexOf($safeInstalledReturn, [StringComparison]::Ordinal) -lt 0) {
            throw '无法构造 v1.8 Generic.List 状态回归样本。'
        }
        $unsafeInstalledText = $unsafeInstalledText.Replace($safeInstalledConstructor, $unsafeInstalledConstructor)
        $unsafeInstalledText = $unsafeInstalledText.Replace($safeInstalledReturn, $unsafeInstalledReturn)
        $unsafeInstalledText = $unsafeInstalledText.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
        [IO.File]::WriteAllText(
            $installedLibraryPath,
            $unsafeInstalledText,
            [Text.UTF8Encoding]::new($true)
        )

        $incompatibleStatus = & powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $StatusScript | Out-String
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^OverallHealthy\s*:\s*False\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^SourceUnsafeGenericListConstruction\s*:\s*False\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^UnsafeGenericListConstruction\s*:\s*True\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^SourceRuntimeCompatibilityPassed\s*:\s*True\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^RuntimeCompatibilityPassed\s*:\s*False\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^RuntimeCompatibilityCode\s*:\s*SUBAGENT_RUNTIME_COMPATIBILITY_FAILED\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^RuntimeCompatibilityExceptionType\s*:\s*System\.ArgumentException\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^RuntimeCompatibilityEngine\s*:\s*Windows PowerShell 5\.1\s*$'
        Assert-Matches -Text $incompatibleStatus -Pattern '(?m)^RuntimeCompatibilityPowerShellVersion\s*:\s*5\.1(?:\.[0-9]+){0,2}\s*$'
    }
    finally {
        Copy-Item -LiteralPath $compatibilityBackup -Destination $installedLibraryPath -Force
        Remove-Item -LiteralPath $compatibilityBackup -Force -ErrorAction SilentlyContinue
    }

    # Force a failure that occurs only in the installed-runtime smoke test. The
    # staging smoke must pass first, so this validates rollback after runtime,
    # config, and VERSION have already been committed but before hooks.json changes.
    $rollbackPackageRoot = Join-Path $TestRoot 'rollback-package'
    $rollbackPackageScripts = Join-Path $rollbackPackageRoot 'scripts'
    $rollbackPackageScriptLib = Join-Path $rollbackPackageScripts 'lib'
    $rollbackPackageSrc = Join-Path $rollbackPackageRoot 'src'
    $rollbackPackageSrcLib = Join-Path $rollbackPackageSrc 'lib'
    $rollbackPackageConfig = Join-Path $rollbackPackageRoot 'config'
    foreach ($directory in @(
        $rollbackPackageScripts,
        $rollbackPackageScriptLib,
        $rollbackPackageSrc,
        $rollbackPackageSrcLib,
        $rollbackPackageConfig
    )) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    Copy-Item -LiteralPath $InstallScript -Destination (Join-Path $rollbackPackageScripts 'install.ps1') -Force
    Copy-Item -LiteralPath $CodexPathLibrary -Destination (Join-Path $rollbackPackageScriptLib 'CodexPath.ps1') -Force
    Copy-Item -LiteralPath $SourceSubagentCorrelationLibrary -Destination (Join-Path $rollbackPackageSrcLib 'SubagentCorrelation.ps1') -Force
    Copy-Item -LiteralPath $ConfigSource -Destination (Join-Path $rollbackPackageConfig 'config.example.json') -Force
    Copy-Item -LiteralPath $VersionSource -Destination (Join-Path $rollbackPackageRoot 'VERSION') -Force

    $rollbackPackageProgram = Join-Path $rollbackPackageSrc 'codex-task-stats.ps1'
    $rollbackProgramText = [IO.File]::ReadAllText($MainScript, [Text.Encoding]::UTF8)
    $rollbackAnchor = 'Set-StrictMode -Version 2.0'
    if ($rollbackProgramText.IndexOf($rollbackAnchor, [StringComparison]::Ordinal) -lt 0) {
        throw '无法构造安装回滚测试主处理器。'
    }
    $forcedFailureCode = @'

# Test-only seam: staging lives below .install-staging-*; only the final runtime
# has task-stats\bin as its direct suffix.
if ($PSScriptRoot -match '(?i)[\\/]task-stats[\\/]bin$') {
    throw 'FORCED_INSTALLED_RUNTIME_SMOKE_FAILURE'
}
'@
    $rollbackProgramText = $rollbackProgramText.Replace(
        $rollbackAnchor,
        $rollbackAnchor + $forcedFailureCode
    )
    $rollbackProgramText = $rollbackProgramText.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
    [IO.File]::WriteAllText($rollbackPackageProgram, $rollbackProgramText, [Text.UTF8Encoding]::new($true))

    $rollbackCodexHome = Join-Path $TestRoot 'rollback-codex-home'
    $rollbackInstallRoot = Join-Path $rollbackCodexHome 'task-stats'
    $rollbackBin = Join-Path $rollbackInstallRoot 'bin'
    $rollbackConfigRoot = Join-Path $rollbackInstallRoot 'config'
    $null = New-Item -ItemType Directory -Path $rollbackBin, $rollbackConfigRoot -Force
    $rollbackInstalledProgram = Join-Path $rollbackBin 'codex-task-stats.ps1'
    $rollbackInstalledLibrary = Join-Path $rollbackBin 'lib\SubagentCorrelation.ps1'
    $rollbackInstalledVersion = Join-Path $rollbackInstallRoot 'VERSION'
    $rollbackInstalledConfig = Join-Path $rollbackConfigRoot 'config.json'
    $rollbackHooksPath = Join-Path $rollbackCodexHome 'hooks.json'

    $legacyRuntimeText = "param([string]`$Event)`r`nWrite-Output 'legacy-runtime'`r`n"
    [IO.File]::WriteAllText($rollbackInstalledProgram, $legacyRuntimeText, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($rollbackInstalledVersion, "v1.7`r`n", $Utf8NoBom)
    $rollbackLegacyConfig = [ordered]@{
        schemaVersion = 6
        collection = [ordered]@{ intermediateMode = 'quiet' }
        rollbackSentinel = 'preserve-config'
    } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($rollbackInstalledConfig, $rollbackLegacyConfig, $Utf8NoBom)
    $rollbackLegacyHooks = [ordered]@{
        description = 'rollback sentinel hooks'
        hooks = [ordered]@{
            Stop = @(
                [ordered]@{
                    hooks = @(
                        [ordered]@{
                            type = 'command'
                            command = 'powershell.exe -NoProfile -Command "exit 0"'
                            timeout = 5
                        }
                    )
                }
            )
        }
    } | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($rollbackHooksPath, $rollbackLegacyHooks, $Utf8NoBom)

    $rollbackBefore = [ordered]@{
        program = (Get-FileHash -LiteralPath $rollbackInstalledProgram -Algorithm SHA256).Hash
        version = (Get-FileHash -LiteralPath $rollbackInstalledVersion -Algorithm SHA256).Hash
        config = (Get-FileHash -LiteralPath $rollbackInstalledConfig -Algorithm SHA256).Hash
        hooks = (Get-FileHash -LiteralPath $rollbackHooksPath -Algorithm SHA256).Hash
    }
    $rollbackInstaller = Join-Path $rollbackPackageScripts 'install.ps1'
    $rollbackResult = Invoke-InstallerExpectingFailure `
        -Installer $rollbackInstaller `
        -CodexHome $rollbackCodexHome
    $rollbackOutput = [string]$rollbackResult.Output
    $rollbackExitCode = [int]$rollbackResult.ExitCode
    if ($rollbackExitCode -eq 0) {
        throw "安装回滚测试应失败，但返回成功。输出：`n$rollbackOutput"
    }
    Assert-Contains -Text $rollbackOutput -Expected '已安装运行时 Stop 烟雾测试未生成正常摘要'

    foreach ($entry in $rollbackBefore.GetEnumerator()) {
        $path = switch ($entry.Key) {
            'program' { $rollbackInstalledProgram }
            'version' { $rollbackInstalledVersion }
            'config' { $rollbackInstalledConfig }
            'hooks' { $rollbackHooksPath }
        }
        $afterHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if (-not [string]::Equals([string]$entry.Value, $afterHash, [StringComparison]::OrdinalIgnoreCase)) {
            throw "安装失败后未恢复 $($entry.Key)。"
        }
    }
    if (Test-Path -LiteralPath $rollbackInstalledLibrary -PathType Leaf) {
        throw '安装失败回滚后仍残留原先不存在的运行时库。'
    }

    & $UninstallScript -Confirm:$false | Out-Null
    $afterUninstall = [IO.File]::ReadAllText((Join-Path $fakeCodexHome 'hooks.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ((Get-TaskStatsHandlerCount -HooksRoot $afterUninstall) -ne 0) {
        throw '卸载程序仍残留 codex-task-stats 处理器。'
    }
    Assert-Contains -Text ($afterUninstall | ConvertTo-Json -Depth 50) -Expected 'powershell.exe -NoProfile -Command'

$DisplayNameTest = Join-Path (Split-Path -Parent $PSScriptRoot) 'tests\subagent-display-name.tests.ps1'
& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $DisplayNameTest
if ($LASTEXITCODE -ne 0) {
    throw "子Agent显示名称回归测试失败，退出码：$LASTEXITCODE"
}


    Write-Host '所有测试均已通过。' -ForegroundColor Green
    Write-Host ''
    Write-Host '开始输出：'
    Write-Host $start.systemMessage
    Write-Host ''
    Write-Host '结束输出：'
    Write-Host $message
    Write-Host ''
    Write-Host '空分类输出：'
    Write-Host $emptyMessage
    Write-Host ''
    Write-Host '失败状态输出：'
    Write-Host $failedMessage
    Write-Host ''
    Write-Host '中断状态输出：'
    Write-Host $interruptedMessage
    Write-Host ''
    Write-Host '未知状态输出：'
    Write-Host $unknownMessage
    Write-Host ''
    Write-Host "测试日志：$($log.FullName)"
}
finally {
    $env:CODEX_TASK_STATS_HOME = $oldHome
    $env:CODEX_HOME = $oldCodexHome
    if ($KeepTemp) {
        Write-Host "已保留临时测试目录：$TestRoot"
    }
    elseif (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
