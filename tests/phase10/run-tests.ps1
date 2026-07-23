[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot = Join-Path $root 'tests/fixtures/phase10'
$baseScripts = Join-Path $root 'template/base/scripts'
$adapter = Join-Path $baseScripts 'verification.py'
$configValidator = Join-Path $baseScripts 'validate-sdlc-config.ps1'
$temporaryRoot = Join-Path $root "tests/.phase10-pwsh-$([guid]::NewGuid().ToString('N'))"
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
function Write-Utf8File {
    param([string] $Path, [string] $Content)
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
function New-AdapterRepo {
    param([string] $Name)
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo 'src'), (Join-Path $repo 'tests'), (Join-Path $repo '.sdlc/reports'), (Join-Path $repo '.sdlc/evidence') -Force | Out-Null
    Write-Utf8File (Join-Path $repo 'src/app.py') "def value():`n    return 1`n"
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase10@example.test'
    & git -C $repo config user.name 'Phase 10 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'verification base'
    Write-Utf8File (Join-Path $repo 'src/app.py') "def value():`n    return 2`n"
    return $repo
}
function Invoke-CoverageCase {
    param([string] $Label, [string] $Report, [int] $ExpectedExit, [string] $ExpectedResult)
    $repo = New-AdapterRepo -Name "adapter-$([guid]::NewGuid().ToString('N'))"
    Copy-Item (Join-Path $fixtureRoot $Report) (Join-Path $repo '.sdlc/reports/input.json')
    $arguments = @('coverage', '--repo-root', $repo, '--report-path', '.sdlc/reports/input.json', '--provider', 'generic-json', '--threshold', '80', '--commit-sha', 'fixture-commit', '--tree-digest', 'fixture-tree', '--output-path', '.sdlc/evidence/coverage.json')
    if ($Label -eq 'excluded paths produce NOT_APPLICABLE') {
        Remove-Item -LiteralPath (Join-Path $repo 'src/app.py')
        Write-Utf8File (Join-Path $repo 'tests/test_app.py') "def test_value():`n    return 2`n"
        & git -C $repo add --all
        & git -C $repo commit --quiet -m 'test base'
        Write-Utf8File (Join-Path $repo 'tests/test_app.py') "def test_value():`n    return 3`n"
        $arguments += @('--exclude', 'tests/**')
    }
    elseif ($Label -eq 'no executable changes produce NOT_APPLICABLE') {
        Write-Utf8File (Join-Path $repo 'src/app.py') "def value():`n    return 1`n"
        Write-Utf8File (Join-Path $repo 'README.md') "base`n"
        & git -C $repo add README.md
        & git -C $repo commit --quiet -m 'readme base'
        Write-Utf8File (Join-Path $repo 'README.md') "changed`n"
    }
    & python $adapter @arguments *> $null
    Assert-ExitCode $Label $LASTEXITCODE $ExpectedExit
    $record = Get-Content -LiteralPath (Join-Path $repo '.sdlc/evidence/coverage.json') -Raw
    Assert-Condition "$Label records $ExpectedResult" ($record -match ('"result"\s*:\s*"' + [regex]::Escape($ExpectedResult) + '"'))
}
function Invoke-MutationCase {
    param([string] $Label, [string] $Report, [int] $ExpectedExit, [string] $ExpectedResult, [int] $Threshold)
    $repo = New-AdapterRepo -Name "mutation-$([guid]::NewGuid().ToString('N'))"
    Copy-Item (Join-Path $fixtureRoot $Report) (Join-Path $repo '.sdlc/reports/input.json')
    $arguments = @('mutation', '--repo-root', $repo, '--report-path', '.sdlc/reports/input.json', '--provider', 'generic-json', '--threshold', [string]$Threshold, '--commit-sha', 'fixture-commit', '--tree-digest', 'fixture-tree', '--output-path', '.sdlc/evidence/mutation.json')
    & python $adapter @arguments *> $null
    Assert-ExitCode $Label $LASTEXITCODE $ExpectedExit
    $record = Get-Content -LiteralPath (Join-Path $repo '.sdlc/evidence/mutation.json') -Raw
    Assert-Condition "$Label records $ExpectedResult" ($record -match ('"result"\s*:\s*"' + [regex]::Escape($ExpectedResult) + '"'))
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    Invoke-CoverageCase 'coverage passes' 'coverage-pass.json' 0 'PASS'
    Invoke-CoverageCase 'low changed-line coverage fails' 'coverage-low.json' 1 'FAIL'
    Invoke-CoverageCase 'stale coverage report fails' 'coverage-stale.json' 1 'FAIL'
    Invoke-CoverageCase 'changed source missing from coverage report fails' 'coverage-missing-file.json' 1 'FAIL'
    $missingRepo = New-AdapterRepo -Name 'missing-report'
    $missingArguments = @('coverage', '--repo-root', $missingRepo, '--report-path', '.sdlc/reports/does-not-exist.json', '--provider', 'generic-json', '--threshold', '80', '--commit-sha', 'fixture-commit', '--tree-digest', 'fixture-tree', '--output-path', '.sdlc/evidence/coverage.json')
    & python $adapter @missingArguments *> $null
    Assert-ExitCode 'missing coverage report is rejected' $LASTEXITCODE 1
    $missingRecord = Get-Content -LiteralPath (Join-Path $missingRepo '.sdlc/evidence/coverage.json') -Raw
    Assert-Condition 'missing report evidence is machine-readable' ($missingRecord -match '"result"\s*:\s*"FAIL"')
    Invoke-CoverageCase 'excluded paths produce NOT_APPLICABLE' 'coverage-excluded.json' 0 'NOT_APPLICABLE'
    Invoke-CoverageCase 'no executable changes produce NOT_APPLICABLE' 'coverage-pass.json' 0 'NOT_APPLICABLE'
    Invoke-MutationCase 'mutation threshold passes' 'mutation-pass.json' 0 'PASS' 50
    Invoke-MutationCase 'mutation threshold failure blocks' 'mutation-fail.json' 1 'FAIL' 80
    Invoke-MutationCase 'undispositioned survivor blocks' 'mutation-no-disposition.json' 1 'FAIL' 50

    $runnerRepo = Join-Path $temporaryRoot 'runner'
    New-Item -ItemType Directory -Path (Join-Path $runnerRepo '.github'), (Join-Path $runnerRepo 'docs'), (Join-Path $runnerRepo 'tests'), (Join-Path $runnerRepo 'src'), (Join-Path $runnerRepo 'scripts') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot 'config-verification-valid.yml') (Join-Path $runnerRepo '.github/sdlc-config.yml')
    Copy-Item (Join-Path $root 'template/base/docs/spec.md') (Join-Path $runnerRepo 'docs/spec.md')
    Copy-Item (Join-Path $fixtureRoot 'write-coverage-report.py') (Join-Path $runnerRepo 'tests/write-coverage-report.py')
    Copy-Item (Join-Path $baseScripts 'feature-context.ps1'), (Join-Path $baseScripts 'validate-sdlc-config.ps1'), (Join-Path $baseScripts 'run-sdlc-task.ps1'), (Join-Path $baseScripts 'task-graph.py'), (Join-Path $baseScripts 'verification.py') (Join-Path $runnerRepo 'scripts')
    Write-Utf8File (Join-Path $runnerRepo 'src/app.py') "def value():`n    return 1`n"
    & git -C $runnerRepo init --quiet
    & git -C $runnerRepo config user.email 'phase10@example.test'
    & git -C $runnerRepo config user.name 'Phase 10 Tests'
    & git -C $runnerRepo add .
    & git -C $runnerRepo commit --quiet -m 'runner base'
    Write-Utf8File (Join-Path $runnerRepo 'src/app.py') "def value():`n    return 2`n"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $runnerRepo 'scripts/run-sdlc-task.ps1') -Task all -RepoRoot $runnerRepo -ConfigPath (Join-Path $runnerRepo '.github/sdlc-config.yml') -RecordSpec *> $null
    Assert-ExitCode 'runner executes coverage adapter' $LASTEXITCODE 0
    $coverageEvidence = Get-Content -LiteralPath (Join-Path $runnerRepo '.sdlc/evidence/coverage.json') -Raw
    Assert-Condition 'runner writes coverage summary' ((Test-Path -LiteralPath (Join-Path $runnerRepo '.sdlc/evidence/coverage.json')) -and $coverageEvidence -match '"result"\s*:\s*"PASS"')
    Assert-Condition 'runner keeps task record separate' (Test-Path -LiteralPath (Join-Path $runnerRepo '.sdlc/evidence/coverage-task.json'))
    $runnerSpec = Get-Content -LiteralPath (Join-Path $runnerRepo 'docs/spec.md') -Raw
    Assert-Condition 'runner records machine-readable gate evidence' ($runnerSpec -match 'gate_coverage_evidence:\s+"\.sdlc/evidence/coverage\.json"')

    $invalidRepo = Join-Path $temporaryRoot 'invalid-config'
    Copy-Item $runnerRepo $invalidRepo -Recurse
    $invalidConfigPath = Join-Path $invalidRepo '.github/sdlc-config.yml'
    $invalidConfig = (Get-Content -LiteralPath $invalidConfigPath -Raw).Replace('coverage_changed_line_threshold: 80', 'coverage_changed_line_threshold: 101')
    Write-Utf8File $invalidConfigPath $invalidConfig
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $invalidRepo -ConfigPath $invalidConfigPath *> $null
    Assert-ExitCode 'threshold outside 0..100 fails config validation' $LASTEXITCODE 1
    $invalidConfig = $invalidConfig.Replace('coverage_changed_line_threshold: 101', 'coverage_changed_line_threshold: 80').Replace('risk_profile: low', 'risk_profile: high').Replace('coverage_enabled: true', 'coverage_enabled: false').Replace('coverage_required_risk_profiles: [low]', 'coverage_required_risk_profiles: [high]')
    Write-Utf8File $invalidConfigPath $invalidConfig
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator -RepoRoot $invalidRepo -ConfigPath $invalidConfigPath *> $null
    Assert-ExitCode 'required high-risk coverage cannot be disabled' $LASTEXITCODE 1

    $graphRepo = Join-Path $temporaryRoot 'graph'
    New-Item -ItemType Directory -Path (Join-Path $graphRepo '.github'), (Join-Path $graphRepo 'docs/specs/alpha'), (Join-Path $graphRepo 'scripts') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot 'config-verification-valid.yml') (Join-Path $graphRepo '.github/sdlc-config.yml')
    Copy-Item (Join-Path $fixtureRoot 'tasks-coverage-only.json') (Join-Path $graphRepo 'docs/specs/alpha/tasks.json')
    Copy-Item (Join-Path $root 'tests/fixtures/phase9/feature-task-spec.md') (Join-Path $graphRepo 'docs/specs/alpha/spec.md')
    Copy-Item (Join-Path $baseScripts 'task-graph.py') (Join-Path $graphRepo 'scripts/task-graph.py')
    $graphOutput = & python (Join-Path $graphRepo 'scripts/task-graph.py') validate --repo-root $graphRepo --feature-id alpha --commit-sha fixture-commit --tree-digest fixture-tree 2>&1
    Assert-ExitCode 'coverage-only task graph is rejected' $LASTEXITCODE 2
    Assert-Condition 'coverage-only rejection explains next verification' (($graphOutput -join "`n") -match 'cannot use coverage or mutation as its only verification')

    $phaseRepo = Join-Path $temporaryRoot 'phase-gate'
    New-Item -ItemType Directory -Path (Join-Path $phaseRepo '.github'), (Join-Path $phaseRepo 'docs'), (Join-Path $phaseRepo 'tests/fixtures/phase0/evidence'), (Join-Path $phaseRepo 'scripts'), (Join-Path $phaseRepo '.sdlc/evidence') -Force | Out-Null
    Copy-Item (Join-Path $fixtureRoot 'config-verification-valid.yml') (Join-Path $phaseRepo '.github/sdlc-config.yml')
    $phaseSpec = (Get-Content (Join-Path $root 'tests/fixtures/phase0/valid-readiness.md') -Raw).Replace('deployment_readiness_enabled: true', 'deployment_readiness_enabled: false') + "`n## Test Strategy`nUnit verification covers the fixture behavior.`n`n## Acceptance Test Mapping`nEvery acceptance criterion maps to the fixture test.`n"
    Write-Utf8File (Join-Path $phaseRepo 'docs/spec.md') $phaseSpec
    Copy-Item (Join-Path $baseScripts 'feature-context.ps1'), (Join-Path $baseScripts 'check-phase.ps1'), (Join-Path $baseScripts 'verification.py') (Join-Path $phaseRepo 'scripts')
    Set-Content -LiteralPath (Join-Path $phaseRepo 'tests/fixtures/phase0/evidence/gate.txt') -Value 'gate'
    & git -C $phaseRepo init --quiet
    & git -C $phaseRepo config user.email 'phase10@example.test'
    & git -C $phaseRepo config user.name 'Phase 10 Tests'
    & git -C $phaseRepo add .
    & git -C $phaseRepo commit --quiet -m 'phase gate base'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $phaseRepo 'scripts/check-phase.ps1') -RepoRoot $phaseRepo -Phase DONE -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'required coverage gate blocks completion when absent' $LASTEXITCODE 2
    New-Item -ItemType Directory -Path (Join-Path $phaseRepo '.sdlc/reports') -Force | Out-Null
    Write-Utf8File (Join-Path $phaseRepo '.sdlc/reports/coverage.json') '{"schema":1,"commit_sha":"fixture-commit","tree_digest":"fixture-tree","files":{}}'
    & python (Join-Path $phaseRepo 'scripts/verification.py') coverage --repo-root $phaseRepo --report-path .sdlc/reports/coverage.json --provider generic-json --threshold 80 --commit-sha fixture-commit --tree-digest fixture-tree --output-path .sdlc/evidence/coverage.json *> $null
    $coverageRecords = "`ngate_build_command: fixture build`ngate_build_commit_sha: fixture-commit`ngate_build_tree_digest: fixture-tree`ngate_build_timestamp: 2026-07-22T00:00:00Z`ngate_build_exit_code: 0`ngate_build_result: PASS`ngate_build_evidence: tests/fixtures/phase0/evidence/gate.txt`ngate_coverage_command: fixture coverage`ngate_coverage_commit_sha: fixture-commit`ngate_coverage_tree_digest: fixture-tree`ngate_coverage_timestamp: 2026-07-22T00:00:00Z`ngate_coverage_exit_code: 0`ngate_coverage_result: PASS`ngate_coverage_evidence: .sdlc/evidence/coverage.json`n"
    $phaseSpec = [System.IO.File]::ReadAllText((Join-Path $phaseRepo 'docs/spec.md'))
    $closing = $phaseSpec.IndexOf("`n---")
    $phaseSpec = $phaseSpec.Insert($closing + 1, $coverageRecords)
    Write-Utf8File (Join-Path $phaseRepo 'docs/spec.md') $phaseSpec
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $phaseRepo 'scripts/check-phase.ps1') -RepoRoot $phaseRepo -Phase DONE -CommitSha fixture-commit -TreeDigest fixture-tree *> $null
    Assert-ExitCode 'current coverage gate permits completion' $LASTEXITCODE 0
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { throw "$failures Phase 10 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 10 regression cases passed.'