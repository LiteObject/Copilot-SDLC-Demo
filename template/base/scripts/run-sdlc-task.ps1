<#
.SYNOPSIS
    Runs one named SDLC validation task or all configured tasks.

.DESCRIPTION
    Reads the structured task registry from .github/sdlc-config.yml and invokes
    each executable with an argument array. It never evaluates a shell command.
    Every task writes a log and JSON evidence record. With -RecordSpec it also
    updates the matching gate_<task>_* fields in docs/spec.md.

.PARAMETER Task
    install, build, test, lint, type_check, package, sbom, sign, deploy,
    smoke_test, rollback, health_check, telemetry_check, failure_drill,
    post_release_check, measurement_baseline, measurement_snapshot,
    measurement_review, or all. Defaults to all.
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'build', 'test', 'lint', 'type_check', 'sast', 'secrets', 'dependency_audit', 'license_audit', 'container_scan', 'iac_scan', 'dast', 'security_tests', 'package', 'sbom', 'sign', 'verify_signature', 'deploy', 'smoke_test', 'rollback', 'health_check', 'telemetry_check', 'failure_drill', 'post_release_check', 'agent_evaluation', 'ai_evaluation', 'ai_red_team', 'ai_production_exercise', 'ai_rollback', 'ai_decommission', 'measurement_baseline', 'measurement_snapshot', 'measurement_review', 'all')]
    [string] $Task = 'all',
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
if (Test-Path -LiteralPath $RepoRoot -PathType Container) { $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
$requestedEvidenceDirectory = $EvidenceDirectory
$workflowContext = Resolve-FeatureContext -RepoRoot $RepoRoot -SpecPath $SpecPath -FeatureId $FeatureId -EvidenceDirectory $EvidenceDirectory
$FeatureId = $workflowContext.FeatureId
$SpecPath = $workflowContext.SpecPath
$specRelativePath = $workflowContext.SpecRelativePath
if ($FeatureId) { $EvidenceDirectory = $workflowContext.EvidenceDirectory } else { $EvidenceDirectory = $requestedEvidenceDirectory }
$script:FeatureId = $FeatureId
$script:SpecRelativePath = $specRelativePath

function ConvertFrom-ConfigScalar {
    param([string] $Value)
    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace('\"', '"')
    }
    return ([regex]::Replace($trimmed, '\s+#.*$', '')).Trim()
}

function ConvertFrom-InlineList {
    param([string] $Value)
    $trimmed = $Value.Trim()
    if ($trimmed -eq '[]') { return @() }
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) { throw "Expected an inline YAML list, got '$Value'." }
    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if (-not $inner) { return @() }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($inner, '"(?:\\.|[^"\\])*"|''[^'']*''|[^,]+')) { [void]$items.Add((ConvertFrom-ConfigScalar $match.Value)) }
    return @($items)
}

function Read-Config {
    param([string] $Content)
    $values = @{}
    $lists = @{}
    $tasks = @{}
    $section = ''
    $taskName = ''
    $activeList = ''
    foreach ($rawLine in ($Content -split '\r?\n')) {
        $line = $rawLine.TrimEnd("`r")
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '^(?<indent>[ ]*)(?<key>[A-Za-z0-9_]+):[ \t]*(?<value>.*)$') {
            $indent = $Matches.indent.Length
            $key = $Matches.key
            $value = $Matches.value.Trim()
            $activeList = ''
            if ($indent -eq 0) {
                $section = $key
                $taskName = ''
                if ($value) { $values[$key] = if ($value.StartsWith('[')) { ConvertFrom-InlineList $value } else { ConvertFrom-ConfigScalar $value } }
                continue
            }
            if ($section -eq 'tasks' -and $indent -eq 2) { $taskName = $key; $tasks[$taskName] = @{}; continue }
            if ($section -eq 'tasks' -and $indent -ge 4 -and $taskName) {
                if ($key -eq 'args') { $tasks[$taskName][$key] = ConvertFrom-InlineList $value }
                else { $tasks[$taskName][$key] = if ($value) { ConvertFrom-ConfigScalar $value } else { '' } }
                continue
            }
            $path = "$section.$key"
            if ($value.StartsWith('[')) { $lists[$path] = ConvertFrom-InlineList $value }
            elseif ($value) { $values[$path] = ConvertFrom-ConfigScalar $value }
            else { $values[$path] = ''; $activeList = $path }
            continue
        }
        if ($activeList -and $line -match '^\s*-\s*(?<item>.*)$') {
            if (-not $lists.ContainsKey($activeList)) { $lists[$activeList] = @() }
            $lists[$activeList] = @($lists[$activeList] + (ConvertFrom-ConfigScalar $Matches.item))
            continue
        }
        throw "Unsupported YAML line: $line"
    }
    return [pscustomobject]@{ Values = $values; Lists = $lists; Tasks = $tasks }
}

function Get-ConfigValue {
    param([psobject] $Config, [string] $Key, [string] $Default = '')
    if ($Config.Values.ContainsKey($Key)) { return [string]$Config.Values[$Key] }
    return $Default
}
function Get-ConfigList {
    param([psobject] $Config, [string] $Key)
    if ($Config.Lists.ContainsKey($Key)) { return @($Config.Lists[$Key]) }
    if ($Config.Values.ContainsKey($Key) -and $Config.Values[$Key] -is [array]) { return @($Config.Values[$Key]) }
    return @()
}
function Get-CommandDisplay {
    param([string] $Executable, [string[]] $Arguments)
    $parts = @($Executable)
    foreach ($argument in $Arguments) { if ($argument -match '[\s"''`]') { $parts += '"' + $argument.Replace('"', '\"') + '"' } else { $parts += $argument } }
    return ($parts -join ' ')
}
function Get-GitValue {
    param([string] $Root, [string[]] $Arguments)
    Push-Location $Root
    try { $value = (& git @Arguments 2>$null | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $value) { return $value }; return 'unknown' }
    finally { Pop-Location }
}
function Get-TreeDigest {
    param([string] $Root, [string] $SpecRelativePath)
    $payload = Get-GitValue -Root $Root -Arguments @('diff', '--binary', 'HEAD', '--', '.', ":(exclude)$SpecRelativePath", ':(exclude).sdlc/**')
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
function Invoke-Task {
    param([string] $TaskName, [hashtable] $TaskConfig, [string] $EvidenceRoot, [string] $CommitSha, [string] $TreeDigest)
    $executable = [string]$TaskConfig.executable
    $arguments = @($TaskConfig.args)
    $command = Get-CommandDisplay -Executable $executable -Arguments $arguments
    $logPath = Join-Path $EvidenceRoot "$TaskName.log"
    $recordPath = Join-Path $EvidenceRoot "$TaskName.json"
    New-Item -ItemType File -Path $logPath -Force | Out-Null
    $started = [DateTime]::UtcNow
    Write-Host "[RUN] ${TaskName}: $command"
    Push-Location $RepoRoot
    try {
        & $executable @arguments 2>&1 | Tee-Object -FilePath $logPath | Out-Host
        $exitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    $finished = [DateTime]::UtcNow
    $result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $relativeLog = $logPath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\', '/'
    $record = [ordered]@{ schema = 1; kind = 'sdlc-task'; task = $TaskName; executable = $executable; args = @($arguments); command = $command; feature_id = $script:FeatureId; spec_path = $script:SpecRelativePath; commit_sha = $CommitSha; tree_digest = $TreeDigest; started_at = $started.ToString('yyyy-MM-ddTHH:mm:ssZ'); finished_at = $finished.ToString('yyyy-MM-ddTHH:mm:ssZ'); exit_code = $exitCode; result = $result; evidence = $relativeLog }
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8
    if ($RecordSpec) {
        $updates = @{
            ("gate_${TaskName}_command") = $command
            ("gate_${TaskName}_commit_sha") = $CommitSha
            ("gate_${TaskName}_tree_digest") = $TreeDigest
            ("gate_${TaskName}_timestamp") = $finished.ToString('yyyy-MM-ddTHH:mm:ssZ')
            ("gate_${TaskName}_exit_code") = [string]$exitCode
            ("gate_${TaskName}_result") = $result
            ("gate_${TaskName}_evidence") = $relativeLog
        }
        if ($script:FeatureId) {
            $updates[("gate_${TaskName}_feature_id")] = $script:FeatureId
            $updates[("gate_${TaskName}_spec_path")] = $script:SpecRelativePath
        }
        Set-SpecMetadata -Path $SpecPath -Updates $updates
    }
    Write-Host "[$result] $TaskName; evidence: $recordPath"
    return $exitCode
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$validator = Join-Path $PSScriptRoot 'validate-sdlc-config.ps1'
$validatorArguments = @('-ConfigPath', $ConfigPath, '-RepoRoot', $RepoRoot, '-EvidenceDirectory', $EvidenceDirectory)
if ($FeatureId) { $validatorArguments += @('-FeatureId', $FeatureId) }
if ($RecordSpec) { $validatorArguments += @('-SpecPath', $SpecPath, '-RecordSpec') }
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator @validatorArguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$config = Read-Config -Content ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path))
if (-not $EvidenceDirectory) { $EvidenceDirectory = Get-ConfigValue $config 'validation.evidence_directory' '.sdlc/evidence' }
$evidenceRoot = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse', 'HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot -SpecRelativePath $specRelativePath
$taskNames = @()
if ($Task -eq 'all') {
    $installTask = Get-ConfigValue $config 'validation.install_task'
    if ($installTask -and $installTask -ne 'none') { $taskNames += $installTask }
    $taskNames += @(Get-ConfigList $config 'validation.required_tasks')
    $taskNames += @(Get-ConfigList $config 'validation.optional_tasks')
    $taskNames += @(Get-ConfigList $config 'security.tasks')
}
else { $taskNames = @($Task) }
$seen = @{}
foreach ($taskName in $taskNames) {
    if ($seen.ContainsKey($taskName)) { continue }
    $seen[$taskName] = $true
    if (-not $config.Tasks.ContainsKey($taskName)) { Write-Host "[FAIL] Task '$taskName' is not configured."; exit 1 }
    $exitCode = Invoke-Task -TaskName $taskName -TaskConfig $config.Tasks[$taskName] -EvidenceRoot $evidenceRoot -CommitSha $commitSha -TreeDigest $treeDigest
    if ($exitCode -ne 0) { exit $exitCode }
}
Write-Host "[PASS] SDLC task run complete: $($taskNames -join ', ')"
exit 0
