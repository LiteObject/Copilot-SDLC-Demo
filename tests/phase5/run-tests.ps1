[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$fixture = Join-Path $root 'tests/fixtures/phase5/config-ai-governance-valid.yml'
$baseScripts = Join-Path $root 'template/base/scripts'
$governanceRoot = Join-Path $root 'template/extensions/ai-governance'
$temporaryRoot = Join-Path $root "tests/.phase5-pwsh-$([guid]::NewGuid().ToString('N'))"
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
    Copy-Item (Join-Path $governanceRoot 'scripts/*.ps1') (Join-Path $repo 'scripts') -Force
    Copy-Item (Join-Path $governanceRoot 'docs/*') (Join-Path $repo 'docs') -Recurse -Force
    & git -C $repo init --quiet
    & git -C $repo config user.email 'phase5@example.test'
    & git -C $repo config user.name 'Phase 5 Tests'
    & git -C $repo add .
    & git -C $repo commit --quiet -m 'phase 5 fixture'
    return $repo
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $validRepo = New-TestRepo 'valid'
    $validator = Join-Path $validRepo 'scripts/validate-ai-governance.ps1'
    $ledger = Join-Path $validRepo 'scripts/record-ai-change.ps1'
    $runner = Join-Path $validRepo 'scripts/run-ai-governance.ps1'

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'AI governance config validates' ($LASTEXITCODE -eq 0)
    Assert-Condition 'governance config evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/ai-governance-config-validation.json'))

    $approvedLedgerArgs = @{
        RepoRoot = $validRepo
        TaskId = 'TASK-42'
        AgentRole = 'developer'
        Provider = 'github'
        Model = 'GPT-5'
        ModelVersion = '5.0'
        Tenant = 'default-tenant'
        Repository = 'this-repository'
        DataClassification = 'internal'
        InstructionVersion = 'instructions-v1'
        Phase = 'CODING'
        SandboxReference = 'worktree-42'
        ToolGrant = [string[]]@('read','search')
        ToolCall = [string[]]@('read docs/spec.md','edit src/app.py')
        ChangedFile = [string[]]@('src/app.py')
        Validation = [string[]]@('build=PASS','test=PASS')
        HumanApproval = [string[]]@('reviewer|APPROVED|APR-42')
        FinalDisposition = 'APPROVED'
    }
    & $ledger @approvedLedgerArgs *> $null
    Assert-Condition 'approved AI change is recorded' ($LASTEXITCODE -eq 0)
    $ledgerPath = Join-Path $validRepo '.sdlc/evidence/ai-change-ledger.jsonl'
    Assert-Condition 'change ledger exists' (Test-Path -LiteralPath $ledgerPath)
    $ledgerContent = Get-Content -LiteralPath $ledgerPath -Raw
    Assert-Condition 'ledger is machine-readable' ($ledgerContent -match '"kind":"sdlc-ai-change-ledger"' -and $ledgerContent -match '"final_disposition":"APPROVED"' -and $ledgerContent -match '"phase":"CODING"')

    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -RepoRoot $validRepo -RecordSpec *> $null
    Assert-Condition 'agent evaluation passes' ($LASTEXITCODE -eq 0)
    Assert-Condition 'evaluation evidence exists' (Test-Path -LiteralPath (Join-Path $validRepo '.sdlc/evidence/agent-evaluation.json'))
    $validSpec = Get-Content -LiteralPath (Join-Path $validRepo 'docs/spec.md') -Raw
    Assert-Condition 'AI governance gate is recorded' ($validSpec -match '(?m)^gate_ai_governance_result:\s+PASS\s*$')

    $beforeLines = @(Get-Content -LiteralPath $ledgerPath).Count
    $rejectedLedgerArgs = @{
        RepoRoot = $validRepo
        TaskId = 'TASK-43'
        AgentRole = 'developer'
        Provider = 'github'
        Model = 'GPT-5'
        ModelVersion = '5.0'
        Tenant = 'default-tenant'
        Repository = 'this-repository'
        DataClassification = 'internal'
        InstructionVersion = 'instructions-v1'
        Phase = 'CODING'
        SandboxReference = 'worktree-43'
        ToolGrant = [string[]]@('execute')
        ToolCall = [string[]]@('execute deploy')
        ChangedFile = [string[]]@('src/app.py')
        Validation = [string[]]@('build=PASS')
        HumanApproval = [string[]]@('reviewer|APPROVED|APR-43')
        FinalDisposition = 'APPROVED'
    }
    & $ledger @rejectedLedgerArgs *> $null
    Assert-Condition 'unapproved tool grant is rejected' ($LASTEXITCODE -eq 1)
    $afterLines = @(Get-Content -LiteralPath $ledgerPath).Count
    Assert-Condition 'rejected ledger entry is not appended' ($beforeLines -eq $afterLines)

    $failureRepo = New-TestRepo 'failure'
    $failureConfigPath = Join-Path $failureRepo '.github/sdlc-config.yml'
    $failureConfig = [System.IO.File]::ReadAllText($failureConfigPath).Replace('printf evaluation-pass', 'exit 9')
    [System.IO.File]::WriteAllText($failureConfigPath, $failureConfig, (New-Object System.Text.UTF8Encoding($false)))
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $failureRepo 'scripts/run-ai-governance.ps1') -RepoRoot $failureRepo -RecordSpec *> $null
    Assert-Condition 'failed agent evaluation blocks governance' ($LASTEXITCODE -eq 1)
    $failureSummary = Get-Content -LiteralPath (Join-Path $failureRepo '.sdlc/evidence/agent-evaluation.json') -Raw
    $failureSpec = Get-Content -LiteralPath (Join-Path $failureRepo 'docs/spec.md') -Raw
    Assert-Condition 'failed evaluation is machine-readable' ($failureSummary -match '"result"\s*:\s*"FAIL"' -and $failureSpec -match '(?m)^gate_ai_governance_result:\s+FAIL\s*$')

    Remove-Item -LiteralPath (Join-Path $validRepo 'docs/agent-permissions.md') -Force
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -RepoRoot $validRepo *> $null
    Assert-Condition 'missing governance document is rejected' ($LASTEXITCODE -eq 1)
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

if ($failures -gt 0) { throw "$failures Phase 5 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 5 regression cases passed.'