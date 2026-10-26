param([ValidateSet('Stop','Start')][string]$Action = 'Stop')
. "$PSScriptRoot/common.ps1"
Assert-Docker
if ($Action -eq 'Stop') {
    try { Invoke-RestMethod 'http://localhost:9001/api/traffic' -Method Delete -ContentType 'application/json' -Body '{}' | Out-Null } catch { }
    Invoke-Compose stop app
    Write-Host 'Application stopped. Console and monitoring remain online. Restore it with: .\scripts\outage.ps1 -Action Start' -ForegroundColor Yellow
} else {
    Invoke-Compose start app
    Wait-Endpoint 'http://localhost:8000/health'
    Write-Host 'Application restored. Wait for alert resolution in the inbox.' -ForegroundColor Green
}
