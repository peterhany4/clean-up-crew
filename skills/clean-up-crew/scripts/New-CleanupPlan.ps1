[CmdletBinding()]
param(
    [string[]]$Items,
    [switch]$AllTier1,
    [string]$OutFile,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'CleanupCommon.ps1')
$ErrorActionPreference = 'Continue'

$targets = Get-CleanupTargets
$selected = @()

if ($AllTier1) {
    $selected = @($targets | Where-Object { [int]$_.tier -eq 1 })
} elseif ($Items -and $Items.Count -gt 0) {
    foreach ($id in $Items) {
        $target = $targets | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $target) {
            Write-Error "Unknown cleanup target: $id"
            Write-Host ('Available targets: ' + (($targets | ForEach-Object { $_.id }) -join ', '))
            exit 2
        }
        if ($selected.id -notcontains $id) {
            $selected += $target
        }
    }
} else {
    Write-Host 'No items selected. Pass -Items <id,...> or -AllTier1.'
    Write-Host ''
    $targets | Select-Object id, name, tier | Format-Table -AutoSize | Out-String | Write-Host
    exit 2
}

if ($selected.Count -eq 0) {
    Write-Error 'No cleanup targets selected.'
    exit 2
}

$planItems = New-Object System.Collections.ArrayList

foreach ($t in $selected) {
    $bytes = [int64]0
    $paths = New-Object System.Collections.ArrayList

    if ($t.type -eq 'contents' -or $t.type -eq 'profile-caches') {
        foreach ($entry in (Expand-CleanupTarget $t)) {
            if ($entry.Kind -ne 'contents') { continue }
            $size = Get-PathSize $entry.Path
            if ($size -gt 0) {
                $bytes += $size
                [void]$paths.Add($entry.Path)
            }
        }
    } elseif ($t.type -eq 'recyclebin') {
        $bytes = Get-RecycleBinSize
        [void]$paths.Add('Recycle Bin')
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

    [void]$planItems.Add([pscustomobject]@{
        id          = $t.id
        name        = $t.name
        tier        = [int]$t.tier
        type        = $t.type
        bytes       = $bytes
        paths       = @($paths)
        blocked     = $blocked
        reason      = $reason
        regenerates = $t.regenerates
        risk        = $t.risk
    })
}

$totalBytes = [int64]0
$blockedBytes = [int64]0
foreach ($item in $planItems) {
    $totalBytes += $item.bytes
    if ($item.blocked) { $blockedBytes += $item.bytes }
}

$plan = [pscustomobject]@{
    planId       = [guid]::NewGuid().ToString()
    createdAt    = (Get-Date).ToString('o')
    drive        = $env:SystemDrive
    items        = @($planItems)
    totalBytes   = $totalBytes
    blockedBytes = $blockedBytes
    totalGB      = [math]::Round($totalBytes / 1GB, 2)
}

if ($OutFile) {
    $plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
}

if ($Json -or -not $OutFile) {
    $plan | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host ("Plan {0} - {1} item(s), {2}" -f $plan.planId, @($planItems).Count, (Format-Bytes $totalBytes))
Write-Host ''
@($planItems) | ForEach-Object {
    [pscustomobject]@{
        ID     = $_.id
        Tier   = $_.tier
        Size   = (Format-Bytes $_.bytes)
        Status = if ($_.blocked) { "blocked: $($_.reason)" } elseif ($_.bytes -eq 0) { 'nothing to delete' } else { 'ready' }
    }
} | Format-Table -AutoSize | Out-String | Write-Host

if ($blockedBytes -gt 0) {
    Write-Host ("Blocked: {0}. Close the listed processes or run as administrator, then regenerate the plan." -f (Format-Bytes $blockedBytes))
}
Write-Host ("Saved to: {0}" -f $OutFile)
Write-Host 'No files have been deleted. Review the plan before applying it.'
