<#
.SYNOPSIS
    Scaffolds the Copilot SDLC customization files into a target folder.

.DESCRIPTION
    Copies the .github customization (agents, instructions, prompts,
    copilot-instructions.md) and docs/spec.md from this repo into a target
    folder, and ensures src/ and tests/ exist. Whole directories are copied,
    so new or renamed agents are picked up automatically.

.PARAMETER Target
    Path to the repo/folder to scaffold into. Created if it does not exist.

.PARAMETER Force
    Overwrite existing customization files in the target without prompting.

.EXAMPLE
    ./scripts/scaffold-sdlc.ps1 -Target ../my-project

.EXAMPLE
    ./scripts/scaffold-sdlc.ps1 -Target C:\code\my-project -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Target,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Repo root is the parent of this script's folder.
$RepoRoot = Split-Path -Parent $PSScriptRoot

$sources = @(
    '.github/copilot-instructions.md',
    '.github/sdlc-config.yml',
    '.github/agents',
    '.github/instructions',
    '.github/prompts',
    '.github/workflows',
    'docs/spec.md',
    'scripts/check-phase.ps1',
    'scripts/check-phase.sh',
    'scripts/scope-audit.ps1',
    'scripts/scope-audit.sh'
)

# Verify we are running from a populated source repo.
foreach ($rel in $sources) {
    $src = Join-Path $RepoRoot $rel
    if (-not (Test-Path $src)) {
        throw "Source not found: $src. Run this script from a clone of the Copilot-SDLC-Demo repo."
    }
}

# Create the target root.
if (-not (Test-Path $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}
$TargetRoot = (Resolve-Path $Target).Path

Write-Host "Scaffolding SDLC customization into: $TargetRoot"

foreach ($rel in $sources) {
    $src = Join-Path $RepoRoot $rel
    $dest = Join-Path $TargetRoot $rel
    $destParent = Split-Path -Parent $dest

    if (-not (Test-Path $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    if ((Test-Path $dest) -and -not $Force) {
        $answer = Read-Host "Exists: $rel. Overwrite? (y/N)"
        if ($answer -notin @('y', 'Y')) {
            Write-Host "  skipped $rel"
            continue
        }
    }

    Copy-Item -Path $src -Destination $destParent -Recurse -Force
    Write-Host "  copied  $rel"
}

# Ensure src/ and tests/ exist with a .gitkeep.
foreach ($dir in @('src', 'tests')) {
    $path = Join-Path $TargetRoot $dir
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    $gitkeep = Join-Path $path '.gitkeep'
    if (-not (Test-Path $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep -Force | Out-Null
    }
    Write-Host "  ensured $dir/"
}

Write-Host ""
Write-Host "Done. Next steps:"
Write-Host "  1. Open '$TargetRoot' in VS Code."
Write-Host "  2. Reload the window so the agents are picked up."
Write-Host "  3. Select the 'sdlc-supervisor' agent and describe what to build."
