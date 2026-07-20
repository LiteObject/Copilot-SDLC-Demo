[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase4/config-operational-valid.yml'
$baseScripts = Join-Path $root 'template/base/scripts'
$operationalRoot = Join-Path $root 'template/extensions/operational-readiness'
$operationalScripts = Join-Path $operationalRoot 'scripts'
$specTemplate = Join-Path $root 'template/base/docs/spec.md'
$temporaryRoot = Join-Path $root "tests/.phase4-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-Condition {
    param([string] $Label, [bool] $Condition)
    if ($Condition) { Write-Host "[PASS] $Label" }
    else { Write-Host "[FAIL] $Label"; $script:failures += 1 }
}
function New-TestRepo {
    param([string] $Name)
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github'), (Join-Path $repo 'docs'), (Join-Path $repo 'tests'), (Join-Path $repo 'scripts') -Force | Out-Null
    Copy-Item $fixture (Join-Path $repo '.github/sdlc-config.yml')
    Copy-Item $specTemplate (Join-Path $repo 'docs/spec.md')
    Copy-Item (Join-Path $baseScripts '*') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $operationalScripts '*.ps1') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $operationalScripts '*.sh') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $operationalRoot 'docs/*') (Join-Path $repo 'docs') -Recurse -Force
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $validRepo = New-TestRepo 'valid'
    $validator = Join-Path $validRepo 'scripts/validate-operational-readiness.ps1'
    $runner = Join-Path $validRepo 'scripts/run-operational-readiness.ps1'
    $outcome = Join-Path $validRepo 'scripts/record-production-outcome.ps1'
    $incident = Join-Path $validRepo 'scripts/record-incident-review.ps1'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'operational config validates' ($LASTEXITCODE -eq 0)
    Assert-Condition 'config evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/operational-readiness-config-validation.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $validRepo -RecordSpec *> $null
    Assert-Condition 'readiness checks pass' ($LASTEXITCODE -eq 0)
    Assert-Condition 'readiness summary exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/operational-readiness.json'))
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'readiness gate is recorded' ($validSpec -match '(?m)^gate_operational_readiness_result:\s+PASS\s*$')

    $failureRepo = New-TestRepo 'failure-drill'
    $failureConfigPath = Join-Path $failureRepo '.github/sdlc-config.yml'
    $failureConfig = [System.IO.File]::ReadAllText($failureConfigPath)
    $failureConfig = [regex]::Replace($failureConfig, '(?ms)(failure_drill:\s+executable: bash\s+args: )\[-c, "exit 0"\]', '$1[-c, "exit 7"]')
    [System.IO.File]::WriteAllText($failureConfigPath, $failureConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failureRepo 'scripts/run-operational-readiness.ps1') -RepoRoot $failureRepo -FailureDrill *> $null
    Assert-Condition 'failed staging drill blocks readiness' ($LASTEXITCODE -eq 1)
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRepo '.sdlc/evidence/operational-readiness.json') -Raw
    Assert-Condition 'failed drill is machine-readable' ($failureSummary -match '"mode"\s*:\s*"failure-drill"' -and $failureSummary -match '"result"\s*:\s*"FAIL"')

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $outcome -RepoRoot $validRepo -ReleaseReference release-42 -Environment production -TechnicalResult PASS -BusinessResult PASS -BusinessOutcome 'Checkout completion met its objective.' -UserFeedback 'No critical customer complaints.' *> $null
    Assert-Condition 'successful production outcome is recorded' ($LASTEXITCODE -eq 0)
    Assert-Condition 'production outcome evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/production-outcome.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $outcome -RepoRoot $validRepo -ReleaseReference release-43 -Environment production -TechnicalResult FAIL -BusinessResult PARTIAL -BusinessOutcome 'Checkout completion degraded.' -UserFeedback 'Customers reported failed checkout.' *> $null
    Assert-Condition 'failed production outcome blocks completion' ($LASTEXITCODE -eq 1)

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $incident -RepoRoot $validRepo -IncidentReference INC-42 -Severity sev2 -Summary 'Checkout errors increased.' -Impact 'Customers could not complete checkout.' -CorrectiveAction 'Add dependency timeout alert.' -ActionOwner platform-team -DueDate 2026-08-01 *> $null
    Assert-Condition 'incident review is recorded' ($LASTEXITCODE -eq 0)
    Assert-Condition 'incident evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/incident-review.json'))

    Remove-Item -LiteralPath (Join-Path $validRepo 'docs/alert-policy.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'missing operational document is rejected' ($LASTEXITCODE -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 4 regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 4 regression cases passed.'
