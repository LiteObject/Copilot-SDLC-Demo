[CmdletBinding()]
param(
    [string] $TaskId,
    [string] $AgentRole,
    [string] $Provider,
    [string] $Model,
    [string] $ModelVersion,
    [string] $Tenant,
    [string] $Repository,
    [string] $DataClassification,
    [string] $InstructionVersion,
    [string] $SandboxReference,
    [ValidateSet('GATHERING_REQS','DESIGN','PLANNING','CODING','REVIEW','TESTING','DEPLOYMENT_READINESS','DONE')]
    [string] $Phase,
    [string[]] $ToolGrant = @(),
    [string[]] $ToolCall = @(),
    [string[]] $McpServer = @(),
    [string[]] $NetworkDestination = @(),
    [string[]] $CredentialScope = @(),
    [string[]] $ChangedFile = @(),
    [string[]] $Validation = @(),
    [string[]] $HumanApproval = @(),
    [string[]] $Action = @(),
    [string] $AutonomyDecisionId = '',
    [string] $AutonomyDecision = '',
    [string] $ApprovalId = '',
    [string] $AutonomyEvidence = '',
    [ValidateSet('APPROVED','REJECTED','PENDING')]
    [string] $FinalDisposition = 'PENDING',
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
if (-not $EvidenceDirectory) { $EvidenceDirectory = '.sdlc/evidence' }

function Get-GovernanceBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^ai_governance:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}

function Get-GovernanceValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}

function Get-GovernanceList {
    param([string] $Body, [string] $Name)
    $value = Get-GovernanceValue -Body $Body -Name $Name
    if (-not $value.StartsWith('[')) { return @() }
    return @($value.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
}

function Test-SafeRelativePath {
    param([string] $Path)
    return -not ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)')
}

function Get-GitValue {
    param([string] $Root, [string[]] $Arguments)
    Push-Location $Root
    try {
        $value = (& git @Arguments 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $value) { return $value }
        return 'unknown'
    }
    finally { Pop-Location }
}

function Get-TreeDigest {
    param([string] $Root)
    $payload = Get-GitValue -Root $Root -Arguments @('diff','--binary','HEAD','--','.',':(exclude)docs/spec.md',':(exclude).sdlc/**')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Add-GovernanceError {
    param([System.Collections.Generic.List[string]] $Errors, [string] $Message)
    [void]$Errors.Add($Message)
    Write-Host "[FAIL] $Message"
}

function Test-Allowlist {
    param([string] $Value, [string[]] $Allowed, [switch] $Wildcard)
    if ($Wildcard -and $Allowed -contains '*') { return $true }
    return $Allowed -contains $Value
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$validator = Join-Path $PSScriptRoot 'validate-ai-governance.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory *> $null
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$configContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-GovernanceBody -Content $configContent
if ($null -eq $body -or (Get-GovernanceValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] ai_governance.enabled is false.'; exit 0 }

$errors = New-Object System.Collections.Generic.List[string]
foreach ($item in @(
        @{ Name = 'task-id'; Value = $TaskId },
        @{ Name = 'agent-role'; Value = $AgentRole },
        @{ Name = 'provider'; Value = $Provider },
        @{ Name = 'model'; Value = $Model },
        @{ Name = 'model-version'; Value = $ModelVersion },
        @{ Name = 'tenant'; Value = $Tenant },
        @{ Name = 'repository'; Value = $Repository },
        @{ Name = 'data-classification'; Value = $DataClassification },
        @{ Name = 'instruction-version'; Value = $InstructionVersion },
        @{ Name = 'phase'; Value = $Phase }
    )) {
    if ([string]::IsNullOrWhiteSpace([string]$item.Value)) { Add-GovernanceError $errors "--$($item.Name) is required." }
}
if ($ToolGrant.Count -eq 0) { Add-GovernanceError $errors 'At least one -ToolGrant is required.' }
if ($ToolCall.Count -eq 0) { Add-GovernanceError $errors 'At least one -ToolCall is required.' }
if ($ChangedFile.Count -eq 0) { Add-GovernanceError $errors 'At least one -ChangedFile is required.' }
if ($Validation.Count -eq 0) { Add-GovernanceError $errors 'At least one -Validation result is required.' }
if ($Action.Count -gt 0 -and ([string]::IsNullOrWhiteSpace($AutonomyDecisionId) -or $AutonomyDecision -notin @('ALLOW','DENY'))) { Add-GovernanceError $errors 'Action-bearing records require an autonomy decision ID and ALLOW or DENY decision.' }
if ($AutonomyDecision -eq 'DENY' -and $FinalDisposition -eq 'APPROVED') { Add-GovernanceError $errors 'A denied autonomy decision cannot have an APPROVED final disposition.' }
if ($AutonomyEvidence -and -not (Test-SafeRelativePath $AutonomyEvidence)) { Add-GovernanceError $errors "Autonomy evidence must be repository-relative: $AutonomyEvidence" }

$providers = @(Get-GovernanceList -Body $body -Name 'approved_providers')
$models = @(Get-GovernanceList -Body $body -Name 'approved_models')
$tenants = @(Get-GovernanceList -Body $body -Name 'approved_tenants')
$repositories = @(Get-GovernanceList -Body $body -Name 'permitted_repositories')
$classifications = @(Get-GovernanceList -Body $body -Name 'allowed_data_classifications')
$tools = @(Get-GovernanceList -Body $body -Name 'tool_allowlist')
$mcpAllowlist = @(Get-GovernanceList -Body $body -Name 'mcp_server_allowlist')
$networkAllowlist = @(Get-GovernanceList -Body $body -Name 'network_destination_allowlist')
$credentialAllowlist = @(Get-GovernanceList -Body $body -Name 'credential_scope_allowlist')
$phaseGrants = @(Get-GovernanceList -Body $body -Name 'phase_tool_grants')
$restrictedActions = @(Get-GovernanceList -Body $body -Name 'restricted_actions')
if (-not (Test-Allowlist -Value $Provider -Allowed $providers)) { Add-GovernanceError $errors "Provider is not approved: $Provider" }
if (-not (Test-Allowlist -Value $Model -Allowed $models)) { Add-GovernanceError $errors "Model is not approved: $Model" }
if (-not (Test-Allowlist -Value $Tenant -Allowed $tenants)) { Add-GovernanceError $errors "Tenant or subscription is not approved: $Tenant" }
if (-not (Test-Allowlist -Value $Repository -Allowed $repositories -Wildcard)) { Add-GovernanceError $errors "Repository is not permitted: $Repository" }
if (-not (Test-Allowlist -Value $DataClassification -Allowed $classifications)) { Add-GovernanceError $errors "Data classification is not allowed: $DataClassification" }
foreach ($grant in $ToolGrant) { if (-not (Test-Allowlist -Value $grant -Allowed $tools)) { Add-GovernanceError $errors "Tool grant is not allowlisted: $grant" } }
foreach ($server in $McpServer) { if (-not (Test-Allowlist -Value $server -Allowed $mcpAllowlist)) { Add-GovernanceError $errors "MCP server is not allowlisted: $server" } }
foreach ($destination in $NetworkDestination) { if (-not (Test-Allowlist -Value $destination -Allowed $networkAllowlist)) { Add-GovernanceError $errors "Network destination is not allowlisted: $destination" } }
foreach ($scope in $CredentialScope) { if (-not (Test-Allowlist -Value $scope -Allowed $credentialAllowlist)) { Add-GovernanceError $errors "Credential scope is not allowlisted: $scope" } }
$phaseGrant = @($phaseGrants | Where-Object { $_ -match ('^' + [regex]::Escape($Phase) + '=') } | Select-Object -First 1)
if ($phaseGrant.Count -eq 0) {
    Add-GovernanceError $errors "No phase tool grant is configured for: $Phase"
}
else {
    $phaseTools = @($phaseGrant[0].Substring($Phase.Length + 1) -split '\|')
    $phaseScopeBreach = $false
    foreach ($grant in $ToolGrant) { if ($phaseTools -notcontains $grant) { $phaseScopeBreach = $true } }
}
foreach ($file in $ChangedFile) {
    if (-not (Test-SafeRelativePath $file)) { Add-GovernanceError $errors "Changed file must be a safe repository-relative path: $file" }
    if ($file.EndsWith('/')) { Add-GovernanceError $errors "Changed file must be an exact file, not a directory: $file" }
}

$approvalRecords = New-Object System.Collections.Generic.List[object]
$approvedApprovals = 0
foreach ($approval in $HumanApproval) {
    $parts = $approval -split '\|'
    if ($parts.Count -lt 3 -or $parts.Count -gt 4 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1]) -or [string]::IsNullOrWhiteSpace($parts[2])) {
        Add-GovernanceError $errors 'Human approval must use approver|DECISION|reference[|timestamp].'
        continue
    }
    $decision = $parts[1].Trim()
    if ($decision -notin @('APPROVED','REJECTED','PENDING')) { Add-GovernanceError $errors "Unsupported human approval decision: $decision" }
    if ($decision -eq 'APPROVED') { $approvedApprovals++ }
    $timestamp = if ($parts.Count -eq 4 -and $parts[3]) { $parts[3] } else { [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
    [void]$approvalRecords.Add([ordered]@{ approver = $parts[0].Trim(); decision = $decision; reference = $parts[2].Trim(); timestamp = $timestamp })
}

$validationRecords = New-Object System.Collections.Generic.List[object]
$validationFailure = $false
foreach ($validation in $Validation) {
    $parts = $validation -split '=', 2
    $name = $parts[0].Trim()
    $result = if ($parts.Count -eq 2) { $parts[1].Trim() } else { 'PASS' }
    if (-not $name) { Add-GovernanceError $errors 'Validation names cannot be empty.'; continue }
    if ($result -notin @('PASS','FAIL','CHANGES_REQUESTED')) { Add-GovernanceError $errors "Unsupported validation result: $result" }
    if ($result -ne 'PASS') { $validationFailure = $true }
    [void]$validationRecords.Add([ordered]@{ name = $name; result = $result })
}

$phaseScopeBreach = if (Get-Variable -Name phaseScopeBreach -ErrorAction SilentlyContinue) { $phaseScopeBreach } else { $false }
if ($phaseScopeBreach -and $approvedApprovals -eq 0) { Add-GovernanceError $errors "Tool grant is outside the '$Phase' phase boundary and requires an APPROVED widening decision." }
if ($phaseScopeBreach -and $approvedApprovals -gt 0) { $Action += 'phase_scope_widened' }
$restrictedAction = $false
foreach ($actionName in $Action) { if ($restrictedActions -contains $actionName) { $restrictedAction = $true } }
if ($restrictedAction -and $approvedApprovals -eq 0) { Add-GovernanceError $errors 'Restricted actions require an APPROVED human approval.' }
if ($FinalDisposition -ne 'PENDING' -and $HumanApproval.Count -eq 0) { Add-GovernanceError $errors 'A final disposition requires a human approval record.' }
if ($FinalDisposition -eq 'APPROVED' -and ($approvedApprovals -eq 0 -or $validationFailure)) { Add-GovernanceError $errors 'APPROVED disposition requires an approved human decision and all validations to PASS.' }
if ((Get-GovernanceValue -Body $body -Name 'sandbox_required' -Default 'false') -eq 'true' -and [string]::IsNullOrWhiteSpace($SandboxReference)) { Add-GovernanceError $errors 'SandboxReference is required by ai_governance.sandbox_required.' }

$ledgerPath = Get-GovernanceValue -Body $body -Name 'ledger_path'
if (-not (Test-SafeRelativePath $ledgerPath)) { Add-GovernanceError $errors "ai_governance.ledger_path must be repository-relative: $ledgerPath" }
if ($errors.Count -gt 0) { exit 1 }

$ledgerFullPath = Join-Path $RepoRoot $ledgerPath
$ledgerParent = Split-Path -Parent $ledgerFullPath
New-Item -ItemType Directory -Path $ledgerParent -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-ai-change-ledger'
    task_id = $TaskId
    agent_role = $AgentRole
    provider = $Provider
    model = $Model
    model_version = $ModelVersion
    tenant = $Tenant
    repository = $Repository
    data_classification = $DataClassification
    instruction_version = $InstructionVersion
    phase = $Phase
    sandbox_reference = $SandboxReference
    tool_grants = @($ToolGrant)
    tool_calls = @($ToolCall)
    mcp_servers = @($McpServer)
    network_destinations = @($NetworkDestination)
    credential_scopes = @($CredentialScope)
    changed_files = @($ChangedFile)
    human_approvals = $approvalRecords.ToArray()
    validations = $validationRecords.ToArray()
    actions = @($Action)
    autonomy_decision_id = $AutonomyDecisionId
    autonomy_decision = if ($AutonomyDecision) { $AutonomyDecision } else { 'NOT_RECORDED' }
    autonomy_approval_id = $ApprovalId
    autonomy_evidence = $AutonomyEvidence
    autonomy = [ordered]@{
        decision_id = $AutonomyDecisionId
        decision = if ($AutonomyDecision) { $AutonomyDecision } else { 'NOT_RECORDED' }
        approval_id = $ApprovalId
        evidence = $AutonomyEvidence
        requested_actions = @($Action)
        final_disposition = $FinalDisposition
    }
    final_disposition = $FinalDisposition
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    tree_digest = Get-TreeDigest -Root $RepoRoot
    recorded_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}
$record | ConvertTo-Json -Depth 16 -Compress | Add-Content -LiteralPath $ledgerFullPath -Encoding utf8
Write-Host "[PASS] AI change recorded: $ledgerPath"
exit 0