[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $SpecPath,
    [string] $EvidenceDirectory,
    [string] $FeatureId,
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

function Get-MeasurementBody {
    param([string] $Content)
    $match = [regex]::Match($Content, '(?ms)^measurement:\s*\r?\n(?<body>.*?)(?=^\S|\z)')
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}
function Get-MeasurementValue {
    param([string] $Body, [string] $Name, [string] $Default = '')
    if ($null -eq $Body) { return $Default }
    $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)')
    if (-not $match.Success) { return $Default }
    return $match.Groups['value'].Value.Trim().Trim('"', "'")
}
function Get-MeasurementList {
    param([string] $Body, [string] $Name)
    $value = Get-MeasurementValue -Body $Body -Name $Name
    if (-not $value.StartsWith('[') -or -not $value.EndsWith(']')) { return @() }
    return @($value.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ })
}
function Test-SafeRelativePath {
    param([string] $Path)
    return -not ([string]::IsNullOrWhiteSpace($Path) -or [System.IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)')
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
    param([string] $Root, [string] $SpecRelativePath)
    $payload = Get-GitValue -Root $Root -Arguments @('diff', '--binary', 'HEAD', '--', '.', ":(exclude)$SpecRelativePath", ':(exclude)docs/specs/**/tasks.json', ':(exclude).sdlc/**')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
function Get-RelativePath {
    param([string] $Root, [string] $Path)
    $rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.Substring($rootPath.Length) -replace '\\','/'
}
function Get-PythonExecutable {
    foreach ($name in @('python', 'python3')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command.Source }
    }
    return $null
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

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config file not found: $ConfigPath"; exit 1 }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-MeasurementBody -Content $content
if ($null -eq $body -or (Get-MeasurementValue -Body $body -Name 'enabled' -Default 'false') -ne 'true') { Write-Host '[SKIP] Measurement is disabled.'; exit 0 }

$validator = Join-Path $PSScriptRoot 'validate-measurement.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $validator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$runner = Join-Path $RepoRoot 'scripts/run-sdlc-task.ps1'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { Write-Host "[FAIL] Task runner not found: $runner"; exit 1 }

$taskFields = @('baseline_task','snapshot_task','review_task')
$checks = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[string]
foreach ($field in $taskFields) {
    $taskName = Get-MeasurementValue -Body $body -Name $field
    Write-Host "[RUN] Measurement check: $taskName"
    $runnerArguments = @('-Task', $taskName, '-RepoRoot', $RepoRoot, '-ConfigPath', $ConfigPath, '-EvidenceDirectory', $EvidenceDirectory)
    if ($FeatureId) { $runnerArguments += @('-FeatureId', $FeatureId) }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $runner @runnerArguments
    $exitCode = $LASTEXITCODE
    $result = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $evidence = Join-Path $RepoRoot "$EvidenceDirectory/$taskName.log"
    $check = [ordered]@{
        task = $taskName
        purpose = $field
        exit_code = $exitCode
        result = $result
        evidence = if (Test-Path -LiteralPath $evidence) { Get-RelativePath -Root $RepoRoot -Path $evidence } else { '' }
    }
    [void]$checks.Add([pscustomobject]$check)
    if ($exitCode -ne 0) { [void]$errors.Add("Measurement task '$taskName' failed with exit code $exitCode.") }
}

$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory
New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$snapshotPath = Get-MeasurementValue -Body $body -Name 'snapshot_path'
$snapshotValidationPath = Join-Path $recordDirectory 'measurement-snapshot-validation.json'
$snapshotExitCode = 1
$snapshotEvidence = ''
if (-not (Test-SafeRelativePath $snapshotPath)) {
    [void]$errors.Add("measurement.snapshot_path must be repository-relative: $snapshotPath")
}
else {
    $snapshotFullPath = Join-Path $RepoRoot $snapshotPath
    $python = Get-PythonExecutable
    $snapshotValidator = Join-Path $PSScriptRoot 'validate-measurement-snapshot.py'
    $expectedMetrics = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('baseline_metrics','delivery_metrics','phase_outcome_metrics','phase_leading_indicators')) {
        foreach ($metric in @(Get-MeasurementList -Body $body -Name $name)) { [void]$expectedMetrics.Add($metric) }
    }
    if ((Get-MeasurementValue -Body $body -Name 'ai_product_metrics_applicable' -Default 'false') -eq 'true') {
        foreach ($metric in @(Get-MeasurementList -Body $body -Name 'ai_product_metrics')) { [void]$expectedMetrics.Add($metric) }
    }
    if (-not $python) {
        [void]$errors.Add('Python 3 is required to validate the measurement snapshot.')
    }
    elseif (-not (Test-Path -LiteralPath $snapshotValidator -PathType Leaf)) {
        [void]$errors.Add("Measurement snapshot validator is missing: $snapshotValidator")
    }
    else {
        $snapshotArguments = @(
            $snapshotValidator,
            '--snapshot-path', $snapshotFullPath,
            '--repo-root', $RepoRoot,
            '--owner', (Get-MeasurementValue -Body $body -Name 'owner'),
            '--retention-days', (Get-MeasurementValue -Body $body -Name 'retention_days'),
            '--config-path', $ConfigPath,
            '--catalog-path', (Join-Path $RepoRoot (Get-MeasurementValue -Body $body -Name 'catalog_path')),
            '--model', (Get-MeasurementValue -Body $body -Name 'model'),
            '--validation-evidence-path', $snapshotValidationPath
        )
        foreach ($metric in $expectedMetrics) { $snapshotArguments += @('--metric', $metric) }
        & $python @snapshotArguments
        $snapshotExitCode = $LASTEXITCODE
        if ($snapshotExitCode -ne 0) { [void]$errors.Add("Measurement snapshot validation failed with exit code $snapshotExitCode.") }
    }
    if (Test-Path -LiteralPath $snapshotFullPath -PathType Leaf) { $snapshotEvidence = Get-RelativePath -Root $RepoRoot -Path $snapshotFullPath }
}
$snapshotCheck = [ordered]@{
    task = 'measurement_snapshot_schema'
    purpose = 'snapshot_validation'
    exit_code = $snapshotExitCode
    result = if ($snapshotExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    evidence = if (Test-Path -LiteralPath $snapshotValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $snapshotValidationPath } else { '' }
}
[void]$checks.Add([pscustomobject]$snapshotCheck)

$python = if ($python) { $python } else { Get-PythonExecutable }
$enginePath = Join-Path $PSScriptRoot 'measurement.py'
$reportPath = Get-MeasurementValue -Body $body -Name 'report_path'
$reportValidationPath = Join-Path $recordDirectory 'measurement-report-validation.json'
$reportExitCode = 1
$reportEvidence = ''
if (-not (Test-SafeRelativePath $reportPath)) {
    [void]$errors.Add("measurement.report_path must be repository-relative: $reportPath")
}
elseif (-not $python) {
    [void]$errors.Add('Python 3 is required to generate the measurement report.')
}
elseif (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    [void]$errors.Add("Measurement engine is missing: $enginePath")
}
else {
    $reportFullPath = Join-Path $RepoRoot $reportPath
    & $python $enginePath report --config-path $ConfigPath --repo-root $RepoRoot --output-path $reportFullPath --evidence-path $reportValidationPath
    $reportExitCode = $LASTEXITCODE
    if ($reportExitCode -ne 0) { [void]$errors.Add("Measurement report generation failed with exit code $reportExitCode.") }
    if (Test-Path -LiteralPath $reportFullPath -PathType Leaf) { $reportEvidence = Get-RelativePath -Root $RepoRoot -Path $reportFullPath }
}
$reportCheck = [ordered]@{
    task = 'measurement_report'
    purpose = 'aggregate_report'
    exit_code = $reportExitCode
    result = if ($reportExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    evidence = if (Test-Path -LiteralPath $reportValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $reportValidationPath } else { '' }
}
[void]$checks.Add([pscustomobject]$reportCheck)

$reviewValidationPath = Join-Path $recordDirectory 'measurement-review-validation.json'
$reviewExitCode = 1
if ($reportExitCode -eq 0 -and $python -and (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    & $python $enginePath validate-review --config-path $ConfigPath --repo-root $RepoRoot --report-path (Join-Path $RepoRoot $reportPath) --evidence-path $reviewValidationPath
    $reviewExitCode = $LASTEXITCODE
    if ($reviewExitCode -ne 0) { [void]$errors.Add("Measurement review validation failed with exit code $reviewExitCode.") }
}
else {
    [void]$errors.Add('Measurement review validation was skipped because the report did not pass.')
}
$reviewCheck = [ordered]@{
    task = 'measurement_review_schema'
    purpose = 'improvement_experiment_validation'
    exit_code = $reviewExitCode
    result = if ($reviewExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    evidence = if (Test-Path -LiteralPath $reviewValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $reviewValidationPath } else { '' }
}
[void]$checks.Add([pscustomobject]$reviewCheck)
$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse', 'HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot -SpecRelativePath $specRelativePath
$checkedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
$exitCode = if ($errors.Count -eq 0) { 0 } else { 1 }
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-measurement'
    command = 'scripts/run-measurement.ps1'
    model = Get-MeasurementValue -Body $body -Name 'model'
    cohort = Get-MeasurementValue -Body $body -Name 'cohort'
    owner = Get-MeasurementValue -Body $body -Name 'owner'
    cadence = Get-MeasurementValue -Body $body -Name 'cadence'
    feature_id = $FeatureId
    spec_path = $specRelativePath
    commit_sha = $commitSha
    tree_digest = $treeDigest
    measured_at = $checkedAt
    snapshot_evidence = $snapshotEvidence
    report_evidence = $reportEvidence
    snapshot_validation_evidence = if (Test-Path -LiteralPath $snapshotValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $snapshotValidationPath } else { '' }
    report_validation_evidence = if (Test-Path -LiteralPath $reportValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $reportValidationPath } else { '' }
    review_validation_evidence = if (Test-Path -LiteralPath $reviewValidationPath -PathType Leaf) { Get-RelativePath -Root $RepoRoot -Path $reviewValidationPath } else { '' }
    metrics = [ordered]@{
        baseline = @(Get-MeasurementList -Body $body -Name 'baseline_metrics')
        delivery = @(Get-MeasurementList -Body $body -Name 'delivery_metrics')
        ai_product = @(Get-MeasurementList -Body $body -Name 'ai_product_metrics')
        phase_outcomes = @(Get-MeasurementList -Body $body -Name 'phase_outcome_metrics')
        phase_leading_indicators = @(Get-MeasurementList -Body $body -Name 'phase_leading_indicators')
    }
    exit_code = $exitCode
    result = $result
    checks = $checks.ToArray()
    errors = $errors.ToArray()
}
$summaryPath = Join-Path $recordDirectory 'measurement.json'
$json = $record | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($summaryPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
if ($RecordSpec) {
    $updates = @{
        measurement_enabled = 'true'
        gate_measurement_command = 'scripts/run-measurement.ps1'
        gate_measurement_commit_sha = $commitSha
        gate_measurement_tree_digest = $treeDigest
        gate_measurement_timestamp = $checkedAt
        gate_measurement_exit_code = [string]$exitCode
        gate_measurement_result = $result
        gate_measurement_evidence = Get-RelativePath -Root $RepoRoot -Path $summaryPath
    }
    if ($FeatureId) {
        $updates['gate_measurement_feature_id'] = $FeatureId
        $updates['gate_measurement_spec_path'] = $specRelativePath
    }
    Set-SpecMetadata -Path $SpecPath -Updates $updates
}
if ($errors.Count -gt 0) { Write-Host '[FAIL] Measurement checks failed.'; exit 1 }
Write-Host "[PASS] Measurement checks complete: $summaryPath"
exit 0