[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $ArgumentList
)

$ErrorActionPreference = 'Stop'
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    $python = Get-Command py -ErrorAction SilentlyContinue
}
if (-not $python) {
    throw 'Python 3.9 or newer is required for the sdlc CLI.'
}
$cli = Join-Path $PSScriptRoot 'sdlc.py'
& $python.Source $cli @ArgumentList
exit $LASTEXITCODE
