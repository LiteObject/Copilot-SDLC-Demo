[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase8/feature-valid.md'
$scopeFixture = Join-Path $root 'tests/fixtures/phase8/feature-scope.md'
$configFixture = Join-Path $root 'tests/fixtures/phase1/config-valid.yml'
$legacyFixture = Join-Path $root 'tests/fixtures/phase0/legacy-spec.md'
$baseScripts = Join-Path $root 'template/base/scripts'
$phaseValidator = Join-Path $baseScripts 'check-phase.ps1'
$scopeAudit = Join-Path $baseScripts 'scope-audit.ps1'
$taskRunner = Join-Path $baseScripts 'run-sdlc-task.ps1'
$migrator = Join-Path $baseScripts 'migrate-spec.ps1'
$scaffolder = Join-Path $root 'tools/scaffold-sdlc.ps1'
$temporaryRoot = Join-Path $root "tests/.phase8-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-ExitCode {
    param([string] $Label, [int] $Actual, [int] $Expected)
    if ($Actual -eq $Expected) { Write-Host "[PASS] $Label ($Actual)" }
    else { Write-Host "[FAIL] ${Label}: expected $Expected, got $Actual"; $script:failures += 1 }
}

function Assert-Condition {
    param([string] $Label, [bool] $Condition)
    if ($Condition) { Write-Host "[PASS] $Label" }
    else { Write-Host "[FAIL] $Label"; $script:failures += 1 }
}

function Write-FeatureSpec {
    param([string] $Path, [string] $FeatureId)
    $content = [System.IO.File]::ReadAllText($fixture).Replace('alpha', $FeatureId)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $featureRepo = Join-Path $temporaryRoot 'features'
    New-Item -ItemType Directory -Path (Join-Path $featureRepo '.github'), (Join-Path $featureRepo 'tests'), (Join-Path $featureRepo 'scripts'), (Join-Path $featureRepo '.sdlc/evidence/alpha'), (Join-Path $featureRepo '.sdlc/evidence/beta') -Force | Out-Null
    Copy-Item $configFixture (Join-Path $featureRepo '.github/sdlc-config.yml')
    Copy-Item (Join-Path $baseScripts '*') (Join-Path $featureRepo 'scripts') -Force
    Write-FeatureSpec (Join-Path $featureRepo 'docs/specs/alpha/spec.md') 'alpha'
    Write-FeatureSpec (Join-Path $featureRepo 'docs/specs/beta/spec.md') 'beta'
    Set-Content -LiteralPath (Join-Path $featureRepo '.sdlc/evidence/alpha/requirements.txt') -Value 'alpha requirements' -NoNewline
    Set-Content -LiteralPath (Join-Path $featureRepo '.sdlc/evidence/beta/requirements.txt') -Value 'beta requirements' -NoNewline

    foreach ($featureId in @('alpha', 'beta')) {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator -RepoRoot $featureRepo -FeatureId $featureId -Phase PLANNING -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
        Assert-ExitCode "feature $featureId validates independently" $LASTEXITCODE 0
    }

    $alphaSpecPath = Join-Path $featureRepo 'docs/specs/alpha/spec.md'
    $alphaSpec = [System.IO.File]::ReadAllText($alphaSpecPath).Replace('.sdlc/evidence/alpha/requirements.txt', '.sdlc/evidence/beta/requirements.txt')
    [System.IO.File]::WriteAllText($alphaSpecPath, $alphaSpec, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator -RepoRoot $featureRepo -FeatureId alpha -Phase PLANNING -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'cross-feature gate evidence is rejected' $LASTEXITCODE 2
    Write-FeatureSpec $alphaSpecPath 'alpha'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator -RepoRoot $featureRepo -FeatureId 'Alpha_Bad' -Phase PLANNING -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'invalid feature ID is rejected' $LASTEXITCODE 1
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $phaseValidator -RepoRoot $featureRepo -FeatureId '../beta' -Phase PLANNING -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'path traversal feature ID is rejected' $LASTEXITCODE 1

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskRunner -Task test -RepoRoot $featureRepo -ConfigPath (Join-Path $featureRepo '.github/sdlc-config.yml') -FeatureId alpha *> $null
    Assert-ExitCode 'feature task execution succeeds' $LASTEXITCODE 0
    Assert-Condition 'feature task evidence is namespaced' (Test-Path -LiteralPath (Join-Path $featureRepo '.sdlc/evidence/alpha/test.json'))
    Assert-Condition 'other feature task evidence is untouched' (-not (Test-Path -LiteralPath (Join-Path $featureRepo '.sdlc/evidence/beta/test.json')))

    $scopeRepo = Join-Path $temporaryRoot 'scope'
    New-Item -ItemType Directory -Path (Join-Path $scopeRepo 'docs/specs/alpha'), (Join-Path $scopeRepo 'docs/specs/beta'), (Join-Path $scopeRepo 'src') -Force | Out-Null
    Copy-Item $scopeFixture (Join-Path $scopeRepo 'docs/specs/alpha/spec.md')
    $betaScope = [System.IO.File]::ReadAllText($scopeFixture).Replace('alpha', 'beta')
    [System.IO.File]::WriteAllText((Join-Path $scopeRepo 'docs/specs/beta/spec.md'), $betaScope, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $scopeRepo 'src/alpha.txt') -Value 'base' -NoNewline
    & git -C $scopeRepo init --quiet
    & git -C $scopeRepo config user.email 'phase8@example.test'
    & git -C $scopeRepo config user.name 'Phase 8 Tests'
    & git -C $scopeRepo add .
    & git -C $scopeRepo commit --quiet -m 'feature scope base'
    Set-Content -LiteralPath (Join-Path $scopeRepo 'src/alpha.txt') -Value 'changed' -NoNewline
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $scopeRepo -FeatureId alpha *> $null
    Assert-ExitCode 'feature scope allows planned file' $LASTEXITCODE 0
    Add-Content -LiteralPath (Join-Path $scopeRepo 'docs/specs/beta/spec.md') -Value "`nchanged outside alpha"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $scopeRepo -FeatureId alpha *> $null
    Assert-ExitCode 'feature scope rejects another feature spec' $LASTEXITCODE 1

    $sharedRepo = Join-Path $temporaryRoot 'shared'
    New-Item -ItemType Directory -Path (Join-Path $sharedRepo 'docs/specs/alpha'), (Join-Path $sharedRepo 'src') -Force | Out-Null
    $sharedSpec = [System.IO.File]::ReadAllText($scopeFixture).Replace("  - src/alpha.txt`r`napproved_globs: []", "  - src/alpha.txt`r`n  - package.json`r`napproved_globs: []")
    if ($sharedSpec -notmatch 'package\.json') { $sharedSpec = [System.IO.File]::ReadAllText($scopeFixture).Replace("  - src/alpha.txt`napproved_globs: []", "  - src/alpha.txt`n  - package.json`napproved_globs: []") }
    $sharedSpec = $sharedSpec.Replace('approved_shared_files: []', 'approved_shared_files: []')
    [System.IO.File]::WriteAllText((Join-Path $sharedRepo 'docs/specs/alpha/spec.md'), $sharedSpec, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $sharedRepo 'src/alpha.txt') -Value 'base' -NoNewline
    Set-Content -LiteralPath (Join-Path $sharedRepo 'package.json') -Value '{"name":"fixture"}' -NoNewline
    & git -C $sharedRepo init --quiet
    & git -C $sharedRepo config user.email 'phase8@example.test'
    & git -C $sharedRepo config user.name 'Phase 8 Tests'
    & git -C $sharedRepo add .
    & git -C $sharedRepo commit --quiet -m 'shared file base'
    Set-Content -LiteralPath (Join-Path $sharedRepo 'package.json') -Value '{"name":"changed"}' -NoNewline
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $sharedRepo -FeatureId alpha *> $null
    Assert-ExitCode 'unapproved shared file is rejected' $LASTEXITCODE 1
    $sharedSpec = (Get-Content -LiteralPath (Join-Path $sharedRepo 'docs/specs/alpha/spec.md') -Raw).Replace('approved_shared_files: []', "approved_shared_files:`n  - package.json|Add fixture dependency|architect|fixture-commit|2026-07-21T00:00:00Z")
    [System.IO.File]::WriteAllText((Join-Path $sharedRepo 'docs/specs/alpha/spec.md'), $sharedSpec, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $sharedRepo -FeatureId alpha *> $null
    Assert-ExitCode 'approved shared file passes' $LASTEXITCODE 0

    $conflictRepo = Join-Path $temporaryRoot 'conflict'
    New-Item -ItemType Directory -Path (Join-Path $conflictRepo 'docs/specs/alpha'), (Join-Path $conflictRepo 'docs/specs/beta'), (Join-Path $conflictRepo 'src') -Force | Out-Null
    $alphaConflict = (Get-Content -LiteralPath $scopeFixture -Raw).Replace('  - src/alpha.txt', "  - src/alpha.txt`n  - src/shared.txt")
    $betaConflict = $alphaConflict.Replace('alpha', 'beta')
    [System.IO.File]::WriteAllText((Join-Path $conflictRepo 'docs/specs/alpha/spec.md'), $alphaConflict, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $conflictRepo 'docs/specs/beta/spec.md'), $betaConflict, (New-Object System.Text.UTF8Encoding($false)))
    Set-Content -LiteralPath (Join-Path $conflictRepo 'src/alpha.txt') -Value 'alpha' -NoNewline
    Set-Content -LiteralPath (Join-Path $conflictRepo 'src/shared.txt') -Value 'base' -NoNewline
    & git -C $conflictRepo init --quiet
    & git -C $conflictRepo config user.email 'phase8@example.test'
    & git -C $conflictRepo config user.name 'Phase 8 Tests'
    & git -C $conflictRepo add .
    & git -C $conflictRepo commit --quiet -m 'feature conflict base'
    Set-Content -LiteralPath (Join-Path $conflictRepo 'src/shared.txt') -Value 'changed' -NoNewline
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $conflictRepo -FeatureId alpha *> $null
    Assert-ExitCode 'same-file feature conflict is rejected' $LASTEXITCODE 2

    $scaffoldRepo = Join-Path $temporaryRoot 'scaffold'
    New-Item -ItemType Directory -Path (Join-Path $scaffoldRepo 'docs') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $scaffoldRepo 'docs/spec.md') -Value 'legacy project spec' -NoNewline
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scaffolder -Target $scaffoldRepo -FeatureId checkout-flow *> $null
    Assert-ExitCode 'feature scaffold succeeds' $LASTEXITCODE 0
    Assert-Condition 'feature scaffold preserves legacy spec' ([System.IO.File]::ReadAllText((Join-Path $scaffoldRepo 'docs/spec.md')) -ceq 'legacy project spec')
    $scaffoldFeaturePath = Join-Path $scaffoldRepo 'docs/specs/checkout-flow/spec.md'
    Assert-Condition 'feature scaffold creates feature spec' (Test-Path -LiteralPath $scaffoldFeaturePath)
    Assert-Condition 'feature scaffold records identity' ((Get-Content -LiteralPath $scaffoldFeaturePath -Raw) -match '(?m)^feature_id:\s+"checkout-flow"\s*$' -and (Get-Content -LiteralPath $scaffoldFeaturePath -Raw) -match '(?m)^spec_path:\s+"docs/specs/checkout-flow/spec.md"\s*$')
    $scaffoldTasksPath = Join-Path $scaffoldRepo 'docs/specs/checkout-flow/tasks.json'
    $scaffoldTasksContent = if (Test-Path -LiteralPath $scaffoldTasksPath) { Get-Content -LiteralPath $scaffoldTasksPath -Raw } else { '' }
    Assert-Condition 'feature scaffold creates task graph starter' ((Test-Path -LiteralPath $scaffoldTasksPath) -and $scaffoldTasksContent -match '"schema_version"\s*:\s*1' -and $scaffoldTasksContent -match '"tasks"\s*:\s*\[\s*\]')

    $migrationRepo = Join-Path $temporaryRoot 'migration'
    New-Item -ItemType Directory -Path (Join-Path $migrationRepo 'docs'), (Join-Path $migrationRepo '.github') -Force | Out-Null
    Copy-Item $legacyFixture (Join-Path $migrationRepo 'docs/spec.md')
    $legacyBefore = [System.IO.File]::ReadAllText((Join-Path $migrationRepo 'docs/spec.md'))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $migrator -RepoRoot $migrationRepo -FeatureId alpha -Force *> $null
    Assert-ExitCode 'feature migration succeeds' $LASTEXITCODE 0
    Assert-Condition 'legacy spec is preserved' ([System.IO.File]::ReadAllText((Join-Path $migrationRepo 'docs/spec.md')) -ceq $legacyBefore)
    $migratedPath = Join-Path $migrationRepo 'docs/specs/alpha/spec.md'
    Assert-Condition 'feature migration creates target spec' (Test-Path -LiteralPath $migratedPath)
    Assert-Condition 'feature migration records identity' ((Get-Content -LiteralPath $migratedPath -Raw) -match '(?m)^feature_id:\s+"alpha"\s*$' -and (Get-ChildItem -Path (Join-Path $migrationRepo '.sdlc/migrations/alpha') -File).Count -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures -gt 0) { throw "$failures Phase 8 regression case(s) failed." }
Write-Host '[PASS] All Phase 8 PowerShell regression cases passed.'
