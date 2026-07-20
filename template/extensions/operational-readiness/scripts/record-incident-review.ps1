[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $IncidentReference,
    [Parameter(Mandatory = $true)]
    [ValidateSet('sev1','sev2','sev3','sev4')]
    [string] $Severity,
    [Parameter(Mandatory = $true)]
    [string] $Summary,
    [Parameter(Mandatory = $true)]
    [string] $Impact,
    [Parameter(Mandatory = $true)]
    [string[]] $CorrectiveAction,
    [Parameter(Mandatory = $true)]
    [string] $ActionOwner,
    [Parameter(Mandatory = $true)]
    [string] $DueDate,
    [ValidateSet('OPEN','CLOSED')]
    [string] $Status = 'OPEN',
    [string] $Reviewer,
    [string] $ClosureDecision,
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
if ([string]::IsNullOrWhiteSpace($IncidentReference) -or [string]::IsNullOrWhiteSpace($Summary) -or [string]::IsNullOrWhiteSpace($Impact) -or [string]::IsNullOrWhiteSpace($ActionOwner) -or [string]::IsNullOrWhiteSpace($DueDate) -or $CorrectiveAction.Count -eq 0) { Write-Host '[FAIL] Incident reference, summary, impact, corrective action, owner, and due date are required.'; exit 1 }
if ($DueDate -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host '[FAIL] DueDate must use YYYY-MM-DD.'; exit 1 }
$severities = @(Get-OperationalList -Body $body -Name 'incident_severities')
if ($severities -notcontains $Severity) { Write-Host "[FAIL] Severity '$Severity' is not configured."; exit 1 }
if ($Status -eq 'CLOSED' -and ([string]::IsNullOrWhiteSpace($Reviewer) -or [string]::IsNullOrWhiteSpace($ClosureDecision))) { Write-Host '[FAIL] Closed incident reviews require Reviewer and ClosureDecision.'; exit 1 }
$path = Get-OperationalValue -Body $body -Name 'incident_record_path'
if (-not (Test-SafeRelativePath $path)) { Write-Host "[FAIL] incident_record_path must be repository-relative: $path"; exit 1 }
New-Item -ItemType Directory -Path (Join-Path $RepoRoot (Split-Path -Parent $path)) -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-incident-review'
    incident_reference = $IncidentReference
    severity = $Severity
    status = $Status
    service = Get-OperationalValue -Body $body -Name 'service_name'
    summary = $Summary
    impact = $Impact
    corrective_actions = @($CorrectiveAction)
    action_owner = $ActionOwner
    due_date = $DueDate
    reviewer = $Reviewer
    closure_decision = $ClosureDecision
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    recorded_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    result = 'PASS'
    exit_code = 0
}
$record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $RepoRoot $path) -Encoding utf8
Write-Host "[PASS] Incident review recorded: $(Join-Path $RepoRoot $path)"
exit 0
