[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixtureRoot = Join-Path $root 'tests/fixtures/phase9'
$taskGraph = Join-Path $root 'template/base/scripts/task-graph.py'
$scopeAudit = Join-Path $root 'template/base/scripts/scope-audit.ps1'
$taskRunner = Join-Path $root 'template/base/scripts/run-sdlc-task.ps1'
$baseScripts = Join-Path $root 'template/base/scripts'
$configFixture = Join-Path $root 'tests/fixtures/phase1/config-valid.yml'
$temporaryRoot = Join-Path $root "tests/.phase9-pwsh-$([guid]::NewGuid().ToString('N'))"
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
function New-GraphRepo {
    param([string] $Name, [string] $TaskFixture)
    $repo = Join-Path $temporaryRoot $Name
    New-Item -ItemType Directory -Path (Join-Path $repo '.github'), (Join-Path $repo 'docs/specs/alpha'), (Join-Path $repo 'scripts'), (Join-Path $repo 'src'), (Join-Path $repo 'tests'), (Join-Path $repo '.sdlc/evidence/alpha') -Force | Out-Null
    Copy-Item $configFixture (Join-Path $repo '.github/sdlc-config.yml')
    Copy-Item (Join-Path $fixtureRoot 'feature-task-spec.md') (Join-Path $repo 'docs/specs/alpha/spec.md')
    Copy-Item (Join-Path $fixtureRoot $TaskFixture) (Join-Path $repo 'docs/specs/alpha/tasks.json')
    Copy-Item (Join-Path $fixtureRoot 'evidence/alpha/TASK-001.json') (Join-Path $repo '.sdlc/evidence/alpha/TASK-001.json')
    Copy-Item (Join-Path $fixtureRoot 'evidence/alpha/TASK-001-failed.json') (Join-Path $repo '.sdlc/evidence/alpha/TASK-001-failed.json')
    Copy-Item (Join-Path $baseScripts 'feature-context.ps1') (Join-Path $repo 'scripts/feature-context.ps1')
    Copy-Item (Join-Path $baseScripts 'task-graph.py') (Join-Path $repo 'scripts/task-graph.py')
    Copy-Item (Join-Path $baseScripts 'validate-sdlc-config.ps1') (Join-Path $repo 'scripts/validate-sdlc-config.ps1')
    Copy-Item $taskRunner (Join-Path $repo 'scripts/run-sdlc-task.ps1')
    Set-Content -LiteralPath (Join-Path $repo 'src/alpha.txt') -Value 'alpha' -NoNewline
    Set-Content -LiteralPath (Join-Path $repo 'tests/alpha.txt') -Value 'test' -NoNewline
    return $repo
}
function Invoke-GraphCase {
    param([string] $Label, [string] $Fixture, [int] $Expected, [string] $TargetPhase = '')
    $repo = New-GraphRepo -Name ([guid]::NewGuid().ToString('N')) -TaskFixture $Fixture
    $args = @($taskGraph, 'validate', '--repo-root', $repo, '--feature-id', 'alpha', '--commit-sha', 'fixture-commit', '--tree-digest', 'fixture-tree')
    if ($TargetPhase) { $args += @('--target-phase', $TargetPhase) }
    & python @args *> $null
    Assert-ExitCode $Label $LASTEXITCODE $Expected
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    Invoke-GraphCase 'valid DAG passes' 'tasks-valid.json' 0
    $summaryRepo = New-GraphRepo -Name 'summary' -TaskFixture 'tasks-valid.json'
    $summaryOutput = & python $taskGraph summary --repo-root $summaryRepo --feature-id alpha --commit-sha fixture-commit --tree-digest fixture-tree 2>&1
    Assert-ExitCode 'task graph summary succeeds' $LASTEXITCODE 0
    Assert-Condition 'task graph summary shows ready task' (($summaryOutput -join "`n") -match 'READY:\s*TASK-002')
    Invoke-GraphCase 'duplicate task IDs fail' 'tasks-duplicate.json' 2
    Invoke-GraphCase 'dependency cycle fails' 'tasks-cycle.json' 2
    Invoke-GraphCase 'missing acceptance mapping fails' 'tasks-missing-mapping.json' 2
    Invoke-GraphCase 'DONE task without evidence fails' 'tasks-missing-evidence.json' 2
    Invoke-GraphCase 'stale task evidence fails' 'tasks-stale-evidence.json' 2
    Invoke-GraphCase 'failed task evidence fails with handoff' 'tasks-failed-evidence.json' 2
    Invoke-GraphCase 'approved blocked task passes validation' 'tasks-blocked.json' 0 'REVIEW'
    Invoke-GraphCase 'unsafe task scope fails' 'tasks-unsafe-scope.json' 2
    Invoke-GraphCase 'incomplete graph blocks REVIEW' 'tasks-valid.json' 2 'REVIEW'
    Invoke-GraphCase 'incomplete release graph blocks DONE' 'tasks-valid.json' 2 'DONE'

    $scopeRepo = New-GraphRepo -Name 'scope' -TaskFixture 'tasks-blocked.json'
    & git -C $scopeRepo init --quiet
    & git -C $scopeRepo config user.email 'phase9@example.test'
    & git -C $scopeRepo config user.name 'Phase 9 Tests'
    & git -C $scopeRepo add .
    & git -C $scopeRepo commit --quiet -m 'task scope base'
    Set-Content -LiteralPath (Join-Path $scopeRepo 'src/alpha.txt') -Value 'changed' -NoNewline
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scopeAudit -RepoRoot $scopeRepo -FeatureId alpha *> $null
    Assert-ExitCode 'task-derived scope passes audit' $LASTEXITCODE 0

    $recordRepo = New-GraphRepo -Name 'record' -TaskFixture 'tasks-valid.json'
    $taskOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskRunner -Task test -TaskId TASK-002 -RepoRoot $recordRepo -ConfigPath (Join-Path $recordRepo '.github/sdlc-config.yml') -FeatureId alpha 2>&1
    if ($LASTEXITCODE -ne 0) { $taskOutput | ForEach-Object { Write-Host "[TASK_RUNNER] $_" } }
    Assert-ExitCode 'task runner records graph evidence' $LASTEXITCODE 0
    $recorded = Get-Content -LiteralPath (Join-Path $recordRepo 'docs/specs/alpha/tasks.json') -Raw | ConvertFrom-Json
    $taskTwo = @($recorded.tasks | Where-Object { $_.id -eq 'TASK-002' })[0]
    Assert-Condition 'recorded evidence targets TASK-002' (@($taskTwo.evidence).Count -eq 1 -and $taskTwo.evidence[0].task -eq 'TASK-002')
    Assert-Condition 'recorded evidence preserves verification task' ((Get-Content -LiteralPath (Join-Path $recordRepo '.sdlc/evidence/alpha/test.json') -Raw) -match '"verification_task"\s*:\s*"test"')
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { throw "$failures Phase 9 regression case(s) failed." }
Write-Host '[PASS] All Phase 9 PowerShell regression cases passed.'
