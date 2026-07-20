<#
.SYNOPSIS
    Validates the opt-in release-assurance contract.

.DESCRIPTION
    Validates release artifact, SBOM, provenance, promotion, smoke-test, and
    rollback settings after the base Phase 1 config validator passes. Disabled
    release assurance is a valid no-op.
#>
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

function Get-ReleaseBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^release_assurance:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if (-not $match.Success) { return $null }
    return $match.Groups['body'].Value
}
function Get-ReleaseValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}
function Get-ReleaseList {
    param([string] $Body, [string] $Name)
    $value = Get-ReleaseValue -Body $Body -Name $Name
    if (-not $value.StartsWith('[')) { return @() }
    return @($value.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
}
function Test-SafeRelativePath {
    param([string] $Path)
    return -not ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)')
}
function Test-TaskConfigured {
    param([string] $Content, [string] $TaskName)
    return $TaskName -eq 'none' -or $Content -match ('(?m)^  ' + [regex]::Escape($TaskName) + ':\s*$')
}
function Get-GitValue {
    param([string] $Root, [string[]] $Arguments)
    Push-Location $Root
    try { $value = (& git @Arguments 2>$null | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $value) { return $value }; return 'unknown' }
    finally { Pop-Location }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-ReleaseBody -Content $content
if ($null -eq $body) { Write-Host '[SKIP] release_assurance is not configured.'; exit 0 }
$enabled = Get-ReleaseValue -Body $body -Name 'enabled'
if ($enabled -ne 'true') { Write-Host '[SKIP] release_assurance.enabled is false.'; exit 0 }
$baseValidator = Join-Path $RepoRoot 'scripts/validate-sdlc-config.ps1'
if (Test-Path -LiteralPath $baseValidator) {
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $baseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$errors = New-Object System.Collections.Generic.List[string]
function Add-ReleaseError { param([string] $Message); [void]$errors.Add($Message); Write-Host "[FAIL] $Message" }
$requiredValues = @('artifact_task','artifact_path','sbom_task','sbom_path','sbom_format','smoke_test_task','rollback_task','release_notes_path','rollback_instructions_path','deployment_task','provenance_path')
foreach ($name in $requiredValues) { if ([string]::IsNullOrWhiteSpace((Get-ReleaseValue $body $name))) { Add-ReleaseError "release_assurance.$name is required." } }
$format = Get-ReleaseValue $body 'sbom_format'
if ($format -notin @('cyclonedx-json','spdx-json')) { Add-ReleaseError "release_assurance.sbom_format '$format' is unsupported." }
$requireProvenance = Get-ReleaseValue $body 'require_provenance'
$requireSignature = Get-ReleaseValue $body 'require_signed_artifact'
if ($requireProvenance -notin @('true','false')) { Add-ReleaseError 'release_assurance.require_provenance must be true or false.' }
if ($requireSignature -notin @('true','false')) { Add-ReleaseError 'release_assurance.require_signed_artifact must be true or false.' }
foreach ($name in @('artifact_path','sbom_path','provenance_path','signature_path','release_notes_path','rollback_instructions_path')) {
    $path = Get-ReleaseValue $body $name
    if ($path -and -not (Test-SafeRelativePath $path)) { Add-ReleaseError "release_assurance.$name must be repository-relative: $path" }
}
$environments = @(Get-ReleaseList $body 'promotion_environments')
$approvals = @(Get-ReleaseList $body 'required_approvals')
if ($environments.Count -eq 0) { Add-ReleaseError 'promotion_environments must contain development, staging, or production environments.' }
if ($approvals.Count -eq 0) { Add-ReleaseError 'required_approvals must identify release approvers.' }
$taskNames = @('artifact_task','sbom_task','smoke_test_task','rollback_task','deployment_task')
if ($requireSignature -eq 'true') { $taskNames += 'signing_task' }
foreach ($field in $taskNames) {
    $taskName = Get-ReleaseValue $body $field
    if (-not (Test-TaskConfigured -Content $content -TaskName $taskName)) { Add-ReleaseError "Configured task '$taskName' for release_assurance.$field is missing from tasks." }
}
if ($requireSignature -eq 'true' -and [string]::IsNullOrWhiteSpace((Get-ReleaseValue $body 'signature_path'))) { Add-ReleaseError 'signature_path is required when require_signed_artifact is true.' }

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-release-config-validation'
    command = 'scripts/validate-release-config.ps1'
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    environments = $environments
    required_approvals = $approvals
    errors = @($errors)
}
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recordDirectory 'release-config-validation.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] Release assurance configuration is valid.'
exit 0
