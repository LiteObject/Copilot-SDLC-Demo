[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot = Join-Path $root 'tests/fixtures/phase1'
$configValidator = Join-Path $root 'template/base/scripts/validate-sdlc-config.ps1'
$taskRunner = Join-Path $root 'template/base/scripts/run-sdlc-task.ps1'
$phaseValidator = Join-Path $root 'template/base/scripts/check-phase.ps1'
$specTemplate = Join-Path $root 'template/base/docs/spec.md'
$temporaryRoot = Join-Path $root "tests/.phase1-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-Condition {
    param(
        [string] $Label,
        [bool] $Condition
    )
    if ($Condition) { Write-Host "[PASS] $Label" }
    else { Write-Host "[FAIL] $Label"; $script:failures += 1 }
}

function Invoke-ExitCase {
    param(
        [string] $Label,
        [scriptblock] $Command,
        [int] $Expected
    )
    & $Command
    $actual = $LASTEXITCODE
    Assert-Condition "$Label (exit $Expected)" ($actual -eq $Expected)
}

function New-TestRepo {
    param(
        [string] $Name,
        [string] $ConfigFixture
    )
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github'), (Join-Path $repo 'docs'), (Join-Path $repo 'tests') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot $ConfigFixture) (Join-Path $repo '.github/sdlc-config.yml')
    Copy-Item $specTemplate (Join-Path $repo 'docs/spec.md')
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $validRepo = New-TestRepo 'valid' 'config-valid.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $validRepo -RecordSpec *> $null
    Assert-Condition 'valid config passes PowerShell validation' ($LASTEXITCODE -eq 0)
    Assert-Condition 'config evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/config-validation.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskRunner -RepoRoot $validRepo -Task all -RecordSpec *> $null
    Assert-Condition 'all configured tasks pass' ($LASTEXITCODE -eq 0)
    Assert-Condition 'build log exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/build.log'))
    Assert-Condition 'test JSON evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/test.json'))
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'config gate is recorded' ($validSpec -match '(?m)^gate_config_result:\s+PASS\s*$')
    Assert-Condition 'build gate is recorded' ($validSpec -match '(?m)^gate_build_result:\s+PASS\s*$')
    Assert-Condition 'test gate is recorded' ($validSpec -match '(?m)^gate_test_result:\s+PASS\s*$')

    $invalidRepo = New-TestRepo 'invalid' 'config-invalid.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $invalidRepo *> $null
    Assert-Condition 'invalid config fails validation' ($LASTEXITCODE -eq 1)

    $shellInvalidRepo = New-TestRepo 'shell-invalid' 'config-shell-invalid.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $shellInvalidRepo *> $null
    Assert-Condition 'shell syntax in executable is rejected' ($LASTEXITCODE -eq 1)

    $failingRepo = New-TestRepo 'failing' 'config-failing-test.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskRunner -RepoRoot $failingRepo -Task test -RecordSpec *> $null
    Assert-Condition 'failing named task returns its process code' ($LASTEXITCODE -eq 3)
    $failingSpec = Get-Content -LiteralPath (Join-Path $failingRepo 'docs/spec.md') -Raw
    Assert-Condition 'failed task gate is recorded' ($failingSpec -match '(?m)^gate_test_result:\s+FAIL\s*$')
    Assert-Condition 'failed task evidence exists' (Test-Path -LiteralPath (Join-Path $failingRepo '.sdlc/evidence/test.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator `
        -SpecPath (Join-Path $fixtureRoot 'config-gated-coding.md') -RepoRoot $root `
        -Phase CODING -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'config gate is required before coding' ($LASTEXITCODE -eq 0)

    Copy-Item (Join-Path $fixtureRoot 'configured-review.md') (Join-Path $validRepo 'docs/spec.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator `
        -SpecPath (Join-Path $validRepo 'docs/spec.md') -RepoRoot $validRepo `
        -Phase REVIEW -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'configured required build gate is enforced before review' ($LASTEXITCODE -eq 0)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 1 regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 1 regression cases passed.'
