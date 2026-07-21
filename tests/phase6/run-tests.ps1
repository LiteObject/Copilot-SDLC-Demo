[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase6/config-ai-lifecycle-valid.yml'
$baseScripts = Join-Path $root 'template/base/scripts'
$lifecycleRoot = Join-Path $root 'template/extensions/ai-lifecycle'
$temporaryRoot = Join-Path $root "tests/.phase6-pwsh-$([guid]::NewGuid().ToString('N'))"
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
    Copy-Item (Join-Path $lifecycleRoot 'scripts/*.ps1') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $lifecycleRoot 'docs/*') (Join-Path $repo 'docs') -Recurse -Force
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase6@example.test'
    & git -C $repo config user.name 'Phase 6 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'phase 6 fixture'
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $validRepo = New-TestRepo 'valid'
    $validator = Join-Path $validRepo 'scripts/validate-ai-lifecycle.ps1'
    $runner = Join-Path $validRepo 'scripts/run-ai-lifecycle.ps1'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'AI lifecycle config validates' ($LASTEXITCODE -eq 0)
    Assert-Condition 'lifecycle config evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/ai-lifecycle-config-validation.json'))

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $validRepo -RecordSpec *> $null
    Assert-Condition 'AI lifecycle checks pass' ($LASTEXITCODE -eq 0)
    Assert-Condition 'lifecycle evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/ai-lifecycle.json'))
    Assert-Condition 'configured evaluation report exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/ai-evaluation.json'))
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'AI lifecycle gate is recorded' ($validSpec -match '(?m)^gate_ai_lifecycle_result:\s+PASS\s*$' -and $validSpec -match '(?m)^ai_lifecycle_enabled:\s+true\s*$')
    $validSummary = Get-Content -LiteralPath (Join-Path $validRepo '.sdlc/evidence/ai-lifecycle.json') -Raw
    Assert-Condition 'all lifecycle checks are machine-readable' ($validSummary -match 'ai_evaluation' -and $validSummary -match 'ai_red_team' -and $validSummary -match 'ai_production_exercise' -and $validSummary -match '"result"\s*:\s*"PASS"')

    $failureRepo = New-TestRepo 'failure'
    $failureConfigPath = Join-Path $failureRepo '.github/sdlc-config.yml'
    $failureConfig = [System.IO.File]::ReadAllText($failureConfigPath).Replace('printf ai-evaluation-pass', 'exit 9')
    [System.IO.File]::WriteAllText($failureConfigPath, $failureConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failureRepo 'scripts/run-ai-lifecycle.ps1') -RepoRoot $failureRepo -RecordSpec *> $null
    Assert-Condition 'failed evaluation blocks lifecycle gate' ($LASTEXITCODE -eq 1)
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRepo '.sdlc/evidence/ai-lifecycle.json') -Raw
    $failureSpec = Get-Content -LiteralPath (Join-Path $failureRepo 'docs/spec.md') -Raw
    Assert-Condition 'failed lifecycle evidence is machine-readable' ($failureSummary -match '"result"\s*:\s*"FAIL"' -and $failureSpec -match '(?m)^gate_ai_lifecycle_result:\s+FAIL\s*$')

    Remove-Item -LiteralPath (Join-Path $validRepo 'docs/ai-runtime-controls.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'missing runtime controls document is rejected' ($LASTEXITCODE -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 6 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 6 regression cases passed.'
