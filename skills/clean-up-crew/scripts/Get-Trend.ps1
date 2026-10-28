[CmdletBinding()]
param(
    [int]$Last = 8,
    [switch]$Json,
    [string]$HistoryFile
)

. (Join-Path $PSScriptRoot 'CleanupCommon.ps1')

$historyPath = if ($HistoryFile) { $HistoryFile } else { $script:CleanupHistoryFile }
$history = @(Get-CleanupHistory -Path $historyPath | Where-Object { $null -ne $_.freeGB })
if ($history.Count -eq 0) {
    Write-Host 'No history yet. Run Get-DiskReport.ps1 -SaveHistory to start tracking.'
    return
}

$sorted = @($history | Sort-Object { [datetime]$_.timestamp })
$take = [int][math]::Max(2, $Last)
$recent = @($sorted | Select-Object -Last $take)

$rows = New-Object System.Collections.ArrayList
$previous = $null
foreach ($entry in $recent) {
    $delta = $null
    if ($previous) {
        $delta = [math]::Round([double]$entry.freeGB - [double]$previous.freeGB, 2)
    }
    [void]$rows.Add([pscustomobject]@{
        timestamp   = (([datetime]$entry.timestamp).ToString('yyyy-MM-dd HH:mm'))
        kind        = $entry.kind
        freeGB      = [double]$entry.freeGB
        deltaGB     = $delta
    })
    $previous = $entry
}

$oldest = $recent | Select-Object -First 1
$newest = $recent | Select-Object -Last 1
$days = ([datetime]$newest.timestamp - [datetime]$oldest.timestamp).TotalDays
$burnPerWeek = $null
$weeksTo2GB = $null
if ($days -gt 0) {
    $burnPerWeek = [math]::Round((([double]$oldest.freeGB - [double]$newest.freeGB) / $days) * 7, 2)
    if ($burnPerWeek -gt 0) {
        $weeksTo2GB = [math]::Round(([double]$newest.freeGB - 2) / $burnPerWeek, 1)
    }
}

$output = [pscustomobject]@{
    entries      = @($rows)
    days         = [math]::Round($days, 1)
    burnGBPerWeek = $burnPerWeek
    weeksTo2GB   = $weeksTo2GB
}

if ($Json) {
    $output | ConvertTo-Json -Depth 6
    return
}

$rows | Format-Table -AutoSize | Out-String | Write-Host
if ($null -ne $burnPerWeek) {
    Write-Host ("Growth: {0:N2} GB/week over {1:N1} days" -f $burnPerWeek, $days)
    if ($null -ne $weeksTo2GB) {
        Write-Host ("At this rate, about {0:N1} weeks until only 2 GB remain." -f $weeksTo2GB)
    } elseif ($burnPerWeek -le 0) {
        Write-Host 'Free space is stable or increasing.'
    }
}
