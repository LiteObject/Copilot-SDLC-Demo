<#
.SYNOPSIS
    Migrates a legacy docs/spec.md to the versioned workflow metadata format.

.DESCRIPTION
    The command preserves the existing Markdown body, extracts the current
    phase, review cycle, meaningful Design content, and exact File Structure
    entries, then prepends schema version 1 metadata. It never writes without
    -Force and always creates a backup before replacing the project-owned spec.

    Exit codes:
      0 - Already migrated or migration completed.
      1 - Migration failed because the input is missing or malformed.
      2 - Migration is required or refused without explicit confirmation.

.PARAMETER SpecPath
    Path to the legacy spec. Defaults to docs/spec.md.

.PARAMETER RepoRoot
    Repository root used for relative paths. Defaults to the template script's
    target repository root.

.PARAMETER ConfigPath
    Optional path to .github/sdlc-config.yml.

.PARAMETER BackupPath
    Optional backup path. Defaults to .sdlc/migrations/<timestamp>.legacy.bak.

.PARAMETER Force
    Write the migrated spec after creating the backup.
#>
[CmdletBinding()]
param(
    [string] $SpecPath,
    [string] $RepoRoot,
    [string] $ConfigPath,
    [string] $BackupPath,
    [string] $FeatureId,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'feature-context.ps1')

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$sourceSpecPath = if ($SpecPath) { $SpecPath } else { Join-Path $RepoRoot 'docs/spec.md' }
if ($FeatureId) {
    $featureContext = Resolve-FeatureContext -RepoRoot $RepoRoot -FeatureId $FeatureId
    $targetSpecPath = $featureContext.SpecPath
    $specRelativePath = $featureContext.SpecRelativePath
}
else {
    $targetSpecPath = $sourceSpecPath
    $specRelativePath = 'docs/spec.md'
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml'
}

function Normalize-RelativePath {
    param([string] $Path)

    $normalized = $Path.Trim() -replace '\\', '/'
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized
}

function Get-SectionBody {
    param(
        [string] $Content,
        [string] $Section
    )

    $pattern = '(?ms)^## ' + [regex]::Escape($Section) + '\s*\r?\n(.*?)(?=^## |^---\s*$|\z)'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-LegacyScalar {
    param(
        [string] $Content,
        [string] $Section
    )

    $pattern = '## ' + [regex]::Escape($Section) + '\s*\r?\n\s*`([^`]+)`'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

function Get-MeaningfulText {
    param([string] $Body)

    $clean = $Body
    $clean = $clean -replace '(?s)<!--.*?-->', ''
    $clean = $clean -replace '(?m)^_.*(?:PM|Designer|Architect|Reviewer|QA).*_\s*$', ''
    $clean = $clean -replace '\((?:PM|Designer|Architect|Reviewer|QA)[^)]*\)', ''
    $clean = $clean -replace '(?m)^\s*```[^\r\n]*$', ''
    $clean = $clean -replace '(?m)^\s*-\s*\[ \]\s*$', ''
    $clean = $clean -replace '(?m)^\s*-?\s*$', ''
    return $clean.Trim()
}

function Get-LegacyPlannedFiles {
    param([string] $Content)

    $match = [regex]::Match(
        $Content,
        '(?ms)^## File Structure\s*\r?\n.*?^```[^\r\n]*\r?\n(?<body>.*?)\r?\n```'
    )
    if (-not $match.Success) { return @() }

    $files = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($match.Groups['body'].Value -split '\r?\n')) {
        $path = Normalize-RelativePath $line
        if ([string]::IsNullOrWhiteSpace($path) -or $path.StartsWith('#') -or $path.StartsWith('//')) {
            continue
        }
        if ($path.EndsWith('/')) {
            Write-Host "[WARN] Skipping legacy directory scope entry '$path'; add exact files after migration."
            continue
        }
        if ($path -match '(^|/)\.\.(?:/|$)' -or $path.StartsWith('/') -or $path -match '^[A-Za-z]:/') {
            Write-Host "[WARN] Skipping unsafe legacy scope entry '$path'."
            continue
        }
        if (-not $files.Contains($path)) { [void]$files.Add($path) }
    }
    return @($files)
}

if (-not (Test-Path -LiteralPath $sourceSpecPath -PathType Leaf)) {
    Write-Host "[FAIL] Legacy spec not found at: $sourceSpecPath"
    exit 1
}
if ($FeatureId -and (Test-Path -LiteralPath $targetSpecPath -PathType Leaf)) {
    Write-Host "[FAIL] Feature spec already exists at: $targetSpecPath"
    exit 1
}

$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $sourceSpecPath).Path)
$frontMatterMatch = [regex]::Match(
    $content,
    '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)
if ($frontMatterMatch.Success) {
    if ($frontMatterMatch.Groups['frontmatter'].Value -match '(?m)^sdlc_schema:\s*1\s*$') {
        Write-Host '[PASS] Source spec already uses workflow metadata schema 1.'
        exit 0
    }
    Write-Host '[FAIL] docs/spec.md has front matter but not the supported sdlc_schema: 1 format.'
    exit 1
}

$validStates = @('GATHERING_REQS', 'DESIGN', 'PLANNING', 'CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')
$currentPhase = Get-LegacyScalar -Content $content -Section 'Current State'
if ($currentPhase -notin $validStates) {
    Write-Host "[FAIL] Legacy Current State '$currentPhase' is missing or invalid."
    exit 1
}

$reviewCycleText = Get-LegacyScalar -Content $content -Section 'Review Cycle'
$reviewCycle = 0
if ($reviewCycleText -and (-not [int]::TryParse($reviewCycleText, [ref]$reviewCycle) -or $reviewCycle -lt 0 -or $reviewCycle -gt 3)) {
    Write-Host "[FAIL] Legacy Review Cycle '$reviewCycleText' must be an integer from 0 through 3."
    exit 1
}

$designRequired = -not [string]::IsNullOrWhiteSpace((Get-MeaningfulText (Get-SectionBody -Content $content -Section 'Design')))
$deploymentReadinessEnabled = $false
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $configText = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
    $deploymentReadinessEnabled = $configText -match '(?m)^\s*deployment_readiness_gate:\s*true\s*$'
}
$aiGovernanceEnabled = $false
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $aiGovernanceEnabled = $configText -match '(?ms)^ai_governance:\s*\r?\n(?:(?!^\S).)*?^\s+enabled:\s*true\s*$'
}
$aiLifecycleEnabled = $false
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $aiLifecycleEnabled = $configText -match '(?ms)^ai_lifecycle:\s*\r?\n(?:(?!^\S).)*?^\s+enabled:\s*true\s*$'
}
$measurementEnabled = $false
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    $measurementEnabled = $configText -match '(?ms)^measurement:\s*\r?\n(?:(?!^\S).)*?^\s+enabled:\s*true\s*$'
}

$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
if (-not $BackupPath) {
    $migrationFolder = if ($FeatureId) { ".sdlc/migrations/$FeatureId" } else { '.sdlc/migrations' }
    $BackupPath = Join-Path $RepoRoot ("$migrationFolder/spec.md.$($timestamp.Replace(':', '').Replace('-', '')).legacy.bak")
}
if (-not [System.IO.Path]::IsPathRooted($BackupPath)) {
    $BackupPath = Join-Path $RepoRoot $BackupPath
}
$backupDirectory = Split-Path -Parent $BackupPath
$rootFullPath = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
$backupFullPath = [System.IO.Path]::GetFullPath($BackupPath)
if (-not $backupFullPath.StartsWith($rootFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "[FAIL] Backup path must be inside the repository root: $BackupPath"
    exit 1
}
$backupRelativePath = Normalize-RelativePath $backupFullPath.Substring($rootFullPath.Length)
$plannedFiles = @(Get-LegacyPlannedFiles -Content $content)
$newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }

$metadataLines = New-Object System.Collections.Generic.List[string]
foreach ($line in @(
        '---',
        'sdlc_schema: 1',
        ('feature_id: "' + $FeatureId + '"'),
        ('spec_path: "' + $specRelativePath + '"'),
        "current_phase: $currentPhase",
        "design_required: $($designRequired.ToString().ToLowerInvariant())",
        "deployment_readiness_enabled: $($deploymentReadinessEnabled.ToString().ToLowerInvariant())",
        "ai_governance_enabled: $($aiGovernanceEnabled.ToString().ToLowerInvariant())",
        "ai_lifecycle_enabled: $($aiLifecycleEnabled.ToString().ToLowerInvariant())",
        "measurement_enabled: $($measurementEnabled.ToString().ToLowerInvariant())",
        'security_gate_enabled: false',
        "review_cycle: $reviewCycle",
        'revision_commit_sha: ""',
        'revision_tree_digest: ""',
        'last_transition_from: legacy',
        "last_transition_to: $currentPhase",
        "last_transition_timestamp: $timestamp",
        'last_transition_actor: migration',
        "last_transition_evidence: $backupRelativePath"
    )) { [void]$metadataLines.Add($line) }
if ($plannedFiles.Count -eq 0) {
    [void]$metadataLines.Add('planned_files: []')
}
else {
    [void]$metadataLines.Add('planned_files:')
    foreach ($file in $plannedFiles) { [void]$metadataLines.Add("  - $file") }
}
[void]$metadataLines.Add('approved_globs: []')
foreach ($gate in @('requirements', 'config', 'install', 'design', 'planning', 'build', 'security', 'review', 'test', 'lint', 'type_check', 'package', 'deploy', 'sbom', 'smoke_test', 'rollback', 'release', 'deployment_readiness', 'ai_governance', 'ai_lifecycle', 'measurement')) {
    foreach ($line in @(
            ('gate_' + $gate + '_command: ""'),
            ('gate_' + $gate + '_commit_sha: ""'),
            ('gate_' + $gate + '_tree_digest: ""'),
            ('gate_' + $gate + '_timestamp: ""'),
            ('gate_' + $gate + '_exit_code: ""'),
            ('gate_' + $gate + '_result: NOT_RUN'),
            ('gate_' + $gate + '_evidence: ""'),
            ('gate_' + $gate + '_feature_id: "' + $FeatureId + '"'),
            ('gate_' + $gate + '_spec_path: "' + $specRelativePath + '"')
        )) { [void]$metadataLines.Add($line) }
}
[void]$metadataLines.Add('---')
    $newContent = ($metadataLines -join $newline) + $newline + $content

Write-Host "[INFO] Legacy state: $currentPhase; review cycle: $reviewCycle; design required: $designRequired; readiness enabled: $deploymentReadinessEnabled"
Write-Host "[INFO] Exact planned files recovered: $($plannedFiles.Count)"
Write-Host "[INFO] Backup: $BackupPath"

if (-not $Force) {
    Write-Host '[BLOCKED] Migration is a dry run. Re-run with -Force to create the backup and write the feature spec.'
    exit 2
}
if (Test-Path -LiteralPath $BackupPath) {
    Write-Host "[FAIL] Backup path already exists: $BackupPath"
    exit 1
}
if (Test-Path -LiteralPath $backupDirectory -PathType Leaf) {
    Write-Host "[FAIL] Backup directory path is a file: $backupDirectory"
    exit 1
}

New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
$targetDirectory = Split-Path -Parent $targetSpecPath
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
$temporarySpec = "$targetSpecPath.migration.tmp"
try {
    [System.IO.File]::WriteAllText($BackupPath, $content, $Utf8NoBom)
    [System.IO.File]::WriteAllText($temporarySpec, $newContent, $Utf8NoBom)
    Move-Item -LiteralPath $temporarySpec -Destination $targetSpecPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporarySpec) { Remove-Item -LiteralPath $temporarySpec -Force }
}

if ($FeatureId) {
    Write-Host "[PASS] Migrated legacy spec to feature '$FeatureId' at $targetSpecPath."
}
else {
    Write-Host '[PASS] Migrated docs/spec.md to workflow metadata schema 1.'
}