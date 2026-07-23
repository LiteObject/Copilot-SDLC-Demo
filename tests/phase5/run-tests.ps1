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
    Copy-Item (Join-Path $governanceRoot 'scripts/autonomy-policy.py') (Join-Path $repo 'scripts') -Force
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
    $autonomy = Join-Path $validRepo 'scripts/check-autonomy.ps1'

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
        Action = [string[]]@('local_validation')
        AutonomyDecisionId = 'AUTO-42'
        AutonomyDecision = 'ALLOW'
        AutonomyEvidence = '.sdlc/evidence/autonomy-decisions.jsonl'
        ApprovalId = 'APR-42'
        FinalDisposition = 'APPROVED'
    }
    & $ledger @approvedLedgerArgs *> $null
    Assert-Condition 'approved AI change is recorded' ($LASTEXITCODE -eq 0)
    $ledgerPath = Join-Path $validRepo '.sdlc/evidence/ai-change-ledger.jsonl'
    Assert-Condition 'change ledger exists' (Test-Path -LiteralPath $ledgerPath)
    $ledgerContent = Get-Content -LiteralPath $ledgerPath -Raw
    Assert-Condition 'ledger is machine-readable' ($ledgerContent -match '"kind":"sdlc-ai-change-ledger"' -and $ledgerContent -match '"final_disposition":"APPROVED"' -and $ledgerContent -match '"phase":"CODING"')
    Assert-Condition 'ledger links autonomy decision' ($ledgerContent -match '"autonomy_decision_id":"AUTO-42"' -and $ledgerContent -match '"autonomy_decision":"ALLOW"' -and $ledgerContent -match '"autonomy_approval_id":"APR-42"')

    $editOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action edit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $editDecision = ($editOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'L1 edit is allowed within bounds' ($LASTEXITCODE -eq 0 -and $editDecision.decision -eq 'ALLOW' -and $editDecision.reason_code -eq 'ALLOWED')

    $readOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action read -Phase CODING -Now '2099-01-01T00:00:00Z' 2>$null
    $readDecision = ($readOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'safe read remains available' ($LASTEXITCODE -eq 0 -and $readDecision.decision -eq 'ALLOW')

    $restrictedOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action commit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $restrictedExit = $LASTEXITCODE
    $restrictedDecision = ($restrictedOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'restricted action is denied without approval' ($restrictedExit -eq 1 -and $restrictedDecision.reason_code -eq 'RESTRICTED_ACTION_APPROVAL_REQUIRED')

    $approval = 'APR-43|reviewer|commit|phase=CODING;files=src/app.py|v1|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-43-evidence'
    $approvedOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action commit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Approval $approval -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $approvedDecision = ($approvedOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'scoped approval permits restricted action' ($LASTEXITCODE -eq 0 -and $approvedDecision.decision -eq 'ALLOW' -and $approvedDecision.approval_id -eq 'APR-43')

    $expiredApproval = 'APR-44|reviewer|commit|phase=CODING;files=src/app.py|v1|2098-12-31T20:00:00Z|2098-12-31T21:00:00Z|APPROVED|APR-44-evidence'
    $expiredOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action commit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Approval $expiredApproval -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $expiredDecision = ($expiredOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'expired approval is denied' ($LASTEXITCODE -eq 1 -and $expiredDecision.reason_code -eq 'APPROVAL_EXPIRED')

    $scopeApproval = 'APR-45|reviewer|commit|phase=CODING;files=src/other.py|v1|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-45-evidence'
    $scopeOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action commit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Approval $scopeApproval -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $scopeDecision = ($scopeOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'out-of-scope approval is denied' ($LASTEXITCODE -eq 1 -and $scopeDecision.reason_code -eq 'APPROVAL_SCOPE_MISMATCH')

    $iterationOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action edit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Iteration 4 -Now '2099-01-01T00:00:00Z' 2>$null
    $iterationDecision = ($iterationOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'iteration exhaustion escalates' ($LASTEXITCODE -eq 1 -and $iterationDecision.reason_code -eq 'ITERATION_LIMIT' -and $iterationDecision.escalation_required)
    $widenOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action local_validation -Phase CODING -ChangedFile src/app.py -ToolGrant execute -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $widenDecision = ($widenOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'permission widening is denied' ($LASTEXITCODE -eq 1 -and $widenDecision.reason_code -eq 'TOOL_GRANT_NOT_ALLOWLISTED')

    $expiredPolicyRepo = New-TestRepo 'expired-policy'
    $expiredPolicyConfig = Join-Path $expiredPolicyRepo '.github/sdlc-config.yml'
    $expiredPolicyText = [System.IO.File]::ReadAllText($expiredPolicyConfig).Replace('2099-12-31T23:59:59Z', '2000-01-01T00:00:00Z')
    [System.IO.File]::WriteAllText($expiredPolicyConfig, $expiredPolicyText, (New-Object System.Text.UTF8Encoding($false)))
    $expiredPolicyRead = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $expiredPolicyRepo 'scripts/check-autonomy.ps1') -RepoRoot $expiredPolicyRepo -Action read -Phase CODING -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'expired policy falls back to safe L0 read' ($LASTEXITCODE -eq 0 -and (($expiredPolicyRead | Select-Object -Last 1) | ConvertFrom-Json).reason_code -eq 'SAFE_L0_FALLBACK')

    $versionApproval = 'APR-46|reviewer|commit|phase=CODING;files=src/app.py|v2|2098-12-31T23:00:00Z|2099-01-01T12:00:00Z|APPROVED|APR-46-evidence'
    $versionOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $autonomy -RepoRoot $validRepo -Action commit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Approval $versionApproval -Iteration 1 -Now '2099-01-01T00:00:00Z' 2>$null
    $versionDecision = ($versionOutput | Select-Object -Last 1) | ConvertFrom-Json
    Assert-Condition 'policy-version-mismatched approval is denied' ($LASTEXITCODE -eq 1 -and $versionDecision.reason_code -eq 'APPROVAL_POLICY_MISMATCH')

    $levelRepo = New-TestRepo 'levels'
    $levelAutonomy = Join-Path $levelRepo 'scripts/check-autonomy.ps1'
    $levelConfig = Join-Path $levelRepo '.github/sdlc-config.yml'
    $levelConfigText = [System.IO.File]::ReadAllText($levelConfig)
    $levelConfigText = $levelConfigText.Replace('autonomy_level: L1', 'autonomy_level: L0')
    [System.IO.File]::WriteAllText($levelConfig, $levelConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $l0Read = & pwsh -NoProfile -ExecutionPolicy Bypass -File $levelAutonomy -RepoRoot $levelRepo -Action read -Phase CODING -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'L0 allows read' ($LASTEXITCODE -eq 0 -and (($l0Read | Select-Object -Last 1) | ConvertFrom-Json).decision -eq 'ALLOW')
    $l0Edit = & pwsh -NoProfile -ExecutionPolicy Bypass -File $levelAutonomy -RepoRoot $levelRepo -Action edit -Phase CODING -ChangedFile src/app.py -ToolGrant edit -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'L0 denies edits' ($LASTEXITCODE -eq 1 -and (($l0Edit | Select-Object -Last 1) | ConvertFrom-Json).decision -eq 'DENY')
    $levelConfigText = $levelConfigText.Replace('autonomy_level: L0', 'autonomy_level: L2')
    [System.IO.File]::WriteAllText($levelConfig, $levelConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $l2Full = & pwsh -NoProfile -ExecutionPolicy Bypass -File $levelAutonomy -RepoRoot $levelRepo -Action full_validation -Phase TESTING -ChangedFile src/app.py -ToolGrant edit -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'L2 allows full validation' ($LASTEXITCODE -eq 0 -and (($l2Full | Select-Object -Last 1) | ConvertFrom-Json).decision -eq 'ALLOW')
    $levelConfigText = $levelConfigText.Replace('autonomy_level: L2', 'autonomy_level: L3')
    [System.IO.File]::WriteAllText($levelConfig, $levelConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $l3Pr = & pwsh -NoProfile -ExecutionPolicy Bypass -File $levelAutonomy -RepoRoot $levelRepo -Action pull_request_update -Phase CODING -Branch feature/test -ChangedFile src/app.py -ToolGrant edit -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'L3 allows bounded pull-request updates' ($LASTEXITCODE -eq 0 -and (($l3Pr | Select-Object -Last 1) | ConvertFrom-Json).decision -eq 'ALLOW')
    $levelConfigText = $levelConfigText.Replace('autonomy_level: L3', 'autonomy_level: L4')
    [System.IO.File]::WriteAllText($levelConfig, $levelConfigText, (New-Object System.Text.UTF8Encoding($false)))
    $l4Batch = & pwsh -NoProfile -ExecutionPolicy Bypass -File $levelAutonomy -RepoRoot $levelRepo -Action maintenance_batch -Phase TESTING -ChangedFile src/app.py -ToolGrant edit -Now '2099-01-01T00:00:00Z' 2>$null
    Assert-Condition 'L4 allows policy-bound maintenance' ($LASTEXITCODE -eq 0 -and (($l4Batch | Select-Object -Last 1) | ConvertFrom-Json).decision -eq 'ALLOW')

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