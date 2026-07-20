<#
.SYNOPSIS
    Builds and records a traceable release bundle.
#>
[CmdletBinding()]
param(
    [string] $ConfigPath,
    [string] $RepoRoot,
    [string] $SpecPath,
    [string] $EvidenceDirectory,
    [switch] $RecordSpec
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot '.github/sdlc-config.yml' }
if (-not $SpecPath) { $SpecPath = Join-Path $RepoRoot 'docs/spec.md' }
if (-not $EvidenceDirectory) { $EvidenceDirectory = '.sdlc/evidence' }

function Get-ReleaseBody { param([string] $Content); $match = [regex]::Match($Content, '(?ms)^release_assurance:\s*\r?\n(?<body>.*?)(?=^\S|\z)'); if ($match.Success) { return $match.Groups['body'].Value }; return $null }
function Get-ReleaseValue { param([string] $Body, [string] $Name, [string] $Default = ''); if ($null -eq $Body) { return $Default }; $match = [regex]::Match($Body, '(?m)^\s*' + [regex]::Escape($Name) + ':\s*(?<value>[^\r\n#]+)'); if (-not $match.Success) { return $Default }; return $match.Groups['value'].Value.Trim().Trim('"', "'") }
function Get-ReleaseList { param([string] $Body, [string] $Name); $value = Get-ReleaseValue $Body $Name; if (-not $value.StartsWith('[')) { return @() }; return @($value.Trim('[', ']') -split ',' | ForEach-Object { $_.Trim().Trim('"', "'") } | Where-Object { $_ }) }
function Get-GitValue { param([string] $Root, [string[]] $Arguments); Push-Location $Root; try { $value = (& git @Arguments 2>$null | Out-String).Trim(); if ($LASTEXITCODE -eq 0 -and $value) { return $value }; return 'unknown' } finally { Pop-Location } }
function Get-TreeDigest { param([string] $Root); $payload = Get-GitValue -Root $Root -Arguments @('diff','--binary','HEAD','--','.',':(exclude)docs/spec.md',':(exclude).sdlc/**'); $sha = [System.Security.Cryptography.SHA256]::Create(); try { return (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($payload)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() } }
function Get-Sha256 { param([string] $Path); return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Set-SpecMetadata { param([string] $Path, [hashtable] $Updates); if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Spec file not found: $Path" }; $content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path); $lines = @(Get-Content -LiteralPath $Path); foreach ($key in $Updates.Keys) { $found = $false; for ($index=0; $index -lt $lines.Count; $index++) { if ($lines[$index] -match ('^' + [regex]::Escape($key) + ':')) { $value = [string]$Updates[$key]; if ($key -notmatch 'result|exit_code') { $value = '"' + $value.Replace('"','\"') + '"' }; $lines[$index] = "${key}: $value"; $found = $true; break } }; if (-not $found) { throw "Spec metadata field '$key' was not found." } }; $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }; [System.IO.File]::WriteAllText($Path, ($lines -join $newline), (New-Object System.Text.UTF8Encoding($false))) }
function Invoke-ConfiguredTask { param([string] $TaskName, [string] $Runner); $arguments = @('-Task',$TaskName,'-RepoRoot',$RepoRoot,'-EvidenceDirectory',$EvidenceDirectory); if ($RecordSpec) { $arguments += @('-SpecPath',$SpecPath,'-RecordSpec') }; & pwsh -NoProfile -ExecutionPolicy Bypass -File $Runner @arguments; if ($LASTEXITCODE -ne 0) { throw "Task '$TaskName' failed with exit code $LASTEXITCODE." } }

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Write-Host "[FAIL] Config not found: $ConfigPath"; exit 1 }
$content = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ConfigPath).Path)
$body = Get-ReleaseBody $content
if ($null -eq $body -or (Get-ReleaseValue $body 'enabled') -ne 'true') { Write-Host '[SKIP] Release assurance is disabled.'; exit 0 }
$releaseValidator = Join-Path $PSScriptRoot 'validate-release-config.ps1'
& pwsh -NoProfile -ExecutionPolicy Bypass -File $releaseValidator -ConfigPath $ConfigPath -RepoRoot $RepoRoot -EvidenceDirectory $EvidenceDirectory
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$releaseDirectory = Join-Path $RepoRoot '.sdlc/release'
New-Item -ItemType Directory -Path $releaseDirectory -Force | Out-Null
$artifactPath = Join-Path $RepoRoot (Get-ReleaseValue $body 'artifact_path')
$sbomPath = Join-Path $RepoRoot (Get-ReleaseValue $body 'sbom_path')
$provenancePath = Join-Path $RepoRoot (Get-ReleaseValue $body 'provenance_path')
$releaseNotesPath = Join-Path $RepoRoot (Get-ReleaseValue $body 'release_notes_path')
$rollbackPath = Join-Path $RepoRoot (Get-ReleaseValue $body 'rollback_instructions_path')
$runner = Join-Path $RepoRoot 'scripts/run-sdlc-task.ps1'
Invoke-ConfiguredTask -TaskName (Get-ReleaseValue $body 'artifact_task') -Runner $runner
if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { throw "Artifact was not produced: $artifactPath" }
Invoke-ConfiguredTask -TaskName (Get-ReleaseValue $body 'sbom_task') -Runner $runner
if (-not (Test-Path -LiteralPath $sbomPath -PathType Leaf)) { throw "SBOM was not produced: $sbomPath" }
$sbom = Get-Content -LiteralPath $sbomPath -Raw | ConvertFrom-Json
$format = Get-ReleaseValue $body 'sbom_format'
if ($format -eq 'cyclonedx-json' -and $sbom.bomFormat -ne 'CycloneDX') { throw 'SBOM is not a CycloneDX JSON document.' }
if ($format -eq 'spdx-json' -and -not $sbom.spdxVersion) { throw 'SBOM is not an SPDX JSON document.' }
$requireSignature = Get-ReleaseValue $body 'require_signed_artifact'
$signaturePath = Join-Path $RepoRoot (Get-ReleaseValue $body 'signature_path')
if ($requireSignature -eq 'true') { Invoke-ConfiguredTask -TaskName (Get-ReleaseValue $body 'signing_task') -Runner $runner; if (-not (Test-Path -LiteralPath $signaturePath -PathType Leaf)) { throw "Signature was not produced: $signaturePath" } }
if (-not (Test-Path -LiteralPath $releaseNotesPath -PathType Leaf)) { throw "Release notes are required: $releaseNotesPath" }
if (-not (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) { throw "Rollback instructions are required: $rollbackPath" }

$commitSha = Get-GitValue -Root $RepoRoot -Arguments @('rev-parse','HEAD')
$treeDigest = Get-TreeDigest -Root $RepoRoot
$artifactRelative = $artifactPath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\','/'
$sbomRelative = $sbomPath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\','/'
$artifactDigest = Get-Sha256 $artifactPath
$sbomDigest = Get-Sha256 $sbomPath
$timestamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
$provenance = [ordered]@{
    _type = 'https://in-toto.io/Statement/v1'
    subject = @([ordered]@{ name = $artifactRelative; digest = [ordered]@{ sha256 = $artifactDigest } })
    predicateType = 'https://slsa.dev/provenance/v1'
    predicate = [ordered]@{
        buildDefinition = [ordered]@{ buildType = 'https://github.com/copilot-sdlc/release'; externalParameters = [ordered]@{ repository = (Get-GitValue -Root $RepoRoot -Arguments @('config','--get','remote.origin.url')); revision = $commitSha }; resolvedDependencies = @([ordered]@{ uri = 'git'; digest = [ordered]@{ sha1 = $commitSha } }) }
        runDetails = [ordered]@{ builder = [ordered]@{ id = 'copilot-sdlc/release-assurance' }; metadata = [ordered]@{ startedOn = $timestamp; finishedOn = $timestamp } }
    }
}
$provenance | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $provenancePath -Encoding utf8
$manifest = [ordered]@{ schema = 1; kind = 'sdlc-release-manifest'; version = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { $commitSha.Substring(0, [Math]::Min(12, $commitSha.Length)) }; source_commit_sha = $commitSha; source_tree_digest = $treeDigest; created_at = $timestamp; artifact = [ordered]@{ path = $artifactRelative; sha256 = $artifactDigest; bytes = (Get-Item -LiteralPath $artifactPath).Length }; sbom = [ordered]@{ path = $sbomRelative; sha256 = $sbomDigest; format = $format }; provenance = [ordered]@{ path = $provenancePath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\','/' }; signature = if ($requireSignature -eq 'true') { $signaturePath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\','/' } else { $null }; promotion_environments = @(Get-ReleaseList $body 'promotion_environments'); required_approvals = @(Get-ReleaseList $body 'required_approvals') }
$manifestPath = Join-Path $releaseDirectory 'release-manifest.json'
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
if ($RecordSpec) { $relativeEvidence = $manifestPath.Substring(((Resolve-Path -LiteralPath $RepoRoot).Path.TrimEnd([char[]]@('\','/')) + [System.IO.Path]::DirectorySeparatorChar).Length) -replace '\\','/'; Set-SpecMetadata -Path $SpecPath -Updates @{ gate_release_command = 'scripts/prepare-release.ps1'; gate_release_commit_sha = $commitSha; gate_release_tree_digest = $treeDigest; gate_release_timestamp = $timestamp; gate_release_exit_code = '0'; gate_release_result = 'PASS'; gate_release_evidence = $relativeEvidence } }
Write-Host "[PASS] Release prepared: $manifestPath"
exit 0
