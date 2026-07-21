[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase7/config-measurement-valid.yml'
$extensionFixture = Join-Path $root 'tests/fixtures/phase7/config-extension-gates.yml'
$phaseFixture = Join-Path $root 'tests/fixtures/phase0/valid-readiness.md'
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
    Copy-Item (Join-Path $measurementRoot 'scripts/validate-measurement-snapshot.py') (Join-Path $repo 'scripts')
    Copy-Item (Join-Path $root 'tests/fixtures/phase7/write-measurement-snapshot.py') (Join-Path $repo 'scripts')
    Copy-Item (Join-Path $measurementRoot 'docs/*') (Join-Path $repo 'docs') -Force
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase7@example.test'
    & git -C $repo config user.name 'Phase 7 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'phase 7 fixture'
    return $repo
}

function New-TransitionRepo {
    param([string] $Name, [switch] $CodingState)
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github'), (Join-Path $repo 'docs'), (Join-Path $repo 'tests/fixtures/phase0/evidence'), (Join-Path $repo 'scripts') -Force | Out-Null
    Copy-Item $extensionFixture (Join-Path $repo '.github/sdlc-config.yml')
    Copy-Item $phaseFixture (Join-Path $repo 'docs/spec.md')
    Copy-Item (Join-Path $baseScripts '*') (Join-Path $repo 'scripts') -Force
    Set-Content -LiteralPath (Join-Path $repo 'tests/fixtures/phase0/evidence/gate.txt') -Value 'fixture gate' -NoNewline
    if ($CodingState) {
        $spec = [System.IO.File]::ReadAllText((Join-Path $repo 'docs/spec.md')).Replace('current_phase: TESTING', 'current_phase: CODING').Replace('last_transition_to: TESTING', 'last_transition_to: CODING').Replace('`TESTING`', '`CODING`').Replace('deployment_readiness_enabled: true', 'deployment_readiness_enabled: false')
    }
    else {
        $spec = [System.IO.File]::ReadAllText((Join-Path $repo 'docs/spec.md')).Replace('deployment_readiness_enabled: true', 'deployment_readiness_enabled: false')
    }
    $spec = $spec.Replace("`r`n", "`n")
    [System.IO.File]::WriteAllText((Join-Path $repo 'docs/spec.md'), $spec, (New-Object System.Text.UTF8Encoding($false)))
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase7@example.test'
    & git -C $repo config user.name 'Phase 7 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'phase 7 transition fixture'
    return $repo
}

function Add-GateRecords {
    param([string] $Repo, [string[]] $Names)
    $specPath = Join-Path $Repo 'docs/spec.md'
    $spec = [System.IO.File]::ReadAllText($specPath)
    $records = New-Object System.Collections.Generic.List[string]
    foreach ($name in $Names) {
        $evidence = ".sdlc/evidence/$name.txt"
        New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $Repo $evidence)) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Repo $evidence) -Value "$name passed" -NoNewline
        foreach ($line in @(
                "gate_${name}_command: fixture",
                "gate_${name}_commit_sha: fixture-commit",
                "gate_${name}_tree_digest: fixture-tree",
                "gate_${name}_timestamp: 2026-07-20T00:00:00Z",
                "gate_${name}_exit_code: 0",
                "gate_${name}_result: PASS",
                "gate_${name}_evidence: $evidence"
            )) { [void]$records.Add($line) }
    }
    $insert = ($records -join "`n") + "`n"
    $closingDelimiter = $spec.IndexOf("`n---")
    if ($closingDelimiter -lt 0) { throw 'Transition fixture front matter closing delimiter was not found.' }
    $spec = $spec.Insert($closingDelimiter + 1, $insert)
    [System.IO.File]::WriteAllText($specPath, $spec, (New-Object System.Text.UTF8Encoding($false)))
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
    Assert-Condition 'all measurement checks are machine-readable' ($summary.checks.Count -eq 4 -and @($summary.checks | Where-Object { $_.result -ne 'PASS' }).Count -eq 0 -and $summary.snapshot_validation_evidence)
    Assert-Condition 'all roadmap phases have both metric types' ($summary.metrics.phase_outcomes.Count -eq 8 -and $summary.metrics.phase_leading_indicators.Count -eq 8)
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'measurement gate is recorded' ($validSpec -match '(?m)^gate_measurement_result:\s+PASS\s*$' -and $validSpec -match '(?m)^measurement_enabled:\s+true\s*$')

    $failureRepo = New-TestRepo 'failure'
    $failureConfigPath = Join-Path $failureRepo '.github/sdlc-config.yml'
    $failureSnapshotScript = Join-Path $failureRepo 'scripts/write-measurement-snapshot.py'
    [System.IO.File]::WriteAllText($failureSnapshotScript, "raise SystemExit(9)`n", (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failureRepo 'scripts/run-measurement.ps1') -RepoRoot $failureRepo -RecordSpec *> $null
    Assert-Condition 'failed measurement task blocks gate' ($LASTEXITCODE -eq 1)
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRepo '.sdlc/evidence/measurement.json') -Raw
    $failureSpec = Get-Content -LiteralPath (Join-Path $failureRepo 'docs/spec.md') -Raw
    Assert-Condition 'failed measurement evidence is machine-readable' ($failureSummary -match '"result"\s*:\s*"FAIL"' -and $failureSpec -match '(?m)^gate_measurement_result:\s+FAIL\s*$')

    $invalidSnapshotRepo = New-TestRepo 'invalid-snapshot'
    $invalidSnapshotScript = Join-Path $invalidSnapshotRepo 'scripts/write-measurement-snapshot.py'
    $invalidSnapshotContent = [System.IO.File]::ReadAllText($invalidSnapshotScript).Replace('"privacy_review": "APPROVED"', '"privacy_review": "NOT_REVIEWED"')
    [System.IO.File]::WriteAllText($invalidSnapshotScript, $invalidSnapshotContent, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $invalidSnapshotRepo 'scripts/run-measurement.ps1') -RepoRoot $invalidSnapshotRepo -RecordSpec *> $null
    Assert-Condition 'invalid snapshot data blocks measurement gate' ($LASTEXITCODE -eq 1)
    $invalidSnapshotSummary = Get-Content -LiteralPath (Join-Path $invalidSnapshotRepo '.sdlc/evidence/measurement.json') -Raw
    Assert-Condition 'invalid snapshot evidence is machine-readable' ($invalidSnapshotSummary -match 'measurement_snapshot_schema' -and $invalidSnapshotSummary -match '"result"\s*:\s*"FAIL"')

    $invalidOwnerRepo = New-TestRepo 'invalid-owner'
    $invalidOwnerConfigPath = Join-Path $invalidOwnerRepo '.github/sdlc-config.yml'
    $invalidOwnerConfig = [System.IO.File]::ReadAllText($invalidOwnerConfigPath).Replace('owner: measurement-owner', 'owner: ""')
    [System.IO.File]::WriteAllText($invalidOwnerConfigPath, $invalidOwnerConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $invalidOwnerRepo 'scripts/validate-measurement.ps1') -RepoRoot $invalidOwnerRepo *> $null
    Assert-Condition 'missing measurement owner is rejected' ($LASTEXITCODE -eq 1)

    Remove-Item -LiteralPath (Join-Path $validRepo 'docs/measurement-privacy-review.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'missing privacy review is rejected' ($LASTEXITCODE -eq 1)

    $completionRepo = New-TransitionRepo 'completion-gates'
    $completionValidator = Join-Path $completionRepo 'scripts/check-phase.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $completionValidator -RepoRoot $completionRepo -SpecPath (Join-Path $completionRepo 'docs/spec.md') -Phase DONE -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'enabled completion gates block direct DONE without deployment' ($LASTEXITCODE -eq 2)
    Add-GateRecords -Repo $completionRepo -Names @('operational_readiness','ai_lifecycle','measurement')
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $completionValidator -RepoRoot $completionRepo -SpecPath (Join-Path $completionRepo 'docs/spec.md') -Phase DONE -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'enabled completion gates pass direct DONE without deployment' ($LASTEXITCODE -eq 0)

    $governanceRepo = New-TransitionRepo 'governance-gate' -CodingState
    $governanceValidator = Join-Path $governanceRepo 'scripts/check-phase.ps1'
    Add-GateRecords -Repo $governanceRepo -Names @('build')
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $governanceValidator -RepoRoot $governanceRepo -SpecPath (Join-Path $governanceRepo 'docs/spec.md') -Phase REVIEW -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'enabled AI governance blocks review without governance gate' ($LASTEXITCODE -eq 2)
    Add-GateRecords -Repo $governanceRepo -Names @('ai_governance')
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $governanceValidator -RepoRoot $governanceRepo -SpecPath (Join-Path $governanceRepo 'docs/spec.md') -Phase REVIEW -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-Condition 'enabled AI governance gate passes review' ($LASTEXITCODE -eq 0)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 7 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 7 regression cases passed.'