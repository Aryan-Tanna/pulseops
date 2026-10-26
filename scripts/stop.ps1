. "$PSScriptRoot/common.ps1"
Invoke-Compose stop
Write-Host 'Stack stopped. All persistent data is retained. Run START.cmd to resume.'
