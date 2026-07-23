[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$scaffolder = Join-Path $root 'tools/scaffold-sdlc.ps1'
$temporaryRoot = Join-Path $root "tests/.phase11-pwsh-$([guid]::NewGuid().ToString('N'))"
$failures = 0

function Assert-ExitCode {
    param([string] $Label, [int] $Actual, [int] $Expected)
    if ($Actual -eq $Expected) { Write-Host "[PASS] $Label ($Actual)" }
    else { Write-Host "[FAIL] ${Label}: expected $Expected, got $Actual"; $script:failures += 1 }
}

function Assert-Condition {
    param([string] $Label, [bool] $Condition)
    if ($Condition) { Write-Host "[PASS] $Label" }
    else { Write-Host "[FAIL] $Label"; $script:failures += 1 }
}

function Write-Utf8File {
    param([string] $Path, [string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Scaffold {
    param([string] $Target, [string] $Surface = 'copilot', [switch] $Update)
    $arguments = @('-Target', $Target, '-AgentSurface', $Surface)
    if ($Update) { $arguments += '-UpdateAgentSurface' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scaffolder @arguments *> $null
    return $LASTEXITCODE
}

function Invoke-Validator {
    param([string] $Target, [string] $Surface)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'scripts/validate-agent-surfaces.ps1') `
        -RepoRoot $Target -AgentSurface $Surface *> $null
    return $LASTEXITCODE
}

function Invoke-GeneratorUpdate {
    param([string] $Target)
    & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target 'scripts/generate-agent-surfaces.ps1') `
        -RepoRoot $Target -Surface generic -Update *> $null
    return $LASTEXITCODE
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $copilotRepo = Join-Path $temporaryRoot 'copilot'
    $exitCode = Invoke-Scaffold -Target $copilotRepo
    Assert-ExitCode 'default Copilot scaffold succeeds' $exitCode 0
    Assert-Condition 'default Copilot scaffold does not create AGENTS.md' (-not (Test-Path (Join-Path $copilotRepo 'AGENTS.md')))
    $copilotInstructions = Get-Content -LiteralPath (Join-Path $copilotRepo '.github/copilot-instructions.md') -Raw
    Assert-Condition 'Copilot adapter records source hash and template version' ($copilotInstructions -match '<!-- portable-contract-sha256: [0-9a-f]{64} -->' -and $copilotInstructions -match '<!-- template-version: 1\.0\.0 -->')
    Assert-ExitCode 'default Copilot adapter validates' (Invoke-Validator -Target $copilotRepo -Surface copilot) 0

    $genericRepo = Join-Path $temporaryRoot 'generic'
    $exitCode = Invoke-Scaffold -Target $genericRepo -Surface generic
    Assert-ExitCode 'generic scaffold succeeds' $exitCode 0
    Assert-Condition 'generic scaffold creates AGENTS.md' (Test-Path (Join-Path $genericRepo 'AGENTS.md'))
    Assert-ExitCode 'generic adapter validates' (Invoke-Validator -Target $genericRepo -Surface generic) 0

    $contractPath = Join-Path $genericRepo 'docs/portable-agent-contract.md'
    $originalContract = Get-Content -LiteralPath $contractPath -Raw
    Write-Utf8File $contractPath ($originalContract + "`nContract drift fixture.`n")
    Assert-ExitCode 'contract drift blocks generic validation' (Invoke-Validator -Target $genericRepo -Surface generic) 1
    Assert-ExitCode 'explicit generic regeneration succeeds' (Invoke-GeneratorUpdate -Target $genericRepo) 0
    Assert-ExitCode 'regenerated generic adapter validates' (Invoke-Validator -Target $genericRepo -Surface generic) 0

    $agentsPath = Join-Path $genericRepo 'AGENTS.md'
    Add-Content -LiteralPath $agentsPath -Value "`nManual adapter edit."
    $manualEdit = Get-Content -LiteralPath $agentsPath -Raw
    $exitCode = Invoke-Scaffold -Target $genericRepo -Surface generic
    Assert-ExitCode 'modified generated adapter scaffold succeeds' $exitCode 0
    Assert-Condition 'modified generated adapter is preserved' ((Get-Content -LiteralPath $agentsPath -Raw) -ceq $manualEdit)
    Assert-ExitCode 'modified generated adapter fails portability validation' (Invoke-Validator -Target $genericRepo -Surface generic) 1
    Assert-ExitCode 'explicit generic adapter update succeeds' (Invoke-Scaffold -Target $genericRepo -Surface generic -Update) 0
    Assert-ExitCode 'explicitly updated generic adapter validates' (Invoke-Validator -Target $genericRepo -Surface generic) 0

    $manualRepo = Join-Path $temporaryRoot 'manual'
    New-Item -ItemType Directory -Path $manualRepo -Force | Out-Null
    Write-Utf8File (Join-Path $manualRepo 'AGENTS.md') "# Project-owned adapter`n"
    $manualBefore = Get-Content -LiteralPath (Join-Path $manualRepo 'AGENTS.md') -Raw
    Assert-ExitCode 'manual adapter scaffold succeeds' (Invoke-Scaffold -Target $manualRepo -Surface generic) 0
    Assert-Condition 'manual adapter is preserved by default' ((Get-Content -LiteralPath (Join-Path $manualRepo 'AGENTS.md') -Raw) -ceq $manualBefore)
    Assert-ExitCode 'manual adapter fails until explicitly adopted' (Invoke-Validator -Target $manualRepo -Surface generic) 1
    Assert-ExitCode 'explicit manual adapter update succeeds' (Invoke-Scaffold -Target $manualRepo -Surface generic -Update) 0
    Assert-ExitCode 'adopted manual adapter validates' (Invoke-Validator -Target $manualRepo -Surface generic) 0

    Add-Content -LiteralPath (Join-Path $copilotRepo '.github/copilot-instructions.md') -Value "`nManual Copilot adapter edit."
    Assert-ExitCode 'modified Copilot adapter fails validation' (Invoke-Validator -Target $copilotRepo -Surface copilot) 1
    Assert-ExitCode 'all-surface explicit update succeeds' (Invoke-Scaffold -Target $copilotRepo -Surface all -Update) 0
    Assert-ExitCode 'all selected surfaces validate together' (Invoke-Validator -Target $copilotRepo -Surface all) 0
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { throw "$failures Phase 11 PowerShell regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 11 CG-5 regression cases passed.'