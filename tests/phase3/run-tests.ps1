[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase3/config-release-valid.yml'
$baseScripts = Join-Path $root 'template/base/scripts'
$releaseScripts = Join-Path $root 'template/extensions/release-assurance/scripts'
$validateRelease = Join-Path $releaseScripts 'validate-release-config.ps1'
$prepareRelease = Join-Path $releaseScripts 'prepare-release.ps1'
$verifyRelease = Join-Path $releaseScripts 'verify-release.ps1'
$temp = Join-Path $root "tests/.phase3-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0
function Assert-Condition { param([string] $Label, [bool] $Condition); if ($Condition) { Write-Host "[PASS] $Label" } else { Write-Host "[FAIL] $Label"; $script:failures += 1 } }
New-Item -ItemType Directory -Path (Join-Path $temp '.github'),(Join-Path $temp 'docs'),(Join-Path $temp 'tests'),(Join-Path $temp 'scripts'),(Join-Path $temp '.sdlc/release') -Force | Out-Null
try {
    Copy-Item $fixture (Join-Path $temp '.github/sdlc-config.yml')
    Copy-Item (Join-Path $root 'template/base/docs/spec.md') (Join-Path $temp 'docs/spec.md')
    Copy-Item (Join-Path $baseScripts '*') (Join-Path $temp 'scripts') -Force
    Set-Content -LiteralPath (Join-Path $temp '.sdlc/release/RELEASE_NOTES.md') -Value 'release fixture'
    Set-Content -LiteralPath (Join-Path $temp '.sdlc/release/ROLLBACK.md') -Value 'rollback fixture'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validateRelease -RepoRoot $temp *> $null
    Assert-Condition 'release config validates' ($LASTEXITCODE -eq 0)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $prepareRelease -RepoRoot $temp -RecordSpec *> $null
    Assert-Condition 'release preparation succeeds' ($LASTEXITCODE -eq 0)
    Assert-Condition 'release manifest exists' (Test-Path -LiteralPath (Join-Path $temp '.sdlc/release/release-manifest.json'))
    Assert-Condition 'provenance exists' (Test-Path -LiteralPath (Join-Path $temp '.sdlc/release/provenance.json'))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRelease -RepoRoot $temp *> $null
    Assert-Condition 'release verification succeeds' ($LASTEXITCODE -eq 0)

    Add-Content -LiteralPath (Join-Path $temp '.sdlc/release/artifact.tar.gz') -Value 'tampered'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $verifyRelease -RepoRoot $temp *> $null
    Assert-Condition 'artifact tampering is rejected' ($LASTEXITCODE -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
if ($failures -gt 0) { throw "$failures Phase 3 regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 3 regression cases passed.'
