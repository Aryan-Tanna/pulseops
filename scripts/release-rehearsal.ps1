# Exercises versioned deployment, rollback, persistent tasks, outage and recovery.
# The application is restored in finally even if the outage assertion fails.
. "$PSScriptRoot/common.ps1"
Assert-Docker
$checks = [System.Collections.Generic.List[object]]::new()
$task = Invoke-RestMethod 'http://localhost:9001/api/tasks' -Method Post -ContentType application/json -Body '{"title":"Release rehearsal persistence check","priority":"low"}'
$initial = Invoke-RestMethod 'http://localhost:8000/api/version'
$tag = 'rehearsal-' + (Get-Date -Format 'yyyyMMddHHmmss')
try {
    & "$PSScriptRoot/deploy.ps1" -Tag $tag -Version '1.0.1'
    $actual = Invoke-RestMethod 'http://localhost:8000/api/version'
    if ($actual.commit -ne $tag) { throw 'Deployment identity did not change.' }
    $checks.Add(@{check='Versioned application deployment'; passed=$true; commit=$actual.commit})
    & "$PSScriptRoot/rollback.ps1"
    $actual = Invoke-RestMethod 'http://localhost:8000/api/version'
    if ($actual.commit -ne $initial.commit -or $actual.version -ne $initial.version) { throw 'Rollback did not restore the initial version.' }
    $tasks = Invoke-RestMethod 'http://localhost:9001/api/tasks'
    if (-not @($tasks | Where-Object { $_.id -eq $task.id }).Count) { throw 'Task data did not survive deployment/rollback.' }
    $checks.Add(@{check='Rollback restored original version and task data'; passed=$true; version=$actual.version})
    $notifications = Invoke-RestMethod 'http://localhost:9001/api/notifications'
    $marker = 0
    foreach ($item in $notifications) { if ($item.id -gt $marker) { $marker = $item.id } }
    & "$PSScriptRoot/outage.ps1" -Action Stop
    $deadline = [DateTime]::UtcNow.AddSeconds(100)
    $fired = $false
    do {
        Start-Sleep -Seconds 3
        $notifications = Invoke-RestMethod 'http://localhost:9001/api/notifications'
        foreach ($item in $notifications) {
            if ($item.id -gt $marker -and $item.status -eq 'firing' -and @($item.alerts | Where-Object { $_.labels.alertname -eq 'WebAppMetricsUnreachable' }).Count) { $fired=$true }
        }
    } while (-not $fired -and [DateTime]::UtcNow -lt $deadline)
    if (-not $fired) { throw 'No actual outage webhook arrived.' }
    $checks.Add(@{check='Outage firing webhook delivered while console stayed online'; passed=$true})
    Write-Host 'PASS outage notification delivered; restoring application.' -ForegroundColor Green
} catch {
    $checks.Add(@{check='Release rehearsal'; passed=$false; error=$_.ToString()})
    throw
} finally {
    & "$PSScriptRoot/outage.ps1" -Action Start
    try { Invoke-RestMethod "http://localhost:9001/api/tasks/$($task.id)" -Method Delete -ContentType application/json -Body '{}' | Out-Null } catch { }
    @{checked_at=[DateTime]::UtcNow.ToString('o'); results=@($checks.ToArray())} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Runtime 'release-rehearsal.json') -Encoding utf8
}
$deadline = [DateTime]::UtcNow.AddSeconds(90)
$resolved = $false
do {
    Start-Sleep -Seconds 3
    foreach ($item in (Invoke-RestMethod 'http://localhost:9001/api/notifications')) {
        if ($item.id -gt $marker -and $item.status -eq 'resolved' -and @($item.alerts | Where-Object { $_.labels.alertname -eq 'WebAppMetricsUnreachable' }).Count) { $resolved=$true }
    }
} while (-not $resolved -and [DateTime]::UtcNow -lt $deadline)
if (-not $resolved) { throw 'No outage resolution webhook arrived.' }
$checks.Add(@{check='Outage resolved webhook delivered'; passed=$true})
@{checked_at=[DateTime]::UtcNow.ToString('o'); results=@($checks.ToArray())} | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Runtime 'release-rehearsal.json') -Encoding utf8
& "$PSScriptRoot/verify.ps1"
Write-Host 'PASS deployment, rollback, persistence, outage and recovery.' -ForegroundColor Green
