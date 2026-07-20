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

function Get-OperationalBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^operational_readiness:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}
function Get-OperationalValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}
function Get-OperationalList {
    param([string] $Body, [string] $Name)
    $value = Get-OperationalValue -Body $Body -Name $Name
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
    try { $value = (& git @Arguments 2>$null | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $value) { return $value }; return 'unknown' }
    finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-OperationalBody -Content $content
if ($null -eq $body) { Write-Host '[SKIP] operational_readiness is not configured.'; exit 0 }
if ((Get-OperationalValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] operational_readiness.enabled is false.'; exit 0 }
$baseValidator = Join-Path $RepoRoot 'scripts/validate-sdlc-config.ps1'
if (Test-Path -LiteralPath $baseValidator) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $baseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$errors = New-Object System.Collections.Generic.List[string]
function Add-ReadinessError { param([string] $Message); [void]$errors.Add($Message); Write-Host "[FAIL] $Message" }
function Test-ListContainsAll {
    param([string[]] $Actual, [string[]] $Expected, [string] $Name)
    foreach ($item in $Expected) { if ($Actual -notcontains $item) { Add-ReadinessError "$Name must include '$item'." } }
}

foreach ($name in @('service_name','service_owner','on_call','health_endpoint','slo_availability','slo_latency','slo_error_rate','slo_throughput','slo_business_outcome','readiness_review_path','incident_response_path','alert_policy_path','escalation_policy_path','feedback_path','incident_record_path','health_check_task','telemetry_check_task','failure_drill_task','post_release_check_task')) {
    if ([string]::IsNullOrWhiteSpace((Get-OperationalValue -Body $body -Name $name))) { Add-ReadinessError "operational_readiness.$name is required." }
}
$healthEndpoint = Get-OperationalValue -Body $body -Name 'health_endpoint'
if ($healthEndpoint -and ($healthEndpoint -notmatch '^/' -or $healthEndpoint -match '(^|[\\/])\.\.([\\/]|$)')) { Add-ReadinessError 'health_endpoint must be an absolute repository service path without traversal.' }
$telemetry = @(Get-OperationalList -Body $body -Name 'required_telemetry')
$slis = @(Get-OperationalList -Body $body -Name 'required_slis')
$reviewItems = @(Get-OperationalList -Body $body -Name 'readiness_review_items')
$severities = @(Get-OperationalList -Body $body -Name 'incident_severities')
Test-ListContainsAll -Actual $telemetry -Expected @('structured_logs','metrics','distributed_traces','correlation_ids') -Name 'required_telemetry'
Test-ListContainsAll -Actual $slis -Expected @('availability','latency','error_rate','throughput','business_outcome') -Name 'required_slis'
Test-ListContainsAll -Actual $reviewItems -Expected @('capacity','backup_recovery','dependency_failure','data_retention','privacy','disaster_recovery') -Name 'readiness_review_items'
Test-ListContainsAll -Actual $severities -Expected @('sev1','sev2','sev3') -Name 'incident_severities'
$retention = 0
if (-not [int]::TryParse((Get-OperationalValue -Body $body -Name 'retention_days'), [ref]$retention) -or $retention -lt 1) { Add-ReadinessError 'retention_days must be a positive integer.' }

$documentPaths = @('readiness_review_path','incident_response_path','alert_policy_path','escalation_policy_path')
foreach ($name in $documentPaths) {
    $path = Get-OperationalValue -Body $body -Name $name
    if ($path -and -not (Test-SafeRelativePath $path)) { Add-ReadinessError "operational_readiness.$name must be repository-relative: $path" }
    elseif ($path -and -not (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf)) { Add-ReadinessError "Required operational document is missing: $path" }
}
$runbooks = @(Get-OperationalList -Body $body -Name 'runbooks')
if ($runbooks.Count -lt 5) { Add-ReadinessError 'runbooks must contain the five common operational runbooks.' }
foreach ($path in $runbooks) {
    if (-not (Test-SafeRelativePath $path)) { Add-ReadinessError "Runbook path must be repository-relative: $path" }
    elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $path) -PathType Leaf)) { Add-ReadinessError "Required runbook is missing: $path" }
}
foreach ($name in @('feedback_path','incident_record_path')) {
    $path = Get-OperationalValue -Body $body -Name $name
    if ($path -and -not (Test-SafeRelativePath $path)) { Add-ReadinessError "operational_readiness.$name must be repository-relative: $path" }
}
$taskFields = @('health_check_task','telemetry_check_task','failure_drill_task','post_release_check_task')
foreach ($field in $taskFields) {
    $task = Get-OperationalValue -Body $body -Name $field
    if (-not (Test-TaskConfigured -Content $content -TaskName $task)) { Add-ReadinessError "Configured task '$task' for operational_readiness.$field is missing from tasks." }
}

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-operational-readiness-config-validation'
    command = 'scripts/validate-operational-readiness.ps1'
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    service = Get-OperationalValue -Body $body -Name 'service_name'
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    errors = @($errors)
}
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recordDirectory 'operational-readiness-config-validation.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] Operational readiness configuration is valid.'
exit 0