$ErrorActionPreference = 'Stop'
$Root = if ($env:PULSEOPS_HOME) { $env:PULSEOPS_HOME } else { Split-Path $PSScriptRoot -Parent }
$Root = [IO.Path]::GetFullPath($Root)
$Runtime = Join-Path $Root '.runtime'
New-Item -ItemType Directory -Path $Runtime -Force | Out-Null

function Initialize-Environment {
    $envFile = Join-Path $Root '.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        $bytes = New-Object byte[] 24
        $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
        $generator.GetBytes($bytes)
        $generator.Dispose()
        $password = [Convert]::ToBase64String($bytes)
        [IO.File]::WriteAllText($envFile, "APP_IMAGE=pulseops-app:local`nCONSOLE_IMAGE=pulseops-console:local`nAPP_VERSION=1.0.0`nCOMMIT_SHA=local`nGRAFANA_ADMIN_PASSWORD=$password`n")
    }
    $script:ComposeBase = @('compose', '--project-directory', $Root, '--env-file', $envFile)
    $deployment = Join-Path $Runtime 'deployment.env'
    if (Test-Path -LiteralPath $deployment) { $script:ComposeBase += @('--env-file', $deployment) }
    $script:ComposeBase += @('-f', (Join-Path $Root 'compose.yaml'))
}
function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$DockerArguments)
    & docker @DockerArguments
    if ($LASTEXITCODE -ne 0) { throw "Docker command failed (exit $LASTEXITCODE): docker $($DockerArguments -join ' ')" }
}
function Invoke-Compose {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$ComposeArguments)
    Invoke-Docker @script:ComposeBase @ComposeArguments
}
function Wait-Endpoint {
    param([string]$Url, [int]$Seconds = 90)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Url -TimeoutSec 4 -UseBasicParsing
            if ($response.StatusCode -eq 200) { return }
        } catch { }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Readiness check timed out: $Url"
}
function Assert-Docker {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker Desktop is not installed. Install Docker Desktop with Linux containers, then run START.cmd again.' }
    try { & docker info --format '{{.OSType}}' 2>$null | Out-Null } catch { }
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Starting Docker Desktop. First startup can take a few minutes...' -ForegroundColor Yellow
        $desktop = Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'
        if (-not (Test-Path -LiteralPath $desktop)) { $desktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe' }
        if (Test-Path -LiteralPath $desktop) { Start-Process -FilePath $desktop -WindowStyle Hidden | Out-Null }
        $ready = $false
        for ($attempt=0; $attempt -lt 120; $attempt++) {
            Start-Sleep -Seconds 2
            try { & docker info --format '{{.OSType}}' 2>$null | Out-Null } catch { }
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        }
        if (-not $ready) { throw 'Docker did not become ready. Complete any Docker Desktop / WSL first-run prompt and run START.cmd again.' }
    }
    $osType = & docker info --format '{{.OSType}}'
    if ($osType -ne 'linux') { throw 'Switch Docker Desktop to Linux containers and retry.' }
}
function Test-Monitoring {
    Invoke-Compose config --quiet
    Invoke-Compose run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
    Invoke-Compose run --rm --no-deps --volume "${Root}/monitoring:/work:ro" --workdir /work --entrypoint promtool prometheus test rules /work/rules.test.yml
    Invoke-Compose run --rm --no-deps --entrypoint amtool alertmanager check-config /etc/alertmanager/alertmanager.yml
}
function Start-RegisteredRunner {
    $runnerDirectory = Join-Path $Root 'actions-runner'
    if ($env:OS -ne 'Windows_NT' -or -not (Test-Path (Join-Path $runnerDirectory '.runner'))) { return }
    $listenerPath = Join-Path $runnerDirectory 'bin/Runner.Listener.exe'
    $listeners = @(Get-Process -Name 'Runner.Listener' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $listenerPath })
    if (-not $listeners.Count) {
        Start-Process -FilePath $env:ComSpec -ArgumentList '/c','run.cmd' -WorkingDirectory $runnerDirectory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Runtime 'runner.log') -RedirectStandardError (Join-Path $Runtime 'runner-error.log') | Out-Null
        Write-Host 'Reconnecting your registered GitHub Actions runner in the background.'
    }
}
Initialize-Environment
