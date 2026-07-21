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

function Get-LifecycleBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^ai_lifecycle:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}
function Get-LifecycleValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}
function Get-LifecycleList {
    param([string] $Body, [string] $Name)
    $value = Get-LifecycleValue -Body $Body -Name $Name
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
function Add-LifecycleError {
    param([System.Collections.Generic.List[string]] $Errors, [string] $Message)
    [void]$Errors.Add($Message)
    Write-Host "[FAIL] $Message"
}
function Test-ListContainsAll {
    param([string[]] $Actual, [string[]] $Expected, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    foreach ($item in $Expected) {
        if ($Actual -notcontains $item) { Add-LifecycleError $Errors "$Name must include '$item'." }
    }
}
function Test-Document {
    param([string] $Path, [string[]] $Terms, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-LifecycleError $Errors "Required AI lifecycle document is missing: $Name"
        return
    }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    foreach ($term in $Terms) {
        if ($content -notmatch [regex]::Escape($term)) { Add-LifecycleError $Errors "$Name must document '$term'." }
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$configContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-LifecycleBody -Content $configContent
if ($null -eq $body) { Write-Host '[SKIP] ai_lifecycle is not configured.'; exit 0 }
if ((Get-LifecycleValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] ai_lifecycle.enabled is false.'; exit 0 }

$baseValidator = Join-Path $RepoRoot 'scripts/validate-sdlc-config.ps1'
if (Test-Path -LiteralPath $baseValidator) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $baseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$errors = New-Object System.Collections.Generic.List[string]
$requiredValues = @(
    'risk_owner','human_oversight','contestability','impact_assessment_path','inventory_path',
    'evaluation_plan_path','evaluation_report_path','risk_disposition_path','red_team_plan_path',
    'runtime_controls_path','monitoring_plan_path','rollback_plan_path','decommissioning_plan_path',
    'model_card_path','system_card_path','model_providers','models','prompt_versions',
    'system_instruction_versions','tools','retrieval_sources','embeddings','datasets',
    'evaluation_datasets','safety_filters','fallback_behavior','material_change_triggers',
    'required_metrics','alert_thresholds','monitoring_cadence','reevaluation_cadence',
    'evaluation_task','red_team_task','production_exercise_task','rollback_task','decommission_task'
)
foreach ($name in $requiredValues) {
    if ([string]::IsNullOrWhiteSpace((Get-LifecycleValue -Body $body -Name $name))) { Add-LifecycleError $errors "ai_lifecycle.$name is required." }
}

$riskTier = Get-LifecycleValue -Body $body -Name 'risk_tier'
if ($riskTier -notin @('low','medium','high','critical')) { Add-LifecycleError $errors 'ai_lifecycle.risk_tier must be low, medium, high, or critical.' }
$retention = 0
if (-not [int]::TryParse((Get-LifecycleValue -Body $body -Name 'retention_days'), [ref]$retention) -or $retention -lt 1) { Add-LifecycleError $errors 'ai_lifecycle.retention_days must be a positive integer.' }

$requiredTrueFields = @('require_red_team','require_production_exercise','tool_authorization_required','least_privilege_required','rate_limit_required','cost_limit_required','input_validation_required','output_validation_required','safety_filter_required','pii_handling_required','audit_log_required','human_escalation_required','kill_switch_required','safe_fallback_required')
foreach ($name in $requiredTrueFields) {
    if ((Get-LifecycleValue -Body $body -Name $name) -ne 'true') { Add-LifecycleError $errors "ai_lifecycle.$name must be true." }
}

$nonEmptyLists = @('intended_uses','prohibited_uses','affected_communities','applicable_laws','model_providers','models','prompt_versions','system_instruction_versions','tools','retrieval_sources','embeddings','datasets','evaluation_datasets','safety_filters','material_change_triggers','required_metrics','alert_thresholds')
foreach ($name in $nonEmptyLists) {
    $value = Get-LifecycleValue -Body $body -Name $name
    $items = @(Get-LifecycleList -Body $body -Name $name)
    if (-not $value.StartsWith('[')) { Add-LifecycleError $errors "ai_lifecycle.$name must be an inline YAML list." }
    elseif ($items.Count -eq 0) { Add-LifecycleError $errors "ai_lifecycle.$name must not be empty." }
}

$pathFields = @('impact_assessment_path','inventory_path','evaluation_plan_path','evaluation_report_path','risk_disposition_path','red_team_plan_path','runtime_controls_path','monitoring_plan_path','rollback_plan_path','decommissioning_plan_path','model_card_path','system_card_path')
foreach ($name in $pathFields) {
    $path = Get-LifecycleValue -Body $body -Name $name
    if (-not (Test-SafeRelativePath $path)) { Add-LifecycleError $errors "ai_lifecycle.$name must be repository-relative: $path" }
}

$documentPaths = @{
    impact_assessment_path = @('Intended Use','Prohibited Use','affected','harm','law','oversight','contestability','risk owner')
    inventory_path = @('Model','Provider','Prompt','System instruction','Tool','Retrieval','Embedding','Dataset','Evaluation dataset','Safety filter','Fallback','License','terms','lineage','Retention','Change history')
    evaluation_plan_path = @('representative','adversarial','task quality','reliability','grounding','hallucination','misinformation','privacy','bias','fairness','robustness','prompt injection','jailbreak','insecure tool invocation','retrieval quality','refusal','threshold','latency','cost','release-blocking')
    risk_disposition_path = @('Risk tier','Risk owner','Decision','residual risk','Mitigations','approval')
    red_team_plan_path = @('prompt injection','sensitive information','supply chain','poisoning','excessive agency','system-prompt','vector','misinformation','unbounded','retest')
    runtime_controls_path = @('Authentication','authorization','least-privilege','Rate limit','Cost limit','Input validation','Output validation','safety filter','PII','Audit log','escalation','Kill switch','fallback')
    monitoring_plan_path = @('quality','safety','drift','adversarial','cost','latency','tool actions','user feedback','disproportional','threshold','incident response','containment','rollback','communication','cadence')
    rollback_plan_path = @('Trigger','Kill switch','Prompt rollback','Model rollback','Safe fallback','communication','retest')
    decommissioning_plan_path = @('End-of-life','owner','notification','access revocation','Data deletion','retention','Embedding','Credential','Decommission')
    model_card_path = @('provider','model','license','terms','intended','prohibited','data lineage','evaluation','limitations','safety','privacy','rollback')
    system_card_path = @('model','prompt','system instruction','tool','retrieval','embedding','dataset','safety filter','fallback','affected','limitation','evaluation','red-team','runtime','monitoring','appeal','decommission')
}
foreach ($name in $documentPaths.Keys) {
    $path = Get-LifecycleValue -Body $body -Name $name
    if (Test-SafeRelativePath $path) { Test-Document -Path (Join-Path $RepoRoot $path) -Terms $documentPaths[$name] -Name $name -Errors $errors }
}

foreach ($field in @('evaluation_task','red_team_task','production_exercise_task','rollback_task','decommission_task')) {
    $task = Get-LifecycleValue -Body $body -Name $field
    if (-not (Test-TaskConfigured -Content $configContent -TaskName $task)) { Add-LifecycleError $errors "Configured task '$task' for ai_lifecycle.$field is missing from tasks." }
}

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-ai-lifecycle-config-validation'
    command = 'scripts/validate-ai-lifecycle.ps1'
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    risk_tier = $riskTier
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    errors = @($errors)
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $recordDirectory 'ai-lifecycle-config-validation.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] AI lifecycle configuration is valid.'
exit 0
