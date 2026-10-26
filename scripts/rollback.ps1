. "$PSScriptRoot/common.ps1"
Assert-Docker
$record = Join-Path $Runtime 'previous-release.json'
if (-not (Test-Path $record)) { throw 'No previous release recorded. Complete a deployment first.' }
$previous = Get-Content $record -Raw | ConvertFrom-Json
if ($previous.image -notmatch '^pulseops-app:[a-z0-9][a-z0-9_.-]{0,127}$') { throw 'Invalid previous image record.' }
Invoke-Docker image inspect $previous.image --format '{{.Id}}'
$deployment = Join-Path $Runtime 'deployment.env'
$backup = Get-Content $deployment -Raw
try {
    [IO.File]::WriteAllText($deployment, "APP_IMAGE=$($previous.image)`n")
    Initialize-Environment
    Invoke-Compose up -d --no-deps --wait --wait-timeout 90 app
    Wait-Endpoint 'http://localhost:8000/health'
    $actual = Invoke-RestMethod 'http://localhost:8000/api/version'
    if ($actual.commit -ne $previous.commit -or $actual.version -ne $previous.version) { throw 'Rollback version verification failed.' }
} catch {
    $failure = $_
    [IO.File]::WriteAllText($deployment, $backup)
    Initialize-Environment
    Invoke-Compose up -d --no-deps --wait --wait-timeout 90 app
    throw $failure
}
$previous | ConvertTo-Json | Set-Content (Join-Path $Runtime 'current-release.json') -Encoding utf8
Write-Host "Restored $($previous.image). Task data and monitoring history were preserved." -ForegroundColor Green
