<#
.SYNOPSIS
    Runs configured security tasks and applies the blocking-severity policy.

.DESCRIPTION
    Each configured security task is executed through run-sdlc-task.ps1, so
    executable and args remain structured. The aggregate JSON record classifies
    explicit severity-bearing output; a nonzero task without an explicit
    severity is treated as high. Critical/high findings block by default.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $EvidenceDirectory,
    [string] $SpecPath,
    [string] $FeatureId,
    [switch] $RecordSpec
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'feature-context.ps1')
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
$requestedEvidenceDirectory = $EvidenceDirectory
$workflowContext = Resolve-FeatureContext -RepoRoot $RepoRoot -SpecPath $SpecPath -FeatureId $FeatureId -EvidenceDirectory $EvidenceDirectory
$FeatureId = $workflowContext.FeatureId
$SpecPath = $workflowContext.SpecPath
$specRelativePath = $workflowContext.SpecRelativePath
if ($FeatureId) { $EvidenceDirectory = $workflowContext.EvidenceDirectory } else { $EvidenceDirectory = $requestedEvidenceDirectory }

function Get-ConfigListFromText {
    param([string] $Content, [string] $Path)
    $match = [regex]::Match($Content, '(?ms)^' + [regex]::Escape($Path.Split('.')[0]) + ':\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if (-not $match.Success) { return @() }
    $body = $match.Groups['body'].Value
    $field = $Path.Split('.')[1]
    $inline = [regex]::Match($body, '(?m)^\s*' + [regex]::Escape($field) + ':\s*\[(?<items>[^\]]*)\]')
    if ($inline.Success) {
        return @($inline.Groups['items'].Value -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
    }
    return @()
}
function Get-ConfigValueFromText {
    param([string] $Content, [string] $Path, [string] $Default)
    $parts = $Path.Split('.')
    $block = [regex]::Match($Content, '(?ms)^' + [regex]::Escape($parts[0]) + ':\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if (-not $block.Success) { return $Default }
    $match = [regex]::Match($block.Groups['body'].Value, '(?m)^\s*' + [regex]::Escape($parts[1]) + ':\s*(?<value>[^\r\n#]+)')
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
    $payload = Get-GitValue -Root $Root -Arguments @('diff', '--binary', 'HEAD', '--', '.', ":(exclude)$SpecRelativePath", ':(exclude)docs/specs/**/tasks.json', ':(exclude).sdlc/**')
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
                if ($key -notmatch 'result|exit_code') { $value = '"' + $value.Replace('"', '\"') + '"' }
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

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$configValidator = Join-Path $PSScriptRoot 'validate-sdlc-config.ps1'
$validatorArgs = @('-ConfigPath', $ConfigPath, '-RepoRoot', $RepoRoot)
if ($FeatureId) { $validatorArgs += @('-FeatureId', $FeatureId) }
if ($RecordSpec) { $validatorArgs += @('-SpecPath', $SpecPath, '-RecordSpec') }
& pwsh -NoProfile -ExecutionPolicy Bypass -File $configValidator @validatorArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$securityTasks = @(Get-ConfigListFromText -Content $content -Path 'security.tasks')
$blockingSeverities = @(Get-ConfigListFromText -Content $content -Path 'security.blocking_severities')
if ($blockingSeverities.Count -eq 0) { $blockingSeverities = @('critical', 'high') }
if (-not $EvidenceDirectory) { $EvidenceDirectory = Get-ConfigValueFromText -Content $content -Path 'validation.evidence_directory' -Default '.sdlc/evidence' }
$evidenceRoot = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse', 'HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot -SpecRelativePath $specRelativePath
$taskRunner = Join-Path $PSScriptRoot 'run-sdlc-task.ps1'
$findings = @()
$overallExit = 0
foreach ($task in $securityTasks) {
    $runnerArgs = @('-Task', $task, '-RepoRoot', $RepoRoot, '-EvidenceDirectory', $EvidenceDirectory)
    if ($FeatureId) { $runnerArgs += @('-FeatureId', $FeatureId) }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskRunner @runnerArgs
    $taskExit = $LASTEXITCODE
    $logPath = Join-Path $evidenceRoot "$task.log"
    $log = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }
    $severity = ''
    foreach ($candidate in @('critical', 'high', 'medium', 'low', 'info')) {
        if ($log -match "(?i)\b$([regex]::Escape($candidate))\b") { $severity = $candidate; break }
    }
    if ($taskExit -ne 0 -and -not $severity) { $severity = 'high' }
    $result = if ($taskExit -eq 0) { 'PASS' } else { 'FAIL' }
    $blocking = $false
    if ($severity -and $blockingSeverities -contains $severity) { $blocking = $true }
    if ($blocking) { $overallExit = 1 }
    $findings += [pscustomobject]@{ task = $task; severity = if ($severity) { $severity } else { 'info' }; result = $result; blocking = $blocking; exit_code = $taskExit; evidence = "$EvidenceDirectory/$task.log" }
}
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$recordPath = Join-Path $evidenceRoot 'security-scan.json'
$record = [ordered]@{ schema = 1; kind = 'sdlc-security-scan'; command = 'scripts/run-security-scans.ps1'; feature_id = $FeatureId; spec_path = $specRelativePath; commit_sha = $commitSha; tree_digest = $treeDigest; timestamp = $timestamp; exit_code = $overallExit; result = if ($overallExit -eq 0) { 'PASS' } else { 'FAIL' }; blocking_severities = @($blockingSeverities); findings = @($findings) }
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8
Write-Host "[INFO] Security evidence: $recordPath"
if ($RecordSpec) {
    $repoFullPath = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $relativeEvidence = $recordPath.Substring($repoFullPath.Length) -replace '\\', '/'
    $updates = @{
        gate_security_command = 'scripts/run-security-scans.ps1'
        gate_security_commit_sha = $commitSha
        gate_security_tree_digest = $treeDigest
        gate_security_timestamp = $timestamp
        gate_security_exit_code = [string]$overallExit
        gate_security_result = if ($overallExit -eq 0) { 'PASS' } else { 'FAIL' }
        gate_security_evidence = $relativeEvidence
    }
    if ($FeatureId) {
        $updates['gate_security_feature_id'] = $FeatureId
        $updates['gate_security_spec_path'] = $specRelativePath
    }
    Set-SpecMetadata -Path $SpecPath -Updates $updates
}
if ($overallExit -ne 0) { Write-Host '[FAIL] Blocking security findings detected.'; exit 1 }
Write-Host '[PASS] Security scan policy passed.'
exit 0
