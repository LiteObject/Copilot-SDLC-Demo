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

function Get-MeasurementBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^measurement:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}
function Get-MeasurementValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}
function Get-MeasurementList {
    param([string] $Body, [string] $Name)
    $value = Get-MeasurementValue -Body $Body -Name $Name
    if (-not $value.StartsWith('[') -or -not $value.EndsWith(']')) { return @() }
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
function Add-MeasurementError {
    param([System.Collections.Generic.List[string]] $Errors, [string] $Message)
    [void]$Errors.Add($Message)
    Write-Host "[FAIL] $Message"
}
function Test-Document {
    param([string] $Path, [string[]] $Terms, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-MeasurementError $Errors "Required measurement document is missing: $Name"
        return
    }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    foreach ($term in $Terms) {
        if ($content -notmatch [regex]::Escape($term)) { Add-MeasurementError $Errors "$Name must document '$term'." }
    }
}
function Test-ListContainsAll {
    param([string[]] $Actual, [string[]] $Expected, [string] $Name, [System.Collections.Generic.List[string]] $Errors)
    foreach ($item in $Expected) {
        if ($Actual -notcontains $item) { Add-MeasurementError $Errors "$Name must include '$item'." }
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$configContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-MeasurementBody -Content $configContent
if ($null -eq $body) { Write-Host '[SKIP] measurement is not configured.'; exit 0 }
if ((Get-MeasurementValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] measurement.enabled is false.'; exit 0 }

$baseValidator = Join-Path $RepoRoot 'scripts/validate-sdlc-config.ps1'
if (Test-Path -LiteralPath $baseValidator) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $baseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$errors = New-Object System.Collections.Generic.List[string]
$requiredValues = @(
    'model','cohort','change_failure_window_days','time_measurement_method','owner','cadence','measurement_plan_path','baseline_path','metric_catalog_path',
    'catalog_path','event_schema_path','events_path','report_path','experiment_path',
    'privacy_review_path','improvement_log_path','quarterly_review_path','snapshot_path',
    'baseline_task','snapshot_task','review_task'
)
foreach ($name in $requiredValues) {
    if ([string]::IsNullOrWhiteSpace((Get-MeasurementValue -Body $body -Name $name))) { Add-MeasurementError $errors "measurement.$name is required." }
}

$cadence = Get-MeasurementValue -Body $body -Name 'cadence'
if ($cadence -notin @('monthly', 'quarterly')) { Add-MeasurementError $errors 'measurement.cadence must be monthly or quarterly.' }
$retention = 0
if (-not [int]::TryParse((Get-MeasurementValue -Body $body -Name 'retention_days'), [ref]$retention) -or $retention -lt 1) { Add-MeasurementError $errors 'measurement.retention_days must be a positive integer.' }
$failureWindow = 0
if (-not [int]::TryParse((Get-MeasurementValue -Body $body -Name 'change_failure_window_days'), [ref]$failureWindow) -or $failureWindow -lt 1) { Add-MeasurementError $errors 'measurement.change_failure_window_days must be a positive integer.' }
$aiApplicable = Get-MeasurementValue -Body $body -Name 'ai_product_metrics_applicable' -Default 'false'
if ($aiApplicable -notin @('true', 'false')) { Add-MeasurementError $errors 'measurement.ai_product_metrics_applicable must be true or false.' }
$requireCompletionGate = Get-MeasurementValue -Body $body -Name 'require_completion_gate' -Default 'false'
if ($requireCompletionGate -notin @('true', 'false')) { Add-MeasurementError $errors 'measurement.require_completion_gate must be true or false.' }

$requiredMetrics = [ordered]@{
    baseline_metrics = @('lead_time','deployment_frequency','change_failure_rate','recovery_time','escaped_defects','security_findings','review_cycle_count','flaky_test_rate','rollback_rate','slo_attainment')
    delivery_metrics = @('complete_evidence_rate','agent_suggested_defect_rate','human_rework','review_acceptance_rate','scope_drift_rate','validation_pass_rate','model_tool_policy_violations','time_saved_or_added')
    phase_outcome_metrics = @('phase0_outcome','phase1_outcome','phase2_outcome','phase3_outcome','phase4_outcome','phase5_outcome','phase6_outcome','phase7_outcome')
    phase_leading_indicators = @('phase0_leading_indicator','phase1_leading_indicator','phase2_leading_indicator','phase3_leading_indicator','phase4_leading_indicator','phase5_leading_indicator','phase6_leading_indicator','phase7_leading_indicator')
}
foreach ($entry in $requiredMetrics.GetEnumerator()) {
    $value = Get-MeasurementValue -Body $body -Name $entry.Key
    $items = @(Get-MeasurementList -Body $body -Name $entry.Key)
    if (-not $value.StartsWith('[')) { Add-MeasurementError $errors "measurement.$($entry.Key) must be an inline YAML list." }
    Test-ListContainsAll -Actual $items -Expected $entry.Value -Name "measurement.$($entry.Key)" -Errors $errors
}
$aiMetrics = @(Get-MeasurementList -Body $body -Name 'ai_product_metrics')
if ($aiApplicable -eq 'true') {
    Test-ListContainsAll -Actual $aiMetrics -Expected @('task_quality','safety_rate','abstention_escalation_rate','user_reported_harms','cost','latency','drift','incident_recurrence') -Name 'measurement.ai_product_metrics' -Errors $errors
}

$allMetricIds = @()
foreach ($name in @('baseline_metrics','delivery_metrics','ai_product_metrics','phase_outcome_metrics','phase_leading_indicators')) { $allMetricIds += @(Get-MeasurementList -Body $body -Name $name) }
$duplicates = @($allMetricIds | Group-Object | Where-Object { $_.Count -gt 1 })
foreach ($duplicate in $duplicates) { Add-MeasurementError $errors "Metric '$($duplicate.Name)' is configured more than once." }
foreach ($metricId in $allMetricIds) {
    if ($metricId -notmatch '^[a-z][a-z0-9_]*$') { Add-MeasurementError $errors "Metric id '$metricId' must use lowercase letters, numbers, and underscores." }
}

$pathFields = @('measurement_plan_path','baseline_path','metric_catalog_path','catalog_path','event_schema_path','events_path','report_path','experiment_path','privacy_review_path','improvement_log_path','quarterly_review_path','snapshot_path')
foreach ($name in $pathFields) {
    $path = Get-MeasurementValue -Body $body -Name $name
    if (-not (Test-SafeRelativePath $path)) { Add-MeasurementError $errors "measurement.$name must be repository-relative: $path" }
}

$documentPaths = @{
    measurement_plan_path = @('Outcome','leading indicator','cadence','owner','retention','privacy')
    baseline_path = @('Baseline','Definition','Owner','Source','Retention')
    metric_catalog_path = @('Metric ID','Definition','Owner','Source','Retention','Privacy review')
    catalog_path = @('sdlc-measurement-catalog','dora-ai-v1','metrics')
    event_schema_path = @('sdlc-measurement-event-schema','common_required','event_types')
    experiment_path = @('sdlc-measurement-experiments','model','experiments')
    privacy_review_path = @('Data minimization','Sensitive','Personal data','Aggregation','Retention','Access','Review outcome')
    improvement_log_path = @('Observed effect','Regression','Owner','Evidence','Accepted')
    quarterly_review_path = @('Period','Completed improvements','Unresolved risks','Exception trends','Next prioritized roadmap','Regression')
}
foreach ($name in $documentPaths.Keys) {
    $path = Get-MeasurementValue -Body $body -Name $name
    if (Test-SafeRelativePath $path) { Test-Document -Path (Join-Path $RepoRoot $path) -Terms $documentPaths[$name] -Name $name -Errors $errors }
}

foreach ($field in @('baseline_task','snapshot_task','review_task')) {
    $task = Get-MeasurementValue -Body $body -Name $field
    if (-not (Test-TaskConfigured -Content $configContent -TaskName $task)) { Add-MeasurementError $errors "Configured task '$task' for measurement.$field is missing from tasks." }
}

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$canonicalValidator = Join-Path $PSScriptRoot 'measurement.py'
$python = Get-Command python -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
if (-not (Test-Path -LiteralPath $canonicalValidator -PathType Leaf)) {
    Add-MeasurementError $errors "Canonical measurement validator is missing: $canonicalValidator"
}
elseif ($null -eq $python) {
    Add-MeasurementError $errors 'Python 3 is required for the canonical measurement validator.'
}
else {
    & $python.Source $canonicalValidator validate-contract --config-path $ConfigPath --repo-root $RepoRoot --evidence-path (Join-Path $recordDirectory 'measurement-model-validation.json')
    if ($LASTEXITCODE -ne 0) { Add-MeasurementError $errors 'Canonical measurement model validation failed.' }
}
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-measurement-config-validation'
    command = 'scripts/validate-measurement.ps1'
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse', 'HEAD')
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    model = Get-MeasurementValue -Body $body -Name 'model'
    cohort = Get-MeasurementValue -Body $body -Name 'cohort'
    change_failure_window_days = Get-MeasurementValue -Body $body -Name 'change_failure_window_days'
    owner = Get-MeasurementValue -Body $body -Name 'owner'
    cadence = $cadence
    require_completion_gate = $requireCompletionGate
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    errors = @($errors)
}
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $recordDirectory 'measurement-config-validation.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] Measurement configuration is valid.'
exit 0