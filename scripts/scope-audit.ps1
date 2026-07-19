<#
.SYNOPSIS
    Compares the actual git diff against the Implementation Plan in docs/spec.md
    to detect scope creep, missing files, and drift.

.DESCRIPTION
    Reads the File Structure from the Implementation Plan section of
    docs/spec.md, then compares it against the current git diff (staged +
    unstaged + untracked). Produces a structured report categorizing every
    changed file as IN_SCOPE, SCOPE_CREEP, or plan items NOT_FOUND.

    Designed to be called by the Reviewer agent during REVIEW, but also usable
    as a pre-commit hook or CI step.

    Exit codes:
      0 — All changes within planned scope.
      1 — Scope creep or missing files detected.
      2 — Could not parse the spec file.

.PARAMETER SpecPath
    Path to the spec file. Defaults to docs/spec.md in the repo root.

.PARAMETER BaseRef
    Git reference to diff against. Defaults to HEAD for uncommitted changes,
    or 'origin/main' for committed work. Use 'staged' for staged-only diff.

.EXAMPLE
    # Check uncommitted changes against the plan
    ./scripts/scope-audit.ps1

.EXAMPLE
    # Check a branch against main
    ./scripts/scope-audit.ps1 -BaseRef origin/main

.EXAMPLE
    # Check only staged changes
    ./scripts/scope-audit.ps1 -BaseRef staged
#>
[CmdletBinding()]
param(
    [string] $SpecPath,
    [string] $BaseRef = 'HEAD'
)

$ErrorActionPreference = 'Stop'

# Resolve the spec path.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SpecPath) {
    $SpecPath = Join-Path $repoRoot 'docs/spec.md'
}

if (-not (Test-Path $SpecPath)) {
    Write-Host "[ERROR] docs/spec.md not found at: $SpecPath"
    exit 2
}

$content = Get-Content $SpecPath -Raw

# ── Extract the planned file list ─────────────────
# Look for the File Structure section under Implementation Plan.
# Expected format:
#   ## File Structure
#   ```
#   src/file1.ts
#   src/file2.ts
#   tests/test_file1.ts
#   ```

$fileStructureMatch = [regex]::Match(
    $content,
    '## File Structure[\s\S]*?\n```[\s\S]*?\n(.*?)\n```',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
)

if (-not $fileStructureMatch.Success) {
    Write-Host "[ERROR] Could not find '## File Structure' section with a code block in docs/spec.md"
    exit 2
}

$fileBlock = $fileStructureMatch.Groups[1].Value
$plannedFiles = $fileBlock -split '\n' |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -notmatch '^#' -and $_ -notmatch '^//' -and $_ -notmatch '^\s*$' }

if ($plannedFiles.Count -eq 0) {
    Write-Host "[WARN] No files found in the File Structure plan."
}

Write-Host "=== Scope Audit ==="
Write-Host "Planned files: $($plannedFiles.Count)"
Write-Host "Base ref: $BaseRef"
Write-Host ""

# ── Get the actual changed files ──────────────────
$changedFiles = @()

try {
    Push-Location $repoRoot

    if ($BaseRef -eq 'staged') {
        $changedFiles = @(git diff --cached --name-only 2>$null)
    } elseif ($BaseRef -eq 'HEAD') {
        # Uncommitted changes: staged + unstaged + untracked (excluding ignored).
        $staged = @(git diff --cached --name-only 2>$null)
        $unstaged = @(git diff --name-only 2>$null)
        $untracked = @(git ls-files --others --exclude-standard 2>$null)
        $changedFiles = @($staged + $unstaged + $untracked | Select-Object -Unique)
    } else {
        $changedFiles = @(git diff --name-only "$BaseRef" 2>$null)
    }

    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "[WARN] git diff returned exit code $LASTEXITCODE — is this a git repository with commits?"
    }
} finally {
    Pop-Location
}

if ($changedFiles.Count -eq 0) {
    Write-Host "[INFO] No changed files detected. Scope is clean."
    exit 0
}

Write-Host "Changed files ($($changedFiles.Count)):"
foreach ($f in $changedFiles) { Write-Host "  $f" }
Write-Host ""

# ── Classify each changed file ────────────────────
$inScope = [System.Collections.Generic.List[string]]::new()
$scopeCreep = [System.Collections.Generic.List[string]]::new()

foreach ($file in $changedFiles) {
    $matched = $false
    foreach ($planFile in $plannedFiles) {
        # Simple glob-like matching: exact match or ** wildcard prefix/suffix.
        if ($file -eq $planFile) {
            $matched = $true
            break
        }
        # Match src/** or tests/** patterns.
        if ($planFile -match '\*\*') {
            $pattern = [regex]::Escape($planFile).Replace('\*\*', '.*')
            if ($file -match $pattern) {
                $matched = $true
                break
            }
        }
        # Match directories: plan says "src/" and file is under it.
        if ($planFile.EndsWith('/') -and $file.StartsWith($planFile)) {
            $matched = $true
            break
        }
    }
    if ($matched) {
        $inScope.Add($file)
    } else {
        $scopeCreep.Add($file)
    }
}

# ── Detect planned files NOT created ───────────────
$missingFiles = [System.Collections.Generic.List[string]]::new()
foreach ($planFile in $plannedFiles) {
    # Skip directory-wide patterns like "src/" or globs when checking existence.
    if ($planFile.EndsWith('/') -or $planFile.Contains('**')) {
        continue
    }
    $fullPath = Join-Path $repoRoot $planFile
    if (-not (Test-Path $fullPath)) {
        $missingFiles.Add($planFile)
    }
}

# ── Report ────────────────────────────────────────
Write-Host "=== Results ==="
Write-Host ""

$hasIssues = $false

if ($inScope.Count -gt 0) {
    Write-Host "[IN_SCOPE] ($($inScope.Count) files)"
    foreach ($f in $inScope) { Write-Host "  OK  $f" }
    Write-Host ""
}

if ($scopeCreep.Count -gt 0) {
    $hasIssues = $true
    Write-Host "[SCOPE_CREEP] ($($scopeCreep.Count) files) — touched files NOT in the plan:"
    foreach ($f in $scopeCreep) { Write-Host "  !!  $f" }
    Write-Host ""
}

if ($missingFiles.Count -gt 0) {
    $hasIssues = $true
    Write-Host "[MISSING] ($($missingFiles.Count) files) — planned files NOT created:"
    foreach ($f in $missingFiles) { Write-Host "  ??  $f" }
    Write-Host ""
}

if (-not $hasIssues) {
    Write-Host "[PASS] All changes are within planned scope. No scope creep detected."
    Write-Host ""
}

# ── Summary JSON (for programmatic consumers) ─────
$summary = @{
    planned    = $plannedFiles.Count
    changed    = $changedFiles.Count
    in_scope   = @($inScope)
    scope_creep = @($scopeCreep)
    missing    = @($missingFiles)
    clean      = (-not $hasIssues)
} | ConvertTo-Json -Compress

Write-Host "--- JSON Summary ---"
Write-Host $summary

if ($hasIssues) {
    exit 1
}
exit 0
