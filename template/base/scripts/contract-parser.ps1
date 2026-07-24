<###
    Shared adapter for the canonical Python contract parser.

    The parser mode is standard by default. Set SDLC_PARSER_MODE=compat only
    for a legacy installation that cannot yet install PyYAML; that mode is
    deprecated and is removed in version 2.0.0.
###>

$ErrorActionPreference = 'Stop'

function Get-ContractPythonCommand {
    foreach ($name in @('python', 'python3', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) { return $command }
    }
    throw 'Python 3.9 or newer is required for canonical contract parsing. Install Python or set SDLC_PARSER_MODE=compat for a legacy installation.'
}

function Read-CanonicalContract {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('sdlc-config', 'spec-front-matter', 'template-manifest', 'generic', 'extension-config', 'task-graph')]
        [string] $Contract
    )

    $parserPath = Join-Path $PSScriptRoot 'contract_parser.py'
    if (-not (Test-Path -LiteralPath $parserPath -PathType Leaf)) {
        throw "Canonical contract parser is missing: $parserPath"
    }
    $python = Get-ContractPythonCommand
    $mode = if ($env:SDLC_PARSER_MODE) { $env:SDLC_PARSER_MODE } else { 'standard' }
    $temporaryPath = Join-Path ([System.IO.Path]::GetTempPath()) "sdlc-contract-$([guid]::NewGuid().ToString('N')).json"
    try {
        & $python.Source $parserPath parse --path $Path --contract $Contract --mode $mode --output $temporaryPath 2>$null
        $exitCode = $LASTEXITCODE
        if (-not (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            throw "Canonical contract parser produced no output for '$Path'."
        }
        $payload = Get-Content -LiteralPath $temporaryPath -Raw | ConvertFrom-Json
        if ($exitCode -ne 0) {
            $firstError = @($payload.errors | Select-Object -First 1)
            if ($firstError.Count -gt 0) {
                $location = if ($firstError[0].line) { " at line $($firstError[0].line), column $($firstError[0].column)" } else { '' }
                throw "Canonical parser rejected '$Path'$location`: $($firstError[0].message)"
            }
            throw "Canonical parser rejected '$Path'."
        }

        $values = @{}
        foreach ($property in @($payload.values.PSObject.Properties)) {
            $values[$property.Name] = [string]$property.Value
        }
        $lists = @{}
        foreach ($property in @($payload.lists.PSObject.Properties)) {
            $lists[$property.Name] = @($property.Value | ForEach-Object { [string]$_ })
        }
        $tasks = @{}
        foreach ($property in @($payload.tasks.PSObject.Properties)) {
            $task = $property.Value
            $tasks[$property.Name] = @{
                executable = [string]$task.executable
                args       = @($task.args | ForEach-Object { [string]$_ })
            }
        }
        return [pscustomobject]@{
            Document  = $payload.document
            Values    = $values
            Lists     = $lists
            Tasks     = $tasks
            Locations = $payload.locations
            Parser    = $payload.parser
            Warnings  = @($payload.warnings | ForEach-Object { [string]$_ })
            Source    = $payload.source
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}