[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,

    [ValidateSet('generic')]
    [string] $Surface = 'generic',

    [string] $TemplateVersion,

    [switch] $Preview,

    [switch] $Force,

    [Alias('UpdateAgentSurface')]
    [switch] $Update
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList ([bool]$false)
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ContractRelativePath = 'docs/portable-agent-contract.md'
$ContractPath = Join-Path $RepoRoot $ContractRelativePath
$OutputPath = Join-Path $RepoRoot 'AGENTS.md'
$StatePath = Join-Path $RepoRoot '.sdlc/sdlc-installer-state.json'

function Normalize-Text {
    param([AllowEmptyString()][string] $Value)
    return (($Value -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")
}

function Get-ContractHash {
    param([Parameter(Mandatory = $true)][string] $Path)
    return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Get-InstalledTemplateVersion {
    if (-not [string]::IsNullOrWhiteSpace($TemplateVersion)) {
        return $TemplateVersion
    }

    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            if ($state.templateVersion) {
                return [string]$state.templateVersion
            }
        }
        catch {
            Write-Warning "Could not read template version from '$StatePath': $($_.Exception.Message)"
        }
    }

    return 'unknown'
}

function Get-RecordedOutputHash {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        return ''
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        foreach ($record in @($state.files)) {
            if ($null -ne $record -and [string]$record.path -eq 'AGENTS.md') {
                return [string]$record.hash
            }
        }
    }
    catch {
        Write-Warning "Could not read installer ownership from '$StatePath': $($_.Exception.Message)"
    }

    return ''
}

function Show-TextDiff {
    param(
        [string] $CurrentPath,
        [string] $CandidatePath
    )

    if (Test-Path -LiteralPath $CurrentPath -PathType Leaf) {
        $current = @(Get-Content -LiteralPath $CurrentPath)
    }
    else {
        $current = @()
    }
    $candidate = @(Get-Content -LiteralPath $CandidatePath)
    if ($current.Count -eq 0) {
        Write-Host '--- /dev/null'
        Write-Host "+++ $CurrentPath"
        foreach ($line in $candidate) {
            Write-Host "+$line"
        }
        return
    }

    Write-Host "--- $CurrentPath"
    Write-Host '+++ generated candidate'
    foreach ($line in @(Compare-Object -ReferenceObject $current -DifferenceObject $candidate)) {
        $prefix = if ($line.SideIndicator -eq '=>') { '+' } else { '-' }
        Write-Host "$prefix$($line.InputObject)"
    }
}

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    throw "Portable agent contract not found: $ContractPath"
}

$contract = [System.IO.File]::ReadAllText($ContractPath)
$contractHash = Get-ContractHash -Path $ContractPath
$version = Get-InstalledTemplateVersion
$header = @(
    '<!-- GENERATED FILE: do not edit directly. -->',
    '<!-- SDLC_PORTABLE_CONTRACT: generic -->',
    "<!-- portable-contract: $ContractRelativePath -->",
    "<!-- portable-contract-sha256: $contractHash -->",
    "<!-- template-version: $version -->",
    ''
) -join "`n"
$candidate = (($contract -replace "`r`n", "`n") -replace "`r", "`n") -replace "`n$", ''
$candidate = $header + "`n" + $candidate + "`n"
$temporaryCandidate = Join-Path ([System.IO.Path]::GetTempPath()) "sdlc-agents-$([guid]::NewGuid().ToString('N')).md"
[System.IO.File]::WriteAllText($temporaryCandidate, $candidate, $Utf8NoBom)

try {
    $current = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($OutputPath)
    }
    else {
        ''
    }

    if ((Normalize-Text $current) -ceq (Normalize-Text $candidate)) {
        Write-Host "[PASS] $OutputPath is current."
        exit 0
    }

    if ($Preview -or $Update -or (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Show-TextDiff -CurrentPath $OutputPath -CandidatePath $temporaryCandidate
    }

    if ($Preview) {
        Write-Host '[PREVIEW] No agent surface files were changed.'
        exit 0
    }

    $recordedHash = Get-RecordedOutputHash
    $currentHash = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
    }
    else {
        ''
    }

    $canRefresh = $Force -and -not [string]::IsNullOrWhiteSpace($recordedHash) -and ($currentHash -ieq $recordedHash)
    if (-not $Update -and (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and -not $canRefresh) {
        Write-Warning "Kept existing $OutputPath. Use -Update (after reviewing the diff) to replace a project-owned or modified adapter."
        exit 0
    }

    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($OutputPath, $candidate, $Utf8NoBom)
    Write-Host "[UPDATED] $OutputPath"
}
finally {
    if (Test-Path -LiteralPath $temporaryCandidate) {
        Remove-Item -LiteralPath $temporaryCandidate -Force -ErrorAction SilentlyContinue
    }
}