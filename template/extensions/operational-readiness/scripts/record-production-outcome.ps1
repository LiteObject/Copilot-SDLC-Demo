[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ReleaseReference,
    [Parameter(Mandatory = $true)]
    [ValidateSet('development','test','staging','production')]
    [string] $Environment,
    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS','FAIL','PARTIAL')]
    [string] $TechnicalResult,
    [Parameter(Mandatory = $true)]
    [ValidateSet('PASS','FAIL','PARTIAL')]
    [string] $BusinessResult,
    [Parameter(Mandatory = $true)]
    [string] $BusinessOutcome,
    [Parameter(Mandatory = $true)]
    [string] $UserFeedback,
    [string] $IncidentReference,
    [switch] $RollbackUsed,
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
function Test-SafeRelativePath {
    param([string] $Path)
    return -not ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)')
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
if ($null -eq $body -or (Get-OperationalValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] Operational readiness is disabled.'; exit 0 }
if ([string]::IsNullOrWhiteSpace($ReleaseReference) -or [string]::IsNullOrWhiteSpace($BusinessOutcome) -or [string]::IsNullOrWhiteSpace($UserFeedback)) { Write-Host '[FAIL] Release reference, business outcome, and user feedback are required.'; exit 1 }
$path = Get-OperationalValue -Body $body -Name 'feedback_path'
if (-not (Test-SafeRelativePath $path)) { Write-Host "[FAIL] feedback_path must be repository-relative: $path"; exit 1 }
$recordDirectory = Join-Path $RepoRoot (Split-Path -Parent $path)
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$result = if ($TechnicalResult -eq 'PASS' -and $BusinessResult -eq 'PASS') { 'PASS' } else { 'FAIL' }
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-production-outcome'
    release_reference = $ReleaseReference
    environment = $Environment
    service = Get-OperationalValue -Body $body -Name 'service_name'
    technical_result = $TechnicalResult
    business_result = $BusinessResult
    business_outcome = $BusinessOutcome
    user_feedback = $UserFeedback
    incident_reference = $IncidentReference
    rollback_used = [bool]$RollbackUsed
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    recorded_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    result = $result
    exit_code = if ($result -eq 'PASS') { 0 } else { 1 }
}
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RepoRoot $path) -Encoding utf8
if ($result -ne 'PASS') { Write-Host "[FAIL] Production outcome is not successful: $path"; exit 1 }
Write-Host "[PASS] Production outcome recorded: $(Join-Path $RepoRoot $path)"
exit 0
