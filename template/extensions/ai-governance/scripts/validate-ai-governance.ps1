[CmdletBinding()]
param(
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

function Test-TaskConfigured {
    param([string] $Content, [string] $TaskName)
    return $TaskName -and $Content -match ('(?m)^  ' + [regex]::Escape($TaskName) + ':\s*$')
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

function Add-GovernanceError {
    param([System.Collections.Generic.List[string]] $Errors, [string] $Message)
    [void]$Errors.Add($Message)
    Write-Host "[FAIL] $Message"
}

function Test-ContainsAll {
    param([string[]] $Actual, [string[]] $Expected, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    foreach ($item in $Expected) {
        if ($Actual -notcontains $item) { Add-GovernanceError $Errors "$Name must include '$item'." }
    }
}

function Normalize-AutonomyAction {
    param([string] $Value)
    $normalized = $Value.Trim().ToLowerInvariant().Replace('-', '_')
    switch ($normalized) {
        'inspect' { return 'read' }
        'execute' { return 'command' }
        'run_command' { return 'command' }
        'validation' { return 'full_validation' }
        'create_branch' { return 'branch' }
        'create_pr' { return 'pull_request' }
        'update_pr' { return 'pull_request_update' }
        'network' { return 'network_access' }
        'new_network_destination' { return 'network_access' }
        'rotate_credentials' { return 'credential_rotation' }
        'production_configuration' { return 'production_config' }
        default { return $normalized }
    }
}

function Test-Document {
    param([string] $Path, [string[]] $Terms, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-GovernanceError $Errors "Required governance document is missing: $Name"
        return
    }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    foreach ($term in $Terms) {
        if ($content -notmatch [regex]::Escape($term)) { Add-GovernanceError $Errors "$Name must document '$term'." }
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$configContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-GovernanceBody -Content $configContent
if ($null -eq $body) { Write-Host '[SKIP] ai_governance is not configured.'; exit 0 }
if ((Get-GovernanceValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] ai_governance.enabled is false.'; exit 0 }

$baseValidator = Join-Path $RepoRoot 'scripts/validate-sdlc-config.ps1'
if (Test-Path -LiteralPath $baseValidator) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $baseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$errors = New-Object System.Collections.Generic.List[string]
$requiredValues = @('policy_path','permissions_path','threat_model_path','evaluation_plan_path','evaluation_scenarios_path','ledger_path','evaluation_evidence_path','approved_providers','approved_models','approved_tenants','permitted_repositories','allowed_data_classifications','prohibited_inputs','tool_allowlist','mcp_server_allowlist','network_destination_allowlist','credential_scope_allowlist','phase_tool_grants','restricted_actions','approval_required_actions','sandbox_type','untrusted_input_policy','autonomy_level','policy_version','policy_expires_at','max_iterations','max_changed_files','allowed_branches','action_classes','approval_requirements','approval_expiration_hours','evaluation_task')
foreach ($name in $requiredValues) {
    if ([string]::IsNullOrWhiteSpace((Get-GovernanceValue -Body $body -Name $name))) { Add-GovernanceError $errors "ai_governance.$name is required." }
}

foreach ($name in @('sandbox_required','command_confirmation_required')) {
    $value = Get-GovernanceValue -Body $body -Name $name
    if ($value -notin @('true','false')) { Add-GovernanceError $errors "ai_governance.$name must be true or false." }
}
$sandboxRequired = Get-GovernanceValue -Body $body -Name 'sandbox_required'
if ($sandboxRequired -eq 'true' -and (Get-GovernanceValue -Body $body -Name 'sandbox_type') -eq 'none') { Add-GovernanceError $errors 'sandbox_type must not be none when sandbox_required is true.' }
if ((Get-GovernanceValue -Body $body -Name 'sandbox_type') -notin @('worktree','container','vm','none')) { Add-GovernanceError $errors 'sandbox_type must be worktree, container, vm, or none.' }
if ((Get-GovernanceValue -Body $body -Name 'command_confirmation_required') -ne 'true') { Add-GovernanceError $errors 'command_confirmation_required must be true.' }
if ((Get-GovernanceValue -Body $body -Name 'untrusted_input_policy') -ne 'treat_as_data') { Add-GovernanceError $errors 'untrusted_input_policy must be treat_as_data.' }
$autonomyLevel = Get-GovernanceValue -Body $body -Name 'autonomy_level'
if ($autonomyLevel -notin @('L0','L1','L2','L3','L4')) { Add-GovernanceError $errors 'autonomy_level must be L0, L1, L2, L3, or L4.' }
$policyVersion = Get-GovernanceValue -Body $body -Name 'policy_version'
if ([string]::IsNullOrWhiteSpace($policyVersion)) { Add-GovernanceError $errors 'policy_version must not be empty.' }
$policyExpiresAt = Get-GovernanceValue -Body $body -Name 'policy_expires_at'
$parsedPolicyExpiry = [DateTimeOffset]::MinValue
if ($policyExpiresAt -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' -or -not [DateTimeOffset]::TryParse($policyExpiresAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedPolicyExpiry)) {
    Add-GovernanceError $errors 'policy_expires_at must be an ISO-8601 UTC timestamp ending in Z.'
}
elseif ($parsedPolicyExpiry -le [DateTimeOffset]::UtcNow) {
    Add-GovernanceError $errors 'policy_expires_at has expired.'
}
$maxIterations = 0
if (-not [int]::TryParse((Get-GovernanceValue -Body $body -Name 'max_iterations'), [ref]$maxIterations) -or $maxIterations -lt 1) { Add-GovernanceError $errors 'max_iterations must be a positive integer.' }
$maxChangedFiles = 0
if (-not [int]::TryParse((Get-GovernanceValue -Body $body -Name 'max_changed_files'), [ref]$maxChangedFiles) -or $maxChangedFiles -lt 0) { Add-GovernanceError $errors 'max_changed_files must be a non-negative integer.' }
$approvalExpirationHours = 0
if (-not [int]::TryParse((Get-GovernanceValue -Body $body -Name 'approval_expiration_hours'), [ref]$approvalExpirationHours) -or $approvalExpirationHours -lt 1) { Add-GovernanceError $errors 'approval_expiration_hours must be a positive integer.' }

$retention = 0
$retentionText = Get-GovernanceValue -Body $body -Name 'audit_retention_days' -Default (Get-GovernanceValue -Body $body -Name 'retention_days')
if (-not [int]::TryParse($retentionText, [ref]$retention) -or $retention -lt 1) { Add-GovernanceError $errors 'audit_retention_days must be a positive integer.' }

$approvedProviders = @(Get-GovernanceList -Body $body -Name 'approved_providers')
$approvedModels = @(Get-GovernanceList -Body $body -Name 'approved_models')
$approvedTenants = @(Get-GovernanceList -Body $body -Name 'approved_tenants')
$repositories = @(Get-GovernanceList -Body $body -Name 'permitted_repositories')
$dataClassifications = @(Get-GovernanceList -Body $body -Name 'allowed_data_classifications')
$prohibitedInputs = @(Get-GovernanceList -Body $body -Name 'prohibited_inputs')
$tools = @(Get-GovernanceList -Body $body -Name 'tool_allowlist')
$grants = @(Get-GovernanceList -Body $body -Name 'phase_tool_grants')
$restrictedActions = @(Get-GovernanceList -Body $body -Name 'restricted_actions')
$approvalActions = @(Get-GovernanceList -Body $body -Name 'approval_required_actions')
$allowedBranches = @(Get-GovernanceList -Body $body -Name 'allowed_branches')
$actionClasses = @(Get-GovernanceList -Body $body -Name 'action_classes')
$approvalRequirements = @(Get-GovernanceList -Body $body -Name 'approval_requirements')
foreach ($name in @('approved_providers','approved_models','approved_tenants','permitted_repositories','allowed_data_classifications','prohibited_inputs','tool_allowlist','mcp_server_allowlist','network_destination_allowlist','credential_scope_allowlist','phase_tool_grants','restricted_actions','approval_required_actions','allowed_branches','action_classes','approval_requirements')) {
    if (-not (Get-GovernanceValue -Body $body -Name $name).StartsWith('[')) { Add-GovernanceError $errors "ai_governance.$name must be an inline YAML list." }
}
if ($approvedProviders.Count -eq 0) { Add-GovernanceError $errors 'approved_providers must not be empty.' }
if ($approvedModels.Count -eq 0) { Add-GovernanceError $errors 'approved_models must not be empty.' }
if ($approvedTenants.Count -eq 0) { Add-GovernanceError $errors 'approved_tenants must not be empty.' }
if ($repositories.Count -eq 0) { Add-GovernanceError $errors 'permitted_repositories must not be empty.' }
Test-ContainsAll $dataClassifications @('public','internal') 'allowed_data_classifications' $errors
Test-ContainsAll $prohibitedInputs @('secrets','credentials','personal_data','untrusted_instructions') 'prohibited_inputs' $errors
Test-ContainsAll $tools @('read','search') 'tool_allowlist' $errors
Test-ContainsAll $restrictedActions @('commit','merge','deploy','rotate_credentials','production_config') 'restricted_actions' $errors
Test-ContainsAll $approvalActions @('commit','merge','deploy','rotate_credentials','production_config') 'approval_required_actions' $errors
$knownActions = @('read','analyze','propose','edit','command','local_validation','full_validation','branch','pull_request','pull_request_update','network_access','maintenance_batch','commit','merge','deploy','production_config','credential_rotation','secret_access','policy_change')
$normalizedActionClasses = @($actionClasses | ForEach-Object { Normalize-AutonomyAction $_ })
foreach ($action in $normalizedActionClasses) { if ($action -notin $knownActions) { Add-GovernanceError $errors "Unsupported action class: $action." } }
foreach ($branch in $allowedBranches) { if ([string]::IsNullOrWhiteSpace($branch) -or $branch -match '\s|\.\.') { Add-GovernanceError $errors "Invalid allowed branch pattern: $branch." } }
$requirementMap = @{}
foreach ($entry in $approvalRequirements) {
    if ($entry -notmatch '^([^=]+)=(human|policy|none)$') { Add-GovernanceError $errors "Invalid approval requirement: $entry."; continue }
    $requirementMap[(Normalize-AutonomyAction $Matches[1])] = $Matches[2]
}
$normalizedApprovalActions = @($approvalActions | ForEach-Object { Normalize-AutonomyAction $_ })
foreach ($action in $restrictedActions) {
    $normalized = Normalize-AutonomyAction $action
    if ($normalized -notin $normalizedActionClasses) { Add-GovernanceError $errors "Restricted action must be listed in action_classes: $normalized." }
    if ($normalized -notin $normalizedApprovalActions) { Add-GovernanceError $errors "Restricted action must require approval: $normalized." }
    if ($requirementMap[$normalized] -ne 'human') { Add-GovernanceError $errors "Restricted action must have a human approval requirement: $normalized." }
}

foreach ($grant in $grants) {
    if ($grant -notmatch '^[A-Z_]+=([^,]+)$') { Add-GovernanceError $errors "Invalid phase_tool_grants entry: $grant" }
}
foreach ($phase in @('GATHERING_REQS','PLANNING','CODING','REVIEW','TESTING','DEPLOYMENT_READINESS')) {
    if (-not ($grants | Where-Object { $_ -match ('^' + [regex]::Escape($phase) + '=') })) { Add-GovernanceError $errors "phase_tool_grants must define '$phase'." }
}

$pathFields = @('policy_path','permissions_path','threat_model_path','evaluation_plan_path','evaluation_scenarios_path','ledger_path','evaluation_evidence_path')
foreach ($name in $pathFields) {
    $path = Get-GovernanceValue -Body $body -Name $name
    if (-not (Test-SafeRelativePath $path)) { Add-GovernanceError $errors "ai_governance.$name must be repository-relative: $path" }
}
Test-Document (Join-Path $RepoRoot (Get-GovernanceValue -Body $body -Name 'policy_path')) @('provider','model','retention','intellectual','approval') 'policy_path' $errors
Test-Document (Join-Path $RepoRoot (Get-GovernanceValue -Body $body -Name 'permissions_path')) @('tool','MCP','network','credential','least privilege','phase') 'permissions_path' $errors
Test-Document (Join-Path $RepoRoot (Get-GovernanceValue -Body $body -Name 'threat_model_path')) @('prompt injection','untrusted','command','secret') 'threat_model_path' $errors
Test-Document (Join-Path $RepoRoot (Get-GovernanceValue -Body $body -Name 'evaluation_plan_path')) @('planning accuracy','test quality','security-finding precision','scope','human rework') 'evaluation_plan_path' $errors
Test-Document (Join-Path $RepoRoot (Get-GovernanceValue -Body $body -Name 'evaluation_scenarios_path')) @('prompt-injection','unsafe-tool-use') 'evaluation_scenarios_path' $errors

$evaluationTask = Get-GovernanceValue -Body $body -Name 'evaluation_task'
if (-not (Test-TaskConfigured -Content $configContent -TaskName $evaluationTask)) { Add-GovernanceError $errors "Configured task '$evaluationTask' for ai_governance.evaluation_task is missing from tasks." }

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-ai-governance-config-validation'
    command = 'scripts/validate-ai-governance.ps1'
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    approved_providers = $approvedProviders
    approved_models = $approvedModels
    tools = $tools
    errors = @($errors)
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $recordDirectory 'ai-governance-config-validation.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] AI governance configuration is valid.'
exit 0