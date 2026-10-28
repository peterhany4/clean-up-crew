# Guardrail tests for the clean-up-crew skill. Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-Guardrails.ps1

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\CleanupCommon.ps1')

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

Assert-True (-not (Test-SafePath 'C:\').Safe) 'Rejects drive root'
Assert-True (-not (Test-SafePath (Join-Path $env:SystemRoot 'System32')).Safe) 'Rejects System32'
Assert-True (-not (Test-SafePath (Join-Path $env:SystemRoot 'WinSxS')).Safe) 'Rejects WinSxS'
Assert-True (-not (Test-SafePath $env:USERPROFILE).Safe) 'Rejects user profile root'
Assert-True (-not (Test-SafePath (Join-Path $env:USERPROFILE 'Desktop')).Safe) 'Rejects Desktop'
Assert-True (-not (Test-SafePath (Join-Path $env:USERPROFILE 'Documents')).Safe) 'Rejects Documents'
Assert-True (-not (Test-SafePath "$env:USERPROFILE\AppData\..\..\Windows").Safe) 'Rejects path traversal'
Assert-True (-not (Test-SafePath "$env:SystemRoot\System32\..\System32").Safe) 'Rejects traversal that resolves into System32'
Assert-True ((Test-SafePath (Join-Path $env:LOCALAPPDATA 'npm-cache\_cacache')).Safe) 'Allows npm cache'
Assert-True ((Test-SafePath (Join-Path $env:SystemRoot 'Temp')).Safe) 'Allows Windows Temp'

$allTargets = Get-CleanupTargets
$badTargets = @($allTargets | Where-Object {
    -not $_.id -or -not $_.name -or $null -eq $_.tier -or -not $_.type -or $null -eq $_.regenerates -or $null -eq $_.risk
})
Assert-True ($badTargets.Count -eq 0) 'All targets have required fields'
$duplicateIds = @($allTargets | Group-Object id | Where-Object { $_.Count -gt 1 })
Assert-True ($duplicateIds.Count -eq 0) 'Target IDs are unique'
$unknownTypes = @($allTargets | Where-Object { $_.type -notin @('contents', 'profile-caches', 'files', 'recyclebin', 'dism') })
Assert-True ($unknownTypes.Count -eq 0) 'Target types are known'

$wildDir = Join-Path $env:TEMP 'opencode-cleanup-wild'
$wildA = Join-Path $wildDir 'a.tmp'
$wildB = Join-Path $wildDir 'b.tmp'
$wildKeep = Join-Path $wildDir 'keep.txt'

$fixture = Join-Path $env:TEMP 'opencode-cleanup-test'
$keepDir = Join-Path $fixture 'keep'
$removeFile = Join-Path $fixture 'remove.txt'
$keepFile = Join-Path $keepDir 'keep.txt'

try {
    if (Test-Path -LiteralPath $wildDir) { Remove-Item -LiteralPath $wildDir -Recurse -Force }
    New-Item -ItemType Directory -Path $wildDir -Force | Out-Null
    Set-Content -LiteralPath $wildA -Value 'a'
    Set-Content -LiteralPath $wildB -Value 'b'
    Set-Content -LiteralPath $wildKeep -Value 'keep'

    $wildMatches = @(Resolve-CleanupPath (Join-Path $wildDir '*.tmp'))
    Assert-True ($wildMatches.Count -eq 2) 'Expands wildcard paths'
    Assert-True (@($wildMatches | Where-Object { $_ -like '*keep.txt' }).Count -eq 0) 'Wildcard expansion respects the pattern'

    $removed = Remove-CleanupFile -Path $wildA
    Assert-True ($removed.Removed -eq 1 -and -not (Test-Path -LiteralPath $wildA)) 'Removes a single file target'
    Assert-True (Test-Path -LiteralPath $wildB) 'Leaves unmatched files alone'

    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    New-Item -ItemType Directory -Path $keepDir -Force | Out-Null
    Set-Content -LiteralPath $removeFile -Value 'delete me'
    Set-Content -LiteralPath $keepFile -Value 'keep me'

    $result = Remove-CleanupContents -Path $fixture -Exclude @($keepDir)

    Assert-True (-not (Test-Path -LiteralPath $removeFile)) 'Removes non-excluded children'
    Assert-True (Test-Path -LiteralPath $keepFile) 'Preserves excluded children'
    Assert-True ($result.Failed -eq 0) 'Reports zero failures'
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $wildDir) { Remove-Item -LiteralPath $wildDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:failures -eq 0) {
    Write-Host ''
    Write-Host 'All guardrail tests passed.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red
}
exit $script:failures
