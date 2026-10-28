[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PlanFile,
    [switch]$Apply,
    [switch]$Json
)

. (Join-Path $PSScriptRoot 'CleanupCommon.ps1')
$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $PlanFile)) {
    throw "Plan file not found: $PlanFile"
}

$plan = Get-Content -LiteralPath $PlanFile -Raw -Encoding UTF8 | ConvertFrom-Json

if ($Apply -and $plan.createdAt) {
    $age = (Get-Date) - [datetime]$plan.createdAt
    if ($age.TotalHours -gt 1) {
        throw "Plan is $([math]::Round($age.TotalMinutes)) minutes old. Regenerate it before applying."
    }
}

$targets = Get-CleanupTargets
$freeBefore = Get-FreeSpaceGB

$results = New-Object System.Collections.ArrayList
$allErrors = New-Object System.Collections.ArrayList
$totalFreedBytes = [int64]0
$totalFailed = 0

foreach ($pi in @($plan.items)) {
    $t = $targets | Where-Object { $_.id -eq $pi.id } | Select-Object -First 1

    if (-not $t) {
        [void]$allErrors.Add("Unknown target in plan: $($pi.id)")
        [void]$results.Add([pscustomobject]@{
            id = $pi.id; name = $pi.name; bytesBefore = [int64]0; freedBytes = [int64]0
            failed = 0; status = 'error: unknown target'
        })
        continue
    }

    $expanded = @(Expand-CleanupTarget $t)
    $actionable = New-Object System.Collections.ArrayList
    $bytesBefore = [int64]0

    foreach ($entry in $expanded) {
        if ($entry.Kind -eq 'contents' -or $entry.Kind -eq 'files') {
            if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
            $safe = Test-SafePath $entry.Path
            if (-not $safe.Safe) {
                [void]$allErrors.Add("Blocked unsafe path for $($t.id): $($entry.Path) ($($safe.Reason))")
                continue
            }
            $bytesBefore += Get-PathSize $entry.Path
        }
        [void]$actionable.Add($entry)
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

    if (-not $Apply) {
        [void]$results.Add([pscustomobject]@{
            id = $t.id
            name = $t.name
            bytesBefore = $bytesBefore
            freedBytes = [int64]0
            failed = 0
            status = if ($blocked) { "blocked: $reason" } elseif ($bytesBefore -eq 0) { 'nothing to delete' } else { 'would delete' }
        })
        continue
    }

    if ($blocked) {
        [void]$results.Add([pscustomobject]@{
            id = $t.id; name = $t.name; bytesBefore = $bytesBefore; freedBytes = [int64]0
            failed = 0; status = "blocked: $reason"
        })
        continue
    }

    $failed = 0
    $itemErrors = New-Object System.Collections.ArrayList

    foreach ($entry in $actionable) {
        switch ($entry.Kind) {
            'contents' {
                $r = Remove-CleanupContents -Path $entry.Path -Exclude @($t.exclude)
                $failed += [int]$r.Failed
                foreach ($err in @($r.Errors)) { [void]$itemErrors.Add($err) }
            }
            'files' {
                $r = Remove-CleanupFile -Path $entry.Path
                $failed += [int]$r.Failed
                foreach ($err in @($r.Errors)) { [void]$itemErrors.Add($err) }
            }
            'recyclebin' {
                try {
                    Clear-RecycleBin -DriveLetter $env:SystemDrive.TrimEnd(':') -Force -ErrorAction Stop
                } catch {
                    if ($_.Exception.Message -notmatch 'empty') {
                        $failed++
                        [void]$itemErrors.Add($_.Exception.Message)
                    }
                }
            }
            'dism' {
                $null = & Dism.exe /Online /Cleanup-Image /StartComponentCleanup 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $failed++
                    [void]$itemErrors.Add("DISM exited with code $LASTEXITCODE")
                }
            }
        }
    }

    $bytesAfter = [int64]0
    foreach ($entry in $actionable) {
        if ($entry.Kind -eq 'contents' -or $entry.Kind -eq 'files') { $bytesAfter += Get-PathSize $entry.Path }
    }
    $freed = [math]::Max(0, $bytesBefore - $bytesAfter)

    $totalFreedBytes += $freed
    $totalFailed += $failed
    foreach ($err in $itemErrors) { [void]$allErrors.Add("$($t.id): $err") }

    [void]$results.Add([pscustomobject]@{
        id          = $t.id
        name        = $t.name
        bytesBefore = $bytesBefore
        freedBytes  = $freed
        failed      = $failed
        status      = if ($failed -gt 0) { 'completed with errors' } else { 'completed' }
    })
}

$freeAfter = Get-FreeSpaceGB
$freedGB = [math]::Round($freeAfter - $freeBefore, 2)

if ($Apply) {
    $itemMap = @{}
    foreach ($r in $results) { $itemMap[$r.id] = $r.freedBytes }
    Write-CleanupHistory -Entry @{
        kind         = 'apply'
        planId       = [string]$plan.planId
        freeGB       = $freeAfter
        freeBeforeGB = $freeBefore
        freeAfterGB  = $freeAfter
        freedGB      = $freedGB
        items        = $itemMap
    }
}

$output = [pscustomobject]@{
    planId       = [string]$plan.planId
    applied      = [bool]$Apply
    freeBeforeGB = $freeBefore
    freeAfterGB  = $freeAfter
    freedGB      = $freedGB
    freedBytes   = $totalFreedBytes
    failed       = $totalFailed
    items        = @($results)
    errors       = @($allErrors)
}

if ($Json) {
    $output | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
if (-not $Apply) {
    Write-Host 'DRY RUN - no files were deleted.' -ForegroundColor Yellow
} else {
    Write-Host 'Cleanup applied.' -ForegroundColor Cyan
}
Write-Host ''
@($results) | ForEach-Object {
    [pscustomobject]@{
        ID     = $_.id
        Size   = (Format-Bytes $_.bytesBefore)
        Freed  = (Format-Bytes $_.freedBytes)
        Status = $_.status
    }
} | Format-Table -AutoSize | Out-String | Write-Host

Write-Host ("Free space: {0:N2} GB -> {1:N2} GB" -f $freeBefore, $freeAfter)
if ($allErrors.Count -gt 0) {
    Write-Host ''
    Write-Host 'Warnings' -ForegroundColor Yellow
    foreach ($err in $allErrors) { Write-Host ("  - " + $err) }
}
Write-Host ''
