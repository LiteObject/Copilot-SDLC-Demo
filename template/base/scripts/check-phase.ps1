<#
.SYNOPSIS
    Validates the SDLC state file before a Supervisor applies a transition.

.DESCRIPTION
    Validates the machine-readable workflow metadata in docs/spec.md, the
    visible state fields, the allowed transition table, prerequisite sections,
    and gate evidence for the requested transition.

    Exit codes:
      0 - All checks passed.
      1 - State file missing or malformed.
      2 - Transition or phase prerequisites not met.

.PARAMETER SpecPath
    Path to the spec file. Defaults to docs/spec.md in the repository root.

.PARAMETER FeatureId
    Normalized feature identifier. Resolves the spec to
    docs/specs/<feature-id>/spec.md and binds gate evidence to the feature.

.PARAMETER RepoRoot
    Repository root used to resolve evidence paths and Git revision data.

.PARAMETER Phase
    Target phase to validate. If omitted, validates the default forward
    transition from the current phase.

.PARAMETER CommitSha
    Override the current Git commit SHA. Intended for deterministic tests.

.PARAMETER TreeDigest
    Override the current working-tree digest. Intended for deterministic tests.
#>
[CmdletBinding()]
param(
    [string] $SpecPath,
    [string] $FeatureId,
    [string] $RepoRoot,
    [ValidateSet('GATHERING_REQS', 'DESIGN', 'PLANNING', 'CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')]
    [string] $Phase,
    [string] $CommitSha,
    [string] $TreeDigest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'feature-context.ps1')

$validStates = @('GATHERING_REQS', 'DESIGN', 'PLANNING', 'CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')
$phaseOrder = @{
    'GATHERING_REQS'       = 0
    'DESIGN'               = 1
    'PLANNING'             = 2
    'CODING'               = 3
    'REVIEW'               = 4
    'TESTING'              = 5
    'DEPLOYMENT_READINESS' = 6
    'DONE'                 = 7
}

if (-not $RepoRoot) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}

$workflowContext = Resolve-FeatureContext -RepoRoot $RepoRoot -SpecPath $SpecPath -FeatureId $FeatureId
$FeatureId = $workflowContext.FeatureId
$SpecPath = $workflowContext.SpecPath
$script:FeatureId = $FeatureId
$script:SpecRelativePath = $workflowContext.SpecRelativePath

function ConvertFrom-YamlScalar {
    param([string] $Value)

    $trimmed = $Value.Trim()
    if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or
        ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
        return $trimmed.Substring(1, $trimmed.Length - 2).Replace('\"', '"')
    }
    return $trimmed
}

function Read-WorkflowMetadata {
    param([string] $Content)

    $frontMatterMatch = [regex]::Match(
        $Content,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---(?:\r?\n|\z)',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    )
    if (-not $frontMatterMatch.Success) {
        throw "docs/spec.md must start with YAML front matter delimited by '---'."
    }

    $values = @{}
    $lists = @{
        planned_files          = @()
        approved_globs         = @()
        approved_shared_files  = @()
    }
    $activeList = $null

    foreach ($line in ($frontMatterMatch.Groups['frontmatter'].Value -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) {
            continue
        }

        if ($line -match '^(?<key>[A-Za-z0-9_]+):[ \t]*(?<value>.*)$') {
            $key = $Matches.key
            $value = ConvertFrom-YamlScalar $Matches.value
            $values[$key] = $value
            $activeList = $null
            if ($key -in @('planned_files', 'approved_globs', 'approved_shared_files')) {
                if ($value -eq '[]') {
                    $lists[$key] = @()
                }
                elseif ($value -eq '') {
                    $lists[$key] = @()
                    $activeList = $key
                }
            }
            continue
        }

        if ($null -ne $activeList -and $line -match '^\s*-\s*(?<item>.*)$') {
            $item = ConvertFrom-YamlScalar $Matches.item
            $lists[$activeList] = @($lists[$activeList] + $item)
            continue
        }

        throw "Unsupported YAML front matter line: $line"
    }

    return [pscustomobject]@{
        Values = $values
        Lists  = $lists
    }
}

function Get-MetadataValue {
    param(
        [hashtable] $Metadata,
        [string] $Name
    )

    if ($Metadata.ContainsKey($Name)) {
        return [string]$Metadata[$Name]
    }
    return $null
}

function ConvertTo-BooleanValue {
    param(
        [string] $Name,
        [string] $Value
    )

    if ($Value -eq 'true') { return $true }
    if ($Value -eq 'false') { return $false }
    throw "Metadata '$Name' must be true or false, not '$Value'."
}

function Get-TextSha256 {
    param([string] $Text)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-CurrentCommitSha {
    param([string] $Root)

    Push-Location $Root
    try {
        $value = (& git rev-parse HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and $value) {
            return ([string]$value).Trim()
        }
        return ''
    }
    finally {
        Pop-Location
    }
}

function Get-CurrentTreeDigest {
    param(
        [string] $Root,
        [string] $SpecRelativePath = 'docs/spec.md'
    )

    $parts = New-Object System.Collections.Generic.List[string]
    Push-Location $Root
    try {
        $diff = (& git diff --binary HEAD -- . ":(exclude)$SpecRelativePath" ':(exclude)docs/specs/**/tasks.json' ':(exclude).sdlc/**' 2>$null | Out-String)
        if ($LASTEXITCODE -ne 0) {
            return ''
        }
        [void]$parts.Add("tracked:$diff")

        $untracked = @(& git ls-files --others --exclude-standard 2>$null)
        foreach ($relativePath in ($untracked | Sort-Object)) {
            if ([string]$relativePath -eq '.sdlc' -or ([string]$relativePath).StartsWith('.sdlc/')) { continue }
            $fullPath = Join-Path $Root ([string]$relativePath)
            if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                $fileHash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
                [void]$parts.Add("untracked:${relativePath}:$fileHash")
            }
        }

        return Get-TextSha256 (($parts | Sort-Object) -join "`n")
    }
    finally {
        Pop-Location
    }
}

function Test-GateRecord {
    param(
        [string] $Name,
        [string[]] $AllowedResults,
        [hashtable] $Metadata,
        [string] $ExpectedCommitSha,
        [string] $ExpectedTreeDigest,
        [string] $Root
    )

    $valid = $true
    $prefix = "gate_$Name"
    $result = Get-MetadataValue $Metadata "${prefix}_result"
    $command = Get-MetadataValue $Metadata "${prefix}_command"
    $commit = Get-MetadataValue $Metadata "${prefix}_commit_sha"
    $tree = Get-MetadataValue $Metadata "${prefix}_tree_digest"
    $timestamp = Get-MetadataValue $Metadata "${prefix}_timestamp"
    $exitCode = Get-MetadataValue $Metadata "${prefix}_exit_code"
    $evidence = Get-MetadataValue $Metadata "${prefix}_evidence"

    if ($result -notin $AllowedResults) {
        Write-Host "[FAIL] Gate '$Name': result must be $($AllowedResults -join ', '), not '$result'."
        $valid = $false
    }
    foreach ($field in @(
            @{ Name = 'command'; Value = $command },
            @{ Name = 'commit_sha'; Value = $commit },
            @{ Name = 'tree_digest'; Value = $tree },
            @{ Name = 'timestamp'; Value = $timestamp },
            @{ Name = 'exit_code'; Value = $exitCode },
            @{ Name = 'evidence'; Value = $evidence }
        )) {
        if ([string]::IsNullOrWhiteSpace([string]$field.Value)) {
            Write-Host "[FAIL] Gate '$Name': field '$($field.Name)' is required."
            $valid = $false
        }
    }

    $parsedExitCode = 0
    if (-not [int]::TryParse($exitCode, [ref]$parsedExitCode)) {
        Write-Host "[FAIL] Gate '$Name': exit_code must be an integer."
        $valid = $false
    }
    elseif (($result -eq 'PASS' -and $parsedExitCode -ne 0) -or
        ($result -ne 'PASS' -and $parsedExitCode -eq 0)) {
        Write-Host "[FAIL] Gate '$Name': result '$result' conflicts with exit_code '$parsedExitCode'."
        $valid = $false
    }

    if ($commit -ne $ExpectedCommitSha) {
        Write-Host "[FAIL] Gate '$Name': commit_sha '$commit' is stale; expected '$ExpectedCommitSha'."
        $valid = $false
    }
    if ($tree -ne $ExpectedTreeDigest) {
        Write-Host "[FAIL] Gate '$Name': tree_digest is stale for the current working tree."
        $valid = $false
    }

    $evidencePath = $evidence
    if ($evidence -and -not [System.IO.Path]::IsPathRooted($evidence)) {
        $evidencePath = Join-Path $Root $evidence
    }
    if ($script:FeatureId) {
        $recordFeatureId = Get-MetadataValue $Metadata "${prefix}_feature_id"
        $recordSpecPath = (Get-MetadataValue $Metadata "${prefix}_spec_path") -replace '\\', '/'
        $expectedEvidencePrefix = ".sdlc/evidence/$($script:FeatureId)/"
        $normalizedEvidence = $evidence -replace '\\', '/'
        if ($recordFeatureId -ne $script:FeatureId) {
            Write-Host "[FAIL] Gate '$Name': feature_id '$recordFeatureId' does not match '$($script:FeatureId)'."
            $valid = $false
        }
        if ($recordSpecPath -ne $script:SpecRelativePath) {
            Write-Host "[FAIL] Gate '$Name': spec_path '$recordSpecPath' does not match '$($script:SpecRelativePath)'."
            $valid = $false
        }
        if ([System.IO.Path]::IsPathRooted($evidence) -or -not $normalizedEvidence.StartsWith($expectedEvidencePrefix, [System.StringComparison]::Ordinal)) {
            Write-Host "[FAIL] Gate '$Name': evidence must be under '$expectedEvidencePrefix'."
            $valid = $false
        }
    }
    if (-not $evidence -or -not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        Write-Host "[FAIL] Gate '$Name': evidence file '$evidence' does not exist."
        $valid = $false
    }

    if ($valid) {
        Write-Host "[PASS] Gate '$Name': evidence is valid for the current revision."
    }
    return $valid
}

function Get-ValidationContract {
    param([string] $Root)

    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $content = Get-Content -LiteralPath $configPath -Raw
    if ($content -notmatch '(?m)^\s*sdlc_config_schema:\s*1\s*$') { return $null }
    $required = New-Object System.Collections.Generic.List[string]
    $requiredMatch = [regex]::Match($content, '(?m)^\s*required_tasks:\s*\[(?<items>[^\]]*)\]')
    if ($requiredMatch.Success) {
        foreach ($item in ($requiredMatch.Groups['items'].Value -split ',')) {
            $task = $item.Trim().Trim('"', "'")
            if ($task) { [void]$required.Add($task) }
        }
    }
    $install = 'none'
    $installMatch = [regex]::Match($content, '(?m)^\s*install_task:\s*(?<value>[^\r\n#]+)')
    if ($installMatch.Success) { $install = $installMatch.Groups['value'].Value.Trim().Trim('"', "'") }
    return [pscustomobject]@{ Required = @($required); Install = $install }
}

function Test-ConfiguredTaskGates {
    param(
        [string] $Root,
        [hashtable] $Metadata,
        [string] $ExpectedCommitSha,
        [string] $ExpectedTreeDigest,
        [string] $TargetPhase,
        [string] $CurrentState
    )

    $contract = Get-ValidationContract -Root $Root
    if ($null -eq $contract) { return $true }
    $tasks = New-Object System.Collections.Generic.List[string]
    if ($CurrentState -eq 'CODING' -and $TargetPhase -eq 'REVIEW') {
        foreach ($task in $contract.Required) { if ($task -ne 'test') { [void]$tasks.Add($task) } }
        if ($contract.Install -eq 'install') { [void]$tasks.Add('install') }
    }
    elseif ($CurrentState -eq 'TESTING' -and $TargetPhase -in @('DONE', 'DEPLOYMENT_READINESS')) {
        foreach ($task in $contract.Required) { [void]$tasks.Add($task) }
        if ($contract.Install -eq 'install') { [void]$tasks.Add('install') }
    }
    $passed = $true
    foreach ($task in ($tasks | Select-Object -Unique)) {
        if (-not (Test-GateRecord -Name $task -AllowedResults @('PASS') -Metadata $Metadata -ExpectedCommitSha $ExpectedCommitSha -ExpectedTreeDigest $ExpectedTreeDigest -Root $Root)) { $passed = $false }
    }
    return $passed
}

function Get-ConfigSectionValue {
    param([string] $Root, [string] $Section, [string] $Key)
    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return '' }
    $inside = $false
    foreach ($rawLine in (Get-Content -LiteralPath $configPath)) {
        $line = [string]$rawLine
        if ($line -match ('^' + [regex]::Escape($Section) + ':\s*$')) { $inside = $true; continue }
        if ($inside -and $line -match '^[^\s#]') { break }
        if ($inside -and $line -match ('^\s+' + [regex]::Escape($Key) + ':\s*(?<value>.*)$')) {
            $value = $Matches.value -replace '\s+#.*$', ''
            return $value.Trim().Trim('"', "'")
        }
    }
    return ''
}

function Get-ConfigSectionList {
    param([string] $Root, [string] $Section, [string] $Key)
    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    $items = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return @() }
    $inside = $false
    $active = $false
    foreach ($rawLine in (Get-Content -LiteralPath $configPath)) {
        $line = [string]$rawLine
        if ($line -match ('^' + [regex]::Escape($Section) + ':\s*$')) { $inside = $true; continue }
        if ($inside -and $line -match '^[^\s#]') { break }
        if ($inside -and $line -match ('^\s+' + [regex]::Escape($Key) + ':\s*(?<value>.*)$')) {
            $value = ($Matches.value -replace '\s+#.*$', '').Trim()
            if ($value.StartsWith('[') -and $value.EndsWith(']')) {
                $inner = $value.Substring(1, $value.Length - 2)
                foreach ($item in ($inner -split ',')) {
                    $clean = $item.Trim().Trim('"', "'")
                    if ($clean) { [void]$items.Add($clean) }
                }
                $active = $false
            }
            else { $active = $true }
            continue
        }
        if ($inside -and $active -and $line -match '^\s+-\s*(?<item>.*)$') {
            $clean = ($Matches.item -replace '\s+#.*$', '').Trim().Trim('"', "'")
            if ($clean) { [void]$items.Add($clean) }
            continue
        }
        if ($active -and $line -notmatch '^\s*$') { $active = $false }
    }
    return @($items)
}

function Get-VerificationContract {
    param([string] $Root)
    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $null }
    $content = Get-Content -LiteralPath $configPath -Raw
    if ($content -notmatch '(?m)^verification:\s*$') { return $null }
    return [pscustomobject]@{
        RiskProfile = Get-ConfigSectionValue -Root $Root -Section 'quality_security' -Key 'risk_profile'
        CoverageEnabled = Get-ConfigSectionValue -Root $Root -Section 'verification' -Key 'coverage_enabled'
        CoverageProfiles = @(Get-ConfigSectionList -Root $Root -Section 'verification' -Key 'coverage_required_risk_profiles')
        MutationEnabled = Get-ConfigSectionValue -Root $Root -Section 'verification' -Key 'mutation_enabled'
        MutationProfiles = @(Get-ConfigSectionList -Root $Root -Section 'verification' -Key 'mutation_required_risk_profiles')
    }
}

function Test-VerificationRecord {
    param(
        [string] $Root,
        [string] $Kind,
        [hashtable] $Metadata,
        [string] $ExpectedCommitSha,
        [string] $ExpectedTreeDigest
    )
    $adapterPath = Join-Path $PSScriptRoot 'verification.py'
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        Write-Host '[FAIL] Verification adapter not found.'
        return $false
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($null -eq $python) {
        Write-Host '[FAIL] Python 3 is required for verification evidence validation.'
        return $false
    }
    $evidence = Get-MetadataValue $Metadata "gate_${Kind}_evidence"
    $output = & $python.Source $adapterPath validate-record --record-kind $Kind --record-path $evidence --repo-root $Root --commit-sha $ExpectedCommitSha --tree-digest $ExpectedTreeDigest 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[FAIL] Verification '$Kind' evidence is invalid: $($output -join ' ')"
        return $false
    }
    Write-Host "[PASS] Verification '$Kind' evidence matches the current report and revision."
    return $true
}

function Test-VerificationGates {
    param(
        [string] $Root,
        [hashtable] $Metadata,
        [string] $ExpectedCommitSha,
        [string] $ExpectedTreeDigest
    )
    $contract = Get-VerificationContract -Root $Root
    if ($null -eq $contract) { return $true }
    $passed = $true
    if ($contract.CoverageProfiles -contains $contract.RiskProfile) {
        if ($contract.CoverageEnabled -ne 'true') {
            Write-Host "[FAIL] Risk profile '$($contract.RiskProfile)' requires verification coverage to be enabled."
            $passed = $false
        }
        elseif (-not (Test-GateRecord -Name 'coverage' -AllowedResults @('PASS') -Metadata $Metadata -ExpectedCommitSha $ExpectedCommitSha -ExpectedTreeDigest $ExpectedTreeDigest -Root $Root)) { $passed = $false }
        elseif (-not (Test-VerificationRecord -Root $Root -Kind 'coverage' -Metadata $Metadata -ExpectedCommitSha $ExpectedCommitSha -ExpectedTreeDigest $ExpectedTreeDigest)) { $passed = $false }
    }
    if ($contract.MutationProfiles -contains $contract.RiskProfile) {
        if ($contract.MutationEnabled -ne 'true') {
            Write-Host "[FAIL] Risk profile '$($contract.RiskProfile)' requires mutation verification to be enabled."
            $passed = $false
        }
        elseif (-not (Test-GateRecord -Name 'mutation' -AllowedResults @('PASS') -Metadata $Metadata -ExpectedCommitSha $ExpectedCommitSha -ExpectedTreeDigest $ExpectedTreeDigest -Root $Root)) { $passed = $false }
        elseif (-not (Test-VerificationRecord -Root $Root -Kind 'mutation' -Metadata $Metadata -ExpectedCommitSha $ExpectedCommitSha -ExpectedTreeDigest $ExpectedTreeDigest)) { $passed = $false }
    }
    return $passed
}

function Test-TaskGraphGate {
    param(
        [string] $Root,
        [string] $CurrentFeatureId,
        [string] $CurrentSpecPath,
        [string] $TargetPhase,
        [string] $ExpectedCommitSha,
        [string] $ExpectedTreeDigest
    )

    if (-not $CurrentFeatureId -or $TargetPhase -notin @('CODING', 'REVIEW', 'TESTING', 'DEPLOYMENT_READINESS', 'DONE')) { return $true }
    $tasksPath = Join-Path $Root "docs/specs/$CurrentFeatureId/tasks.json"
    if (-not (Test-Path -LiteralPath $tasksPath -PathType Leaf)) { return $true }
    $taskGraphPath = Join-Path $PSScriptRoot 'task-graph.py'
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if ($null -eq $python) {
        Write-Host '[FAIL] Python 3 is required when a feature tasks.json exists.'
        return $false
    }
    $output = & $python.Source $taskGraphPath validate --repo-root $Root --feature-id $CurrentFeatureId --spec-path $CurrentSpecPath --target-phase $TargetPhase --commit-sha $ExpectedCommitSha --tree-digest $ExpectedTreeDigest 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host '[FAIL] Task graph gate failed:'
        $output | ForEach-Object { Write-Host "  $_" }
        return $false
    }
    Write-Host "[PASS] Task graph is valid for feature '$CurrentFeatureId' and target phase '$TargetPhase'."
    return $true
}

function Get-SectionBody {
    param(
        [string] $Content,
        [string] $Section
    )

    $pattern = '(?ms)^## ' + [regex]::Escape($Section) + '\s*\r?\n(.*?)(?=^## |^---\s*$|\z)'
    $match = [regex]::Match($Content, $pattern)
    if ($match.Success) {
        return $match.Groups[1].Value
    }
    return $null
}

function Test-Phase2Config {
    param([string] $Root)
    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $false }
    $config = Get-Content -LiteralPath $configPath -Raw
    return $config -match '(?m)^quality_security:\s*$'
}

    function Test-ReleaseAssuranceEnabled {
        param([string] $Root)
        $configPath = Join-Path $Root '.github/sdlc-config.yml'
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $false }
        $config = Get-Content -LiteralPath $configPath -Raw
        return $config -match '(?ms)^release_assurance:\s*\r?\n(?:(?!^\S).)*?^\s*enabled:\s*true\s*$'
    }

function Test-ConfigFlag {
    param(
        [string] $Root,
        [string] $Section,
        [string] $Field
    )

    $configPath = Join-Path $Root '.github/sdlc-config.yml'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return $false }
    $config = Get-Content -LiteralPath $configPath -Raw
    $pattern = '(?ms)^' + [regex]::Escape($Section) + ':\s*\r?\n(?:(?!^\S).)*?^\s*' + [regex]::Escape($Field) + ':\s*true\s*$'
    return $config -match $pattern
}

function Test-RequiredSections {
    param(
        [string] $Content,
        [string] $TargetPhase,
        [bool] $DesignRequired,
        [bool] $DeploymentReadinessEnabled,
        [bool] $Phase2Enabled,
        [bool] $SecurityReviewRequired
    )

    $sections = @{
        'GATHERING_REQS'       = @('Goal', 'Requirements', 'Acceptance Criteria', 'Out of Scope')
        'DESIGN'               = @('Design')
        'PLANNING'             = @('Tech Stack', 'File Structure', 'Implementation Plan')
        'CODING'               = @('Implementation Plan')
        'REVIEW'               = @('Review Findings')
        'TESTING'              = @('Test Results')
        'DEPLOYMENT_READINESS' = @('Deployment Readiness')
        'DONE'                 = @()
    }
    if ($Phase2Enabled) {
        $sections['PLANNING'] = @($sections['PLANNING'] + 'Test Strategy' + 'Acceptance Test Mapping')
        if ($SecurityReviewRequired) { $sections['PLANNING'] = @($sections['PLANNING'] + 'Security Design Review') }
    }
    $allPassed = $true
    $targetIndex = $phaseOrder[$TargetPhase]

    foreach ($state in $validStates) {
        if ($phaseOrder[$state] -ge $targetIndex) {
            break
        }
        if ($state -eq 'DESIGN' -and -not $DesignRequired) {
            Write-Host "[SKIP] Phase 'DESIGN' is disabled for this project."
            continue
        }
        if ($state -eq 'DEPLOYMENT_READINESS' -and -not $DeploymentReadinessEnabled) {
            Write-Host "[SKIP] Phase 'DEPLOYMENT_READINESS' is disabled for this project."
            continue
        }

        foreach ($section in $sections[$state]) {
            $body = Get-SectionBody -Content $Content -Section $section
            if ($null -eq $body) {
                Write-Host "[FAIL] Phase '$state': section '## $section' not found."
                $allPassed = $false
                continue
            }

            $clean = $body
            $clean = $clean -replace '(?s)<!--.*?-->', ''
            $clean = $clean -replace '(?m)^_.*(?:PM|Designer|Architect|Reviewer|QA).*_\s*$', ''
            $clean = $clean -replace '\((?:PM|Designer|Architect|Reviewer|QA)[^)]*\)', ''
            $clean = $clean -replace '(?m)^\s*```[^\r\n]*$', ''
            $clean = $clean -replace '(?m)^\s*-\s*\[ \]\s*$', ''
            $clean = $clean -replace '(?m)^\s*-?\s*$', ''
            $clean = $clean -replace '(?m)^\s*\d+\.\s*$', ''
            $clean = $clean.Trim()

            if ($section -eq 'Security Design Review' -and $SecurityReviewRequired -and $clean -match '(?i)Status:\s*NOT_REQUIRED') {
                Write-Host "[FAIL] Phase '$state': security review is required but remains NOT_REQUIRED."
                $allPassed = $false
                continue
            }

            if ([string]::IsNullOrWhiteSpace($clean)) {
                Write-Host "[FAIL] Phase '$state': section '## $section' appears empty."
                $allPassed = $false
            }
            else {
                Write-Host "[PASS] Phase '$state': section '## $section' is populated."
            }
        }
    }
    return $allPassed
}

if (-not (Test-Path -LiteralPath $SpecPath -PathType Leaf)) {
    Write-Host "[FAIL] docs/spec.md not found at: $SpecPath"
    exit 1
}

$content = Get-Content -LiteralPath $SpecPath -Raw
try {
    $metadata = Read-WorkflowMetadata -Content $content
    $requiredKeys = @(
        'sdlc_schema', 'current_phase', 'design_required',
        'deployment_readiness_enabled', 'security_gate_enabled', 'review_cycle',
        'last_transition_to', 'planned_files', 'approved_globs'
    )
    foreach ($key in $requiredKeys) {
        if (-not $metadata.Values.ContainsKey($key)) {
            throw "Required workflow metadata '$key' is missing."
        }
    }
}
catch {
    Write-Host "[FAIL] $($_.Exception.Message)"
    exit 1
}

if ($FeatureId) {
    $declaredFeatureId = Get-MetadataValue $metadata.Values 'feature_id'
    $declaredSpecPath = (Get-MetadataValue $metadata.Values 'spec_path') -replace '\\', '/'
    if ($declaredFeatureId -ne $FeatureId) {
        Write-Host "[FAIL] Spec feature_id '$declaredFeatureId' does not match requested feature '$FeatureId'."
        exit 1
    }
    if ($declaredSpecPath -ne $script:SpecRelativePath) {
        Write-Host "[FAIL] Spec spec_path '$declaredSpecPath' does not match '$script:SpecRelativePath'."
        exit 1
    }
}

$schema = Get-MetadataValue $metadata.Values 'sdlc_schema'
if ($schema -ne '1') {
    Write-Host "[FAIL] Unsupported sdlc_schema '$schema'. Expected '1'."
    exit 1
}

$currentState = Get-MetadataValue $metadata.Values 'current_phase'
if ($currentState -notin $validStates) {
    Write-Host "[FAIL] Invalid current_phase '$currentState'. Must be one of: $($validStates -join ', ')"
    exit 1
}

$visibleStateMatch = [regex]::Match($content, '## Current State\s*\r?\n\s*`([^`]+)`')
$visibleCycleMatch = [regex]::Match($content, '## Review Cycle\s*\r?\n\s*`([^`]+)`')
if (-not $visibleStateMatch.Success -or $visibleStateMatch.Groups[1].Value.Trim() -ne $currentState) {
    Write-Host "[FAIL] Visible 'Current State' does not match current_phase '$currentState'."
    exit 1
}

$reviewCycle = 0
if (-not [int]::TryParse((Get-MetadataValue $metadata.Values 'review_cycle'), [ref]$reviewCycle) -or
    $reviewCycle -lt 0 -or $reviewCycle -gt 3) {
    Write-Host "[FAIL] review_cycle must be an integer from 0 through 3."
    exit 1
}
if (-not $visibleCycleMatch.Success -or $visibleCycleMatch.Groups[1].Value.Trim() -ne [string]$reviewCycle) {
    Write-Host "[FAIL] Visible 'Review Cycle' does not match review_cycle '$reviewCycle'."
    exit 1
}

try {
    $designRequired = ConvertTo-BooleanValue 'design_required' (Get-MetadataValue $metadata.Values 'design_required')
    $deploymentReadinessEnabled = ConvertTo-BooleanValue 'deployment_readiness_enabled' (Get-MetadataValue $metadata.Values 'deployment_readiness_enabled')
    $securityGateEnabled = ConvertTo-BooleanValue 'security_gate_enabled' (Get-MetadataValue $metadata.Values 'security_gate_enabled')
}
catch {
    Write-Host "[FAIL] $($_.Exception.Message)"
    exit 1
}

$lastTransitionTo = Get-MetadataValue $metadata.Values 'last_transition_to'
if ($lastTransitionTo -ne $currentState) {
    Write-Host "[FAIL] last_transition_to '$lastTransitionTo' does not match current_phase '$currentState'."
    exit 1
}
if ($currentState -ne 'GATHERING_REQS' -and (Get-MetadataValue $metadata.Values 'last_transition_actor') -notin @('supervisor', 'migration')) {
    Write-Host '[FAIL] Non-initial workflow states must be applied by the supervisor or an evidenced migration.'
    exit 1
}
if ((Get-MetadataValue $metadata.Values 'last_transition_actor') -eq 'migration') {
    $migrationEvidence = Get-MetadataValue $metadata.Values 'last_transition_evidence'
    $migrationEvidencePath = if ([System.IO.Path]::IsPathRooted($migrationEvidence)) { $migrationEvidence } else { Join-Path $RepoRoot $migrationEvidence }
    if ([string]::IsNullOrWhiteSpace($migrationEvidence) -or -not (Test-Path -LiteralPath $migrationEvidencePath -PathType Leaf)) {
        Write-Host '[FAIL] Migration bootstrap requires an existing last_transition_evidence file.'
        exit 1
    }
}
if (($currentState -eq 'DESIGN' -and -not $designRequired) -or
    ($currentState -eq 'DEPLOYMENT_READINESS' -and -not $deploymentReadinessEnabled)) {
    Write-Host "[FAIL] Current phase '$currentState' is disabled by workflow metadata."
    exit 1
}

$targetPhase = $Phase
if (-not $targetPhase) {
    switch ($currentState) {
        'GATHERING_REQS' { $targetPhase = if ($designRequired) { 'DESIGN' } else { 'PLANNING' } }
        'DESIGN' { $targetPhase = 'PLANNING' }
        'PLANNING' { $targetPhase = 'CODING' }
        'CODING' { $targetPhase = 'REVIEW' }
        'REVIEW' { $targetPhase = 'TESTING' }
        'TESTING' { $targetPhase = if ($deploymentReadinessEnabled) { 'DEPLOYMENT_READINESS' } else { 'DONE' } }
        'DEPLOYMENT_READINESS' { $targetPhase = 'DONE' }
        'DONE' {
            Write-Host '[PASS] Already at final state: DONE'
            exit 0
        }
    }
}

if ($targetPhase -notin $validStates) {
    Write-Host "[FAIL] Invalid target phase '$targetPhase'. Must be one of: $($validStates -join ', ')"
    exit 1
}

$allPassed = $true
$transition = "$currentState -> $targetPhase"
$allowed = @(
    'GATHERING_REQS -> DESIGN',
    'GATHERING_REQS -> PLANNING',
    'DESIGN -> PLANNING',
    'PLANNING -> CODING',
    'CODING -> REVIEW',
    'REVIEW -> CODING',
    'REVIEW -> TESTING',
    'REVIEW -> GATHERING_REQS',
    'TESTING -> CODING',
    'TESTING -> DEPLOYMENT_READINESS',
    'TESTING -> DONE',
    'DEPLOYMENT_READINESS -> CODING',
    'DEPLOYMENT_READINESS -> DONE'
)
if ($transition -notin $allowed) {
    Write-Host "[FAIL] Illegal workflow transition: $transition"
    $allPassed = $false
}
if ($targetPhase -eq 'DESIGN' -and -not $designRequired) {
    Write-Host '[FAIL] DESIGN is disabled, so the target phase is invalid.'
    $allPassed = $false
}
if ($targetPhase -eq 'DEPLOYMENT_READINESS' -and -not $deploymentReadinessEnabled) {
    Write-Host '[FAIL] DEPLOYMENT_READINESS is disabled, so the target phase is invalid.'
    $allPassed = $false
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'CODING' -and $reviewCycle -ge 3) {
    Write-Host '[FAIL] Review cycle cap reached; REVIEW cannot return to CODING. Escalate instead.'
    $allPassed = $false
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'GATHERING_REQS' -and $reviewCycle -ne 3) {
    Write-Host '[FAIL] Escalation to GATHERING_REQS requires review_cycle 3.'
    $allPassed = $false
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'GATHERING_REQS') {
    $escalationEvidence = Get-MetadataValue $metadata.Values 'last_transition_evidence'
    $escalationPath = if ([System.IO.Path]::IsPathRooted($escalationEvidence)) { $escalationEvidence } else { Join-Path $RepoRoot $escalationEvidence }
    if ([string]::IsNullOrWhiteSpace($escalationEvidence) -or -not (Test-Path -LiteralPath $escalationPath -PathType Leaf)) {
        Write-Host '[FAIL] Review-cycle escalation requires an existing last_transition_evidence file.'
        $allPassed = $false
    }
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'CODING' -and $reviewCycle -ge 3) {
    $allPassed = $false
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'TESTING' -and $reviewCycle -ne 0) {
    Write-Host '[FAIL] Approved review must reset review_cycle to 0 before TESTING.'
    $allPassed = $false
}
if ($currentState -eq 'TESTING' -and $targetPhase -eq 'DONE' -and $deploymentReadinessEnabled) {
    Write-Host '[FAIL] TESTING cannot transition directly to DONE while readiness is enabled.'
    $allPassed = $false
}

$expectedCommitSha = if ($CommitSha) { $CommitSha } else { Get-CurrentCommitSha -Root $RepoRoot }
$expectedTreeDigest = if ($TreeDigest) { $TreeDigest } else { Get-CurrentTreeDigest -Root $RepoRoot -SpecRelativePath $script:SpecRelativePath }
$taskGraphValid = Test-TaskGraphGate -Root $RepoRoot -CurrentFeatureId $FeatureId -CurrentSpecPath $SpecPath -TargetPhase $targetPhase -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest
if (-not $taskGraphValid) { $allPassed = $false }
$phase2Enabled = Test-Phase2Config -Root $RepoRoot
$securityReviewRequired = $securityGateEnabled
$releaseAssuranceEnabled = Test-ReleaseAssuranceEnabled -Root $RepoRoot
$aiGovernanceEnabled = Test-ConfigFlag -Root $RepoRoot -Section 'ai_governance' -Field 'enabled'
$operationalReadinessEnabled = Test-ConfigFlag -Root $RepoRoot -Section 'operational_readiness' -Field 'enabled'
$aiLifecycleEnabled = Test-ConfigFlag -Root $RepoRoot -Section 'ai_lifecycle' -Field 'enabled'
$measurementCompletionGateEnabled = (Test-ConfigFlag -Root $RepoRoot -Section 'measurement' -Field 'enabled') -and
    (Test-ConfigFlag -Root $RepoRoot -Section 'measurement' -Field 'require_completion_gate')
if ($releaseAssuranceEnabled -and $currentState -eq 'TESTING' -and $targetPhase -eq 'DONE') {
    if (-not (Test-GateRecord -Name 'release' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}

if ($currentState -eq 'GATHERING_REQS' -and $targetPhase -in @('DESIGN', 'PLANNING')) {
    if (-not (Test-GateRecord -Name 'requirements' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'PLANNING' -and $targetPhase -eq 'CODING') {
    if (-not (Test-GateRecord -Name 'config' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'DESIGN' -and $targetPhase -eq 'PLANNING') {
    if (-not (Test-GateRecord -Name 'design' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'PLANNING' -and $targetPhase -eq 'CODING') {
    if (-not (Test-GateRecord -Name 'planning' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'CODING' -and $targetPhase -eq 'REVIEW') {
    if (-not (Test-GateRecord -Name 'build' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
    if ($securityGateEnabled -and -not (Test-GateRecord -Name 'security' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
    if ($aiGovernanceEnabled -and -not (Test-GateRecord -Name 'ai_governance' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
    if (-not (Test-ConfiguredTaskGates -Root $RepoRoot -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -TargetPhase $targetPhase -CurrentState $currentState)) { $allPassed = $false }
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'CODING') {
    if (-not (Test-GateRecord -Name 'review' -AllowedResults @('CHANGES_REQUESTED') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'TESTING') {
    if (-not (Test-GateRecord -Name 'review' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'REVIEW' -and $targetPhase -eq 'GATHERING_REQS') {
    if (-not (Test-GateRecord -Name 'review' -AllowedResults @('CHANGES_REQUESTED') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'TESTING' -and $targetPhase -eq 'CODING') {
    if (-not (Test-GateRecord -Name 'test' -AllowedResults @('FAIL') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'TESTING' -and $targetPhase -in @('DEPLOYMENT_READINESS', 'DONE')) {
    if (-not (Test-GateRecord -Name 'test' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
    if (-not (Test-ConfiguredTaskGates -Root $RepoRoot -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -TargetPhase $targetPhase -CurrentState $currentState)) { $allPassed = $false }
    if (-not (Test-VerificationGates -Root $RepoRoot -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest)) { $allPassed = $false }
}
if ($currentState -eq 'DEPLOYMENT_READINESS' -and $targetPhase -eq 'CODING') {
    if (-not (Test-GateRecord -Name 'deployment_readiness' -AllowedResults @('FAIL') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if ($currentState -eq 'DEPLOYMENT_READINESS' -and $targetPhase -eq 'DONE') {
    if (-not (Test-GateRecord -Name 'deployment_readiness' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
        if ($releaseAssuranceEnabled -and -not (Test-GateRecord -Name 'release' -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
}
if (($currentState -eq 'TESTING' -and $targetPhase -eq 'DONE') -or
    ($currentState -eq 'DEPLOYMENT_READINESS' -and $targetPhase -eq 'DONE')) {
    $completionGates = @()
    if ($operationalReadinessEnabled) { $completionGates += 'operational_readiness' }
    if ($aiLifecycleEnabled) { $completionGates += 'ai_lifecycle' }
    if ($measurementCompletionGateEnabled) { $completionGates += 'measurement' }
    foreach ($gate in $completionGates) {
        if (-not (Test-GateRecord -Name $gate -AllowedResults @('PASS') -Metadata $metadata.Values -ExpectedCommitSha $expectedCommitSha -ExpectedTreeDigest $expectedTreeDigest -Root $RepoRoot)) { $allPassed = $false }
    }
}

Write-Host "Checking phase prerequisites up to: $targetPhase (current state: $currentState)"
if (-not (Test-RequiredSections -Content $content -TargetPhase $targetPhase -DesignRequired $designRequired -DeploymentReadinessEnabled $deploymentReadinessEnabled -Phase2Enabled $phase2Enabled -SecurityReviewRequired $securityReviewRequired)) {
    $allPassed = $false
}

if ($allPassed) {
    Write-Host "[PASS] All transition and prerequisite checks passed for phase: $targetPhase"
    exit 0
}

Write-Host '[FAIL] Some transition, gate, or prerequisite checks failed. See output above.'
exit 2
