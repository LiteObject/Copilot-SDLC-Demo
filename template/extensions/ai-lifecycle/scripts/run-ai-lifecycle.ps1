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
                if ($key -notmatch 'result|exit_code|_enabled') { $value = '"' + $value.Replace('"','\"') + '"' }
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
$body = Get-LifecycleBody -Content $configContent
if ($null -eq $body -or (Get-LifecycleValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] AI lifecycle is disabled.'; exit 0 }

$validator = Join-Path $PSScriptRoot 'validate-ai-lifecycle.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runner = Join-Path $RepoRoot 'scripts/run-sdlc-task.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { Write-Host "[FAIL] Task runner not found: $runner"; exit 1 }

$taskFields = @('evaluation_task','red_team_task','production_exercise_task')
$checks = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
foreach ($field in $taskFields) {
    $taskName = Get-LifecycleValue -Body $body -Name $field
    Write-Host "[RUN] AI lifecycle check: $taskName"
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner -Task $taskName -RepoRoot $RepoRoot -ConfigPath $ConfigPath -EvidenceDirectory $EvidenceDirectory
    $exitCode = $LASTEXITCODE
    $result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $evidence = Join-Path $RepoRoot "$EvidenceDirectory/$taskName.log"
    $check = [ordered]@{ task = $taskName; purpose = $field; exit_code = $exitCode; result = $result; evidence = if (Test-Path -LiteralPath $evidence) { Get-RelativePath -Root $RepoRoot -Path $evidence } else { '' } }
    [void]$checks.Add([pscustomobject]$check)
    if ($exitCode -ne 0) { [void]$errors.Add("AI lifecycle task '$taskName' failed with exit code $exitCode.") }
}

$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot
$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$checkedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
$exitCode = if ($errors.Count -eq 0) { 0 } else { 1 }
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-ai-lifecycle'
    command = 'scripts/run-ai-lifecycle.ps1'
    risk_tier = Get-LifecycleValue -Body $body -Name 'risk_tier'
    commit_sha = $commitSha
    tree_digest = $treeDigest
    checked_at = $checkedAt
    exit_code = $exitCode
    result = $result
    checks = $checks.ToArray()
    errors = $errors.ToArray()
}
$summaryPath = Join-Path $recordDirectory 'ai-lifecycle.json'
$reportPath = Get-LifecycleValue -Body $body -Name 'evaluation_report_path'
if (-not (Test-SafeRelativePath $reportPath)) { Write-Host "[FAIL] ai_lifecycle.evaluation_report_path must be repository-relative: $reportPath"; exit 1 }
$evaluationReportPath = Join-Path $RepoRoot $reportPath
$evaluationReportParent = Split-Path -Parent $evaluationReportPath
New-Item -ItemType Directory -Path $evaluationReportParent -Force | Out-Null
$json = $record | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($summaryPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($evaluationReportPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))

if ($RecordSpec) {
    $updates = @{
        ai_lifecycle_enabled = 'true'
        gate_ai_lifecycle_command = 'scripts/run-ai-lifecycle.ps1'
        gate_ai_lifecycle_commit_sha = $commitSha
        gate_ai_lifecycle_tree_digest = $treeDigest
        gate_ai_lifecycle_timestamp = $checkedAt
        gate_ai_lifecycle_exit_code = [string]$exitCode
        gate_ai_lifecycle_result = $result
        gate_ai_lifecycle_evidence = Get-RelativePath -Root $RepoRoot -Path $summaryPath
    }
    Set-SpecMetadata -Path $SpecPath -Updates $updates
}
if ($errors.Count -gt 0) { Write-Host '[FAIL] AI lifecycle checks failed.'; exit 1 }
Write-Host "[PASS] AI lifecycle checks complete: $summaryPath"
exit 0
