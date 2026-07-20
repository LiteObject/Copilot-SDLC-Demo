[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot = Join-Path $root 'tests/fixtures/phase2'
$configValidator = Join-Path $root 'template/base/scripts/validate-sdlc-config.ps1'
$securityRunner = Join-Path $root 'template/base/scripts/run-security-scans.ps1'
$specTemplate = Join-Path $root 'template/base/docs/spec.md'
$temporaryRoot = Join-Path $root "tests/.phase2-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-Condition {
    param([string] $Label, [bool] $Condition)
    if ($Condition) { Write-Host "[PASS] $Label" }
    else { Write-Host "[FAIL] $Label"; $script:failures += 1 }
}
function New-TestRepo {
    param([string] $Name, [string] $Fixture)
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github'), (Join-Path $repo 'docs'), (Join-Path $repo 'tests') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot $Fixture) (Join-Path $repo '.github/sdlc-config.yml')
    Copy-Item $specTemplate (Join-Path $repo 'docs/spec.md')
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $passRepo = New-TestRepo 'security-pass' 'config-security-pass.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $passRepo -RecordSpec *> $null
    Assert-Condition 'security config passes validation' ($LASTEXITCODE -eq 0)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $securityRunner -RepoRoot $passRepo -RecordSpec *> $null
    Assert-Condition 'passing security scan policy succeeds' ($LASTEXITCODE -eq 0)
    Assert-Condition 'security summary evidence exists' (Test-Path -LiteralPath (Join-Path $passRepo '.sdlc/evidence/security-scan.json'))
    $passSpec = Get-Content -LiteralPath (Join-Path $passRepo 'docs/spec.md') -Raw
    Assert-Condition 'passing security gate is recorded' ($passSpec -match '(?m)^gate_security_result:\s+PASS\s*$')
    Assert-Condition 'security review enables security gate' ($passSpec -match '(?m)^security_gate_enabled:\s+true\s*$')

    $highRepo = New-TestRepo 'security-high' 'config-security-high.yml'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $securityRunner -RepoRoot $highRepo -RecordSpec *> $null
    Assert-Condition 'blocking security finding fails policy' ($LASTEXITCODE -eq 1)
    Assert-Condition 'blocking security summary exists' (Test-Path -LiteralPath (Join-Path $highRepo '.sdlc/evidence/security-scan.json'))
    $highSummary = Get-Content -LiteralPath (Join-Path $highRepo '.sdlc/evidence/security-scan.json') -Raw
    Assert-Condition 'high severity is machine-readable' ($highSummary -match '"severity"\s*:\s*"high"')
    Assert-Condition 'blocking finding is machine-readable' ($highSummary -match '"blocking"\s*:\s*true')
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 2 regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 2 regression cases passed.'
