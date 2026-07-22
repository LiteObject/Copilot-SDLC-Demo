[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $SpecPath,
    [string] $EvidenceDirectory,
    [string] $FeatureId,
    [switch] $FailureDrill,
    [switch] $RecordSpec
)

$ErrorActionPreference = 'Stop'
$featureContextPath = Join-Path $PSScriptRoot 'feature-context.ps1'
if (-not (Test-Path -LiteralPath $featureContextPath -PathType Leaf)) { $featureContextPath = Join-Path $PSScriptRoot '../../../base/scripts/feature-context.ps1' }
. $featureContextPath
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
$workflowContext = Resolve-FeatureContext -RepoRoot $RepoRoot -SpecPath $SpecPath -FeatureId $FeatureId -EvidenceDirectory $EvidenceDirectory
$FeatureId = $workflowContext.FeatureId
$SpecPath = $workflowContext.SpecPath
$specRelativePath = $workflowContext.SpecRelativePath
$EvidenceDirectory = if ($FeatureId) { $workflowContext.EvidenceDirectory } elseif ($EvidenceDirectory) { $EvidenceDirectory } else { '.sdlc/evidence' }

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
function Get-GitValue {
    param([string] $Root, [string[]] $Arguments)
    Push-Location $Root
    try { $value = (& git @Arguments 2>$null | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $value) { return $value }; return 'unknown' }
    finally { Pop-Location }
}
function Get-TreeDigest {
    param([string] $Root, [string] $SpecRelativePath)
    $payload = Get-GitValue -Root $Root -Arguments @('diff','--binary','HEAD','--','.',":(exclude)$SpecRelativePath",':(exclude)docs/specs/**/tasks.json',':(exclude).sdlc/**')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
function Set-SpecMetadata {
    param([string] $Path, [hashtable] $Updates)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Spec file not found for -RecordSpec: $Path" }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    $lines = @(Get-Content -LiteralPath $Path)
    foreach ($key in $Updates.Keys) {
        $found = $false
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match ('^' + [regex]::Escape($key) + ':')) {
                $value = [string]$Updates[$key]
                if ($key -notmatch 'result|exit_code') { $value = '"' + $value.Replace('"','\"') + '"' }
                $lines[$index] = "${key}: $value"
                $found = $true
                break
            }
        }
        if (-not $found) { throw "Spec metadata field '$key' was not found in $Path" }
    }
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    [System.IO.File]::WriteAllText($Path, ($lines -join $newline), (New-Object System.Text.UTF8Encoding($false)))
}
function Get-RelativePath {
    param([string] $Root, [string] $Path)
    $rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Substring($rootPath.Length) -replace '\\','/'
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-OperationalBody -Content $content
if ($null -eq $body -or (Get-OperationalValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] Operational readiness is disabled.'; exit 0 }

$validator = Join-Path $PSScriptRoot 'validate-operational-readiness.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runner = Join-Path $RepoRoot 'scripts/run-sdlc-task.ps1'
$taskFields = @('health_check_task','telemetry_check_task','post_release_check_task')
if ($FailureDrill) { $taskFields = @('health_check_task','telemetry_check_task','failure_drill_task','post_release_check_task') }
$checks = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
foreach ($field in $taskFields) {
    $taskName = Get-OperationalValue -Body $body -Name $field
    Write-Host "[RUN] Operational check: $taskName"
    $runnerArguments = @('-Task', $taskName, '-RepoRoot', $RepoRoot, '-ConfigPath', $ConfigPath, '-EvidenceDirectory', $EvidenceDirectory)
    if ($FeatureId) { $runnerArguments += @('-FeatureId', $FeatureId) }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner @runnerArguments
    $exitCode = $LASTEXITCODE
    $result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $evidence = Join-Path $RepoRoot "$EvidenceDirectory/$taskName.log"
    $check = [ordered]@{ task = $taskName; purpose = $field; exit_code = $exitCode; result = $result; evidence = if (Test-Path -LiteralPath $evidence) { Get-RelativePath -Root $RepoRoot -Path $evidence } else { '' } }
    [void]$checks.Add([pscustomobject]$check)
    if ($exitCode -ne 0) { [void]$errors.Add("Operational task '$taskName' failed with exit code $exitCode.") }
}

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot -SpecRelativePath $specRelativePath
$summaryPath = Join-Path $recordDirectory 'operational-readiness.json'
$result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
$summaryExitCode = if ($errors.Count -eq 0) { 0 } else { 1 }
$serviceName = Get-OperationalValue -Body $body -Name 'service_name'
$mode = if ($FailureDrill) { 'failure-drill' } else { 'readiness' }
$checkedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-operational-readiness'
    command = 'scripts/run-operational-readiness.ps1'
    service = $serviceName
    mode = $mode
    feature_id = $FeatureId
    spec_path = $specRelativePath
    commit_sha = $commitSha
    tree_digest = $treeDigest
    checked_at = $checkedAt
    exit_code = $summaryExitCode
    result = $result
    checks = $checks.ToArray()
    errors = $errors.ToArray()
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($RecordSpec) {
    $relativeSummary = Get-RelativePath -Root $RepoRoot -Path $summaryPath
    $updates = @{
        gate_operational_readiness_command = 'scripts/run-operational-readiness.ps1'
        gate_operational_readiness_commit_sha = $commitSha
        gate_operational_readiness_tree_digest = $treeDigest
        gate_operational_readiness_timestamp = $record.checked_at
        gate_operational_readiness_exit_code = [string]$record.exit_code
        gate_operational_readiness_result = $result
        gate_operational_readiness_evidence = $relativeSummary
    }
    if ($FeatureId) {
        $updates['gate_operational_readiness_feature_id'] = $FeatureId
        $updates['gate_operational_readiness_spec_path'] = $specRelativePath
    }
    Set-SpecMetadata -Path $SpecPath -Updates $updates
}
if ($errors.Count -gt 0) { Write-Host '[FAIL] Operational readiness checks failed.'; exit 1 }
Write-Host "[PASS] Operational readiness checks complete: $summaryPath"
exit 0
