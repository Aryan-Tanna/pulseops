param([string]$Repository = '')
. "$PSScriptRoot/common.ps1"
if ($env:OS -ne 'Windows_NT') { throw 'This helper configures the Windows demo laptop.' }
Wait-Endpoint 'http://localhost:9001/health' 5
$headers = @{ 'User-Agent' = 'PulseOps-setup'; 'Accept' = 'application/vnd.github+json' }

function Get-VerifiedAsset {
    param([string]$ApiUrl, [string]$Pattern, [string]$Destination)
    $release = Invoke-RestMethod $ApiUrl -Headers $headers
    $assets = @($release.assets | Where-Object { $_.name -match $Pattern })
    if ($assets.Count -ne 1) { throw 'Could not select one official Windows x64 release asset.' }
    $asset = $assets[0]
    if ($asset.digest -notmatch '^sha256:([a-f0-9]{64})$') { throw 'The official release asset has no SHA256 digest. Do not install an unverified archive.' }
    $expected = $Matches[1]
    Write-Host "Downloading $($asset.name)..." -ForegroundColor Cyan
    Invoke-WebRequest $asset.browser_download_url -OutFile $Destination -UseBasicParsing
    if ((Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Downloaded archive checksum does not match the official digest.' }
}

$ghCommand = Get-Command gh -ErrorAction SilentlyContinue
if ($ghCommand) { $gh = $ghCommand.Source } else {
    $tools = Join-Path $Runtime 'tools'
    New-Item -ItemType Directory -Path $tools -Force | Out-Null
    $found = Get-ChildItem $tools -Recurse -Filter gh.exe | Select-Object -First 1
    if (-not $found) {
        $archive = Join-Path $tools 'gh.zip'
        Get-VerifiedAsset 'https://api.github.com/repos/cli/cli/releases/latest' '^gh_[0-9.]+_windows_amd64.zip$' $archive
        Expand-Archive -LiteralPath $archive -DestinationPath (Join-Path $tools 'github-cli') -Force
        $found = Get-ChildItem (Join-Path $tools 'github-cli') -Recurse -Filter gh.exe | Select-Object -First 1
    }
    if (-not $found) { throw 'GitHub CLI was not found after extraction.' }
    $gh = $found.FullName
}
function Invoke-Gh {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$GhArguments)
    & $gh @GhArguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub operation failed: $($GhArguments[0])" }
}

try { & $gh auth status 2>$null | Out-Null } catch { }
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ONE-TIME ACTION: follow GitHub device sign-in below and approve access in your browser.' -ForegroundColor Yellow
    Invoke-Gh auth login --hostname github.com --git-protocol https --web --scopes workflow
}
Invoke-Gh auth setup-git
$login = (Invoke-Gh api user --jq '.login').Trim()
if (-not $Repository) { $Repository = "$login/pulseops" }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Use owner/repository.' }

Push-Location $Root
try {
    if (-not (Test-Path (Join-Path $Root '.git'))) {
        & git init -b main
        if ($LASTEXITCODE -ne 0) { throw 'Git initialization failed.' }
    }
    $branch = (& git branch --show-current).Trim()
    if ($branch -ne 'main') { throw 'This demo expects the main branch. Select it before connecting.' }
    $existingName = & git config user.name
    if (-not $existingName) { & git config user.name $login }
    $existingEmail = & git config user.email
    if (-not $existingEmail) { & git config user.email "$login@users.noreply.github.com" }
    & git add --all
    if ($LASTEXITCODE -ne 0) { throw 'Could not stage project files.' }
    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 1) {
        & git commit -m 'Build PulseOps application, CI/CD, monitoring and demo console'
        if ($LASTEXITCODE -ne 0) { throw 'Could not commit project files.' }
    }
    $repoInfo = $null
    try { $repoInfo = & $gh repo view $Repository --json visibility,url 2>$null } catch { }
    if ($LASTEXITCODE -ne 0) {
        Invoke-Gh repo create $Repository --private --description 'Local CI/CD and observability lab with Prometheus and Grafana'
    } elseif (($repoInfo | ConvertFrom-Json).visibility -ne 'PRIVATE') {
        throw 'Use a private repository for this laptop runner. No visibility settings were changed.'
    }
    $remote = $null
    try { $remote = & git remote get-url origin 2>$null } catch { }
    if ($LASTEXITCODE -eq 0) {
        if ($remote -notin @("https://github.com/$Repository.git", "https://github.com/$Repository", "git@github.com:$Repository.git")) { throw 'Existing origin points elsewhere. Pass its repository name explicitly.' }
    } else {
        & git remote add origin "https://github.com/$Repository.git"
        if ($LASTEXITCODE -ne 0) { throw 'Could not add repository remote.' }
    }
    & git push -u origin main
    if ($LASTEXITCODE -ne 0) { throw 'Push failed. Existing repository history was not overwritten.' }
} finally { Pop-Location }

$runner = Join-Path $Root 'actions-runner'
New-Item -ItemType Directory -Path $runner -Force | Out-Null
if (-not (Test-Path (Join-Path $runner 'config.cmd'))) {
    $archive = Join-Path $Runtime 'runner.zip'
    Get-VerifiedAsset 'https://api.github.com/repos/actions/runner/releases/latest' '^actions-runner-win-x64-[0-9.]+.zip$' $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $runner -Force
}
if (-not (Test-Path (Join-Path $runner '.runner'))) {
    $registration = Invoke-Gh api --method POST "repos/$Repository/actions/runners/registration-token" | ConvertFrom-Json
    Push-Location $runner
    try {
        & .\config.cmd --unattended --url "https://github.com/$Repository" --token $registration.token --name pulseops-laptop --labels pulseops --work _work
        if ($LASTEXITCODE -ne 0) { throw 'Runner registration failed.' }
    } finally { $registration = $null; Pop-Location }
} else {
    $configuration = Get-Content (Join-Path $runner '.runner') -Raw | ConvertFrom-Json
    if ($configuration.gitHubUrl.TrimEnd('/') -ne "https://github.com/$Repository") { throw 'This runner belongs to a different repository.' }
}

$runners = Invoke-Gh api "repos/$Repository/actions/runners" | ConvertFrom-Json
$online = @($runners.runners | Where-Object { $_.name -eq 'pulseops-laptop' -and $_.status -eq 'online' })
if (-not $online.Count) {
    Start-Process -FilePath $env:ComSpec -ArgumentList '/c','run.cmd' -WorkingDirectory $runner -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Runtime 'runner.log') -RedirectStandardError (Join-Path $Runtime 'runner-error.log') | Out-Null
}
$ready = $false
for ($attempt=0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Seconds 3
    $runners = Invoke-Gh api "repos/$Repository/actions/runners" | ConvertFrom-Json
    if (@($runners.runners | Where-Object { $_.name -eq 'pulseops-laptop' -and $_.status -eq 'online' }).Count) { $ready=$true; break }
}
if (-not $ready) { throw 'Runner is not online. Inspect .runtime/runner.log, then retry this helper.' }
Invoke-Gh variable set PULSEOPS_HOME --repo $Repository --body $Root
Invoke-Gh variable set PULSEOPS_RUNNER_READY --repo $Repository --body true
Invoke-RestMethod 'http://localhost:9001/api/settings' -Method Post -ContentType application/json -Body (@{repository="https://github.com/$Repository"} | ConvertTo-Json) | Out-Null
Invoke-Gh workflow run deploy.yml --repo $Repository --ref main
Write-Host "Connected. Your first real deployment is running: https://github.com/$Repository/actions" -ForegroundColor Green
Write-Host 'After a reboot, START.cmd reconnects the registered runner automatically.'
