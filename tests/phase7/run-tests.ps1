[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase7/config-measurement-valid.yml'
$baseScripts = Join-Path $root 'template/base/scripts'
$measurementRoot = Join-Path $root 'template/extensions/measurement'
$temporaryRoot = Join-Path $root "tests/.phase7-pwsh-$([guid]::NewGuid().ToString('N'))"
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
    Copy-Item (Join-Path $root 'template/base/docs/spec.md') (Join-Path $repo 'docs/spec.md')
    Copy-Item (Join-Path $baseScripts '*') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $measurementRoot 'scripts/*.ps1') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $measurementRoot 'docs/*') (Join-Path $repo 'docs') -Force
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase7@example.test'
    & git -C $repo config user.name 'Phase 7 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'phase 7 fixture'
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $validRepo = New-TestRepo 'valid'
    $validator = Join-Path $validRepo 'scripts/validate-measurement.ps1'
    $runner = Join-Path $validRepo 'scripts/run-measurement.ps1'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'measurement config validates' ($LASTEXITCODE -eq 0)
    Assert-Condition 'measurement config evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/measurement-config-validation.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $validRepo -RecordSpec *> $null
    Assert-Condition 'measurement checks pass' ($LASTEXITCODE -eq 0)
    $summaryPath = Join-Path $validRepo '.sdlc/evidence/measurement.json'
    Assert-Condition 'measurement evidence exists' (Test-Path -LiteralPath $summaryPath)
    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Assert-Condition 'all measurement checks are machine-readable' ($summary.checks.Count -eq 3 -and @($summary.checks | Where-Object { $_.result -ne 'PASS' }).Count -eq 0)
    Assert-Condition 'all roadmap phases have both metric types' ($summary.metrics.phase_outcomes.Count -eq 8 -and $summary.metrics.phase_leading_indicators.Count -eq 8)
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'measurement gate is recorded' ($validSpec -match '(?m)^gate_measurement_result:\s+PASS\s*$' -and $validSpec -match '(?m)^measurement_enabled:\s+true\s*$')

    $failureRepo = New-TestRepo 'failure'
    $failureConfigPath = Join-Path $failureRepo '.github/sdlc-config.yml'
    $failureConfig = [System.IO.File]::ReadAllText($failureConfigPath).Replace('printf measurement-snapshot-pass', 'exit 9')
    [System.IO.File]::WriteAllText($failureConfigPath, $failureConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failureRepo 'scripts/run-measurement.ps1') -RepoRoot $failureRepo -RecordSpec *> $null
    Assert-Condition 'failed measurement task blocks gate' ($LASTEXITCODE -eq 1)
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRepo '.sdlc/evidence/measurement.json') -Raw
    $failureSpec = Get-Content -LiteralPath (Join-Path $failureRepo 'docs/spec.md') -Raw
    Assert-Condition 'failed measurement evidence is machine-readable' ($failureSummary -match '"result"\s*:\s*"FAIL"' -and $failureSpec -match '(?m)^gate_measurement_result:\s+FAIL\s*$')

    $invalidOwnerRepo = New-TestRepo 'invalid-owner'
    $invalidOwnerConfigPath = Join-Path $invalidOwnerRepo '.github/sdlc-config.yml'
    $invalidOwnerConfig = [System.IO.File]::ReadAllText($invalidOwnerConfigPath).Replace('owner: measurement-owner', 'owner: ""')
    [System.IO.File]::WriteAllText($invalidOwnerConfigPath, $invalidOwnerConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $invalidOwnerRepo 'scripts/validate-measurement.ps1') -RepoRoot $invalidOwnerRepo *> $null
    Assert-Condition 'missing measurement owner is rejected' ($LASTEXITCODE -eq 1)

    Remove-Item -LiteralPath (Join-Path $validRepo 'docs/measurement-privacy-review.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'missing privacy review is rejected' ($LASTEXITCODE -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 7 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 7 regression cases passed.'