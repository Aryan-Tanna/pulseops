param([switch]$NoBrowser, [switch]$Rebuild)
. "$PSScriptRoot/common.ps1"
Assert-Docker
function Test-LocalImage {
    param([string]$Name)
    try { & docker image inspect $Name --format '{{.Id}}' 2>$null | Out-Null } catch { }
    return $LASTEXITCODE -eq 0
}
Write-Host '[1/5] Checking cached monitoring images...' -ForegroundColor Cyan
foreach ($entry in @(@('prometheus','prom/prometheus:v3.15.1'), @('grafana','grafana/grafana:13.2.2'), @('alertmanager','prom/alertmanager:v0.34.1'))) {
    if (-not (Test-LocalImage $entry[1])) { Invoke-Compose pull $entry[0] }
}
Write-Host '[2/5] Preparing the application and independent console...' -ForegroundColor Cyan
$files = @((Join-Path $Root 'Dockerfile'), (Join-Path $Root 'requirements.txt'), (Join-Path $Root '.dockerignore'), (Join-Path $Root 'version.txt'))
foreach ($folder in @('app','console','web','tests')) {
    $files += @(Get-ChildItem (Join-Path $Root $folder) -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and $_.Extension -ne '.pyc' } | Select-Object -ExpandProperty FullName)
}
$parts = @($files | Sort-Object | ForEach-Object { $_.Substring($Root.Length) + '|' + (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
$hasher = [Security.Cryptography.SHA256]::Create()
$fingerprint = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($parts -join "`n")))).Replace('-','')
$hasher.Dispose()
$stamp = Join-Path $Runtime 'source.sha256'
$sameSource = (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $fingerprint)
if ($Rebuild -or -not $sameSource -or -not (Test-LocalImage 'pulseops-app:local') -or -not (Test-LocalImage 'pulseops-console:local')) {
    $localVersion = (Get-Content (Join-Path $Root 'version.txt') -Raw).Trim()
    Invoke-Docker build --build-arg "APP_VERSION=$localVersion" --build-arg COMMIT_SHA=local --tag pulseops-app:local $Root
    Invoke-Compose build console
    [IO.File]::WriteAllText($stamp, $fingerprint)
} else {
    Write-Host 'Source unchanged; reusing local images (no image download or build needed).'
}
Write-Host '[3/5] Testing the application and validating monitoring...' -ForegroundColor Cyan
$image = 'pulseops-app:local'
$deploymentFile = Join-Path $Runtime 'deployment.env'
if (Test-Path -LiteralPath $deploymentFile) {
    $image = ((Get-Content $deploymentFile | Where-Object { $_ -like 'APP_IMAGE=*' }) -replace '^APP_IMAGE=', '')
}
if (-not (Test-LocalImage $image)) { throw "Retained release image is missing: $image. Deploy a new release with scripts/deploy.ps1." }
Invoke-Docker run --rm --entrypoint python $image -m unittest discover -s tests -v
Test-Monitoring
Write-Host '[4/5] Starting the stack with persistent storage...' -ForegroundColor Cyan
Invoke-Compose up -d --pull never --wait --wait-timeout 120
Write-Host '[5/5] Verifying live services...' -ForegroundColor Cyan
& "$PSScriptRoot/verify.ps1"
if (-not $?) { throw 'Live verification failed.' }
Start-RegisteredRunner
Write-Host "`nPulseOps is ready: http://localhost:9001" -ForegroundColor Green
Write-Host 'Grafana opens without a login in read-only demo mode.'
Write-Host 'Admin credentials are in the ignored .env file if you want to edit Grafana.'
if (-not $NoBrowser) { Start-Process 'http://localhost:9001' }
