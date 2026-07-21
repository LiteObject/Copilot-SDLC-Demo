<#
.SYNOPSIS
    Validates the versioned .github/sdlc-config.yml contract.

.DESCRIPTION
    The supported YAML subset deliberately uses structured task records:
    executable plus args. It rejects shell command strings and validates the
    package manager, manifest, test directories, task registry, and command
    availability before implementation or CI starts.

    Exit codes:
      0 - configuration is valid
      1 - configuration is incomplete or invalid
      2 - configuration could not be parsed

.PARAMETER ConfigPath
    Path to .github/sdlc-config.yml. Defaults to the repository root.

.PARAMETER RepoRoot
    Repository root used for relative paths and Git revision evidence.

.PARAMETER EvidenceDirectory
    Directory for the validation JSON record. Defaults to validation.evidence_directory.

.PARAMETER SpecPath
    Path to docs/spec.md when -RecordSpec is supplied.

.PARAMETER RecordSpec
    Write gate_config_* fields in docs/spec.md after recording the evidence.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $EvidenceDirectory,
    [string] $SpecPath,
    [switch] $RecordSpec
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml'
}
if (-not $SpecPath) {
    $SpecPath = Join-Path $RepoRoot 'docs/spec.md'
}

function ConvertFrom-ConfigScalar {
    param([string] $Value)

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace('\"', '"')
    }
    return ([regex]::Replace($trimmed, '\s+#.*$', '')).Trim()
}

function ConvertFrom-InlineList {
    param([string] $Value)

    $trimmed = $Value.Trim()
    if ($trimmed -eq '[]') { return @() }
    if (-not ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']'))) {
        throw "Expected an inline YAML list, got '$Value'."
    }

    $inner = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    if (-not $inner) { return @() }
    $items = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($inner, '"(?:\\.|[^"\\])*"|''[^'']*''|[^,]+')) {
        [void]$items.Add((ConvertFrom-ConfigScalar $match.Value))
    }
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
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }

        if ($line -match '^(?<indent>[ ]*)(?<key>[A-Za-z0-9_]+):[ \t]*(?<value>.*)$') {
            $indent = $Matches.indent.Length
            $key = $Matches.key
            $value = $Matches.value.Trim()
            $activeList = ''

            if ($indent -eq 0) {
                $section = $key
                $taskName = ''
                if ($value) {
                    $values[$key] = if ($value.StartsWith('[')) { ConvertFrom-InlineList $value } else { ConvertFrom-ConfigScalar $value }
                }
                continue
            }

            if ($section -eq 'tasks' -and $indent -eq 2) {
                $taskName = $key
                $tasks[$taskName] = @{}
                continue
            }

            if ($section -eq 'tasks' -and $indent -ge 4 -and $taskName) {
                if ($key -eq 'args') {
                    $tasks[$taskName][$key] = ConvertFrom-InlineList $value
                }
                elseif ($value) {
                    $tasks[$taskName][$key] = ConvertFrom-ConfigScalar $value
                }
                else {
                    $tasks[$taskName][$key] = ''
                }
                continue
            }

            $path = "$section.$key"
            if ($value.StartsWith('[')) {
                $lists[$path] = ConvertFrom-InlineList $value
            }
            elseif ($value) {
                $values[$path] = ConvertFrom-ConfigScalar $value
            }
            else {
                $values[$path] = ''
                $activeList = $path
            }
            continue
        }

        if ($activeList -and $line -match '^\s*-\s*(?<item>.*)$') {
            if (-not $lists.ContainsKey($activeList)) { $lists[$activeList] = @() }
            $lists[$activeList] = @($lists[$activeList] + (ConvertFrom-ConfigScalar $Matches.item))
            continue
        }

        throw "Unsupported YAML line: $line"
    }

    return [pscustomobject]@{
        Values = $values
        Lists  = $lists
        Tasks  = $tasks
    }
}

function Get-ConfigValue {
    param(
        [psobject] $Config,
        [string] $Key,
        [string] $Default = ''
    )

    if ($Config.Values.ContainsKey($Key)) { return [string]$Config.Values[$Key] }
    return $Default
}

function Get-ConfigList {
    param(
        [psobject] $Config,
        [string] $Key
    )

    if ($Config.Lists.ContainsKey($Key)) { return @($Config.Lists[$Key]) }
    if ($Config.Values.ContainsKey($Key) -and $Config.Values[$Key] -is [array]) { return @($Config.Values[$Key]) }
    return @()
}

function Add-ValidationError {
    param(
        [System.Collections.Generic.List[string]] $Errors,
        [string] $Message
    )

    [void]$Errors.Add($Message)
    Write-Host "[FAIL] $Message"
}

function Test-SafeRelativePath {
    param([string] $Path)

    return -not ([string]::IsNullOrWhiteSpace($Path) -or
        [System.IO.Path]::IsPathRooted($Path) -or
        $Path -match '(^|[\\/])\.\.([\\/]|$)')
}

function Get-CommandDisplay {
    param(
        [string] $Executable,
        [string[]] $Arguments
    )

    $parts = @($Executable)
    foreach ($argument in $Arguments) {
        if ($argument -match '[\s"''`]') { $parts += '"' + $argument.Replace('"', '\"') + '"' }
        else { $parts += $argument }
    }
    return ($parts -join ' ')
}

function Get-GitValue {
    param(
        [string] $Root,
        [string[]] $Arguments
    )

    Push-Location $Root
    try {
        $value = (& git @Arguments 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $value) { return $value }
        return 'unknown'
    }
    finally {
        Pop-Location
    }
}

function Get-TreeDigest {
    param([string] $Root)

    $payload = Get-GitValue -Root $Root -Arguments @('diff', '--binary', 'HEAD', '--', '.', ':(exclude)docs/spec.md', ':(exclude).sdlc/**')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Set-SpecMetadata {
    param(
        [string] $Path,
        [hashtable] $Updates
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Spec file not found for -RecordSpec: $Path"
    }
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path)
    $lines = @(Get-Content -LiteralPath $Path)
    foreach ($key in $Updates.Keys) {
        $found = $false
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match ('^' + [regex]::Escape($key) + ':')) {
                $value = [string]$Updates[$key]
                if ($key -notmatch 'result|exit_code|_enabled') { $value = '"' + $value.Replace('"', '\"') + '"' }
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

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Host "[FAIL] Config file not found: $ConfigPath"
    exit 1
}

try {
    $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
    $config = Read-Config -Content $content
}
catch {
    Write-Host "[FAIL] Could not parse $ConfigPath`: $($_.Exception.Message)"
    exit 2
}

$errors = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$allowedPackageManagers = @('npm', 'yarn', 'pnpm', 'pip', 'poetry', 'cargo', 'dotnet', 'go', 'none')
$allowedTasks = @('install', 'build', 'test', 'lint', 'type_check', 'sast', 'secrets', 'dependency_audit', 'license_audit', 'container_scan', 'iac_scan', 'dast', 'security_tests', 'package', 'sbom', 'sign', 'verify_signature', 'deploy', 'smoke_test', 'rollback', 'health_check', 'telemetry_check', 'failure_drill', 'post_release_check', 'agent_evaluation', 'ai_evaluation', 'ai_red_team', 'ai_production_exercise', 'ai_rollback', 'ai_decommission', 'measurement_baseline', 'measurement_snapshot', 'measurement_review')
$allowedTestLayers = @('unit', 'integration', 'contract', 'api', 'e2e', 'accessibility', 'performance', 'resilience', 'fuzz', 'property')
$allowedSeverities = @('critical', 'high', 'medium', 'low', 'info')

if ((Get-ConfigValue $config 'sdlc_config_schema') -ne '1') {
    Add-ValidationError $errors "sdlc_config_schema must be 1."
}
$packageManager = Get-ConfigValue $config 'stack.package_manager'
if ($packageManager -notin $allowedPackageManagers) {
    Add-ValidationError $errors "stack.package_manager '$packageManager' is unsupported. Supported values: $($allowedPackageManagers -join ', ')."
}
$manifest = Get-ConfigValue $config 'stack.package_manifest'
if ($packageManager -eq 'none') {
    if ($manifest -and $manifest -ne 'none') { Add-ValidationError $errors "stack.package_manifest must be empty or 'none' when package_manager is none." }
}
elseif ([string]::IsNullOrWhiteSpace($manifest)) {
    Add-ValidationError $errors 'stack.package_manifest is required for a managed package_manager.'
}
elseif (-not (Test-SafeRelativePath $manifest)) {
    Add-ValidationError $errors "stack.package_manifest must be a safe repository-relative file: $manifest"
}
elseif (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $manifest) -PathType Leaf)) {
    Add-ValidationError $errors "Package manifest does not exist: $manifest"
}

$framework = Get-ConfigValue $config 'testing.framework'
if ([string]::IsNullOrWhiteSpace($framework)) { Add-ValidationError $errors 'testing.framework must be configured.' }
$testDirectories = Get-ConfigList $config 'testing.directories'
if ($testDirectories.Count -eq 0) { Add-ValidationError $errors 'testing.directories must contain at least one directory.' }
foreach ($directory in $testDirectories) {
    if (-not (Test-SafeRelativePath $directory)) { Add-ValidationError $errors "Testing directory must be repository-relative: $directory"; continue }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $directory) -PathType Container)) { Add-ValidationError $errors "Testing directory does not exist: $directory" }
}

$requiredTasks = Get-ConfigList $config 'validation.required_tasks'
$optionalTasks = Get-ConfigList $config 'validation.optional_tasks'
$installTask = Get-ConfigValue $config 'validation.install_task'
if ($requiredTasks.Count -eq 0) { Add-ValidationError $errors 'validation.required_tasks must contain build and test.' }
foreach ($requiredTask in @('build', 'test')) {
    if ($requiredTasks -notcontains $requiredTask) { Add-ValidationError $errors "validation.required_tasks must include '$requiredTask'." }
}
foreach ($task in @($requiredTasks + $optionalTasks + $securityTasks)) {
    if ([string]::IsNullOrWhiteSpace([string]$task)) { continue }
    if ($task -notin $allowedTasks -or $task -eq 'install') { Add-ValidationError $errors "Unknown validation task '$task'." }
}
if (($requiredTasks | Where-Object { $optionalTasks -contains $_ }).Count -gt 0) { Add-ValidationError $errors 'A task cannot be both required and optional.' }
if ($installTask -ne 'none' -and $installTask -notin $allowedTasks) { Add-ValidationError $errors "validation.install_task must be install or none, not '$installTask'." }
if ($packageManager -eq 'none' -and $installTask -ne 'none') { Add-ValidationError $errors 'validation.install_task must be none when package_manager is none.' }
if ($packageManager -ne 'none' -and $installTask -eq 'none') { Add-ValidationError $errors 'validation.install_task must be install for a managed package_manager.' }

$riskProfile = Get-ConfigValue $config 'quality_security.risk_profile'
if ($riskProfile -notin @('low', 'medium', 'high', 'critical')) { Add-ValidationError $errors "quality_security.risk_profile '$riskProfile' must be low, medium, high, or critical." }
$testLayers = Get-ConfigList $config 'quality_security.required_test_layers'
if ($testLayers.Count -eq 0) { Add-ValidationError $errors 'quality_security.required_test_layers must contain at least one test layer.' }
foreach ($layer in $testLayers) { if ($layer -notin $allowedTestLayers) { Add-ValidationError $errors "Unsupported required test layer '$layer'." } }
$mappingRequired = Get-ConfigValue $config 'quality_security.acceptance_mapping_required'
if ($mappingRequired -notin @('true', 'false')) { Add-ValidationError $errors 'quality_security.acceptance_mapping_required must be true or false.' }
$securityReviewRequired = Get-ConfigValue $config 'security.review_required'
$aiGovernanceEnabled = Get-ConfigValue $config 'ai_governance.enabled' 'false'
$aiLifecycleEnabled = Get-ConfigValue $config 'ai_lifecycle.enabled' 'false'
$measurementEnabled = Get-ConfigValue $config 'measurement.enabled' 'false'
if ($securityReviewRequired -notin @('true', 'false')) { Add-ValidationError $errors 'security.review_required must be true or false.' }
$securityTasks = @(Get-ConfigList $config 'security.tasks' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$blockingSeverities = @(Get-ConfigList $config 'security.blocking_severities' | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($blockingSeverities.Count -eq 0) { Add-ValidationError $errors 'security.blocking_severities must contain at least one severity.' }
foreach ($severity in $blockingSeverities) { if ($severity -notin $allowedSeverities) { Add-ValidationError $errors "Unsupported blocking severity '$severity'." } }
foreach ($securityTask in $securityTasks) {
    if ($securityTask -notin @('sast', 'secrets', 'dependency_audit', 'license_audit', 'container_scan', 'iac_scan', 'dast', 'security_tests')) { Add-ValidationError $errors "Unsupported security task '$securityTask'." }
}
if ($securityReviewRequired -eq 'true' -and $securityTasks.Count -eq 0) { [void]$warnings.Add('security.review_required is true but security.tasks is empty; configure at least one scanner or security test task.') }

$allConfiguredTasks = @($requiredTasks + $optionalTasks + $securityTasks)
if ($installTask -ne 'none') { $allConfiguredTasks += $installTask }
$taskNames = @($config.Tasks.Keys)
foreach ($taskName in $taskNames) {
    if ($taskName -notin $allowedTasks) { Add-ValidationError $errors "Unknown task registry entry '$taskName'." }
}
foreach ($taskName in $allConfiguredTasks | Select-Object -Unique) {
    if ([string]::IsNullOrWhiteSpace([string]$taskName)) { continue }
    if (-not $config.Tasks.ContainsKey($taskName)) {
        Add-ValidationError $errors "Task '$taskName' is listed but has no tasks.$taskName record."
        continue
    }
    $task = $config.Tasks[$taskName]
    $executable = if ($task.ContainsKey('executable')) { [string]$task.executable } else { '' }
    if ([string]::IsNullOrWhiteSpace($executable)) { Add-ValidationError $errors "tasks.$taskName.executable is required."; continue }
    if ($executable -match '[\s;&|<>$`]') { Add-ValidationError $errors "tasks.$taskName.executable must be a single executable, not shell syntax." }
    if (-not $task.ContainsKey('args') -or $null -eq $task.args) { Add-ValidationError $errors "tasks.$taskName.args must be an inline list." }
    if (-not (Get-Command $executable -ErrorAction SilentlyContinue)) { Add-ValidationError $errors "Executable for task '$taskName' is not available: $executable" }
}

$evidenceDirectory = if ($EvidenceDirectory) { $EvidenceDirectory } else { Get-ConfigValue $config 'validation.evidence_directory' '.sdlc/evidence' }
if (-not (Test-SafeRelativePath $evidenceDirectory)) { Add-ValidationError $errors "validation.evidence_directory must be repository-relative: $evidenceDirectory" }

if ($errors.Count -eq 0) {
    Write-Host "[PASS] Configuration schema 1 is valid for package manager '$packageManager'."
    Write-Host "[PASS] Required tasks: $($requiredTasks -join ', '); optional tasks: $(if ($optionalTasks.Count) { $optionalTasks -join ', ' } else { 'none' })."
}
else {
    Write-Host "[FAIL] Configuration validation found $($errors.Count) error(s)."
}

$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse', 'HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$recordDirectory = Join-Path $RepoRoot $evidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$recordPath = Join-Path $recordDirectory 'config-validation.json'
$record = [ordered]@{
    schema        = 1
    kind          = 'sdlc-config-validation'
    config_schema = Get-ConfigValue $config 'sdlc_config_schema'
    package_manager = $packageManager
    required_tasks = @($requiredTasks)
    optional_tasks = @($optionalTasks)
    risk_profile  = $riskProfile
    required_test_layers = @($testLayers)
    security_tasks = @($securityTasks)
    blocking_severities = @($blockingSeverities)
    command       = 'validate-sdlc-config'
    commit_sha    = $commitSha
    tree_digest   = $treeDigest
    timestamp     = $timestamp
    exit_code     = if ($errors.Count -eq 0) { 0 } else { 1 }
    result        = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
    errors        = @($errors)
    warnings      = @($warnings)
}
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recordPath -Encoding utf8
Write-Host "[INFO] Validation evidence: $recordPath"

if ($RecordSpec) {
    $repoFullPath = (Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $relativeEvidence = $recordPath.Substring($repoFullPath.Length) -replace '\\', '/'
    $updates = @{
        gate_config_command = 'scripts/validate-sdlc-config.ps1'
        gate_config_commit_sha = $commitSha
        gate_config_tree_digest = $treeDigest
        gate_config_timestamp = $timestamp
        gate_config_exit_code = if ($errors.Count -eq 0) { '0' } else { '1' }
        gate_config_result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
        gate_config_evidence = $relativeEvidence
    }
    if ($securityReviewRequired -eq 'true') { $updates['security_gate_enabled'] = 'true' }
    if ($aiGovernanceEnabled -eq 'true') { $updates['ai_governance_enabled'] = 'true' }
    if ($aiLifecycleEnabled -eq 'true') { $updates['ai_lifecycle_enabled'] = 'true' }
    if ($measurementEnabled -eq 'true') { $updates['measurement_enabled'] = 'true' }
    try { Set-SpecMetadata -Path $SpecPath -Updates $updates; Write-Host "[INFO] Recorded gate_config_* in $SpecPath" }
    catch { Write-Host "[FAIL] Could not record config gate in spec: $($_.Exception.Message)"; $errors.Add($_.Exception.Message) }
}

if ($errors.Count -gt 0) { exit 1 }
exit 0
