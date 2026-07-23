<#
.SYNOPSIS
    Installs the Copilot SDLC template into a target folder.

.DESCRIPTION
    The base payload is read from template/base. Optional extensions are read
    from template/extensions/<extension> and applied after the base payload.
    Files ending in .template or .tmpl are rendered without that suffix.
    Existing project-owned files are preserved. Template-owned files are
    refreshed only when they are still unchanged from the previous install.

.PARAMETER Target
    Path to the repository or folder to install into. Created if needed.

.PARAMETER Template
    Template name. The repository currently provides base; default is an alias
    for base and is retained for compatibility.

.PARAMETER Extension
    One or more extension names or extension folder paths.

.PARAMETER Variable
    Template variable values in Name=Value form.

.PARAMETER Force
    Refresh unchanged template-owned files. Project-owned files are preserved.

.PARAMETER ValidateConfig
    Run the installed Phase 1 configuration validator and fail if adoption is
    not configured yet.

.PARAMETER FeatureId
    Create a new project-owned feature spec at
    docs/specs/<feature-id>/spec.md. Existing docs/spec.md is preserved.

.PARAMETER AgentSurface
    Select the generated agent surface: copilot (default), generic, or all.

.PARAMETER UpdateAgentSurface
    Show a diff and explicitly replace a project-owned or modified agent adapter.

.PARAMETER PreviewAgentSurface
    Preview the generated generic adapter without changing it.

.EXAMPLE
    ./tools/scaffold-sdlc.ps1 -Target ../my-project

.EXAMPLE
    ./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension frontend

.EXAMPLE
    ./tools/scaffold-sdlc.ps1 -Target ../my-project -FeatureId checkout-flow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string] $Target,

    [string] $Template = 'base',

    [Alias('Extensions')]
    [string[]] $Extension = @(),

    [Alias('Variables')]
    [string[]] $Variable = @(),

    [switch] $Force,

    [switch] $ValidateConfig,

    [string] $FeatureId,

    [ValidateSet('copilot', 'generic', 'all')]
    [string] $AgentSurface = 'copilot',

    [switch] $UpdateAgentSurface,

    [switch] $PreviewAgentSurface
)

$ErrorActionPreference = 'Stop'

if ($env:SDLC_CANONICAL_BACKEND -ne '1') {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        $python = Get-Command py -ErrorAction SilentlyContinue
    }
    if (-not $python) {
        throw 'Python 3.9 or newer is required for the sdlc CLI.'
    }
    $cli = Join-Path $PSScriptRoot 'sdlc.py'
    $arguments = @('init', '--target', $Target, '--template', $Template, '--agent-surface', $AgentSurface)
    foreach ($name in $Extension) { $arguments += @('--extension', $name) }
    foreach ($value in $Variable) { $arguments += @('--variable', $value) }
    if ($Force) { $arguments += '--force' }
    if ($ValidateConfig) { $arguments += '--validate-config' }
    if ($FeatureId) { $arguments += @('--feature-id', $FeatureId) }
    if ($UpdateAgentSurface) { $arguments += '--update-agent-surface' }
    if ($PreviewAgentSurface) { $arguments += '--preview-agent-surface' }
    & $python.Source $cli @arguments
    exit $LASTEXITCODE
}

$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$TemplateRoot = Join-Path $RepoRoot 'template/base'
$ExtensionsRoot = Join-Path $RepoRoot 'template/extensions'
$StateRelativePath = '.sdlc/sdlc-installer-state.json'
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList ([bool]$false)
$FeatureContextPath = Join-Path $TemplateRoot 'scripts/feature-context.ps1'
if (Test-Path -LiteralPath $FeatureContextPath -PathType Leaf) {
    . $FeatureContextPath
}
$ProjectOwnedPaths = @(
    '.github/sdlc-config.yml',
    'docs/spec.md'
)

function ConvertTo-InstallerRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $normalized = $Path -replace '\\', '/'
    while ($normalized.StartsWith('./')) {
        $normalized = $normalized.Substring(2)
    }

    return ($normalized -replace '^/+', '')
}

function Assert-SafeRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        [System.IO.Path]::IsPathRooted($Path) -or
        $Path -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "Template output path must be relative to the target: $Path"
    }
}

function Test-ProjectOwnedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return $ProjectOwnedPaths -contains $Path
}

if ($FeatureId) {
    if (Get-Command Assert-FeatureIdentifier -ErrorAction SilentlyContinue) {
        $FeatureId = Assert-FeatureIdentifier $FeatureId
    }
    elseif ($FeatureId -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "FeatureId '$FeatureId' is invalid. Use lowercase letters, numbers, and single hyphens only."
    }
}
$FeatureSpecRelativePath = if ($FeatureId) { "docs/specs/$FeatureId/spec.md" } else { '' }

function New-TemplateEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source,

        [Parameter(Mandatory = $true)]
        [string] $RelativePath
    )

    $outputPath = ConvertTo-InstallerRelativePath -Path $RelativePath
    $render = $false
    foreach ($suffix in @('.template', '.tmpl')) {
        if ($outputPath.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $outputPath = $outputPath.Substring(0, $outputPath.Length - $suffix.Length)
            $render = $true
            break
        }
    }

    Assert-SafeRelativePath -Path $outputPath

    return [pscustomobject]@{
        Source       = $Source
        RelativePath = $outputPath
        Render       = $render
    }
}

function Get-TemplateEntries {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Root,

        [string] $Prefix = '',

        [switch] $SkipExtensionDirectories
    )

    $rootPath = (Resolve-Path -LiteralPath $Root).Path
    $trimCharacters = [char[]]@('\', '/')
    $entries = New-Object System.Collections.ArrayList

    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)) {
        $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart($trimCharacters)
        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }
        if ($relativePath -match '(^|[\\/])__pycache__([\\/]|$)|\.pyc$') {
            continue
        }

        $firstPart = ($relativePath -split '[\\/]')[0]
        if ($firstPart -eq '.git') {
            continue
        }
        if ($SkipExtensionDirectories -and
            ($firstPart -in @('extensions', '_extensions')) -and
            ($relativePath -match '[\\/]')) {
            continue
        }

        if ([string]::IsNullOrWhiteSpace($Prefix)) {
            $targetRelativePath = $relativePath
        }
        else {
            $targetRelativePath = Join-Path $Prefix $relativePath
        }

        [void]$entries.Add((New-TemplateEntry -Source $file.FullName -RelativePath $targetRelativePath))
    }

    return $entries.ToArray()
}

function Resolve-ExtensionRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Extension names cannot be empty.'
    }

    if ([System.IO.Path]::IsPathRooted($Name) -or $Name -match '[\\/]') {
        if (-not (Test-Path -LiteralPath $Name -PathType Container)) {
            throw "Extension path not found: $Name"
        }

        return (Resolve-Path -LiteralPath $Name).Path
    }

    if ($Name -eq '.' -or $Name -eq '..' -or $Name -match ':') {
        throw "Invalid extension name: $Name"
    }

    $candidates = @(
        (Join-Path $ExtensionsRoot $Name)
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Extension '$Name' was not found. Looked in: $($candidates -join ', ')."
}

function Add-TemplateLayer {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Entries,

        [Parameter(Mandatory = $true)]
        [string] $Layer
    )

    foreach ($entry in $Entries) {
        $key = ConvertTo-InstallerRelativePath -Path ([string]$entry.RelativePath)
        Assert-SafeRelativePath -Path $key

        if ($planned.ContainsKey($key)) {
            if ($planned[$key].Layer -eq $Layer) {
                throw "Template layer '$Layer' produces more than one file for '$key'."
            }

            Write-Verbose "Extension layer '$Layer' overrides '$($planned[$key].Layer)' for '$key'."
        }
        else {
            [void]$installOrder.Add($key)
        }

        $planned[$key] = [pscustomobject]@{
            Layer = $Layer
            Entry = $entry
        }
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Text
    )

    $normalized = (($Text -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-TemplateEntry {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Entry,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [hashtable] $Tokens
    )

    $destinationParent = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }

    if ($Entry.Render) {
        $content = [System.IO.File]::ReadAllText([string]$Entry.Source)
        foreach ($name in $Tokens.Keys) {
            $token = '{{' + $name + '}}'
            $content = $content.Replace($token, [string]($Tokens[$name]))
        }

        [System.IO.File]::WriteAllText($Destination, $content, $Utf8NoBom)
    }
    else {
        Copy-Item -LiteralPath ([string]$Entry.Source) -Destination $Destination -Force
    }
}

function Show-TextDiff {
    param(
        [string] $CurrentPath,
        [string] $CandidatePath
    )

    $current = if (Test-Path -LiteralPath $CurrentPath -PathType Leaf) {
        @(Get-Content -LiteralPath $CurrentPath)
    }
    else {
        @()
    }
    $candidate = @(Get-Content -LiteralPath $CandidatePath)
    Write-Host "--- $CurrentPath"
    Write-Host '+++ generated candidate'
    foreach ($line in @(Compare-Object -ReferenceObject $current -DifferenceObject $candidate)) {
        $prefix = if ($line.SideIndicator -eq '=>') { '+' } else { '-' }
        Write-Host "$prefix$($line.InputObject)"
    }
}

function Update-ExplicitCopilotAdapter {
    param(
        [Parameter(Mandatory = $true)]
        [psobject] $Entry,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [hashtable] $Tokens
    )

    $temporaryCandidate = Join-Path ([System.IO.Path]::GetTempPath()) "sdlc-copilot-$([guid]::NewGuid().ToString('N')).md"
    try {
        Write-TemplateEntry -Entry $Entry -Destination $temporaryCandidate -Tokens $Tokens
        $current = if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [System.IO.File]::ReadAllText($Destination)
        }
        else {
            ''
        }
        $candidate = [System.IO.File]::ReadAllText($temporaryCandidate)
        if ($current -ceq $candidate) {
            Write-Host "  kept    .github/copilot-instructions.md (already current)"
            return if (Test-Path -LiteralPath $Destination -PathType Leaf) { Get-FileSha256 -Path $Destination } else { '' }
        }

        Show-TextDiff -CurrentPath $Destination -CandidatePath $temporaryCandidate
        if ($PreviewAgentSurface) {
            Write-Host '  preview .github/copilot-instructions.md (no changes written)'
            return ''
        }

        Write-TemplateEntry -Entry $Entry -Destination $Destination -Tokens $Tokens
        Write-Host '  updated .github/copilot-instructions.md (explicit agent-surface update)'
        return Get-FileSha256 -Path $Destination
    }
    finally {
        if (Test-Path -LiteralPath $temporaryCandidate) {
            Remove-Item -LiteralPath $temporaryCandidate -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-InstallerState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Files,

        [Parameter(Mandatory = $true)]
        [string] $TemplateName,

        [string[]] $ExtensionNames = @(),

        [string] $TemplateVersion = '',

        [string] $AgentSurface = 'copilot',

        [string] $PortableContractHash = '',

        [string] $ManifestSha256 = '',

        [string] $SourceRevision = 'unknown',

        [string] $Platform = 'unknown',

        [hashtable] $ExtensionVersions = @{}
    )

    $parent = Split-Path -Parent $Path
    if (Test-Path -LiteralPath $parent -PathType Leaf) {
        throw "Cannot write installer state because '$parent' is a file."
    }
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $records = New-Object System.Collections.ArrayList
    foreach ($key in ($Files.Keys | Sort-Object)) {
        [void]$records.Add([pscustomobject]@{
            path = $key
            hash = $Files[$key]
        })
    }

    $state = [ordered]@{
        schemaVersion = 1
        stateVersion = 2
        installer     = 'Copilot-SDLC-Demo'
        installerVersion = '1.0.0'
        template      = $TemplateName
        templateVersion = $TemplateVersion
        installedTemplateVersion = $TemplateVersion
        agentSurface  = $AgentSurface
        portableContractSha256 = $PortableContractHash
        manifestSha256 = $ManifestSha256
        manifestHash = $ManifestSha256
        sourceRevision = $SourceRevision
        platform = $Platform
        installedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        extensions    = @($ExtensionNames)
        extensionVersions = $ExtensionVersions
        files         = @($records.ToArray())
    }

    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $Utf8NoBom)
}

function Get-ManifestBaseInstalls {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Template manifest not found: $Path"
    }

    $installs = New-Object System.Collections.ArrayList
    $inBase = $false
    $inInstalls = $false
    $installsIndent = -1

    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.TrimEnd()
        $trimmed = $line.TrimStart()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $indent = $line.Length - $trimmed.Length
        if ($indent -eq 0) {
            $inBase = $trimmed.StartsWith('base:')
            $inInstalls = $false
            continue
        }
        if (-not $inBase) {
            continue
        }

        if ($inInstalls) {
            if ($indent -gt $installsIndent -and $trimmed.StartsWith('-')) {
                $item = $trimmed.Substring(1).Trim()
                if ($item) {
                    [void]$installs.Add($item)
                }
                continue
            }
            $inInstalls = $false
        }

        if ($trimmed.StartsWith('installs:')) {
            $inInstalls = $true
            $installsIndent = $indent
        }
    }

    return $installs.ToArray()
}

function Get-ManifestTemplateVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $trimmed = $rawLine.Trim()
        if ($trimmed -match '^version:\s*(.+)$') {
            return $Matches[1].Trim().Trim('"', "'")
        }
    }

    throw "Template version is missing from $Path"
}

function Get-ManifestExtensionVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Name
    )

    $extensionHeader = '^  ' + [regex]::Escape($Name) + ':\s*$'
    $inExtension = $false
    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path)) {
        $line = $rawLine.TrimEnd("`r")
        if ($line -match $extensionHeader) {
            $inExtension = $true
            continue
        }
        if ($inExtension -and $line -match '^  [A-Za-z0-9._-]+:\s*$') {
            break
        }
        if ($inExtension -and $line -match '^    version:\s*(.+)$') {
            return $Matches[1].Trim().Trim('"', "'")
        }
    }

    return 'unknown'
}

function Assert-ManifestCoversBase {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $Installs,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $BaseOutputs,

        [Parameter(Mandatory = $true)]
        [string] $ManifestPath
    )

    if ($Installs.Count -eq 0) {
        throw "Template manifest lists no base.installs entries: $ManifestPath"
    }

    $normalized = @($Installs | ForEach-Object { ConvertTo-InstallerRelativePath -Path $_ })

    $covers = {
        param($entry, $output)
        if ($entry.EndsWith('/')) {
            return $output.StartsWith($entry, [System.StringComparison]::Ordinal)
        }
        return ($output -ceq $entry)
    }

    $uncovered = New-Object System.Collections.ArrayList
    foreach ($output in $BaseOutputs) {
        $isCovered = $false
        foreach ($entry in $normalized) {
            if (& $covers $entry $output) {
                $isCovered = $true
                break
            }
        }
        if (-not $isCovered) {
            [void]$uncovered.Add($output)
        }
    }

    $unmatched = New-Object System.Collections.ArrayList
    foreach ($entry in $normalized) {
        $isMatched = $false
        foreach ($output in $BaseOutputs) {
            if (& $covers $entry $output) {
                $isMatched = $true
                break
            }
        }
        if (-not $isMatched) {
            [void]$unmatched.Add($entry)
        }
    }

    if ($uncovered.Count -gt 0 -or $unmatched.Count -gt 0) {
        $details = New-Object System.Collections.ArrayList
        if ($uncovered.Count -gt 0) {
            [void]$details.Add("base files missing from the manifest: $($uncovered -join ', ')")
        }
        if ($unmatched.Count -gt 0) {
            [void]$details.Add("manifest entries with no matching base file: $($unmatched -join ', ')")
        }
        throw "template/manifest.yml is out of sync with template/base ($($details -join '; ')). Update base.installs in $ManifestPath."
    }
}

if ([string]::IsNullOrWhiteSpace($Template)) {
    throw 'Template name cannot be empty.'
}
if ($Template -ieq 'default') {
    $Template = 'base'
}
if ($Template -ine 'base') {
    throw "Template '$Template' is not available. The repository provides the 'base' template."
}
if (-not (Test-Path -LiteralPath $TemplateRoot -PathType Container)) {
    throw "Base template not found: $TemplateRoot"
}

$planned = @{}
$installOrder = New-Object System.Collections.ArrayList

$baseEntries = @(Get-TemplateEntries -Root $TemplateRoot)
Add-TemplateLayer -Entries $baseEntries -Layer "template '$Template'"

$manifestPath = Join-Path $RepoRoot 'template/manifest.yml'
$baseOutputs = @($baseEntries | ForEach-Object { ConvertTo-InstallerRelativePath -Path ([string]$_.RelativePath) })
$manifestInstalls = @(Get-ManifestBaseInstalls -Path $manifestPath)
Assert-ManifestCoversBase -Installs $manifestInstalls -BaseOutputs $baseOutputs -ManifestPath $manifestPath
$TemplateVersion = Get-ManifestTemplateVersion -Path $manifestPath
$PortableContractPath = Join-Path $TemplateRoot 'docs/portable-agent-contract.md'
if (-not (Test-Path -LiteralPath $PortableContractPath -PathType Leaf)) {
    throw "Portable agent contract not found: $PortableContractPath"
}
$PortableContractHash = (Get-FileSha256 -Path $PortableContractPath).ToLowerInvariant()
$CopilotAdapterTemplatePath = Join-Path $TemplateRoot '.github/copilot-instructions.md.template'
if (-not (Test-Path -LiteralPath $CopilotAdapterTemplatePath -PathType Leaf)) {
    throw "Copilot adapter template not found: $CopilotAdapterTemplatePath"
}
$CopilotAdapterTemplateHash = Get-TextSha256 -Text ([System.IO.File]::ReadAllText($CopilotAdapterTemplatePath))

$extensionRoots = @()
foreach ($extensionName in $Extension) {
    $extensionRoot = Resolve-ExtensionRoot -Name $extensionName
    if ($extensionRoots -contains $extensionRoot) {
        Write-Verbose "Skipping duplicate extension root: $extensionRoot"
        continue
    }

    $extensionRoots += $extensionRoot
    $extensionEntries = @(Get-TemplateEntries -Root $extensionRoot)
    if ($extensionEntries.Count -eq 0) {
        Write-Warning "Extension '$extensionName' contains no files to install."
        continue
    }

    Add-TemplateLayer -Entries $extensionEntries -Layer "extension '$extensionName'"
}

if ($installOrder.Count -eq 0) {
    throw "Template '$Template' does not contain any installable files."
}

$StateKey = ConvertTo-InstallerRelativePath -Path $StateRelativePath
if ($planned.ContainsKey($StateKey)) {
    throw "Templates cannot install '$StateRelativePath'; that path is reserved for installer state."
}

if (-not (Test-Path -LiteralPath $Target)) {
    New-Item -ItemType Directory -Path $Target -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    throw "Target must be a directory: $Target"
}

$TargetRoot = (Resolve-Path -LiteralPath $Target).Path
$FeatureSpecPath = if ($FeatureId) { Join-Path $TargetRoot $FeatureSpecRelativePath } else { '' }
if ($FeatureSpecPath -and (Test-Path -LiteralPath $FeatureSpecPath)) {
    throw "Feature spec already exists at: $FeatureSpecPath"
}
$projectName = Split-Path -Leaf $TargetRoot
if ([string]::IsNullOrWhiteSpace($projectName)) {
    $projectName = $TargetRoot
}

$templateTokens = @{
    ProjectName  = $projectName
    ProjectRoot  = $TargetRoot
    Template     = $Template
    TemplateVersion = $TemplateVersion
    PortableContractHash = $PortableContractHash
    CopilotAdapterTemplateHash = $CopilotAdapterTemplateHash
    PROJECT_NAME = $projectName
    PROJECT_ROOT = $TargetRoot
}

foreach ($definition in $Variable) {
    if ([string]::IsNullOrWhiteSpace($definition)) {
        throw 'Template variables must use Name=Value form.'
    }

    $separator = $definition.IndexOf('=')
    if ($separator -lt 1) {
        throw "Template variable '$definition' must use Name=Value form."
    }

    $name = $definition.Substring(0, $separator).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Template variable '$definition' has no name."
    }

    $templateTokens[$name] = $definition.Substring($separator + 1)
}

$StatePath = Join-Path (Join-Path $TargetRoot '.sdlc') 'sdlc-installer-state.json'
$StateDirectory = Split-Path -Parent $StatePath
$stateExists = Test-Path -LiteralPath $StatePath
$managedFiles = @{}

if ($stateExists) {
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        throw "Installer state path is not a file: $StatePath"
    }

    try {
        $installedState = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read installer state '$StatePath': $($_.Exception.Message)"
    }

    if ($installedState.schemaVersion -ne 1 -or
        $installedState.installer -cne 'Copilot-SDLC-Demo') {
        throw "Refusing to overwrite unrecognized installer state: $StatePath"
    }

    foreach ($record in @($installedState.files)) {
        if ($null -eq $record) {
            continue
        }

        $recordPath = ConvertTo-InstallerRelativePath -Path ([string]($record.path))
        $recordHash = [string]($record.hash)
        Assert-SafeRelativePath -Path $recordPath

        if ($recordPath -ieq $StateKey -or
            [string]::IsNullOrWhiteSpace($recordHash) -or
            $managedFiles.ContainsKey($recordPath)) {
            throw "Installer state contains an invalid file record: $recordPath"
        }

        $managedFiles[$recordPath] = $recordHash
    }
}

if (Test-Path -LiteralPath $StateDirectory -PathType Leaf) {
    throw "Cannot write installer state because '$StateDirectory' is a project-owned file."
}

$nextManagedFiles = @{}

Write-Host "Installing SDLC template '$Template' into: $TargetRoot"

$written = 0
$leftUntouched = 0
foreach ($manifestPath in $installOrder) {
    $planItem = $planned[$manifestPath]
    $entry = $planItem.Entry
    $destination = Join-Path $TargetRoot ([string]$entry.RelativePath)

    if (Test-ProjectOwnedPath -Path $manifestPath) {
        if (Test-Path -LiteralPath $destination) {
            Write-Host "  kept    $manifestPath (project-owned)"
            $leftUntouched += 1
            continue
        }

        Write-TemplateEntry -Entry $entry -Destination $destination -Tokens $templateTokens
        $written += 1
        Write-Host "  installed $manifestPath (project-owned default)"
        continue
    }

    if (Test-Path -LiteralPath $destination) {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            Write-Warning "Skipped $($entry.RelativePath): the destination is a directory."
            $leftUntouched += 1
            continue
        }

        if (-not $managedFiles.ContainsKey($manifestPath)) {
            Write-Host "  kept    $($entry.RelativePath) (project-owned)"
            $leftUntouched += 1
            continue
        }

        $recordedHash = [string]($managedFiles[$manifestPath])
        $currentHash = Get-FileSha256 -Path $destination
        if ([string]::IsNullOrWhiteSpace($recordedHash) -or
            ($currentHash -ine $recordedHash)) {
            Write-Host "  kept    $($entry.RelativePath) (modified after install)"
            $leftUntouched += 1
            continue
        }

        $nextManagedFiles[$manifestPath] = $recordedHash
        if (-not $Force) {
            Write-Host "  kept    $($entry.RelativePath) (installer-owned; use -Force to refresh)"
            $leftUntouched += 1
            continue
        }

        $verb = 'updated'
    }
    else {
        $verb = 'installed'
    }

    Write-TemplateEntry -Entry $entry -Destination $destination -Tokens $templateTokens
    $nextManagedFiles[$manifestPath] = Get-FileSha256 -Path $destination
    $written += 1
    Write-Host "  $verb  $($entry.RelativePath)"
}

$copilotKey = '.github/copilot-instructions.md'
if ($UpdateAgentSurface -and $AgentSurface -in @('copilot', 'all') -and $planned.ContainsKey($copilotKey)) {
    $copilotHash = Update-ExplicitCopilotAdapter `
        -Entry $planned[$copilotKey].Entry `
        -Destination (Join-Path $TargetRoot $copilotKey) `
        -Tokens $templateTokens
    if (-not [string]::IsNullOrWhiteSpace($copilotHash) -and -not $PreviewAgentSurface) {
        $nextManagedFiles[$copilotKey] = $copilotHash
    }
}

$agentWasPresent = Test-Path -LiteralPath (Join-Path $TargetRoot 'AGENTS.md') -PathType Leaf
$agentWasManaged = $managedFiles.ContainsKey('AGENTS.md')
$agentRecordedHash = if ($agentWasManaged) { [string]$managedFiles['AGENTS.md'] } else { '' }
$agentHashBefore = if ($agentWasPresent) { Get-FileSha256 -Path (Join-Path $TargetRoot 'AGENTS.md') } else { '' }
$agentCanRefresh = $agentWasManaged -and ($agentHashBefore -ieq $agentRecordedHash)
if ($AgentSurface -in @('generic', 'all')) {
    $generatorPath = Join-Path $TemplateRoot 'scripts/generate-agent-surfaces.ps1'
    $generatorArguments = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $generatorPath,
        '-RepoRoot',
        $TargetRoot,
        '-Surface',
        'generic',
        '-TemplateVersion',
        $TemplateVersion
    )
    if ($PreviewAgentSurface) {
        $generatorArguments += '-Preview'
    }
    elseif ($UpdateAgentSurface) {
        $generatorArguments += '-Update'
    }
    elseif ($Force) {
        $generatorArguments += '-Force'
    }
    & pwsh @generatorArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Generic agent surface generation failed with exit code $LASTEXITCODE."
    }

    $agentPath = Join-Path $TargetRoot 'AGENTS.md'
    if (Test-Path -LiteralPath $agentPath -PathType Leaf) {
        $agentHashAfter = Get-FileSha256 -Path $agentPath
        $agentCreated = -not $agentWasPresent
        $agentUpdateApplied = $UpdateAgentSurface -and -not $PreviewAgentSurface
        if ($agentCreated -or $agentCanRefresh -or $agentUpdateApplied -or
            ($agentWasManaged -and $agentHashAfter -ieq $agentRecordedHash)) {
            $nextManagedFiles['AGENTS.md'] = $agentHashAfter
        }
    }
}

$ManifestSha256 = (Get-FileSha256 -Path (Join-Path $RepoRoot 'template/manifest.yml')).ToLowerInvariant()
$SourceRevision = (& git -C $RepoRoot rev-parse HEAD 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace([string]$SourceRevision)) {
    $SourceRevision = 'unknown'
}
$PlatformName = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
$ExtensionVersions = @{}
foreach ($extensionName in $Extension) {
    $ExtensionVersions[$extensionName] = if ([System.IO.Path]::IsPathRooted($extensionName) -or $extensionName -match '[\\/]') { 'unknown' } else { Get-ManifestExtensionVersion -Path (Join-Path $RepoRoot 'template/manifest.yml') -Name $extensionName }
}

Write-InstallerState -Path $StatePath -Files $nextManagedFiles `
    -TemplateName $Template -ExtensionNames @($Extension) `
    -TemplateVersion $TemplateVersion -AgentSurface $AgentSurface `
    -PortableContractHash $PortableContractHash -ManifestSha256 $ManifestSha256 `
    -SourceRevision ([string]$SourceRevision) -Platform $PlatformName `
    -ExtensionVersions $ExtensionVersions
Write-Host "  recorded installer ownership in $StateRelativePath"

if ($FeatureId) {
    $featureSpecParent = Split-Path -Parent $FeatureSpecPath
    New-Item -ItemType Directory -Path $featureSpecParent -Force | Out-Null
    $featureSpecContent = [System.IO.File]::ReadAllText((Join-Path $TemplateRoot 'docs/spec.md'))
    $featureSpecContent = $featureSpecContent.Replace('feature_id: ""', "feature_id: `"$FeatureId`"")
    $featureSpecContent = $featureSpecContent.Replace('spec_path: "docs/spec.md"', "spec_path: `"$FeatureSpecRelativePath`"")
    [System.IO.File]::WriteAllText($FeatureSpecPath, $featureSpecContent, $Utf8NoBom)
    Write-Host "  created  $FeatureSpecRelativePath (project-owned feature spec)"
    $featureTasksPath = Join-Path $featureSpecParent 'tasks.json'
    $featureTasks = [ordered]@{
        schema_version = 1
        feature_id = $FeatureId
        spec_path = $FeatureSpecRelativePath
        manual_verifications = @()
        tasks = @()
    }
    [System.IO.File]::WriteAllText($featureTasksPath, ($featureTasks | ConvertTo-Json -Depth 8) + [Environment]::NewLine, $Utf8NoBom)
    Write-Host "  created  docs/specs/$FeatureId/tasks.json (project-owned task graph starter)"
}

Write-Host ""
Write-Host "Done. Wrote $written file(s); left $leftUntouched existing file(s) untouched."
Write-Host "Use -Force to refresh only files that are still installer-owned and unchanged."
if ($ValidateConfig) {
    $validatorPath = Join-Path $TargetRoot 'scripts/validate-sdlc-config.ps1'
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $validatorPath -RepoRoot $TargetRoot
    if ($LASTEXITCODE -ne 0) {
        throw "SDLC configuration validation failed. Edit '$TargetRoot/.github/sdlc-config.yml' and rerun with -ValidateConfig."
    }
}
else {
    Write-Host "[INCOMPLETE] Run scripts/validate-sdlc-config.ps1 after configuring .github/sdlc-config.yml. Use -ValidateConfig to enforce this during scaffolding."
}
Write-Host "Open '$TargetRoot' in VS Code and reload the window to pick up the agents."
