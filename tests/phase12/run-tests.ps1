[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$cli = Join-Path $root 'tools/sdlc.py'
$scaffolder = Join-Path $root 'tools/scaffold-sdlc.ps1'
$configFixture = Join-Path $root 'tests/fixtures/phase1/config-valid.yml'
$temporaryRoot = Join-Path $root "tests/.phase12-pwsh-$([guid]::NewGuid().ToString('N'))"
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
function Invoke-Cli {
    param([string[]] $Arguments)
    & python $cli @Arguments *> $null
    return $LASTEXITCODE
}
function Invoke-Scaffold {
    param([string] $Target, [switch] $Generic, [string[]] $Extension)
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scaffolder, '-Target', $Target)
    if ($Generic) { $arguments += @('-AgentSurface', 'generic') }
    foreach ($name in $Extension) { $arguments += @('-Extension', $name) }
    & pwsh @arguments *> $null
    return $LASTEXITCODE
}
function New-Source {
    param([string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item (Join-Path $root 'template') (Join-Path $Destination 'template') -Recurse
    Copy-Item (Join-Path $root 'tools') (Join-Path $Destination 'tools') -Recurse
}

New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $baseRepo = Join-Path $temporaryRoot 'base'
    $exitCode = Invoke-Cli @('init', '--target', $baseRepo, '--version', '1.0.0', '--extension', 'frontend', '--agent-surface', 'generic', '--shell', 'powershell')
    Assert-ExitCode 'pinned CLI installation succeeds' $exitCode 0
    $statePath = Join-Path $baseRepo '.sdlc/sdlc-installer-state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $requiredFields = @('templateVersion', 'extensionVersions', 'manifestSha256', 'sourceRevision', 'platform')
    $allFields = $true
    foreach ($field in $requiredFields) { if (-not ($state.PSObject.Properties.Name -contains $field)) { $allFields = $false } }
    Assert-Condition 'installer state records CG-6 provenance' ($allFields -and $state.templateVersion -eq '1.0.0' -and $state.extensionVersions.frontend -eq '1.0.0')
    Assert-Condition 'installed target includes portable CLI' (Test-Path -LiteralPath (Join-Path $baseRepo 'scripts/sdlc.py'))
    Assert-Condition 'generic adapter is installed' (Test-Path -LiteralPath (Join-Path $baseRepo 'AGENTS.md'))

    $exitCode = Invoke-Scaffold -Target $baseRepo -Generic
    Assert-ExitCode 'repeat compatibility install succeeds' $exitCode 0
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Condition 'repeat install preserves selected extension' ((Test-Path -LiteralPath (Join-Path $baseRepo '.github/instructions/frontend-ux.instructions.md')) -and $state.extensionVersions.frontend -eq '1.0.0')

    $exitCode = Invoke-Cli @('diff', '--target', $baseRepo, '--version', '1.0.0', '--shell', 'powershell', '--json')
    Assert-ExitCode 'clean installation diff succeeds' $exitCode 0

    Copy-Item $configFixture (Join-Path $baseRepo '.github/sdlc-config.yml') -Force
    New-Item -ItemType Directory -Path (Join-Path $baseRepo 'tests') -Force | Out-Null
    $exitCode = Invoke-Cli @('doctor', '--target', $baseRepo, '--source', $root, '--shell', 'powershell', '--json')
    Assert-ExitCode 'doctor passes a configured target' $exitCode 0
    $doctorEvidence = Join-Path $baseRepo '.sdlc/evidence/installer-doctor.json'
    Assert-Condition 'doctor evidence exists' ((Test-Path -LiteralPath $doctorEvidence) -and (Get-Content -LiteralPath $doctorEvidence -Raw) -match '"result"\s*:\s*"PASS"')

    $badPin = Join-Path $temporaryRoot 'bad-pin'
    $exitCode = Invoke-Cli @('init', '--target', $badPin, '--version', '9.9.9', '--shell', 'powershell')
    Assert-ExitCode 'unsupported pinned version is rejected' $exitCode 1
    Assert-Condition 'rejected pin writes no installer state' (-not (Test-Path -LiteralPath (Join-Path $badPin '.sdlc/sdlc-installer-state.json')))

    $incompatibleSource = Join-Path $temporaryRoot 'source-incompatible'
    New-Source -Destination $incompatibleSource
    $incompatibleManifestPath = Join-Path $incompatibleSource 'template/manifest.yml'
    $incompatibleManifest = (Get-Content -LiteralPath $incompatibleManifestPath -Raw).Replace('supported_installers: [1.0.0]', 'supported_installers: [9.9.9]')
    Write-Utf8File $incompatibleManifestPath $incompatibleManifest
    $incompatibleTarget = Join-Path $temporaryRoot 'incompatible-installer'
    $exitCode = Invoke-Cli @('init', '--target', $incompatibleTarget, '--source', $incompatibleSource, '--version', '1.0.0', '--shell', 'powershell')
    Assert-ExitCode 'incompatible installer version is rejected' $exitCode 1
    Assert-Condition 'incompatible installer writes no state' (-not (Test-Path -LiteralPath (Join-Path $incompatibleTarget '.sdlc/sdlc-installer-state.json')))

    $upgradeSource = Join-Path $temporaryRoot 'source-1.1.0'
    New-Source -Destination $upgradeSource
    $upgradeManifestPath = Join-Path $upgradeSource 'template/manifest.yml'
    $upgradeManifest = Get-Content -LiteralPath $upgradeManifestPath -Raw
    $upgradeManifest = $upgradeManifest.Replace('  version: 1.0.0', '  version: 1.1.0')
    Write-Utf8File $upgradeManifestPath $upgradeManifest
    Add-Content -LiteralPath (Join-Path $upgradeSource 'template/base/docs/portable-agent-contract.md') -Value "`nUpgrade fixture."

    $beforeSpec = 'project-owned spec before update'
    $beforeConfig = 'project-owned config before update'
    Write-Utf8File (Join-Path $baseRepo 'docs/spec.md') $beforeSpec
    Write-Utf8File (Join-Path $baseRepo '.github/sdlc-config.yml') $beforeConfig
    $beforeContract = Get-Content -LiteralPath (Join-Path $baseRepo 'docs/portable-agent-contract.md') -Raw
    $exitCode = Invoke-Cli @('update', '--target', $baseRepo, '--source', $upgradeSource, '--version', '1.1.0', '--shell', 'powershell')
    Assert-ExitCode 'upgrade across pinned releases succeeds' $exitCode 0
    Assert-Condition 'upgrade applies source change' ((Get-Content -LiteralPath (Join-Path $baseRepo 'docs/portable-agent-contract.md') -Raw) -match 'Upgrade fixture\.')
    Assert-Condition 'upgrade preserves project-owned files' ((Get-Content -LiteralPath (Join-Path $baseRepo 'docs/spec.md') -Raw) -ceq $beforeSpec -and (Get-Content -LiteralPath (Join-Path $baseRepo '.github/sdlc-config.yml') -Raw) -ceq $beforeConfig)

    $exitCode = Invoke-Cli @('rollback', '--target', $baseRepo)
    Assert-ExitCode 'rollback succeeds' $exitCode 0
    $afterContract = Get-Content -LiteralPath (Join-Path $baseRepo 'docs/portable-agent-contract.md') -Raw
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Condition 'rollback restores managed files' ($afterContract -ceq $beforeContract -and $state.lastOperation -eq 'rollback')
    Assert-Condition 'rollback evidence exists' (@(Get-ChildItem -LiteralPath (Join-Path $baseRepo '.sdlc/evidence') -Filter 'installer-rollback-*.json').Count -gt 0)

    $conflictRepo = Join-Path $temporaryRoot 'conflict'
    Assert-ExitCode 'conflict fixture installation succeeds' (Invoke-Cli @('init', '--target', $conflictRepo, '--version', '1.0.0', '--shell', 'powershell')) 0
    Add-Content -LiteralPath (Join-Path $conflictRepo 'scripts/check-phase.sh') -Value "`nuser conflict"
    $exitCode = Invoke-Cli @('update', '--target', $conflictRepo, '--version', '1.0.0', '--shell', 'powershell')
    Assert-ExitCode 'modified template file requires update decision' $exitCode 2
    $conflictState = Get-Content -LiteralPath (Join-Path $conflictRepo '.sdlc/sdlc-installer-state.json') -Raw
    Assert-Condition 'update preserves modified template file' ((Get-Content -LiteralPath (Join-Path $conflictRepo 'scripts/check-phase.sh') -Raw) -match 'user conflict' -and $conflictState -match 'scripts/check-phase\.sh')
    $exitCode = Invoke-Cli @('update', '--target', $conflictRepo, '--version', '1.0.0', '--accept-conflicts', '--shell', 'powershell')
    Assert-ExitCode 'explicit conflict decision succeeds' $exitCode 0
    $latestUpdateEvidence = Get-ChildItem -LiteralPath (Join-Path $conflictRepo '.sdlc/evidence') -Filter 'installer-update-*.json' | Sort-Object Name | Select-Object -Last 1
    Assert-Condition 'accepted conflict refreshes the template file' ((Get-Content -LiteralPath (Join-Path $conflictRepo 'scripts/check-phase.sh') -Raw) -notmatch 'user conflict' -and (Get-Content -LiteralPath $latestUpdateEvidence.FullName -Raw) -match 'scripts/check-phase\.sh')

    $exitCode = Invoke-Cli @('update', '--target', $baseRepo, '--version', '1.0.0', '--remove-extension', 'frontend', '--shell', 'powershell')
    Assert-ExitCode 'extension removal succeeds' $exitCode 0
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-Condition 'extension files are removed when unchanged' (-not (Test-Path -LiteralPath (Join-Path $baseRepo '.github/instructions/frontend-ux.instructions.md')) -and @($state.extensions).Count -eq 0)

    $outsideExtension = Join-Path (Split-Path $temporaryRoot -Parent) 'outside-extension'
    New-Item -ItemType Directory -Path $outsideExtension -Force | Out-Null
    $traversalExtension = Join-Path $temporaryRoot '..\outside-extension'
    $exitCode = Invoke-Cli @('init', '--target', (Join-Path $temporaryRoot 'path-traversal'), '--extension', $traversalExtension, '--shell', 'powershell')
    Assert-ExitCode 'extension path traversal is rejected' $exitCode 1
    Remove-Item -LiteralPath $outsideExtension -Recurse -Force -ErrorAction SilentlyContinue

    $releaseDir = Join-Path $temporaryRoot 'release'
    $exitCode = Invoke-Cli @('release', '--output-dir', $releaseDir)
    Assert-ExitCode 'release archive is created' $exitCode 0
    $archive = Get-ChildItem -LiteralPath $releaseDir -Filter '*.zip' | Select-Object -First 1
    $exitCode = Invoke-Cli @('release', '--verify', $archive.FullName)
    Assert-ExitCode 'release checksum verification succeeds' $exitCode 0
    Assert-Condition 'release sidecars exist' ((Test-Path -LiteralPath ($archive.FullName + '.sha256')) -and (Test-Path -LiteralPath ($archive.FullName -replace '\.zip$', '.release.json')))
    Write-Utf8File ($archive.FullName + '.sha256') ('0' * 64 + '  ' + $archive.Name + "`n")
    $exitCode = Invoke-Cli @('release', '--verify', $archive.FullName)
    Assert-ExitCode 'tampered release checksum is rejected' $exitCode 1
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($failures -gt 0) { throw "$failures Phase 12 PowerShell CG-6 regression case(s) failed." }
Write-Host '[PASS] All PowerShell Phase 12 CG-6 regression cases passed.'
