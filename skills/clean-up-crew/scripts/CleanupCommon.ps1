# Shared helpers for the clean-up-crew skill. Dot-source this file from the scripts.

$script:SkillRoot = Split-Path -Parent $PSScriptRoot
$script:TargetsFile = Join-Path $script:SkillRoot 'references\targets.json'
$script:CleanupHistoryDir = Join-Path $env:LOCALAPPDATA 'opencode-disk-cleanup'
$script:CleanupHistoryFile = Join-Path $script:CleanupHistoryDir 'history.jsonl'

function Get-CleanupTargets {
    if (-not (Test-Path -LiteralPath $script:TargetsFile)) {
        throw "Targets file not found: $script:TargetsFile"
    }
    $json = Get-Content -LiteralPath $script:TargetsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($json.targets)
}

function Expand-TargetPath {
    param([Parameter(Mandatory)][string]$Path)
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded)
}

function Test-SafePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Safe = $false; Reason = 'empty path' }
    }
    if ($Path -match '\.\.') {
        return [pscustomobject]@{ Safe = $false; Reason = 'path contains ..' }
    }

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '^[A-Za-z]:$') {
        return [pscustomobject]@{ Safe = $false; Reason = 'drive root' }
    }

    $denyExact = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        (Join-Path $env:SystemRoot 'SysWOW64'),
        (Join-Path $env:SystemRoot 'WinSxS'),
        (Join-Path $env:SystemRoot 'servicing'),
        (Join-Path $env:SystemRoot 'Installer'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads'),
        (Join-Path $env:USERPROFILE 'Pictures'),
        (Join-Path $env:USERPROFILE 'Videos'),
        (Join-Path $env:USERPROFILE 'Music'),
        (Join-Path $env:USERPROFILE 'OneDrive'),
        $env:LOCALAPPDATA,
        $env:APPDATA,
        (Join-Path $env:USERPROFILE '.ssh'),
        (Join-Path $env:USERPROFILE '.config')
    ) | Where-Object { $_ }

    foreach ($d in $denyExact) {
        $canonical = [IO.Path]::GetFullPath($d).TrimEnd('\')
        if ($full -ieq $canonical) {
            return [pscustomobject]@{ Safe = $false; Reason = "protected path: $d" }
        }
    }

    $segments = @($full -split '\\' | Where-Object { $_ })
    if ($segments.Count -lt 3) {
        return [pscustomobject]@{ Safe = $false; Reason = 'path is too shallow' }
    }

    $item = Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
    if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        return [pscustomobject]@{ Safe = $false; Reason = 'path is a reparse point' }
    }

    return [pscustomobject]@{ Safe = $true; Reason = '' }
}

function Expand-CleanupTarget {
    param([Parameter(Mandatory)]$Target)

    $result = New-Object System.Collections.ArrayList

    switch ([string]$Target.type) {
        'contents' {
            foreach ($p in @($Target.paths)) {
                if (-not $p) { continue }
                [void]$result.Add([pscustomobject]@{ Path = (Expand-TargetPath $p); Kind = 'contents' })
            }
        }
        'profile-caches' {
            $root = Expand-TargetPath $Target.profileRoot
            if (Test-Path -LiteralPath $root) {
                $profiles = Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match [string]$Target.profilePattern }
                foreach ($prof in $profiles) {
                    foreach ($cache in @($Target.cacheDirs)) {
                        if (-not $cache) { continue }
                        [void]$result.Add([pscustomobject]@{ Path = (Join-Path $prof.FullName $cache); Kind = 'contents' })
                    }
                }
            }
            foreach ($p in @($Target.extraPaths)) {
                if (-not $p) { continue }
                [void]$result.Add([pscustomobject]@{ Path = (Expand-TargetPath $p); Kind = 'contents' })
            }
        }
        'recyclebin' {
            [void]$result.Add([pscustomobject]@{ Path = ''; Kind = 'recyclebin' })
        }
        'dism' {
            [void]$result.Add([pscustomobject]@{ Path = ''; Kind = 'dism' })
        }
        default {
            [void]$result.Add([pscustomobject]@{ Path = ''; Kind = 'unknown' })
        }
    }

    return @($result)
}

function Get-PathSize {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return [int64]0 }
    if (-not (Test-Path -LiteralPath $Path)) { return [int64]0 }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }

    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Get-FreeSpaceGB {
    param([string]$Drive = $env:SystemDrive)
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Drive'" -ErrorAction SilentlyContinue
    if (-not $disk) { throw "Drive not found: $Drive" }
    return [math]::Round($disk.FreeSpace / 1GB, 2)
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-ProcessesRunning {
    param([string[]]$Names)
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-RecycleBinSize {
    $path = Join-Path $env:SystemDrive '$Recycle.Bin'
    return Get-PathSize $path
}

function Get-CleanupHistory {
    param([string]$Path = $script:CleanupHistoryFile)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $entries = @()
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entries += ($line | ConvertFrom-Json)
        } catch {
            # Ignore corrupt lines rather than failing the report.
        }
    }
    return $entries
}

function Write-CleanupHistory {
    param([hashtable]$Entry)

    if (-not (Test-Path -LiteralPath $script:CleanupHistoryDir)) {
        New-Item -ItemType Directory -Path $script:CleanupHistoryDir -Force | Out-Null
    }
    if (-not $Entry.ContainsKey('timestamp')) {
        $Entry['timestamp'] = (Get-Date).ToString('o')
    }
    $json = $Entry | ConvertTo-Json -Compress -Depth 6
    Add-Content -LiteralPath $script:CleanupHistoryFile -Value $json -Encoding UTF8
}

function Remove-CleanupContents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Exclude = @()
    )

    $removed = 0
    $failed = 0
    $errors = New-Object System.Collections.ArrayList

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Removed = 0; Failed = 0; Errors = @() }
    }

    $excludeFull = @()
    foreach ($e in @($Exclude)) {
        if (-not $e) { continue }
        $excludeFull += [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($e)).TrimEnd('\')
    }

    $children = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        $childFull = $child.FullName.TrimEnd('\')
        $skip = $false
        foreach ($e in $excludeFull) {
            if ($childFull -ieq $e) { $skip = $true; break }
        }
        if ($skip) { continue }

        try {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        } catch {
            $failed++
            [void]$errors.Add(("{0}: {1}" -f $child.FullName, $_.Exception.Message))
        }
    }

    return [pscustomobject]@{ Removed = $removed; Failed = $failed; Errors = @($errors) }
}
