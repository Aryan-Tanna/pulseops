. "$PSScriptRoot/common.ps1"
foreach ($url in @('http://localhost:8000/health', 'http://localhost:9001/health', 'http://localhost:9090/-/ready', 'http://localhost:3000/api/health', 'http://localhost:9093/-/ready')) {
    Wait-Endpoint $url
    Write-Host "PASS $url" -ForegroundColor Green
}
$deadline = [DateTime]::UtcNow.AddSeconds(60)
do {
    $targets = Invoke-RestMethod 'http://localhost:9090/api/v1/targets' -TimeoutSec 5
    $target = @($targets.data.activeTargets | Where-Object { $_.labels.job -eq 'webapp' })
    if ($target.Count -eq 1 -and $target[0].health -eq 'up') { break }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $deadline)
if ($target.Count -ne 1 -or $target[0].health -ne 'up') { throw 'Prometheus webapp target is not healthy.' }
$version = Invoke-RestMethod 'http://localhost:8000/api/version'
$result = @{ checked_at = [DateTime]::UtcNow.ToString('o'); services = 'ready'; prometheus_target = 'up'; version = $version }
$result | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Runtime 'latest-verification.json') -Encoding utf8
Write-Host "PASS Prometheus target is up; application version $($version.version), commit $($version.commit)" -ForegroundColor Green
