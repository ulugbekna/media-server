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

.PARAMETER MediaRoot
    Folder for your library (movies/ and tv/ are created inside it).
    Example: D:\media

.PARAMETER DownloadsRoot
    Folder for torrent downloads. Example: D:\downloads

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

.EXAMPLE
    .\setup.ps1
    Uses default paths under the current directory.

.EXAMPLE
    .\setup.ps1 -MediaRoot D:\media -DownloadsRoot D:\downloads

.EXAMPLE
    .\setup.ps1 -Vpn
    Same as above but routes qBittorrent through the VPN.

.EXAMPLE
    .\setup.ps1 -Vpn -Telegram
    Full stack: VPN + Telegram request bot.
#>

[CmdletBinding()]
param(
    [string]$MediaRoot,
    [string]$DownloadsRoot,
    [string]$ConfigRoot,
    [string]$Timezone,
    [switch]$Vpn,
    [switch]$Telegram
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

if (-not $MediaRoot)     { $MediaRoot     = Join-Path $PSScriptRoot "media" }
if (-not $DownloadsRoot) { $DownloadsRoot = Join-Path $PSScriptRoot "downloads" }
if (-not $ConfigRoot)    { $ConfigRoot    = Join-Path $PSScriptRoot "config" }
if (-not $Timezone)      { $Timezone      = (Get-TimeZone).Id }

# Docker on Windows accepts forward slashes; normalise for the .env file.
function ConvertTo-DockerPath($p) {
    return ($p -replace '\\', '/')
}

$MediaRootDocker     = ConvertTo-DockerPath (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $MediaRoot)).Path
$DownloadsRootDocker = ConvertTo-DockerPath (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $DownloadsRoot)).Path
$ConfigRootDocker    = ConvertTo-DockerPath (Resolve-Path -LiteralPath (New-Item -ItemType Directory -Force -Path $ConfigRoot)).Path

Write-OK "Media:     $MediaRootDocker"
Write-OK "Downloads: $DownloadsRootDocker"
Write-OK "Config:    $ConfigRootDocker"

# -----------------------------------------------------------------------------
# 3. Create folder layout
# -----------------------------------------------------------------------------
Write-Step "Creating folder layout"

$folders = @(
    "$MediaRoot\movies",
    "$MediaRoot\tv",
    "$DownloadsRoot\complete",
    "$DownloadsRoot\incomplete",
    "$ConfigRoot\prowlarr",
    "$ConfigRoot\qbittorrent",
    "$ConfigRoot\sonarr",
    "$ConfigRoot\radarr",
    "$ConfigRoot\bazarr",
    "$ConfigRoot\overseerr",
    "$ConfigRoot\searcharr\data",
    "$ConfigRoot\searcharr\logs"
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
    Write-Host  "    Free up space or point CONFIG_ROOT/MEDIA_ROOT/DOWNLOADS_ROOT to a larger drive."
    exit 1
}
Write-OK "Disk:      $freeGb GB free on $($drive.Name):"

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
    $envContent = Update-EnvVar $envContent "TZ"            $Timezone
    $envContent = Update-EnvVar $envContent "PUID"          "1000"
    $envContent = Update-EnvVar $envContent "PGID"          "1000"
    $envContent = Update-EnvVar $envContent "CONFIG_ROOT"    $ConfigRootDocker
    $envContent = Update-EnvVar $envContent "DOWNLOADS_ROOT" $DownloadsRootDocker
    $envContent = Update-EnvVar $envContent "MEDIA_ROOT"     $MediaRootDocker
    [System.IO.File]::WriteAllText($envPath, $envContent, [System.Text.UTF8Encoding]::new($false))
} else {
    $envBody = @"
# Generated by setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
TZ=$Timezone
PUID=1000
PGID=1000
CONFIG_ROOT=$ConfigRootDocker
DOWNLOADS_ROOT=$DownloadsRootDocker
MEDIA_ROOT=$MediaRootDocker
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
Write-Step "Pulling images (first run can take a few minutes)"
& docker @composeArgs pull
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
Write-Host "  qBittorrent complete dir   /downloads/complete"
Write-Host "  qBittorrent incomplete dir /downloads/incomplete"
Write-Host "  Sonarr TV root folder      /tv"
Write-Host "  Radarr Movies root folder  /movies"
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
Write-Host ""
Write-Host "Next steps: see README.md, section 'Wire the services together'." -ForegroundColor Magenta
Write-Host ""
