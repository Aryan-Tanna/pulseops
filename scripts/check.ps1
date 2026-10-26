param([string]$Image = 'pulseops-test:local', [switch]$SkipBuild)
$source = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/common.ps1"
Assert-Docker
if (-not $SkipBuild) { Invoke-Docker build --tag $Image $source }
Invoke-Docker run --rm --entrypoint python $Image -m unittest discover -s tests -v
Test-Monitoring
