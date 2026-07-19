<#
.SYNOPSIS
    Compares changed files with the explicit planned_files scope in docs/spec.md.

.DESCRIPTION
    Exact paths are the default. Glob patterns are accepted only when a
    matching approved_globs record contains pattern, justification, approver,
    revision, and timestamp fields separated by '|'. Directory entries such as
    src/ are rejected.

    Exit codes:
      0 - Scope is clean.
      1 - Scope creep or missing files detected.
      2 - The scope plan could not be parsed or is invalid.

.PARAMETER SpecPath
    Path to the spec file. Defaults to docs/spec.md in the repository root.

.PARAMETER RepoRoot
    Repository root used for Git operations and relative paths.

.PARAMETER BaseRef
    Git reference to diff against. Defaults to HEAD. Use staged for staged-only
    changes.
#>
[CmdletBinding()]
param(
    [string] $SpecPath,
    [string] $RepoRoot,
    [string] $BaseRef = 'HEAD'
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $SpecPath) {
    $SpecPath = Join-Path $RepoRoot 'docs/spec.md'
}

function ConvertFrom-YamlScalar {
    param([string] $Value)

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace('\"', '"')
    }
    return $trimmed
}

function Read-ScopeMetadata {
    param([string] $Content)

    $frontMatterMatch = [regex]::Match(
        $Content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $frontMatterMatch.Success) {
        throw "docs/spec.md must start with YAML front matter delimited by '---'."
    }

    $values = @{}
    $plannedFiles = New-Object System.Collections.Generic.List[string]
    $approvedGlobs = New-Object System.Collections.Generic.List[string]
    $activeList = $null
    foreach ($line in ($frontMatterMatch.Groups['frontmatter'].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }
        if ($line -match '^(?<key>[A-Za-z0-9_]+):[ \t]*(?<value>.*)$') {
            $key = $Matches.key
            $value = ConvertFrom-YamlScalar $Matches.value
            $values[$key] = $value
            $activeList = $null
            if ($key -in @('planned_files', 'approved_globs') -and $value -eq '') {
                $activeList = $key
            }
            elseif ($key -in @('planned_files', 'approved_globs') -and $value -ne '[]') {
                throw "Metadata list '$key' must use [] or an indented YAML list."
            }
            continue
        }
        if ($null -ne $activeList -and $line -match '^\s*-\s*(?<item>.*)$') {
            $item = ConvertFrom-YamlScalar $Matches.item
            if ($activeList -eq 'planned_files') { [void]$plannedFiles.Add($item) }
            else { [void]$approvedGlobs.Add($item) }
            continue
        }
        throw "Unsupported YAML front matter line: $line"
    }

    return [pscustomobject]@{
        Values        = $values
        PlannedFiles  = @($plannedFiles)
        ApprovedGlobs = @($approvedGlobs)
    }
}

function Normalize-RelativePath {
    param([string] $Path)

    $normalized = $Path.Trim() -replace '\\', '/'
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized
}

function Test-GlobPattern {
    param([string] $Pattern)

    return $Pattern.Contains('*') -or $Pattern.Contains('?') -or $Pattern.Contains('[')
}

function Convert-GlobToRegex {
    param([string] $Pattern)

    $escaped = [regex]::Escape($Pattern)
    $escaped = $escaped.Replace('\*\*', '.*')
    $escaped = $escaped.Replace('\*', '[^/]*')
    $escaped = $escaped.Replace('\?', '[^/]')
    return "^$escaped$"
}

function Find-GlobApproval {
    param(
        [string] $Pattern,
        [string[]] $ApprovedGlobs,
        [string] $Revision
    )

    foreach ($record in $ApprovedGlobs) {
        $parts = $record -split '\|', 5
        if ($parts.Count -ne 5) { continue }
        $approvalPattern = Normalize-RelativePath $parts[0]
        $justification = $parts[1].Trim()
        $approver = $parts[2].Trim()
        $approvalRevision = $parts[3].Trim()
        $timestamp = $parts[4].Trim()
        if ($approvalPattern -eq $Pattern -and
            $justification -and $approver -and $approvalRevision -and $timestamp -and
            ([string]::IsNullOrWhiteSpace($Revision) -or $approvalRevision -eq $Revision)) {
            return $true
        }
    }
    return $false
}

function Get-ChangedFiles {
    param(
        [string] $Root,
        [string] $Reference
    )

    $changed = New-Object System.Collections.Generic.List[string]
    Push-Location $Root
    try {
        if ($Reference -eq 'staged') {
            foreach ($file in @(git diff --cached --name-only 2>$null)) { if ($file) { [void]$changed.Add((Normalize-RelativePath $file)) } }
        }
        elseif ($Reference -eq 'HEAD') {
            foreach ($file in @(git diff --cached --name-only 2>$null)) { if ($file) { [void]$changed.Add((Normalize-RelativePath $file)) } }
            foreach ($file in @(git diff --name-only 2>$null)) { if ($file) { [void]$changed.Add((Normalize-RelativePath $file)) } }
            foreach ($file in @(git ls-files --others --exclude-standard 2>$null)) { if ($file) { [void]$changed.Add((Normalize-RelativePath $file)) } }
        }
        else {
            foreach ($file in @(git diff --name-only $Reference 2>$null)) { if ($file) { [void]$changed.Add((Normalize-RelativePath $file)) } }
        }
    }
    finally {
        Pop-Location
    }
    return @($changed | Sort-Object -Unique)
}

if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) {
    Write-Host "[ERROR] docs/spec.md not found at: $SpecPath"
    exit 2
}

$content = Get-Content -LiteralPath $SpecPath -Raw
try {
    $metadata = Read-ScopeMetadata -Content $content
}
catch {
    Write-Host "[ERROR] $($_.Exception.Message)"
    exit 2
}

if (-not $metadata.Values.ContainsKey('sdlc_schema') -or $metadata.Values['sdlc_schema'] -ne '1') {
    Write-Host "[ERROR] Unsupported or missing sdlc_schema. Expected '1'."
    exit 2
}
if (-not $metadata.Values.ContainsKey('planned_files') -or -not $metadata.Values.ContainsKey('approved_globs')) {
    Write-Host '[ERROR] planned_files and approved_globs are required in the workflow metadata.'
    exit 2
}

$revision = if ($metadata.Values.ContainsKey('revision_commit_sha')) { [string]$metadata.Values['revision_commit_sha'] } else { '' }
$plannedEntries = New-Object System.Collections.Generic.List[object]
$invalidPlan = New-Object System.Collections.Generic.List[string]
$unapprovedGlobs = New-Object System.Collections.Generic.List[string]

foreach ($rawPath in $metadata.PlannedFiles) {
    $path = Normalize-RelativePath $rawPath
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if ($path.StartsWith('/') -or $path -match '^[A-Za-z]:/' -or $path -match '(^|/)\.\.(?:/|$)') {
        [void]$invalidPlan.Add("$path (path must be relative)")
        continue
    }
    if ($path.EndsWith('/')) {
        [void]$invalidPlan.Add("$path (directory entries are not allowed; list exact files)")
        continue
    }

    $isGlob = Test-GlobPattern $path
    $approved = $true
    if ($isGlob) {
        $approved = Find-GlobApproval -Pattern $path -ApprovedGlobs $metadata.ApprovedGlobs -Revision $revision
        if (-not $approved) {
            [void]$unapprovedGlobs.Add($path)
        }
    }
    [void]$plannedEntries.Add([pscustomobject]@{
            Pattern  = $path
            IsGlob   = $isGlob
            Approved = $approved
        })
}

Write-Host '=== Scope Audit ==='
Write-Host "Planned files: $($plannedEntries.Count)"
Write-Host "Base ref: $BaseRef"
Write-Host ''

if ($invalidPlan.Count -gt 0) {
    Write-Host "[PLAN_INVALID] ($($invalidPlan.Count))"
    foreach ($issue in $invalidPlan) { Write-Host "  !!  $issue" }
    Write-Host ''
}
if ($unapprovedGlobs.Count -gt 0) {
    Write-Host "[PLAN_INVALID] ($($unapprovedGlobs.Count)) unapproved glob patterns"
    foreach ($pattern in $unapprovedGlobs) { Write-Host "  !!  $pattern requires an approved_globs record" }
    Write-Host ''
}

$changedFiles = @(Get-ChangedFiles -Root $RepoRoot -Reference $BaseRef)
if ($changedFiles.Count -eq 0) {
    Write-Host '[INFO] No changed files detected.'
}
else {
    Write-Host "Changed files ($($changedFiles.Count)):$([Environment]::NewLine)  $($changedFiles -join ([Environment]::NewLine + '  '))"
    Write-Host ''
}

$workflowFiles = @('docs/spec.md')
$workflowChanges = New-Object System.Collections.Generic.List[string]
$inScope = New-Object System.Collections.Generic.List[string]
$scopeCreep = New-Object System.Collections.Generic.List[string]

foreach ($file in $changedFiles) {
    if (($workflowFiles -contains $file) -or $file -eq '.sdlc' -or $file.StartsWith('.sdlc/')) {
        [void]$workflowChanges.Add($file)
        continue
    }

    $matched = $false
    foreach ($entry in $plannedEntries) {
        if ($entry.IsGlob) {
            if ($entry.Approved -and $file -match (Convert-GlobToRegex $entry.Pattern)) {
                $matched = $true
                break
            }
        }
        elseif ($file -ceq $entry.Pattern) {
            $matched = $true
            break
        }
    }
    if ($matched) { [void]$inScope.Add($file) }
    else { [void]$scopeCreep.Add($file) }
}

$missingFiles = New-Object System.Collections.Generic.List[string]
foreach ($entry in $plannedEntries) {
    if ($entry.IsGlob) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $entry.Pattern) -PathType Leaf)) {
        [void]$missingFiles.Add($entry.Pattern)
    }
}

Write-Host '=== Results ==='
Write-Host ''
if ($workflowChanges.Count -gt 0) {
    Write-Host "[WORKFLOW] ($($workflowChanges.Count) files excluded from product scope)"
    foreach ($file in $workflowChanges) { Write-Host "  OK  $file" }
    Write-Host ''
}
if ($inScope.Count -gt 0) {
    Write-Host "[IN_SCOPE] ($($inScope.Count) files)"
    foreach ($file in $inScope) { Write-Host "  OK  $file" }
    Write-Host ''
}
if ($scopeCreep.Count -gt 0) {
    Write-Host "[SCOPE_CREEP] ($($scopeCreep.Count) files) - changed files not in planned_files:"
    foreach ($file in $scopeCreep) { Write-Host "  !!  $file" }
    Write-Host ''
}
if ($missingFiles.Count -gt 0) {
    Write-Host "[MISSING] ($($missingFiles.Count) files) - exact planned files not present:"
    foreach ($file in $missingFiles) { Write-Host "  ??  $file" }
    Write-Host ''
}
if ($invalidPlan.Count -eq 0 -and $unapprovedGlobs.Count -eq 0 -and
    $scopeCreep.Count -eq 0 -and $missingFiles.Count -eq 0) {
    Write-Host '[PASS] All changes are within the approved planned scope.'
}

$summary = [ordered]@{
    planned         = $plannedEntries.Count
    changed         = $changedFiles.Count
    workflow        = @($workflowChanges)
    in_scope        = @($inScope)
    scope_creep     = @($scopeCreep)
    missing         = @($missingFiles)
    invalid_plan    = @($invalidPlan)
    unapproved_globs = @($unapprovedGlobs)
    clean           = ($invalidPlan.Count -eq 0 -and $unapprovedGlobs.Count -eq 0 -and $scopeCreep.Count -eq 0 -and $missingFiles.Count -eq 0)
}
Write-Host '--- JSON Summary ---'
Write-Host ($summary | ConvertTo-Json -Compress)

if ($invalidPlan.Count -gt 0 -or $unapprovedGlobs.Count -gt 0) { exit 2 }
if ($scopeCreep.Count -gt 0 -or $missingFiles.Count -gt 0) { exit 1 }
exit 0
