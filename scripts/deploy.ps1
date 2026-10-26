param([string]$Tag = '', [string]$Version = '', [switch]$SkipBuild, [switch]$SkipTests)
$source = Split-Path $PSScriptRoot -Parent
. "$PSScriptRoot/common.ps1"
Assert-Docker
if (-not $Tag) { $Tag = 'local-' + (Get-Date -Format 'yyyyMMddHHmmss') }
if ($Tag -notmatch '^[a-z0-9][a-z0-9_.-]{0,127}$') { throw 'Invalid image tag.' }
if (-not $Version) { $Version = (Get-Content (Join-Path $source 'version.txt') -Raw).Trim() }
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}$') { throw 'Invalid version.' }
$image = "pulseops-app:$Tag"
if (-not $SkipBuild) { Invoke-Docker build --build-arg "APP_VERSION=$Version" --build-arg "COMMIT_SHA=$Tag" --tag $image $source }
if (-not $SkipTests) { Invoke-Docker run --rm --entrypoint python $image -m unittest discover -s tests -v }
Test-Monitoring
$previous = Invoke-RestMethod 'http://localhost:8000/api/version' -TimeoutSec 5
$currentConfig = & docker @script:ComposeBase config --format json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read current Compose configuration.' }
$oldImage = ($currentConfig | ConvertFrom-Json).services.app.image
$deployment = Join-Path $Runtime 'deployment.env'
$backup = if (Test-Path $deployment) { Get-Content $deployment -Raw } else { $null }
try {
    [IO.File]::WriteAllText($deployment, "APP_IMAGE=$image`n")
    Initialize-Environment
    Invoke-Compose up -d --no-deps --wait --wait-timeout 90 app
    Wait-Endpoint 'http://localhost:8000/health'
    $actual = Invoke-RestMethod 'http://localhost:8000/api/version'
    if ($actual.commit -ne $Tag -or $actual.version -ne $Version) { throw 'Running version does not match the release.' }
} catch {
    $failure = $_
    Write-Warning 'Deployment failed. Restoring the previous image.'
    if ($null -ne $backup) { [IO.File]::WriteAllText($deployment, $backup) } else { [IO.File]::WriteAllText($deployment, "APP_IMAGE=$oldImage`n") }
    Initialize-Environment
    Invoke-Compose up -d --no-deps --wait --wait-timeout 90 app
    throw $failure
}
@{ image=$oldImage; version=$previous.version; commit=$previous.commit } | ConvertTo-Json | Set-Content (Join-Path $Runtime 'previous-release.json') -Encoding utf8
@{ image=$image; version=$Version; commit=$Tag; deployed_at=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content (Join-Path $Runtime 'current-release.json') -Encoding utf8
Write-Host "Deployed $Version ($Tag). Previous image retained: $oldImage" -ForegroundColor Green
