[CmdletBinding()]
param(
    [string] $Action,
    [string] $Phase,
    [string] $FeatureId,
    [string] $SpecPath,
    [string[]] $ChangedFile = @(),
    [string[]] $ToolGrant = @(),
    [string[]] $NetworkDestination = @(),
    [string] $Branch,
    [string] $Iteration = '0',
    [string] $Now,
    [string] $ApprovalRecord,
    [string] $Approval,
    [string] $DecisionId,
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $EvidenceDirectory,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'
$core = Join-Path $PSScriptRoot 'autonomy-policy.py'
if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    Write-Host "[FAIL] Autonomy policy engine not found: $core"
    exit 1
}
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
if (-not $python) {
    Write-Host '[FAIL] Python 3 is required for check-autonomy.'
    exit 1
}
if ($Help) {
    & $python.Source $core --help
    exit $LASTEXITCODE
}

$arguments = @()
foreach ($pair in @(
        @('--action', $Action),
        @('--phase', $Phase),
        @('--feature-id', $FeatureId),
        @('--spec-path', $SpecPath),
        @('--branch', $Branch),
        @('--iteration', $Iteration),
        @('--now', $Now),
        @('--approval-record', $ApprovalRecord),
        @('--approval', $Approval),
        @('--decision-id', $DecisionId),
        @('--config-path', $ConfigPath),
        @('--repo-root', $RepoRoot),
        @('--evidence-directory', $EvidenceDirectory)
    )) {
    if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) { $arguments += $pair[0]; $arguments += $pair[1] }
}
foreach ($file in $ChangedFile) { $arguments += '--changed-file'; $arguments += $file }
foreach ($grant in $ToolGrant) { $arguments += '--tool-grant'; $arguments += $grant }
foreach ($destination in $NetworkDestination) { $arguments += '--network-destination'; $arguments += $destination }

& $python.Source $core @arguments
exit $LASTEXITCODE