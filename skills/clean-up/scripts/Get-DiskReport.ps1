[CmdletBinding()]
param(
    [int]$TopDirs = 8,
    [switch]$SkipTopDirs,
    [switch]$Json,
    [switch]$SaveHistory,
    [switch]$IncludeDism
)

. (Join-Path $PSScriptRoot 'CleanupCommon.ps1')
$ErrorActionPreference = 'Continue'

$drive = $env:SystemDrive
if (-not $drive.EndsWith(':')) { $drive = $drive + ':' }

$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
$totalBytes = [double]$disk.Size
$freeBytes = [double]$disk.FreeSpace
$usedBytes = $totalBytes - $freeBytes
$freePct = if ($totalBytes -gt 0) { [math]::Round($freeBytes / $totalBytes * 100, 1) } else { 0 }

$systemFiles = @()

$pageFile = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1
if ($pageFile) {
    $systemFiles += [pscustomobject]@{
        Name   = 'pagefile.sys'
        Bytes  = [int64]$pageFile.AllocatedBaseSize * 1MB
        Status = 'system-managed'
    }
}

foreach ($name in @('hiberfil.sys', 'swapfile.sys')) {
    $path = Join-Path ($drive + '\') $name
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($item) {
        $systemFiles += [pscustomobject]@{ Name = $name; Bytes = [int64]$item.Length; Status = 'present' }
    } elseif ($name -eq 'hiberfil.sys') {
        $status = 'not present or inaccessible without admin'
        $power = (& powercfg.exe /a 2>&1 | Out-String)
        if ($power -match 'Hibernate' -and $power -notmatch 'has not been enabled') {
            $status = 'enabled; exact size needs admin'
        }
        $systemFiles += [pscustomobject]@{ Name = $name; Bytes = $null; Status = $status }
    }
}

$targets = Get-CleanupTargets
$targetRows = New-Object System.Collections.ArrayList

foreach ($t in $targets) {
    $bytes = [int64]0
    $paths = @()

    if ($t.type -eq 'contents' -or $t.type -eq 'profile-caches') {
        foreach ($entry in (Expand-CleanupTarget $t)) {
            if ($entry.Kind -ne 'contents') { continue }
            $size = Get-PathSize $entry.Path
            if ($size -gt 0) {
                $bytes += $size
                $paths += $entry.Path
            }
        }
    } elseif ($t.type -eq 'recyclebin') {
        $bytes = Get-RecycleBinSize
        $paths = @('Recycle Bin')
    }

    $blocked = $false
    $reason = ''
    if ($t.processes -and (Test-ProcessesRunning @($t.processes))) {
        $blocked = $true
        $reason = 'process running: ' + (@($t.processes) -join ', ')
    } elseif ($t.requiresAdmin -and -not (Test-IsAdmin)) {
        $blocked = $true
        $reason = 'requires administrator'
    }

    [void]$targetRows.Add([pscustomobject]@{
        id         = $t.id
        name       = $t.name
        tier       = [int]$t.tier
        bytes      = $bytes
        paths      = @($paths)
        blocked    = $blocked
        reason     = $reason
        regenerates = $t.regenerates
        risk       = $t.risk
    })
}

$topLocal = @()
if (-not $SkipTopDirs) {
    $topLocal = Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Bytes = (Get-PathSize $_.FullName) }
        } |
        Sort-Object Bytes -Descending |
        Select-Object -First $TopDirs
}

$npmRoot = Join-Path $env:APPDATA 'npm\node_modules'
$topNpm = @()
if (Test-Path -LiteralPath $npmRoot) {
    $topNpm = Get-ChildItem -LiteralPath $npmRoot -Directory -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Bytes = (Get-PathSize $_.FullName) }
        } |
        Sort-Object Bytes -Descending |
        Select-Object -First 6
}

$dism = $null
if ($IncludeDism) {
    if (Test-IsAdmin) {
        $raw = (& Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 2>&1 | Out-String)
        $dism = [pscustomobject]@{
            ActualGB = if ($raw -match 'Actual Size of Component Store\s*:\s*([\d.]+)\s*GB') { [double]$matches[1] } else { $null }
            BackupsGB = if ($raw -match 'Backups and Disabled Features\s*:\s*([\d.]+)\s*GB') { [double]$matches[1] } else { $null }
            ReclaimablePackages = if ($raw -match 'Number of Reclaimable Packages\s*:\s*(\d+)') { [int]$matches[1] } else { $null }
            CleanupRecommended = if ($raw -match 'Component Store Cleanup Recommended\s*:\s*(\w+)') { $matches[1] } else { $null }
        }
    } else {
        $dism = [pscustomobject]@{ Error = 'requires administrator' }
    }
}

$history = @(Get-CleanupHistory | Where-Object { $null -ne $_.freeGB })
$trend = $null
if ($history.Count -ge 2) {
    $sorted = @($history | Sort-Object { [datetime]$_.timestamp })
    $first = $sorted[0]
    $last = $sorted[-1]
    $days = ([datetime]$last.timestamp - [datetime]$first.timestamp).TotalDays
    if ($days -gt 0) {
        $burnPerWeek = [math]::Round((([double]$first.freeGB - [double]$last.freeGB) / $days) * 7, 2)
        $weeksToLow = $null
        if ($burnPerWeek -gt 0) {
            $weeksToLow = [math]::Round(([double]$last.freeGB - 2) / $burnPerWeek, 1)
        }
        $trend = [pscustomobject]@{
            Entries     = $sorted.Count
            FirstDate   = $first.timestamp
            LastDate    = $last.timestamp
            FirstFreeGB = $first.freeGB
            LastFreeGB  = $last.freeGB
            BurnGBPerWeek = $burnPerWeek
            WeeksTo2GB  = $weeksToLow
        }
    }
}

$recommendations = New-Object System.Collections.ArrayList
if ($freePct -lt 15) {
    [void]$recommendations.Add('Free space is below 15%. Clean tier 1 caches before installing anything large.')
}
$tier1Bytes = [int64]0
foreach ($row in $targetRows) {
    if ($row.tier -eq 1 -and -not $row.blocked) { $tier1Bytes += $row.bytes }
}
if ($tier1Bytes -gt 0) {
    [void]$recommendations.Add("Tier 1 caches hold $(Format-Bytes $tier1Bytes). Review them with /clean-up.")
}
$hiber = $systemFiles | Where-Object { $_.Name -eq 'hiberfil.sys' } | Select-Object -First 1
if ($hiber -and $null -ne $hiber.Bytes -and $hiber.Bytes -gt 4GB) {
    [void]$recommendations.Add("Hibernation file uses $(Format-Bytes $hiber.Bytes). Disabling hibernation is reversible but requires explicit consent.")
} elseif ($hiber -and $hiber.Status -like 'enabled*') {
    [void]$recommendations.Add("Hibernation is enabled; the exact hiberfil.sys size needs an elevated shell (typically several GB).")
}
$bigNpm = $topNpm | Where-Object { $_.Bytes -gt 1GB } | Select-Object -First 1
if ($bigNpm) {
    [void]$recommendations.Add("Global npm package '$($bigNpm.Name)' is $(Format-Bytes $bigNpm.Bytes). Review whether it is still used.")
}
if ($trend -and $trend.BurnGBPerWeek -gt 0.3) {
    [void]$recommendations.Add("Disk use is growing about $($trend.BurnGBPerWeek) GB/week; roughly $($trend.WeeksTo2GB) weeks until 2 GB remain at this rate.")
}

$report = [pscustomobject]@{
    timestamp      = (Get-Date).ToString('o')
    drive          = $drive
    totalGB        = [math]::Round($totalBytes / 1GB, 2)
    freeGB         = [math]::Round($freeBytes / 1GB, 2)
    freePct        = $freePct
    usedGB         = [math]::Round($usedBytes / 1GB, 2)
    systemFiles    = @($systemFiles | ForEach-Object {
        [pscustomobject]@{
            Name   = $_.Name
            GB     = if ($null -ne $_.Bytes) { [math]::Round($_.Bytes / 1GB, 2) } else { $null }
            Status = $_.Status
        }
    })
    targets        = @($targetRows)
    topLocalAppData = @($topLocal | ForEach-Object { [pscustomobject]@{ Name = $_.Name; GB = [math]::Round($_.Bytes / 1GB, 2) } })
    topNpmGlobal   = @($topNpm | ForEach-Object { [pscustomobject]@{ Name = $_.Name; GB = [math]::Round($_.Bytes / 1GB, 2) } })
    componentStore = $dism
    trend          = $trend
    recommendations = @($recommendations)
}

if ($SaveHistory) {
    $targetMap = @{}
    foreach ($row in $targetRows) {
        $targetMap[$row.id] = [math]::Round($row.bytes / 1GB, 3)
    }
    Write-CleanupHistory -Entry @{
        kind    = 'report'
        drive   = $drive
        freeGB  = $report.freeGB
        totalGB = $report.totalGB
        targets = $targetMap
    }
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host ("{0}  {1:N2} GB total | {2:N2} GB free ({3:N1}%)" -f $drive, $report.totalGB, $report.freeGB, $report.freePct) -ForegroundColor Cyan
foreach ($sf in $report.systemFiles) {
    if ($null -ne $sf.GB) {
        Write-Host ("  {0,-14} {1,7:N2} GB" -f $sf.Name, $sf.GB)
    } else {
        Write-Host ("  {0,-14} {1}" -f $sf.Name, $sf.Status)
    }
}
Write-Host ''

Write-Host 'Cleanup targets' -ForegroundColor Cyan
$targetView = $targetRows | Sort-Object tier, @{ Expression = { $_.bytes }; Descending = $true } | ForEach-Object {
    [pscustomobject]@{
        ID     = $_.id
        Tier   = $_.tier
        Size   = (Format-Bytes $_.bytes)
        Status = if ($_.blocked) { "blocked: $($_.reason)" } elseif ($_.bytes -eq 0) { 'empty' } else { 'ready' }
    }
}
$targetView | Format-Table -AutoSize | Out-String | Write-Host

if (-not $SkipTopDirs) {
    Write-Host 'Top LocalAppData folders' -ForegroundColor Cyan
    $topLocal | ForEach-Object {
        [pscustomobject]@{ Folder = $_.Name; Size = (Format-Bytes $_.Bytes) }
    } | Format-Table -AutoSize | Out-String | Write-Host
}

if ($topNpm.Count -gt 0) {
    Write-Host 'Top global npm packages' -ForegroundColor Cyan
    $topNpm | ForEach-Object {
        [pscustomobject]@{ Package = $_.Name; Size = (Format-Bytes $_.Bytes) }
    } | Format-Table -AutoSize | Out-String | Write-Host
}

if ($dism) {
    Write-Host 'Component store' -ForegroundColor Cyan
    $dism | Format-List | Out-String | Write-Host
}

if ($trend) {
    Write-Host 'Trend' -ForegroundColor Cyan
    Write-Host ("  {0} -> {1}: {2:N2} GB -> {3:N2} GB ({4:N2} GB/week)" -f `
        ([datetime]$trend.FirstDate).ToString('yyyy-MM-dd'), ([datetime]$trend.LastDate).ToString('yyyy-MM-dd'), `
        $trend.FirstFreeGB, $trend.LastFreeGB, $trend.BurnGBPerWeek)
}

if ($recommendations.Count -gt 0) {
    Write-Host ''
    Write-Host 'Recommendations' -ForegroundColor Cyan
    foreach ($r in $recommendations) { Write-Host ("  - " + $r) }
}
Write-Host ''
