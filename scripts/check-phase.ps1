<#
.SYNOPSIS
    Validates the SDLC state file (docs/spec.md) before advancing phases.

.DESCRIPTION
    Checks that docs/spec.md is well-formed and that the current phase's
    required sections are populated. Designed to be called by the SDLC
    Supervisor agent before advancing state, and also usable as a manual
    pre-flight check.

    Exit codes:
      0 — All checks passed.
      1 — State file missing or malformed.
      2 — Current phase prerequisites not met.

.PARAMETER SpecPath
    Path to the spec file. Defaults to docs/spec.md in the repo root.

.PARAMETER Phase
    The phase to validate prerequisites for. If omitted, validates all
    phases up to and including the current state in the file.

.EXAMPLE
    ./scripts/check-phase.ps1

.EXAMPLE
    ./scripts/check-phase.ps1 -Phase CODING
#>
[CmdletBinding()]
param(
    [string] $SpecPath,
    [ValidateSet('GATHERING_REQS', 'DESIGN', 'PLANNING', 'CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')]
    [string] $Phase
)

$ErrorActionPreference = 'Stop'

# Resolve the spec path.
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $SpecPath) {
    $SpecPath = Join-Path $repoRoot 'docs/spec.md'
}

if (-not (Test-Path $SpecPath)) {
    Write-Host "[FAIL] docs/spec.md not found at: $SpecPath"
    exit 1
}

$content = Get-Content $SpecPath -Raw

# ── Extract current state ──────────────────────────
$validStates = @('GATHERING_REQS', 'DESIGN', 'PLANNING', 'CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')
$stateMatch = [regex]::Match($content, '## Current State\s*\n\s*`([^`]+)`')
if (-not $stateMatch.Success) {
    Write-Host "[FAIL] Could not find '## Current State' section with a valid state value."
    exit 1
}

$currentState = $stateMatch.Groups[1].Value.Trim()

if ($currentState -notin $validStates) {
    Write-Host "[FAIL] Invalid Current State: '$currentState'. Must be one of: $($validStates -join ', ')"
    exit 1
}

# ── Phase prerequisite checks ──────────────────────
$phaseOrder = @{
    'GATHERING_REQS'      = 0
    'DESIGN'              = 1
    'PLANNING'            = 2
    'CODING'              = 3
    'REVIEW'              = 4
    'TESTING'             = 5
    'DEPLOYMENT_READINESS' = 6
    'DONE'                = 7
}

# Determine which phase to check.
if ($Phase) {
    $targetPhase = $Phase
} else {
    # When no explicit phase, we're validating readiness to advance FROM current.
    $currentIndex = $phaseOrder[$currentState]
    $nextIndex = $currentIndex + 1
    if ($nextIndex -ge $validStates.Count) {
        Write-Host "[PASS] Already at final state: $currentState"
        exit 0
    }
    $targetPhase = $validStates[$nextIndex]
}

$sections = @{
    'GATHERING_REQS'      = @('Goal', 'Requirements', 'Acceptance Criteria', 'Out of Scope')
    'DESIGN'              = @('Design')
    'PLANNING'            = @('Tech Stack', 'File Structure', 'Implementation Plan')
    'CODING'              = @('Implementation Plan')
    'REVIEW'              = @('Review Findings')
    'TESTING'             = @('Test Results')
    'DEPLOYMENT_READINESS' = @('Deployment Readiness')
    'DONE'                 = @()
}

$targetIndex = $phaseOrder[$targetPhase]

Write-Host "Checking phase prerequisites up to: $targetPhase (current state: $currentState)"

$allPassed = $true

foreach ($state in $validStates) {
    $stateIdx = $phaseOrder[$state]
    if ($stateIdx -ge $targetIndex) {
        # Don't check the target phase itself for completeness — we're validating
        # that prior phases are done so we CAN enter this phase.
        break
    }

    $requiredSections = $sections[$state]
    if (-not $requiredSections) { continue }

    # Skip DESIGN when the workflow has already bypassed it for a non-UI project.
    if ($state -eq 'DESIGN') {
        if ($currentState -ne 'DESIGN') {
            Write-Host "[SKIP] Phase 'DESIGN' was bypassed for this project."
            continue
        }
    }

    # Skip DEPLOYMENT_READINESS if the config flag is off.
    if ($state -eq 'DEPLOYMENT_READINESS') {
        $configPath = Join-Path $repoRoot '.github/sdlc-config.yml'
        if (Test-Path $configPath) {
            $configText = Get-Content $configPath -Raw
            if ($configText -match 'deployment_readiness_gate:\s*false') {
                Write-Host "[SKIP] Phase 'DEPLOYMENT_READINESS' is disabled in .github/sdlc-config.yml."
                continue
            }
        }
    }

    foreach ($section in $requiredSections) {
        # Check that the section heading exists and has non-empty content after it.
        $sectionPattern = "## $section\s*\n+(.+?)(?=\n## |\n---|\z)"
        $sectionMatch = [regex]::Match($content, $sectionPattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)

        if (-not $sectionMatch.Success) {
            Write-Host "[FAIL] Phase '$state': section '## $section' not found."
            $allPassed = $false
            continue
        }

        $body = $sectionMatch.Groups[1].Value.Trim()
        # Remove common placeholder text.
        # Remove placeholder instructions.
        # Italic lines containing agent names: _...Agent..._
        $body = $body -replace '(?m)^_.*(?:PM|Designer|Architect|Reviewer|QA).*_\s*$', ''
        # Bare parenthesized agent annotations: (Agent ...)
        $body = $body -replace '\((?:PM|Designer|Architect|Reviewer|QA)[^)]*\)', ''
        $body = $body -replace '<!--.*?-->', ''
        $body = $body -replace '(?m)^[ \t]*```[^\r\n]*$', '' # remove code fences, retain contents
        $body = $body -replace '- \[ \]', ''          # remove empty checkboxes
        $body = $body -replace '^\s*-?\s*$', ''       # remove bare list markers
        $body = $body -replace '(?m)^[ \t]*\d+\.[ \t]*$', '' # remove empty numbered items
        $body = $body.Trim()

        if ([string]::IsNullOrWhiteSpace($body)) {
            Write-Host "[FAIL] Phase '$state': section '## $section' appears empty."
            $allPassed = $false
        } else {
            Write-Host "[PASS] Phase '$state': section '## $section' is populated."
        }
    }
}

# ── Final result ───────────────────────────────────
if ($allPassed) {
    Write-Host "[PASS] All prerequisite checks passed for phase: $targetPhase"
    exit 0
} else {
    Write-Host "[FAIL] Some prerequisite checks failed. See output above."
    exit 2
}
