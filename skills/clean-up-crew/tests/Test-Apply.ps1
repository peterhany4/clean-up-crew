# End-to-end apply test using a temporary fixture target.
# The real targets.json and history file are backed up and restored around the test.

$ErrorActionPreference = 'Stop'

$skillRoot = Split-Path -Parent $PSScriptRoot
$scriptsDir = Join-Path $skillRoot 'scripts'
$targetsPath = Join-Path $skillRoot 'references\targets.json'
$backupPath = Join-Path $env:TEMP 'clean-up-targets-backup.json'
$planPath = Join-Path $env:TEMP 'clean-up-test-plan.json'
$fixture = Join-Path $env:TEMP 'opencode-cleanup-apply-test'
$filesFixture = Join-Path $env:TEMP 'opencode-cleanup-files-test'
$historyPath = Join-Path $env:LOCALAPPDATA 'opencode-disk-cleanup\history.jsonl'
$historyBackup = Join-Path $env:TEMP 'clean-up-history-backup.jsonl'
$historyExisted = Test-Path -LiteralPath $historyPath

$script:failures = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        Write-Host "PASS  $Message" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $Message" -ForegroundColor Red
        $script:failures++
    }
}

Copy-Item -LiteralPath $targetsPath -Destination $backupPath -Force
if ($historyExisted) {
    Copy-Item -LiteralPath $historyPath -Destination $historyBackup -Force
}

try {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    New-Item -ItemType Directory -Path (Join-Path $fixture 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixture 'a.txt') -Value ('x' * 4096)
    Set-Content -LiteralPath (Join-Path $fixture 'sub\b.txt') -Value ('y' * 4096)

    if (Test-Path -LiteralPath $filesFixture) { Remove-Item -LiteralPath $filesFixture -Recurse -Force }
    New-Item -ItemType Directory -Path $filesFixture -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $filesFixture 'one.dmp') -Value ('z' * 4096)
    Set-Content -LiteralPath (Join-Path $filesFixture 'two.dmp') -Value ('z' * 4096)
    Set-Content -LiteralPath (Join-Path $filesFixture 'keep.txt') -Value 'keep'

    $json = Get-Content -LiteralPath $targetsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $testTarget = [pscustomobject]@{
        id = 'test-fixture'
        name = 'Test fixture'
        tier = 1
        type = 'contents'
        paths = @($fixture)
        exclude = @()
        processes = @()
        requiresAdmin = $false
        regenerates = 'not applicable'
        risk = 'none'
    }
    $testFilesTarget = [pscustomobject]@{
        id = 'test-files'
        name = 'Test files'
        tier = 1
        type = 'files'
        paths = @((Join-Path $filesFixture '*.dmp'))
        exclude = @()
        processes = @()
        requiresAdmin = $false
        regenerates = 'not applicable'
        risk = 'none'
    }
    $json.targets = @($json.targets) + $testTarget + $testFilesTarget
    $json | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $targetsPath -Encoding UTF8

    # Seed a report entry so the trend has both report and apply data to compare.
    $historyDir = Split-Path -Parent $historyPath
    if (-not (Test-Path -LiteralPath $historyDir)) {
        New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
    }
    $seedEntry = @{
        timestamp = (Get-Date).AddMinutes(-1).ToString('o')
        kind      = 'report'
        drive     = 'C:'
        freeGB    = 5.0
        totalGB   = 100.0
        targets   = @{}
    } | ConvertTo-Json -Compress -Depth 6
    Add-Content -LiteralPath $historyPath -Value $seedEntry -Encoding UTF8

    $planScript = Join-Path $scriptsDir 'New-CleanupPlan.ps1'
    & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$($planScript.Replace("'", "''"))' -Items @('test-fixture','test-files') -OutFile '$($planPath.Replace("'", "''"))' -Json" | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'Plan generation succeeds'

    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($plan.items).Count -eq 2) 'Plan includes both fixture targets'
    Assert-True (($plan.items | Where-Object id -eq 'test-fixture').bytes -gt 0) 'Plan sees fixture bytes'
    Assert-True (($plan.items | Where-Object id -eq 'test-files').bytes -gt 0) 'Plan sees file target bytes'

    $resultJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'Invoke-Cleanup.ps1') `
        -PlanFile $planPath -Apply -Json
    Assert-True ($LASTEXITCODE -eq 0) 'Apply exits successfully'

    $result = $resultJson | ConvertFrom-Json
    Assert-True ([bool]$result.applied) 'Result reports applied'
    Assert-True (Test-Path -LiteralPath $fixture) 'Keeps the target directory itself'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'a.txt'))) 'Deletes file child'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture 'sub'))) 'Deletes directory child'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $filesFixture 'one.dmp'))) 'Deletes wildcard-matched files'
    Assert-True (Test-Path -LiteralPath (Join-Path $filesFixture 'keep.txt')) 'Keeps files outside the wildcard'
    Assert-True ([int64]$result.freedBytes -gt 0) 'Reports freed bytes'

    $historyEntries = @(Get-Content -LiteralPath $historyPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
    $applyEntry = $historyEntries | Where-Object { $_.kind -eq 'apply' -and $_.planId -eq [string]$result.planId } | Select-Object -Last 1
    Assert-True ($null -ne $applyEntry -and $null -ne $applyEntry.freeGB) 'Apply history records freeGB'

    $trendJson = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptsDir 'Get-Trend.ps1') `
        -Last 8 -HistoryFile $historyPath -Json
    Assert-True ($LASTEXITCODE -eq 0) 'Trend generation succeeds'
    $trend = $trendJson | ConvertFrom-Json
    Assert-True (@($trend.entries).Count -ge 2) 'Trend includes report and apply entries'
    Assert-True ($null -ne $trend.burnGBPerWeek) 'Trend calculates a numeric rate'
} finally {
    if (Test-Path -LiteralPath $backupPath) {
        Copy-Item -LiteralPath $backupPath -Destination $targetsPath -Force
    }
    if ($historyExisted) {
        if (Test-Path -LiteralPath $historyBackup) {
            Copy-Item -LiteralPath $historyBackup -Destination $historyPath -Force
        }
    } elseif (Test-Path -LiteralPath $historyPath) {
        Remove-Item -LiteralPath $historyPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $filesFixture) { Remove-Item -LiteralPath $filesFixture -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $planPath) { Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue }
}

$restored = Get-Content -LiteralPath $targetsPath -Raw -Encoding UTF8
$backup = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8
Assert-True ($restored -eq $backup) 'Restores original targets.json'
if ($historyExisted) {
    $restoredHistory = Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8
    $backupHistory = Get-Content -LiteralPath $historyBackup -Raw -Encoding UTF8
    Assert-True ($restoredHistory -eq $backupHistory) 'Restores original history'
} else {
    Assert-True (-not (Test-Path -LiteralPath $historyPath)) 'Leaves no test history entry'
}
Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $historyBackup -Force -ErrorAction SilentlyContinue

if ($script:failures -eq 0) {
    Write-Host ''
    Write-Host 'Apply test passed.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red
}
exit $script:failures
