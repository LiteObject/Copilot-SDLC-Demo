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

.EXAMPLE
    ./tools/scaffold-sdlc.ps1 -Target ../my-project

.EXAMPLE
    ./tools/scaffold-sdlc.ps1 -Target ../my-project -Extension frontend
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

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$TemplateRoot = Join-Path $RepoRoot 'template/base'
$ExtensionsRoot = Join-Path $RepoRoot 'template/extensions'
$StateRelativePath = '.sdlc/sdlc-installer-state.json'
$Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList ([bool]$false)
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

function Write-InstallerState {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [hashtable] $Files,

        [Parameter(Mandatory = $true)]
        [string] $TemplateName,

        [string[]] $ExtensionNames = @()
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
        installer     = 'Copilot-SDLC-Demo'
        template      = $TemplateName
        extensions    = @($ExtensionNames)
        files         = @($records.ToArray())
    }

    $json = $state | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, $Utf8NoBom)
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
$projectName = Split-Path -Leaf $TargetRoot
if ([string]::IsNullOrWhiteSpace($projectName)) {
    $projectName = $TargetRoot
}

$templateTokens = @{
    ProjectName  = $projectName
    ProjectRoot  = $TargetRoot
    Template     = $Template
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
            ($currentHash -cne $recordedHash)) {
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

Write-InstallerState -Path $StatePath -Files $nextManagedFiles `
    -TemplateName $Template -ExtensionNames @($Extension)
Write-Host "  recorded installer ownership in $StateRelativePath"

Write-Host ""
Write-Host "Done. Wrote $written file(s); left $leftUntouched existing file(s) untouched."
Write-Host "Use -Force to refresh only files that are still installer-owned and unchanged."
Write-Host "Open '$TargetRoot' in VS Code and reload the window to pick up the agents."
