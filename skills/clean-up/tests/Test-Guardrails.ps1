# Guardrail tests for the clean-up skill. Run with:
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

$fixture = Join-Path $env:TEMP 'opencode-cleanup-test'
$keepDir = Join-Path $fixture 'keep'
$removeFile = Join-Path $fixture 'remove.txt'
$keepFile = Join-Path $keepDir 'keep.txt'

try {
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
}

if ($script:failures -eq 0) {
    Write-Host ''
    Write-Host 'All guardrail tests passed.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host "$($script:failures) test(s) failed." -ForegroundColor Red
}
exit $script:failures
