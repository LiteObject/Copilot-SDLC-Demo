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
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 8 regression case(s) failed." }
Write-Host '[PASS] All Phase 8 PowerShell regression cases passed.'
