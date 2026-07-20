<# Verify release manifest, artifact digest, SBOM, provenance, and optional signature. #>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $ManifestPath,
    [string] $ConfigPath,
    [string] $EvidenceDirectory
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ManifestPath) { $ManifestPath = Join-Path $RepoRoot '.sdlc/release/release-manifest.json' }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
if (-not $EvidenceDirectory) { $EvidenceDirectory = '.sdlc/evidence' }
if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { Write-Host "[FAIL] Release manifest not found: $ManifestPath"; exit 1 }
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
$errors = New-Object System.Collections.Generic.List[string]
function Add-VerifyError { param([string] $Message); [void]$errors.Add($Message); Write-Host "[FAIL] $Message" }
function Get-Sha256 { param([string] $Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Resolve-ManifestPath { param([string] $Relative); if ([System.IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe manifest path: $Relative" }; return Join-Path $RepoRoot $Relative }
$artifactPath = Resolve-ManifestPath $manifest.artifact.path
$sbomPath = Resolve-ManifestPath $manifest.sbom.path
$provenancePath = Resolve-ManifestPath $manifest.provenance.path
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { Add-VerifyError "Artifact missing: $($manifest.artifact.path)" } else { if ((Get-Sha256 $artifactPath) -ne [string]$manifest.artifact.sha256) { Add-VerifyError 'Artifact SHA-256 does not match the release manifest.' } }
if (-not (Test-Path -LiteralPath $sbomPath -PathType Leaf)) { Add-VerifyError "SBOM missing: $($manifest.sbom.path)" } else { if ((Get-Sha256 $sbomPath) -ne [string]$manifest.sbom.sha256) { Add-VerifyError 'SBOM SHA-256 does not match the release manifest.' }; try { $sbom = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json; if ($manifest.sbom.format -eq 'cyclonedx-json' -and $sbom.bomFormat -ne 'CycloneDX') { Add-VerifyError 'SBOM is not CycloneDX JSON.' }; if ($manifest.sbom.format -eq 'spdx-json' -and -not $sbom.spdxVersion) { Add-VerifyError 'SBOM is not SPDX JSON.' } } catch { Add-VerifyError "SBOM is not valid JSON: $($_.Exception.Message)" } }
if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) { Add-VerifyError "Provenance missing: $($manifest.provenance.path)" } else { try { $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json; $subject = @($provenance.subject) | Where-Object { $_.name -eq $manifest.artifact.path }; if (-not $subject -or $subject[0].digest.sha256 -ne $manifest.artifact.sha256) { Add-VerifyError 'Provenance subject does not match the artifact digest.' } } catch { Add-VerifyError "Provenance is not valid JSON: $($_.Exception.Message)" } }
$signature = $manifest.signature
if ($null -ne $signature -and [string]$signature) { if (-not (Test-Path -LiteralPath (Resolve-ManifestPath $signature) -PathType Leaf)) { Add-VerifyError "Signature missing: $signature" } }
$recordDirectory = Join-Path $RepoRoot $EvidenceDirectory; New-Item -ItemType Directory -Path $recordDirectory -Force | Out-Null
$record = [ordered]@{ schema = 1; kind = 'sdlc-release-verification'; manifest = $ManifestPath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.Length + 1)); checked_at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }; exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }; errors = @($errors) }
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $recordDirectory 'release-verification.json') -Encoding utf8
if ($errors.Count -gt 0) { exit 1 }
Write-Host '[PASS] Release manifest and supply-chain evidence verified.'
exit 0
