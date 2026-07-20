[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $SpecPath,
    [string] $EvidenceDirectory,
    [switch] $RecordSpec
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
if (-not $SpecPath) { $SpecPath = Join-Path $RepoRoot 'docs/spec.md' }
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

function Get-TreeDigest {
    param([string] $Root)
    $payload = Get-GitValue -Root $Root -Arguments @('diff','--binary','HEAD','--','.',':(exclude)docs/spec.md',':(exclude).sdlc/**')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}

function Get-RelativePath {
    param([string] $Root, [string] $Path)
    $rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Substring($rootPath.Length) -replace '\\','/'
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

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$configContent = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-GovernanceBody -Content $configContent
if ($null -eq $body -or (Get-GovernanceValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] ai_governance.enabled is false.'; exit 0 }

$validator = Join-Path $PSScriptRoot 'validate-ai-governance.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$taskName = Get-GovernanceValue -Body $body -Name 'evaluation_task'
$runner = Join-Path $RepoRoot 'scripts/run-sdlc-task.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { Write-Host "[FAIL] Task runner not found: $runner"; exit 1 }
Write-Host "[RUN] AI governance evaluation: $taskName"
& pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -Task $taskName -RepoRoot $RepoRoot -ConfigPath $ConfigPath -EvidenceDirectory $EvidenceDirectory
$exitCode = $LASTEXITCODE
$result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
$taskEvidence = Join-Path $RepoRoot "$EvidenceDirectory/$taskName.json"
$configuredEvidence = Get-GovernanceValue -Body $body -Name 'evaluation_evidence_path' -Default "$EvidenceDirectory/agent-evaluation.json"
if ([System.IO.Path]::IsPathRooted($configuredEvidence) -or $configuredEvidence -match '(^|[\\/])\.\.([\\/]|$)') { Write-Host "[FAIL] evaluation_evidence_path must be repository-relative: $configuredEvidence"; exit 1 }
$summaryPath = Join-Path $RepoRoot $configuredEvidence
New-Item -ItemType Directory -Path (Split-Path -Parent $summaryPath) -Force | Out-Null
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-ai-agent-evaluation'
    command = 'scripts/run-ai-governance.ps1'
    task = $taskName
    commit_sha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
    tree_digest = Get-TreeDigest -Root $RepoRoot
    evaluated_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    exit_code = $exitCode
    result = $result
    evidence = if (Test-Path -LiteralPath $taskEvidence) { Get-RelativePath -Root $RepoRoot -Path $taskEvidence } else { '' }
    errors = if ($exitCode -eq 0) { @() } else { @("Evaluation task '$taskName' failed with exit code $exitCode.") }
}
$record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding utf8
if ($RecordSpec) {
    $relativeSummary = Get-RelativePath -Root $RepoRoot -Path $summaryPath
    Set-SpecMetadata -Path $SpecPath -Updates @{
        ai_governance_enabled = 'true'
        gate_ai_governance_command = 'scripts/run-ai-governance.ps1'
        gate_ai_governance_commit_sha = $record.commit_sha
        gate_ai_governance_tree_digest = $record.tree_digest
        gate_ai_governance_timestamp = $record.evaluated_at
        gate_ai_governance_exit_code = [string]$exitCode
        gate_ai_governance_result = $result
        gate_ai_governance_evidence = $relativeSummary
    }
}
if ($exitCode -ne 0) { Write-Host '[FAIL] AI governance evaluation failed.'; exit 1 }
Write-Host "[PASS] AI governance evaluation complete: $summaryPath"
exit 0