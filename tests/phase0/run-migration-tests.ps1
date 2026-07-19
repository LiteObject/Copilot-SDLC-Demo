[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase0/legacy-spec.md'
$migration = Join-Path $root 'template/base/scripts/migrate-spec.ps1'
$validator = Join-Path $root 'template/base/scripts/check-phase.ps1'
$temporaryRoot = Join-Path $root "tests/.phase0-migration-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-Condition {
    param(
        [string] $Label,
        [bool] $Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Label"
    }
    else {
        Write-Host "[FAIL] $Label"
        $script:failures += 1
    }
}

New-Item -ItemType Directory -Path (Join-Path $temporaryRoot 'docs'), (Join-Path $temporaryRoot '.github') -Force | Out-Null
try {
    Copy-Item $fixture (Join-Path $temporaryRoot 'docs/spec.md')
    Set-Content -LiteralPath (Join-Path $temporaryRoot '.github/sdlc-config.yml') -Value "integrations:`n  deployment_readiness_gate: true"
    $original = [System.IO.File]::ReadAllText((Join-Path $temporaryRoot 'docs/spec.md'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $migration -RepoRoot $temporaryRoot *> $null
    Assert-Condition 'migration requires explicit force' ($LASTEXITCODE -eq 2)
    Assert-Condition 'dry run preserves legacy spec' ([System.IO.File]::ReadAllText((Join-Path $temporaryRoot 'docs/spec.md')) -ceq $original)

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $migration -RepoRoot $temporaryRoot -Force *> $null
    Assert-Condition 'forced migration succeeds' ($LASTEXITCODE -eq 0)
    $migrated = [System.IO.File]::ReadAllText((Join-Path $temporaryRoot 'docs/spec.md'))
    Assert-Condition 'schema is initialized' ($migrated -match '(?m)^sdlc_schema:\s*1\s*$')
    Assert-Condition 'current phase is preserved' ($migrated -match '(?m)^current_phase:\s*CODING\s*$')
    Assert-Condition 'review cycle is preserved' ($migrated -match '(?m)^review_cycle:\s*2\s*$')
    Assert-Condition 'design requirement is inferred' ($migrated -match '(?m)^design_required:\s*true\s*$')
    Assert-Condition 'readiness configuration is inferred' ($migrated -match '(?m)^deployment_readiness_enabled:\s*true\s*$')
    Assert-Condition 'exact planned files are recovered' ($migrated -match '(?m)^\s*- src/app\.ts\s*$' -and $migrated -match '(?m)^\s*- tests/app\.test\.ts\s*$')
    Assert-Condition 'migration backup exists' ((Get-ChildItem -Path (Join-Path $temporaryRoot '.sdlc/migrations') -File).Count -eq 1)

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $migration -RepoRoot $temporaryRoot *> $null
    Assert-Condition 'migration is idempotent after schema initialization' ($LASTEXITCODE -eq 0)

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $temporaryRoot -Phase REVIEW *> $null
    Assert-Condition 'migrated state is validator-readable but gate-blocked' ($LASTEXITCODE -eq 2)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

if ($failures -gt 0) {
    throw "$failures migration regression case(s) failed."
}
Write-Host '[PASS] All PowerShell migration regression cases passed.'