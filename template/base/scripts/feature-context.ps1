<##
.SYNOPSIS
    Resolves the feature-scoped workflow paths used by SDLC commands.

.DESCRIPTION
    Feature IDs are repository-safe, lowercase identifiers. A feature resolves
    to docs/specs/<feature-id>/spec.md and .sdlc/evidence/<feature-id>.
    Omitting FeatureId preserves the legacy docs/spec.md and .sdlc/evidence
    paths.
#>

function Get-FeatureRepoRelativePath {
    param(
        [string] $Root,
        [string] $Path
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
    $candidatePath = if ([System.IO.Path]::IsPathRooted($Path)) {
        [System.IO.Path]::GetFullPath($Path)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $Root $Path))
    }
    return ([System.IO.Path]::GetRelativePath($rootPath, $candidatePath) -replace '\\', '/')
}

function Assert-FeatureIdentifier {
    param([string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "FeatureId '$Value' is invalid. Use lowercase letters, numbers, and single hyphens only."
    }
    return $Value
}

function Resolve-FeatureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepoRoot,
        [string] $SpecPath,
        [string] $FeatureId,
        [string] $EvidenceDirectory
    )

    $rootPath = [System.IO.Path]::GetFullPath($RepoRoot)
    if ($FeatureId) {
        $validatedFeatureId = Assert-FeatureIdentifier $FeatureId
        $relativeSpecPath = "docs/specs/$validatedFeatureId/spec.md"
        if ($SpecPath) {
            $requestedRelativePath = Get-FeatureRepoRelativePath -Root $rootPath -Path $SpecPath
            if ($requestedRelativePath -ne $relativeSpecPath) {
                throw "Feature '$validatedFeatureId' must use spec path '$relativeSpecPath', not '$requestedRelativePath'."
            }
        }

        $expectedEvidenceDirectory = ".sdlc/evidence/$validatedFeatureId"
        if ($EvidenceDirectory) {
            $normalizedEvidenceDirectory = $EvidenceDirectory.Trim() -replace '\\', '/'
            while ($normalizedEvidenceDirectory.StartsWith('./')) {
                $normalizedEvidenceDirectory = $normalizedEvidenceDirectory.Substring(2)
            }
            if ($normalizedEvidenceDirectory -ne '.sdlc/evidence' -and
                $normalizedEvidenceDirectory -ne $expectedEvidenceDirectory) {
                throw "Feature '$validatedFeatureId' must use evidence directory '$expectedEvidenceDirectory'."
            }
        }

        return [pscustomobject]@{
            FeatureId        = $validatedFeatureId
            SpecPath         = Join-Path $rootPath $relativeSpecPath
            SpecRelativePath = $relativeSpecPath
            EvidenceDirectory = $expectedEvidenceDirectory
            EvidencePrefix   = "$expectedEvidenceDirectory/"
        }
    }

    return [pscustomobject]@{
        FeatureId        = ''
        SpecPath         = if ($SpecPath) { $SpecPath } else { Join-Path $rootPath 'docs/spec.md' }
        SpecRelativePath = 'docs/spec.md'
        EvidenceDirectory = $EvidenceDirectory
        EvidencePrefix   = '.sdlc/evidence/'
    }
}
