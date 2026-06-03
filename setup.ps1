<#
.SYNOPSIS
    One-shot installer for the home media server stack on Windows.

.DESCRIPTION
    - Verifies Docker Desktop is installed and running.
    - Creates media, downloads, and config folders.
    - Generates .env from .env.example if missing (with Windows-friendly paths).
    - Pulls images and starts the stack with `docker compose up -d`.
    - Waits for qBittorrent to print its first-run password, extracts it, and
      displays it together with all service URLs and API keys.

.PARAMETER DataRoot
    Single parent folder for ALL downloads and media — required for
    Sonarr/Radarr hardlinking. Layout (created automatically):
        DataRoot\torrents\complete\
        DataRoot\torrents\incomplete\
        DataRoot\media\tv\
        DataRoot\media\movies\
    Example: D:\media-data

.PARAMETER ConfigRoot
    Folder for service configs (state, databases, settings).
    Example: D:\media-server\config

.PARAMETER Vpn
    Route qBittorrent through a Gluetun VPN container. Requires VPN_*
    values to be set in .env (see .env.example for examples).

.PARAMETER Telegram
    Run the Searcharr Telegram bot so you can request movies/shows from
    your phone. Requires TELEGRAM_BOT_TOKEN to be set in .env (get a
    token from @BotFather; see README "Telegram requests").

.PARAMETER Recyclarr
    Apply the TRaSH-Guides quality profiles, custom formats, and naming
    schemes to Sonarr and Radarr. Runs immediately and then daily at 04:00.

.PARAMETER Proxy
    Run a Caddy reverse proxy in front of every web UI. Lets you reach the
    services as https://sonarr.miniserver.local etc. over a single SSH
    tunnel (port 443) instead of memorising six port numbers.

.EXAMPLE
    .\setup.ps1
    Uses default paths under the current directory.

.EXAMPLE
    .\setup.ps1 -DataRoot D:\media-data -ConfigRoot D:\media-server\config

.EXAMPLE
    .\setup.ps1 -Vpn
    Same as above but routes qBittorrent through the VPN.

.EXAMPLE
    .\setup.ps1 -Vpn -Telegram -Recyclarr -Proxy
    Full kit: VPN, Telegram, TRaSH profiles, HTTPS reverse proxy.
#>

[CmdletBinding()]
param(
    [string]$DataRoot,
    [string]$ConfigRoot,
    [string]$Timezone,
    [switch]$Vpn,
    [switch]$Telegram,
    [switch]$Recyclarr,
    [switch]$Proxy
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step($msg)    { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-OK($msg)      { Write-Host "    $msg" -ForegroundColor Green }
function Write-WarnMsg($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Write-ErrMsg($msg)  { Write-Host "    $msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 1. Prerequisites
# -----------------------------------------------------------------------------
Write-Step "Checking Docker Desktop"

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-ErrMsg "Docker is not installed."
    Write-Host ""
    Write-Host "Install Docker Desktop for Windows, then re-run this script:"
    Write-Host "  https://www.docker.com/products/docker-desktop/"
    Write-Host ""
    Write-Host "Or with winget:  winget install Docker.DockerDesktop"
    exit 1
}

try {
    docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "daemon not reachable" }
    Write-OK "Docker is running."
} catch {
    Write-ErrMsg "Docker Desktop is installed but not running."
    Write-Host "    Start Docker Desktop and wait for the whale icon to settle, then re-run."
    exit 1
}

# -----------------------------------------------------------------------------
# 2. Resolve paths
# -----------------------------------------------------------------------------
Write-Step "Resolving paths"

if (-not $DataRoot)   { $DataRoot   = Join-Path $PSScriptRoot "data" }
if (-not $ConfigRoot) { $ConfigRoot = Join-Path $PSScriptRoot "config" }
if (-not $Timezone)   { $Timezone   = (Get-TimeZone).Id }

# Docker on Windows accepts forward slashes; normalise for the .env file.
function ConvertTo-DockerPath($p) {
    return ($p -replace '\\', '/')
}

$DataRootDocker   = ConvertTo-DockerPath (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $DataRoot)).Path
$ConfigRootDocker = ConvertTo-DockerPath (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $ConfigRoot)).Path

Write-OK "Data:      $DataRootDocker"
Write-OK "Config:    $ConfigRootDocker"

# -----------------------------------------------------------------------------
# 3. Create folder layout
# -----------------------------------------------------------------------------
Write-Step "Creating folder layout"

$folders = @(
    # Single-root data layout — see docker-compose.yml header for why.
    "$DataRoot\torrents\complete",
    "$DataRoot\torrents\incomplete",
    "$DataRoot\media\tv",
    "$DataRoot\media\movies",
    "$ConfigRoot\prowlarr",
    "$ConfigRoot\qbittorrent",
    "$ConfigRoot\sonarr",
    "$ConfigRoot\radarr",
    "$ConfigRoot\bazarr",
    "$ConfigRoot\overseerr",
    "$ConfigRoot\searcharr\data",
    "$ConfigRoot\searcharr\logs",
    "$ConfigRoot\recyclarr",
    "$ConfigRoot\caddy\data",
    "$ConfigRoot\caddy\config"
)
foreach ($f in $folders) {
    if (-not (Test-Path -LiteralPath $f)) {
        New-Item -ItemType Directory -Force -Path $f | Out-Null
        Write-OK "created $f"
    }
}

# -----------------------------------------------------------------------------
# 3b. Pre-flight checks
# -----------------------------------------------------------------------------
Write-Step "Pre-flight checks"

# --- Disk space ---
$drive = (Get-Item -LiteralPath $ConfigRoot).PSDrive
$freeGb = [Math]::Floor($drive.Free / 1GB)
if ($freeGb -lt 20) {
    Write-ErrMsg "Only $freeGb GB free on drive $($drive.Name):. Need at least 20 GB."
    Write-Host  "    Free up space or point CONFIG_ROOT/DATA_ROOT to a larger drive."
    exit 1
}
Write-OK "Disk:      $freeGb GB free on $($drive.Name):"

# --- Same-filesystem (drive) check for hardlink correctness ---
# Sonarr/Radarr hardlink completed downloads from /data/torrents/... to
# /data/media/... — that only works if both sub-paths live on the same
# host drive (single Linux mount inside the container).
$torrentsDrive = (Get-Item -LiteralPath (Join-Path $DataRoot "torrents")).PSDrive.Name
$mediaDrive    = (Get-Item -LiteralPath (Join-Path $DataRoot "media")).PSDrive.Name
if ($torrentsDrive -ne $mediaDrive) {
    Write-ErrMsg "DATA_ROOT\torrents and DATA_ROOT\media are on DIFFERENT drives:"
    Write-ErrMsg "    torrents: ${torrentsDrive}:"
    Write-ErrMsg "    media:    ${mediaDrive}:"
    Write-ErrMsg "Sonarr/Radarr will fall back to copies (2x disk usage)."
    Write-ErrMsg "Move both under a single drive and re-run."
    exit 1
}
Write-OK "Hardlinks: torrents and media share one drive (${torrentsDrive}:)"

# --- Port conflicts ---
$portConflict = $false
$portsToCheck = @(
    @{ port = 9696; service = "Prowlarr" },
    @{ port = 8080; service = "qBittorrent" },
    @{ port = 8989; service = "Sonarr" },
    @{ port = 7878; service = "Radarr" },
    @{ port = 6767; service = "Bazarr" },
    @{ port = 5055; service = "Overseerr" },
    @{ port = 6881; service = "qBittorrent (BitTorrent)" }
)
if ($Proxy) {
    $portsToCheck += @{ port = 443; service = "Caddy (reverse proxy HTTPS)" }
}
foreach ($p in $portsToCheck) {
    $listener = Get-NetTCPConnection -LocalPort $p.port -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $owningPid = $listener[0].OwningProcess
        $proc = (Get-Process -Id $owningPid -ErrorAction SilentlyContinue).ProcessName
        Write-ErrMsg "Port $($p.port) (needed for $($p.service)) is already in use by $proc (PID $owningPid)."
        $portConflict = $true
    }
}
if ($portConflict) {
    Write-ErrMsg "Stop the conflicting process or change the host port in docker-compose.yml,"
    Write-ErrMsg "then re-run."
    exit 1
}
Write-OK "Ports:     no conflicts"

# --- Sleep / power warning (Windows-specific gotcha) ---
$sleepTimeoutAC = (powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Select-String "Current AC Power Setting Index" | ForEach-Object { [Convert]::ToInt32($_.Line.Trim().Split(":")[1].Trim(), 16) })
if ($sleepTimeoutAC -and $sleepTimeoutAC -ne 0) {
    Write-WarnMsg "System will sleep after $($sleepTimeoutAC/60) min on AC power."
    Write-WarnMsg "For a closeted media server, disable sleep:"
    Write-Host    "    powercfg /change standby-timeout-ac 0"
}

# -----------------------------------------------------------------------------
# 4. Generate .env
# -----------------------------------------------------------------------------
Write-Step "Writing .env"

$envPath = Join-Path $PSScriptRoot ".env"

function Update-EnvVar([string]$content, [string]$key, [string]$value) {
    if ($content -match "(?m)^${key}=") {
        return $content -replace "(?m)^${key}=.*$", "${key}=${value}"
    } else {
        return $content.TrimEnd() + "`n${key}=${value}`n"
    }
}

if (Test-Path -LiteralPath $envPath) {
    Write-WarnMsg ".env already exists — preserving existing credentials; updating path/UID fields only."
    $envContent = Get-Content -LiteralPath $envPath -Raw
    $envContent = Update-EnvVar $envContent "TZ"          $Timezone
    $envContent = Update-EnvVar $envContent "PUID"        "1000"
    $envContent = Update-EnvVar $envContent "PGID"        "1000"
    $envContent = Update-EnvVar $envContent "CONFIG_ROOT" $ConfigRootDocker
    $envContent = Update-EnvVar $envContent "DATA_ROOT"   $DataRootDocker
    [System.IO.File]::WriteAllText($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
} else {
    $envBody = @"
# Generated by setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
TZ=$Timezone
PUID=1000
PGID=1000
CONFIG_ROOT=$ConfigRootDocker
DATA_ROOT=$DataRootDocker
"@
    # Use WriteAllText to guarantee BOM-less UTF-8 on both PS 5.1 and PS 7+.
    [System.IO.File]::WriteAllText($envPath, $envBody, [System.Text.UTF8Encoding]::new($false))
}
Write-OK ".env written."

# -----------------------------------------------------------------------------
# 4b. VPN preflight
# -----------------------------------------------------------------------------
$composeArgs = @("compose")
if ($Vpn) {
    $composeArgs += @("-f", "docker-compose.yml", "-f", "docker-compose.vpn.yml")
    Write-Step "VPN mode enabled (gluetun + qBittorrent)"

    $envExample = Get-Content -LiteralPath (Join-Path $PSScriptRoot ".env.example") -Raw
    $vpnBlock   = ($envExample -split "# VPN settings \(optional\)")[1]
    if ($vpnBlock) {
        Add-Content -LiteralPath $envPath -Value "`n# VPN settings (optional)$vpnBlock"
    }

    if (-not $env:VPN_SERVICE_PROVIDER) {
        $envContent = Get-Content -LiteralPath $envPath -Raw
        if ($envContent -notmatch '(?m)^VPN_SERVICE_PROVIDER=\S') {
            Write-WarnMsg "VPN_SERVICE_PROVIDER is empty in .env."
            Write-Host    "    Edit .env and fill in your provider credentials, then re-run:"
            Write-Host    "      .\setup.ps1 -Vpn"
            Write-Host    "    See .env.example for Mullvad / ProtonVPN / NordVPN examples."
            exit 1
        }
    }
}

# -----------------------------------------------------------------------------
# 4c. Telegram preflight (Searcharr is brought up after settings.py generation)
# -----------------------------------------------------------------------------
$telegramBotToken = $null
if ($Telegram) {
    Write-Step "Telegram bot mode enabled (Searcharr)"

    $envContent = Get-Content -LiteralPath $envPath -Raw
    if ($envContent -notmatch '(?m)^TELEGRAM_BOT_TOKEN=') {
        $envExample = Get-Content -LiteralPath (Join-Path $PSScriptRoot ".env.example") -Raw
        $tgBlock    = ($envExample -split "# Telegram bot \(optional\)")[1]
        if ($tgBlock) {
            Add-Content -LiteralPath $envPath -Value "`n# Telegram bot (optional)$tgBlock"
        }
        $envContent = Get-Content -LiteralPath $envPath -Raw
    }

    $tokenMatch = [regex]::Match($envContent, '(?m)^TELEGRAM_BOT_TOKEN=(.+)$')
    if ($tokenMatch.Success -and $tokenMatch.Groups[1].Value.Trim()) {
        $telegramBotToken = $tokenMatch.Groups[1].Value.Trim()
    } else {
        Write-WarnMsg "TELEGRAM_BOT_TOKEN is empty in .env."
        Write-Host    "    1. Open Telegram, message @BotFather, send /newbot, follow prompts."
        Write-Host    "    2. Copy the bot token (e.g. 1234567890:AAA-...) into .env:"
        Write-Host    "         TELEGRAM_BOT_TOKEN=<paste here>"
        Write-Host    "    3. Re-run: .\setup.ps1 -Telegram"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# 5. Start the stack
# -----------------------------------------------------------------------------
Write-Step "Pulling images"
$pullExtras = @()
if ($Vpn)       { $pullExtras += "Gluetun" }
if ($Telegram)  { $pullExtras += "Searcharr" }
if ($Recyclarr) { $pullExtras += "Recyclarr" }
if ($Proxy)     { $pullExtras += "Caddy" }
$extraText = if ($pullExtras.Count -gt 0) { " + " + ($pullExtras -join " + ") } else { "" }
Write-WarnMsg "Initial pull is ~4 GB (Prowlarr + qBit + Sonarr + Radarr + Bazarr + Overseerr$extraText)."
Write-WarnMsg "On a typical 50 Mbps connection this takes 10-15 minutes."
Write-WarnMsg "Subsequent re-runs only pull what's changed (usually nothing)."
Write-Host ""
& docker @composeArgs pull --quiet
if ($LASTEXITCODE -ne 0) { Write-ErrMsg "docker compose pull failed."; exit 1 }

Write-Step "Starting containers"
& docker @composeArgs up -d
if ($LASTEXITCODE -ne 0) { Write-ErrMsg "docker compose up failed."; exit 1 }

# -----------------------------------------------------------------------------
# 6. Wait for services to be reachable
# -----------------------------------------------------------------------------
function Wait-ForUrl($name, $url, $timeoutSec = 90) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3 -MaximumRedirection 5
            if ($r.StatusCode -lt 500) { return $true }
        } catch { Start-Sleep -Milliseconds 750 }
    }
    return $false
}

Write-Step "Waiting for services to come up"
$services = @(
    @{ name = "Prowlarr";    url = "http://localhost:9696" },
    @{ name = "qBittorrent"; url = "http://localhost:8080" },
    @{ name = "Sonarr";      url = "http://localhost:8989" },
    @{ name = "Radarr";      url = "http://localhost:7878" },
    @{ name = "Bazarr";      url = "http://localhost:6767" },
    @{ name = "Overseerr";   url = "http://localhost:5055" }
)
foreach ($s in $services) {
    if (Wait-ForUrl $s.name $s.url) {
        Write-OK "$($s.name) ready at $($s.url)"
    } else {
        Write-WarnMsg "$($s.name) did not respond within timeout (it may still be initialising)."
    }
}

# -----------------------------------------------------------------------------
# 7. Retrieve qBittorrent temp password and API keys
# -----------------------------------------------------------------------------
function Get-QbtTempPassword {
    $logs = docker logs qbittorrent 2>&1 | Out-String
    $m = [regex]::Match($logs, "temporary password.*?:\s*([^\s]+)")
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ArrApiKey($configFile) {
    if (-not (Test-Path -LiteralPath $configFile)) { return $null }
    try {
        [xml]$cfg = Get-Content -LiteralPath $configFile -Raw
        return $cfg.Config.ApiKey
    } catch { return $null }
}

# Give Sonarr/Radarr/Prowlarr a few extra seconds to write their config files.
Start-Sleep -Seconds 5

$qbtPass     = Get-QbtTempPassword
$sonarrKey   = Get-ArrApiKey  (Join-Path $ConfigRoot "sonarr\config.xml")
$radarrKey   = Get-ArrApiKey  (Join-Path $ConfigRoot "radarr\config.xml")
$prowlarrKey = Get-ArrApiKey  (Join-Path $ConfigRoot "prowlarr\config.xml")

# -----------------------------------------------------------------------------
# 7b. Telegram bot — generate Searcharr settings.py and start the container
# -----------------------------------------------------------------------------
$telegramBotPassword      = $null
$telegramAdminBotPassword = $null
if ($Telegram) {
    Write-Step "Configuring Searcharr"
    if (-not $sonarrKey -or -not $radarrKey) {
        Write-ErrMsg "Cannot configure Searcharr: Sonarr/Radarr API keys not found yet."
        Write-Host  "    Give the services another minute to initialise, then re-run with -Telegram."
    } else {
        $searcharrSettings = Join-Path $ConfigRoot "searcharr\data\settings.py"
        $envContent = Get-Content -LiteralPath $envPath -Raw
        $envPwMatch    = [regex]::Match($envContent, '(?m)^TELEGRAM_BOT_PASSWORD=(.*)$')
        $envAdminMatch = [regex]::Match($envContent, '(?m)^TELEGRAM_ADMIN_PASSWORD=(.*)$')

        function New-RandomPassword {
            $bytes = New-Object byte[] 16
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            $b64 = [Convert]::ToBase64String($bytes) -replace '[/+=]', ''
            return $b64.Substring(0, [Math]::Min(16, $b64.Length))
        }

        if (Test-Path -LiteralPath $searcharrSettings) {
            Write-WarnMsg "Searcharr settings.py already exists — preserving passwords."
            $existing = Get-Content -LiteralPath $searcharrSettings -Raw
            $pm = [regex]::Match($existing, '(?m)^searcharr_password\s*=\s*"([^"]*)"')
            $am = [regex]::Match($existing, '(?m)^searcharr_admin_password\s*=\s*"([^"]*)"')
            $telegramBotPassword      = if ($pm.Success) { $pm.Groups[1].Value } else { New-RandomPassword }
            $telegramAdminBotPassword = if ($am.Success) { $am.Groups[1].Value } else { New-RandomPassword }
        } else {
            $telegramBotPassword      = if ($envPwMatch.Success    -and $envPwMatch.Groups[1].Value.Trim())    { $envPwMatch.Groups[1].Value.Trim() }    else { New-RandomPassword }
            $telegramAdminBotPassword = if ($envAdminMatch.Success -and $envAdminMatch.Groups[1].Value.Trim()) { $envAdminMatch.Groups[1].Value.Trim() } else { New-RandomPassword }
        }

        $template = Get-Content -LiteralPath (Join-Path $PSScriptRoot "searcharr-settings.template.py") -Raw
        # Use literal string Replace (not -replace) so passwords/tokens with $ or \ aren't interpreted as regex.
        $rendered = $template.
            Replace('__SEARCHARR_PASSWORD__',       $telegramBotPassword).
            Replace('__SEARCHARR_ADMIN_PASSWORD__', $telegramAdminBotPassword).
            Replace('__TGRAM_TOKEN__',              $telegramBotToken).
            Replace('__SONARR_API_KEY__',           $sonarrKey).
            Replace('__RADARR_API_KEY__',           $radarrKey)
        [System.IO.File]::WriteAllText($searcharrSettings, $rendered, [System.Text.UTF8Encoding]::new($false))
        Write-OK "Wrote $searcharrSettings"

        Write-Step "Starting Searcharr"
        $tgArgs = @("compose", "-f", "docker-compose.yml")
        if ($Vpn) { $tgArgs += @("-f", "docker-compose.vpn.yml") }
        $tgArgs += @("-f", "docker-compose.telegram.yml", "up", "-d", "searcharr")
        & docker @tgArgs
    }
}

# -----------------------------------------------------------------------------
# 7c. Recyclarr — render config and start container
# -----------------------------------------------------------------------------
if ($Recyclarr) {
    Write-Step "Configuring Recyclarr"
    if (-not $sonarrKey -or -not $radarrKey) {
        Write-ErrMsg "Cannot configure Recyclarr: Sonarr/Radarr API keys not found yet."
        Write-Host  "    Give the services another minute to initialise, then re-run with -Recyclarr."
    } else {
        $recyclarrRoot = Join-Path $ConfigRoot "recyclarr"
        $recyclarrConfigs = Join-Path $recyclarrRoot "configs"
        if (-not (Test-Path -LiteralPath $recyclarrConfigs)) {
            New-Item -ItemType Directory -Force -Path $recyclarrConfigs | Out-Null
        }

        # Generate v8-format starter configs via Recyclarr itself, so the
        # format always matches the installed version.
        $rcRootDocker = $recyclarrRoot -replace '\\','/'
        foreach ($template in @("web-1080p", "hd-bluray-web")) {
            $cfgFile = Join-Path $recyclarrConfigs "$template.yml"
            if (-not (Test-Path -LiteralPath $cfgFile)) {
                Write-Step "  Generating starter config for '$template'"
                docker run --rm `
                    -v "${rcRootDocker}:/config" `
                    ghcr.io/recyclarr/recyclarr:latest `
                    config create --template $template *>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-WarnMsg "    template '$template' not generated"
                }
            }
        }

        # Patch base_url and api_key in every generated config.
        Get-ChildItem -LiteralPath $recyclarrConfigs -Filter *.yml | ForEach-Object {
            $lines = Get-Content -LiteralPath $_.FullName
            $current = $null
            $out = New-Object System.Collections.Generic.List[string]
            foreach ($line in $lines) {
                $stripped = $line.TrimStart()
                if     ($stripped -match '^sonarr:\s*$') { $current = 'sonarr' }
                elseif ($stripped -match '^radarr:\s*$') { $current = 'radarr' }
                if ($line -match '^(\s*)base_url:\s*') {
                    $indent = $matches[1]
                    $url = if ($current -eq 'sonarr') { 'http://sonarr:8989' } elseif ($current -eq 'radarr') { 'http://radarr:7878' } else { $null }
                    if ($url) { $out.Add("${indent}base_url: $url"); continue }
                }
                if ($line -match '^(\s*)api_key:\s*') {
                    $indent = $matches[1]
                    $key = if ($current -eq 'sonarr') { $sonarrKey } elseif ($current -eq 'radarr') { $radarrKey } else { $null }
                    if ($key) { $out.Add("${indent}api_key: $key"); continue }
                }
                $out.Add($line)
            }
            [System.IO.File]::WriteAllLines($_.FullName, $out)
            Write-OK "  Patched $($_.Name)"
        }

        Write-Step "Starting Recyclarr (first sync immediately, then daily at 04:00)"
        $rcArgs = @("compose", "-f", "docker-compose.yml")
        if ($Vpn)      { $rcArgs += @("-f", "docker-compose.vpn.yml") }
        if ($Telegram) { $rcArgs += @("-f", "docker-compose.telegram.yml") }
        $rcArgs += @("-f", "docker-compose.recyclarr.yml", "up", "-d", "recyclarr")
        & docker @rcArgs

        Write-Step "Running initial TRaSH-Guides sync (this can take ~30 s)"
        docker exec recyclarr recyclarr sync 2>&1 | Select-Object -Last 20 | ForEach-Object { Write-Host "    $_" }
        if ($LASTEXITCODE -eq 0) {
            Write-OK "Initial sync complete. Check Sonarr -> Settings -> Profiles."
        } else {
            Write-WarnMsg "Initial sync exited non-zero. See 'docker logs recyclarr'."
        }
    }
}

# -----------------------------------------------------------------------------
# 7d. Caddy reverse proxy — copy Caddyfile and start container
# -----------------------------------------------------------------------------
if ($Proxy) {
    Write-Step "Configuring Caddy reverse proxy"
    $caddyFile = Join-Path $ConfigRoot "caddy\Caddyfile"
    if (-not (Test-Path -LiteralPath $caddyFile)) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "caddy\Caddyfile.template") -Destination $caddyFile
        Write-OK "Copied Caddyfile template to $caddyFile"
    } else {
        Write-WarnMsg "Caddyfile already exists — preserving your edits."
    }
    # Adjust qBittorrent upstream when VPN is active.
    if ($Vpn) {
        $content = Get-Content -LiteralPath $caddyFile -Raw
        if ($content -match 'reverse_proxy qbittorrent:8080') {
            $content = $content -replace 'reverse_proxy qbittorrent:8080', 'reverse_proxy gluetun:8080'
            [System.IO.File]::WriteAllText($caddyFile, $content, [System.Text.UTF8Encoding]::new($false))
            Write-OK "VPN mode: pointed qBittorrent reverse_proxy at gluetun:8080"
        }
    }

    Write-Step "Starting Caddy"
    $proxyArgs = @("compose", "-f", "docker-compose.yml")
    if ($Vpn)       { $proxyArgs += @("-f", "docker-compose.vpn.yml") }
    if ($Telegram)  { $proxyArgs += @("-f", "docker-compose.telegram.yml") }
    if ($Recyclarr) { $proxyArgs += @("-f", "docker-compose.recyclarr.yml") }
    $proxyArgs += @("-f", "docker-compose.proxy.yml", "up", "-d", "caddy")
    & docker @proxyArgs

    Start-Sleep -Seconds 4
    Write-Step "Caddy is up. Internal root CA cert (import into your Mac keychain to silence browser warnings):"
    $certPath = "/data/caddy/pki/authorities/local/root.crt"
    docker exec caddy test -f $certPath 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-OK "    docker cp caddy:$certPath ./caddy-root.crt"
        Write-OK "    On your Mac:"
        Write-OK "      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt"
    } else {
        Write-WarnMsg "Caddy's root cert not generated yet — give it another 30 s then check $($certPath.Substring(1))."
    }
}

# -----------------------------------------------------------------------------
# 8. Summary
# -----------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " Media server is up. Open these in your browser:" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  Prowlarr     http://localhost:9696"
Write-Host "  qBittorrent  http://localhost:8080"
Write-Host "  Sonarr       http://localhost:8989"
Write-Host "  Radarr       http://localhost:7878"
Write-Host "  Bazarr       http://localhost:6767"
Write-Host "  Overseerr    http://localhost:5055"
Write-Host ""

Write-Host "Credentials & API keys" -ForegroundColor Magenta
Write-Host "----------------------"
Write-Host ""
Write-Host "  *** Copy these values to a password manager, then clear your terminal:" -ForegroundColor Yellow
Write-Host "  ***   Clear-History" -ForegroundColor Yellow
Write-Host "  *** Do not share this terminal output." -ForegroundColor Yellow
Write-Host ""
if ($qbtPass) {
    Write-Host "  qBittorrent  user: admin"
    Write-Host "  qBittorrent  pass: $qbtPass   <-- change this on first login!"
} else {
    Write-WarnMsg "Could not find qBittorrent temp password. Run:"
    Write-Host    "      docker logs qbittorrent | findstr /i ""temporary password"""
}
if ($prowlarrKey) { Write-Host "  Prowlarr API key: $prowlarrKey" }
if ($sonarrKey)   { Write-Host "  Sonarr   API key: $sonarrKey" }
if ($radarrKey)   { Write-Host "  Radarr   API key: $radarrKey" }
if ($Telegram -and $telegramBotPassword) {
    Write-Host ""
    Write-Host "  Telegram bot password:        $telegramBotPassword"
    Write-Host "  Telegram bot admin password:  $telegramAdminBotPassword"
    Write-Host "  Authenticate by messaging your bot:  /start $telegramBotPassword"
}
Write-Host ""

Write-Host "Paths inside containers (use these in Sonarr/Radarr/qBittorrent UI):" -ForegroundColor Magenta
Write-Host "  qBittorrent complete dir   /data/torrents/complete"
Write-Host "  qBittorrent incomplete dir /data/torrents/incomplete"
Write-Host "  Sonarr TV root folder      /data/media/tv"
Write-Host "  Radarr Movies root folder  /data/media/movies"
Write-Host ""
Write-Host "These all live under the SAME /data mount inside every container —" -ForegroundColor Magenta
Write-Host "that's what makes hardlinking (instant import, 1x disk usage) work."
if ($Vpn) {
    Write-Host ""
    Write-Host "VPN is active. Important wiring difference:" -ForegroundColor Yellow
    Write-Host "  In Sonarr/Radarr -> Download Clients -> qBittorrent, set the"
    Write-Host "  Host field to 'gluetun' (NOT 'qbittorrent'). qBit shares the"
    Write-Host "  gluetun container's network and is only reachable via that name."
    Write-Host "  Check your public IP with:  docker exec gluetun wget -qO- https://ifconfig.me"
}
if ($Telegram) {
    Write-Host ""
    Write-Host "Telegram bot is active." -ForegroundColor Yellow
    Write-Host "  1. Open Telegram and find your bot (search the name you gave @BotFather)."
    Write-Host "  2. Send:   /start <password shown above>"
    Write-Host "  3. Try:    /movie inception   or   /series severance"
    Write-Host "  Logs:      docker logs searcharr"
}
if ($Recyclarr) {
    Write-Host ""
    Write-Host "Recyclarr is active. TRaSH-Guides quality profiles applied to Sonarr and Radarr." -ForegroundColor Yellow
    Write-Host "  Re-sync schedule: daily at 04:00"
    Write-Host "  Force sync now:   docker exec recyclarr recyclarr sync"
    Write-Host "  Edit configs:     $ConfigRoot\recyclarr\configs\"
    Write-Host "  Logs:             docker logs recyclarr"
}
if ($Proxy) {
    $suffix = if ($env:CADDY_DOMAIN_SUFFIX) { $env:CADDY_DOMAIN_SUFFIX } else { 'miniserver.local' }
    Write-Host ""
    Write-Host "Caddy reverse proxy is active. Friendly HTTPS hostnames:" -ForegroundColor Yellow
    Write-Host "  https://sonarr.$suffix     -> Sonarr"
    Write-Host "  https://radarr.$suffix     -> Radarr"
    Write-Host "  https://prowlarr.$suffix   -> Prowlarr"
    Write-Host "  https://qbittorrent.$suffix -> qBittorrent"
    Write-Host "  https://bazarr.$suffix     -> Bazarr"
    Write-Host "  https://overseerr.$suffix  -> Overseerr"
    Write-Host ""
    Write-Host "  Setup steps on your Mac (one-time):"
    Write-Host "    1. Add the hostnames to /etc/hosts so they resolve to 127.0.0.1."
    Write-Host "    2. SSH-tunnel port 443 from your Mac: ssh -L 443:localhost:443 miniserver"
    Write-Host "    3. Import Caddy's root CA so the browser stops warning."
    Write-Host "    See README 'Reverse proxy (Caddy)' for the exact commands."
}
Write-Host ""
Write-Host "Next steps: see README.md, section 'Wire the services together'." -ForegroundColor Magenta
Write-Host ""
