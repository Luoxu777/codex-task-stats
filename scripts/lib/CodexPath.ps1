Set-StrictMode -Version 2.0

function Get-CodexWindowsUserProfile {
    [CmdletBinding()]
    param()

    $profilePath = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        $profilePath = [string]$env:USERPROFILE
    }
    if ([string]::IsNullOrWhiteSpace($profilePath) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:HOMEDRIVE) -and
        -not [string]::IsNullOrWhiteSpace([string]$env:HOMEPATH)) {
        $profilePath = [string]$env:HOMEDRIVE + [string]$env:HOMEPATH
    }
    if ([string]::IsNullOrWhiteSpace($profilePath)) {
        throw '无法确定当前 Windows 用户目录。'
    }

    return [IO.Path]::GetFullPath($profilePath)
}

function ConvertTo-CodexAbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$SourceLabel = 'Codex Home'
    )

    $candidate = [System.Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ($candidate.Length -ge 2) {
        $first = $candidate[0]
        $last = $candidate[$candidate.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $candidate = $candidate.Substring(1, $candidate.Length - 2).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "$SourceLabel 路径不能为空。"
    }

    $userProfile = Get-CodexWindowsUserProfile
    if ([string]::Equals($candidate, '~', [StringComparison]::Ordinal)) {
        $candidate = $userProfile
    }
    elseif ($candidate.StartsWith('~\', [StringComparison]::Ordinal) -or
        $candidate.StartsWith('~/', [StringComparison]::Ordinal)) {
        $candidate = Join-Path $userProfile $candidate.Substring(2)
    }

    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $basePath = [System.Environment]::CurrentDirectory
        if ([string]::IsNullOrWhiteSpace($basePath)) {
            $basePath = (Get-Location).Path
        }
        $candidate = Join-Path $basePath $candidate
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($candidate)
    }
    catch {
        throw "$SourceLabel 路径无效 '$Path'：$($_.Exception.Message)"
    }

    $root = [IO.Path]::GetPathRoot($fullPath)
    while ($fullPath.Length -gt $root.Length -and
        ($fullPath.EndsWith('\', [StringComparison]::Ordinal) -or
            $fullPath.EndsWith('/', [StringComparison]::Ordinal))) {
        $fullPath = $fullPath.Substring(0, $fullPath.Length - 1)
    }

    $trimCharacters = [char[]]@([char]92, [char]47)
    $normalizedPathForComparison = $fullPath.TrimEnd($trimCharacters)
    $normalizedRootForComparison = ([IO.Path]::GetFullPath($root)).TrimEnd($trimCharacters)
    if ([string]::Equals($normalizedPathForComparison, $normalizedRootForComparison, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$SourceLabel 不能是文件系统根目录：$fullPath"
    }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        throw "$SourceLabel 指向文件而不是目录：$fullPath"
    }

    return $fullPath
}

function Get-CodexHomeInfo {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExplicitPath,

        [bool]$ExplicitlyProvided = $false
    )

    $defaultPath = ConvertTo-CodexAbsolutePath -Path (Join-Path (Get-CodexWindowsUserProfile) '.codex') -SourceLabel 'Windows 用户默认 Codex Home'
    $environmentPath = $null
    $environmentPathError = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CODEX_HOME)) {
        try {
            $environmentPath = ConvertTo-CodexAbsolutePath -Path $env:CODEX_HOME -SourceLabel 'CODEX_HOME'
        }
        catch {
            # An explicit -CodexHome must remain authoritative even when a stale
            # or malformed CODEX_HOME happens to exist in the parent process.
            # Without an explicit override, fail instead of silently falling
            # back to a different directory.
            if (-not $ExplicitlyProvided) {
                throw
            }
            $environmentPathError = $_.Exception.Message
        }
    }

    if ($ExplicitlyProvided) {
        if ([string]::IsNullOrWhiteSpace([string]$ExplicitPath)) {
            throw '已提供 -CodexHome，但其值为空。'
        }
        $selectedPath = ConvertTo-CodexAbsolutePath -Path $ExplicitPath -SourceLabel '-CodexHome'
        $source = 'Parameter'
        $sourceDisplay = '-CodexHome 参数'
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$environmentPath)) {
        $selectedPath = $environmentPath
        $source = 'EnvironmentVariable'
        $sourceDisplay = 'CODEX_HOME 环境变量'
    }
    else {
        $selectedPath = $defaultPath
        $source = 'UserProfileDefault'
        $sourceDisplay = 'Windows 用户默认目录'
    }

    return [PSCustomObject][ordered]@{
        Path = $selectedPath
        Source = $source
        SourceDisplay = $sourceDisplay
        EnvironmentPath = $environmentPath
        EnvironmentPathError = $environmentPathError
        DefaultPath = $defaultPath
    }
}

function Resolve-CodexHome {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExplicitPath,

        [bool]$ExplicitlyProvided = $false
    )

    return Get-CodexHomeInfo -ExplicitPath $ExplicitPath -ExplicitlyProvided $ExplicitlyProvided
}

function Get-ExistingAlternativeCodexHomes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedInfo
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    $selected = [string]$ResolvedInfo.Path

    foreach ($candidateInfo in @(
        [PSCustomObject]@{ Path = $ResolvedInfo.EnvironmentPath; Source = 'CODEX_HOME 环境变量' },
        [PSCustomObject]@{ Path = $ResolvedInfo.DefaultPath; Source = 'Windows 用户默认目录' }
    )) {
        $candidate = [string]$candidateInfo.Path
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([string]::Equals($candidate, $selected, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $markers = [System.Collections.Generic.List[string]]::new()
        foreach ($marker in @('hooks.json', 'config.toml', 'task-stats')) {
            try {
                if (Test-Path -LiteralPath ([IO.Path]::Combine($candidate, $marker))) {
                    $markers.Add($marker)
                }
            }
            catch { }
        }
        if ($markers.Count -gt 0) {
            $results.Add([PSCustomObject][ordered]@{
                Path = $candidate
                Source = [string]$candidateInfo.Source
                Markers = ($markers -join ', ')
            })
        }
    }

    return @($results)
}

function Write-CodexHomeWarnings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedInfo
    )

    $environmentPathError = [string]$ResolvedInfo.EnvironmentPathError
    if (-not [string]::IsNullOrWhiteSpace($environmentPathError)) {
        Write-Warning ("CODEX_HOME 无效，但本次已由 -CodexHome 参数覆盖：{0}" -f $environmentPathError)
    }

    foreach ($alternative in @(Get-ExistingAlternativeCodexHomes -ResolvedInfo $ResolvedInfo)) {
        Write-Warning ("另一个候选 Codex Home 也存在，但本次不会修改：{0}（来源：{1}；发现：{2}）。如果该目录才是目标，请显式使用 -CodexHome。" -f $alternative.Path, $alternative.Source, $alternative.Markers)
    }
}

function Write-CodexHomeSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ResolvedInfo,
        [string]$HooksPath,
        [string]$InstallRoot,
        [string]$LogsPath
    )

    Write-Host ('Codex Home       : ' + [string]$ResolvedInfo.Path)
    Write-Host ('路径来源         : ' + [string]$ResolvedInfo.SourceDisplay)
    if (-not [string]::IsNullOrWhiteSpace($HooksPath)) {
        Write-Host ('Hooks 文件       : ' + $HooksPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
        Write-Host ('程序安装目录     : ' + $InstallRoot)
    }
    if (-not [string]::IsNullOrWhiteSpace($LogsPath)) {
        Write-Host ('日志目录         : ' + $LogsPath)
    }

    Write-CodexHomeWarnings -ResolvedInfo $ResolvedInfo
}
