[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot = Join-Path $root 'tests/fixtures/phase0'
$phaseValidator = Join-Path $root 'template/base/scripts/check-phase.ps1'
$scopeAudit = Join-Path $root 'template/base/scripts/scope-audit.ps1'
$temporaryRoot = Join-Path $root "tests/.phase0-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-ExitCode {
    param(
        [string] $Label,
        [int] $Actual,
        [int] $Expected
    )

    if ($Actual -eq $Expected) {
        Write-Host "[PASS] $Label ($Actual)"
    }
    else {
        Write-Host "[FAIL] ${Label}: expected $Expected, got $Actual"
        $script:failures += 1
    }
}

function Invoke-PhaseCase {
    param(
        [string] $Label,
        [string] $Fixture,
        [string] $TargetPhase,
        [int] $Expected,
        [string] $Commit = 'fixture-commit',
        [string] $Tree = 'fixture-tree'
    )

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator `
        -SpecPath (Join-Path $fixtureRoot $Fixture) `
        -RepoRoot $root `
        -Phase $TargetPhase `
        -CommitSha $Commit `
        -TreeDigest $Tree *> $null
    Assert-ExitCode $Label $LASTEXITCODE $Expected
}

function Invoke-ScopeCase {
    param(
        [string] $Label,
        [int] $Expected
    )

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit `
        -RepoRoot $scopeRoot `
        -SpecPath (Join-Path $scopeRoot 'docs/spec.md') *> $null
    Assert-ExitCode $Label $LASTEXITCODE $Expected
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    Invoke-PhaseCase 'valid requirements to planning' 'valid-planning.md' 'PLANNING' 0
    Invoke-PhaseCase 'valid testing to readiness' 'valid-readiness.md' 'DEPLOYMENT_READINESS' 0
    Invoke-PhaseCase 'failed test blocks done' 'failed-test.md' 'DONE' 2
    Invoke-PhaseCase 'failed readiness blocks done' 'failed-readiness.md' 'DONE' 2
    Invoke-PhaseCase 'fourth review cycle is blocked' 'review-cycle-cap.md' 'CODING' 2
    Invoke-PhaseCase 'illegal direct jump is blocked' 'valid-planning.md' 'DONE' 2
    Invoke-PhaseCase 'stale gate revision is blocked' 'valid-planning.md' 'PLANNING' 2 -Commit 'stale-commit'

    $crlfPath = Join-Path $temporaryRoot 'crlf-spec.md'
    $crlfContent = [System.IO.File]::ReadAllText((Join-Path $fixtureRoot 'valid-planning.md'))
    $crlfContent = $crlfContent.Replace("`r`n", "`n").Replace("`n", "`r`n")
    [System.IO.File]::WriteAllText($crlfPath, $crlfContent, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator `
        -SpecPath $crlfPath -RepoRoot $root -Phase PLANNING `
        -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'CRLF phase fixture' $LASTEXITCODE 0

    $scopeRoot = Join-Path $temporaryRoot 'scope-repo'
    New-Item -ItemType Directory -Path (Join-Path $scopeRoot 'docs'), (Join-Path $scopeRoot 'src') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot 'scope-exact.md') (Join-Path $scopeRoot 'docs/spec.md')
    Set-Content -LiteralPath (Join-Path $scopeRoot 'src/allowed.txt') -Value 'allowed' -NoNewline
    & git -C $scopeRoot init --quiet
    & git -C $scopeRoot config user.email 'phase0@example.test'
    & git -C $scopeRoot config user.name 'Phase 0 Tests'
    & git -C $scopeRoot add docs/spec.md
    & git -C $scopeRoot commit --quiet -m 'fixture base'
    Invoke-ScopeCase 'exact planned file passes' 0

    $scopeCrlfContent = [System.IO.File]::ReadAllText((Join-Path $fixtureRoot 'scope-exact.md'))
    $scopeCrlfContent = $scopeCrlfContent.Replace("`r`n", "`n").Replace("`n", "`r`n")
    [System.IO.File]::WriteAllText((Join-Path $scopeRoot 'docs/spec.md'), $scopeCrlfContent, (New-Object System.Text.UTF8Encoding($false)))
    Invoke-ScopeCase 'CRLF scope fixture' 0

    Set-Content -LiteralPath (Join-Path $scopeRoot 'src/unplanned.txt') -Value 'creep' -NoNewline
    Invoke-ScopeCase 'unplanned file is scope creep' 1

    Copy-Item (Join-Path $fixtureRoot 'scope-directory.md') (Join-Path $scopeRoot 'docs/spec.md') -Force
    Invoke-ScopeCase 'directory scope entry is invalid' 2

    Copy-Item (Join-Path $fixtureRoot 'scope-glob-unapproved.md') (Join-Path $scopeRoot 'docs/spec.md') -Force
    Invoke-ScopeCase 'unapproved glob is invalid' 2

    Remove-Item (Join-Path $scopeRoot 'src/unplanned.txt') -Force
    Remove-Item (Join-Path $scopeRoot 'src/allowed.txt') -Force
    Copy-Item (Join-Path $fixtureRoot 'scope-glob-approved.md') (Join-Path $scopeRoot 'docs/spec.md') -Force
    New-Item -ItemType Directory -Path (Join-Path $scopeRoot 'src/nested') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $scopeRoot 'src/nested/ok.txt') -Value 'approved' -NoNewline
    & git -C $scopeRoot add docs/spec.md
    & git -C $scopeRoot commit --quiet -m 'approved glob plan'
    Invoke-ScopeCase 'approved glob passes' 0
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($failures -gt 0) {
    throw "$failures Phase 0 regression case(s) failed."
}
Write-Host '[PASS] All Phase 0 PowerShell regression cases passed.'