[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,

    [Alias('Surface')]
    [ValidateSet('copilot', 'generic', 'all')]
    [string] $AgentSurface = 'copilot',

    [string] $OutputPath = '.sdlc/evidence/agent-surfaces.json'
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ContractRelativePath = 'docs/portable-agent-contract.md'
$ContractPath = Join-Path $RepoRoot $ContractRelativePath
$errors = New-Object System.Collections.ArrayList
$requiredRules = @(
    'phase-transitions',
    'state-schema',
    'gate-commands',
    'task-ids',
    'permission-rules',
    'prohibited-actions',
    'evidence-requirements',
    'escalation-behavior',
    'editor-boundaries'
)

function Add-ValidationError {
    param([string] $Message)
    [void]$errors.Add($Message)
}

function Normalize-Text {
    param([AllowEmptyString()][string] $Value)
    return (($Value -replace "`r`n", "`n") -replace "`r", "`n").TrimEnd("`n")
}

function Get-TextSha256 {
    param([AllowEmptyString()][string] $Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((Normalize-Text $Text))
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-HeaderValue {
    param(
        [string] $Content,
        [string] $Name
    )
    $pattern = "(?m)^<!--\s*" + [regex]::Escape($Name) + ":\s*(.*?)\s*-->\s*$"
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }
    return ''
}

if (-not (Test-Path -LiteralPath $ContractPath -PathType Leaf)) {
    Add-ValidationError "Canonical contract is missing: $ContractRelativePath"
    $contract = ''
    $contractHash = ''
}
else {
    $contract = [System.IO.File]::ReadAllText($ContractPath)
    $contractHash = (Get-FileHash -LiteralPath $ContractPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

foreach ($rule in $requiredRules) {
    $marker = "<!-- PORTABLE_RULE: $rule -->"
    if ($contract -notmatch [regex]::Escape($marker)) {
        Add-ValidationError "Canonical contract is missing required rule marker: $rule"
    }
}

function Test-Adapter {
    param(
        [string] $Surface,
        [string] $RelativePath,
        [switch] $RequireExactContract
    )

    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-ValidationError "$Surface adapter is missing: $RelativePath"
        return
    }

    $content = [System.IO.File]::ReadAllText($path)
    if ($content -notmatch '(?m)^<!-- GENERATED FILE:') {
        Add-ValidationError "$Surface adapter is not marked as generated: $RelativePath"
    }
    if ((Get-HeaderValue -Content $content -Name 'SDLC_PORTABLE_CONTRACT') -cne $Surface) {
        Add-ValidationError "$Surface adapter has the wrong surface marker: $RelativePath"
    }
    if ((Get-HeaderValue -Content $content -Name 'portable-contract') -cne $ContractRelativePath) {
        Add-ValidationError "$Surface adapter does not point to $ContractRelativePath"
    }
    if ((Get-HeaderValue -Content $content -Name 'portable-contract-sha256').ToLowerInvariant() -cne $contractHash) {
        Add-ValidationError "$Surface adapter has a stale portable contract hash: $RelativePath"
    }
    if ([string]::IsNullOrWhiteSpace((Get-HeaderValue -Content $content -Name 'template-version'))) {
        Add-ValidationError "$Surface adapter is missing a template version: $RelativePath"
    }

    if ($Surface -eq 'copilot') {
        $adapterTemplateHash = (Get-HeaderValue -Content $content -Name 'adapter-template-sha256').ToLowerInvariant()
        $placeholderContent = [regex]::Replace(
            (Normalize-Text $content),
            '(?m)^<!-- adapter-template-sha256:.*-->$',
            '<!-- adapter-template-sha256: {{CopilotAdapterTemplateHash}} -->'
        )
        $placeholderContent = [regex]::Replace(
            $placeholderContent,
            '(?m)^<!-- portable-contract-sha256:.*-->$',
            '<!-- portable-contract-sha256: {{PortableContractHash}} -->'
        )
        $placeholderContent = [regex]::Replace(
            $placeholderContent,
            '(?m)^<!-- template-version:.*-->$',
            '<!-- template-version: {{TemplateVersion}} -->'
        )
        $computedAdapterTemplateHash = Get-TextSha256 -Text $placeholderContent
        if ([string]::IsNullOrWhiteSpace($adapterTemplateHash) -or $adapterTemplateHash -cne $computedAdapterTemplateHash) {
            Add-ValidationError "$Surface adapter content differs from its generated template: $RelativePath"
        }
    }

    foreach ($rule in $requiredRules) {
        $marker = "<!-- PORTABLE_RULE: $rule -->"
        if ($content -notmatch [regex]::Escape($marker)) {
            Add-ValidationError "$Surface adapter is missing required rule: $rule"
        }
    }

    if ($RequireExactContract) {
        $separator = $content.IndexOf("`n`n", [System.StringComparison]::Ordinal)
        if ($separator -lt 0) {
            Add-ValidationError "$Surface adapter has no generated contract body: $RelativePath"
        }
        else {
            $body = $content.Substring($separator + 2)
            if ((Normalize-Text $body) -cne (Normalize-Text $contract)) {
                Add-ValidationError "$Surface adapter body differs from the canonical contract: $RelativePath"
            }
        }
    }
}

if ($AgentSurface -in @('copilot', 'all')) {
    Test-Adapter -Surface 'copilot' -RelativePath '.github/copilot-instructions.md'
}
if ($AgentSurface -in @('generic', 'all')) {
    Test-Adapter -Surface 'generic' -RelativePath 'AGENTS.md' -RequireExactContract
}

if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $recordPath = $OutputPath
}
else {
    $recordPath = Join-Path $RepoRoot $OutputPath
}
$recordParent = Split-Path -Parent $recordPath
if (-not (Test-Path -LiteralPath $recordParent)) {
    New-Item -ItemType Directory -Path $recordParent -Force | Out-Null
}
$result = if ($errors.Count -eq 0) { 'PASS' } else { 'FAIL' }
$record = [ordered]@{
    schema = 1
    kind = 'sdlc-agent-surface-validation'
    contract_path = $ContractRelativePath
    contract_sha256 = $contractHash
    agent_surface = $AgentSurface
    result = $result
    exit_code = if ($errors.Count -eq 0) { 0 } else { 1 }
    timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    errors = @($errors.ToArray())
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding utf8

if ($errors.Count -gt 0) {
    foreach ($message in $errors) {
        Write-Error $message
    }
    exit 1
}

Write-Host "[PASS] $AgentSurface agent surface matches $ContractRelativePath."
exit 0