#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# One-shot installer for the home media server stack on Linux / macOS.
# (Equivalent of setup.ps1.)
#
# Usage: ./setup.sh [--vpn]
# -----------------------------------------------------------------------------
set -euo pipefail

USE_VPN=0
USE_TELEGRAM=0
USE_RECYCLARR=0
for arg in "$@"; do
    case "$arg" in
        --vpn) USE_VPN=1 ;;
        --telegram) USE_TELEGRAM=1 ;;
        --recyclarr) USE_RECYCLARR=1 ;;
        -h|--help)
            echo "Usage: $0 [--vpn] [--telegram] [--recyclarr]"
            echo "  --vpn        Route qBittorrent through Gluetun (fill VPN_* in .env first)"
            echo "  --telegram   Run Searcharr (fill TELEGRAM_BOT_TOKEN in .env first)"
            echo "  --recyclarr  Apply TRaSH-Guides quality profiles to Sonarr/Radarr"
            exit 0 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

cyan()   { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
green()  { printf "\033[1;32m    %s\033[0m\n" "$*"; }
yellow() { printf "\033[1;33m    %s\033[0m\n" "$*"; }
red()    { printf "\033[1;31m    %s\033[0m\n" "$*"; }

# 1. Docker check ------------------------------------------------------------
cyan "Checking Docker"
if ! command -v docker >/dev/null 2>&1; then
    red "Docker is not installed."
    echo "    macOS:  https://www.docker.com/products/docker-desktop/"
    echo "    Linux:  https://docs.docker.com/engine/install/"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    red "Docker daemon is not running. Start Docker Desktop / dockerd and retry."
    exit 1
fi
green "Docker is running."

# 2. Paths -------------------------------------------------------------------
cyan "Resolving paths"
MEDIA_ROOT="${MEDIA_ROOT:-$SCRIPT_DIR/media}"
DOWNLOADS_ROOT="${DOWNLOADS_ROOT:-$SCRIPT_DIR/downloads}"
CONFIG_ROOT="${CONFIG_ROOT:-$SCRIPT_DIR/config}"
TZ_VALUE="${TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo UTC)}"

mkdir -p "$MEDIA_ROOT"/{movies,tv}
mkdir -p "$DOWNLOADS_ROOT"/{complete,incomplete}
mkdir -p "$CONFIG_ROOT"/{prowlarr,qbittorrent,sonarr,radarr,bazarr,overseerr}
mkdir -p "$CONFIG_ROOT"/searcharr/{data,logs}
mkdir -p "$CONFIG_ROOT"/recyclarr

green "Media:     $MEDIA_ROOT"
green "Downloads: $DOWNLOADS_ROOT"
green "Config:    $CONFIG_ROOT"

# 2b. Pre-flight checks ------------------------------------------------------
cyan "Pre-flight checks"

# --- Disk space ---
# Docker images alone are ~3-4 GB; warn under 20 GB free.
# `df -k -P` is the only `df` invocation supported by both macOS and Linux.
DISK_FREE_KB=$(df -k -P "$CONFIG_ROOT" | awk 'NR==2 {print $4}')
DISK_FREE_GB=$(( DISK_FREE_KB / 1024 / 1024 ))
if [ "$DISK_FREE_GB" -lt 20 ]; then
    red "Only ${DISK_FREE_GB} GB free on $(df -P "$CONFIG_ROOT" | awk 'NR==2{print $6}')."
    red "Need at least 20 GB for images + space for the media library."
    echo "    Free up space or set CONFIG_ROOT/MEDIA_ROOT/DOWNLOADS_ROOT to a larger drive."
    exit 1
fi
green "Disk:      ${DISK_FREE_GB} GB free"

# --- Port conflicts ---
# Detect anything already listening on a port we're about to publish.
check_port() {
    local port="$1" service="$2"
    if command -v lsof >/dev/null 2>&1 && lsof -i ":$port" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
        red "Port $port (needed for $service) is already in use:"
        lsof -i ":$port" -sTCP:LISTEN -n -P | tail -n +1 | head -3 | sed 's/^/        /'
        return 1
    fi
    return 0
}
PORT_CONFLICT=0
# Each port the base stack publishes on the host:
check_port 9696 "Prowlarr"    || PORT_CONFLICT=1
check_port 8080 "qBittorrent" || PORT_CONFLICT=1
check_port 8989 "Sonarr"      || PORT_CONFLICT=1
check_port 7878 "Radarr"      || PORT_CONFLICT=1
check_port 6767 "Bazarr"      || PORT_CONFLICT=1
check_port 5055 "Overseerr"   || PORT_CONFLICT=1
check_port 6881 "qBittorrent (BitTorrent)" || PORT_CONFLICT=1
if [ "$PORT_CONFLICT" = "1" ]; then
    red "Port conflict(s) detected. Stop the conflicting process or change the host"
    red "port in docker-compose.yml, then re-run."
    exit 1
fi
green "Ports:     no conflicts"

# --- PUID/PGID sanity ---
# LSIO images default to 1000:1000. If your shell runs as 0 (root) or a
# high UID (e.g. corporate-managed Mac), file ownership inside the bind
# mounts won't match what the container writes — silent permission issues.
SHELL_UID=$(id -u)
SHELL_GID=$(id -g)
if [ "$SHELL_UID" = "0" ]; then
    yellow "Warning: running as root. Container files will be owned by root on disk."
    yellow "         Consider running as a regular user with PUID 1000."
elif [ "$SHELL_UID" -ne 1000 ] || [ "$SHELL_GID" -ne 1000 ]; then
    yellow "Note: your UID:GID is ${SHELL_UID}:${SHELL_GID} but containers run as 1000:1000."
    yellow "      Files written by the containers will not be owned by your shell user."
    yellow "      If you plan to edit/move files manually outside Docker, override:"
    yellow "        echo 'PUID=${SHELL_UID}' >> .env"
    yellow "        echo 'PGID=${SHELL_GID}' >> .env"
fi
green "User:      UID=${SHELL_UID} GID=${SHELL_GID}"

# 3. .env --------------------------------------------------------------------
cyan "Writing .env"

update_env_var() {
    local key="$1" val="$2" file=".env"
    if grep -q "^${key}=" "$file"; then
        awk -v k="${key}=" -v v="$val" \
            'substr($0,1,length(k))==k{print k v; next} 1' "$file" > "${file}.tmp" \
            && mv "${file}.tmp" "$file"
    else
        printf '\n%s=%s\n' "$key" "$val" >> "$file"
    fi
}

if [ -f .env ]; then
    yellow ".env already exists — preserving existing credentials; updating path/UID fields only."
    update_env_var TZ         "$TZ_VALUE"
    update_env_var PUID       "$(id -u)"
    update_env_var PGID       "$(id -g)"
    update_env_var CONFIG_ROOT    "$CONFIG_ROOT"
    update_env_var DOWNLOADS_ROOT "$DOWNLOADS_ROOT"
    update_env_var MEDIA_ROOT     "$MEDIA_ROOT"
else
    cat > .env <<EOF
# Generated by setup.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')
TZ=$TZ_VALUE
PUID=$(id -u)
PGID=$(id -g)
CONFIG_ROOT=$CONFIG_ROOT
DOWNLOADS_ROOT=$DOWNLOADS_ROOT
MEDIA_ROOT=$MEDIA_ROOT
EOF
fi
green ".env written."

# 4. Pull and start ----------------------------------------------------------
COMPOSE=(docker compose)
if [ "$USE_VPN" = "1" ]; then
    COMPOSE+=(-f docker-compose.yml -f docker-compose.vpn.yml)
    cyan "VPN mode enabled (gluetun + qBittorrent)"
    # Append VPN settings template from .env.example if absent.
    if ! grep -q '^VPN_SERVICE_PROVIDER=' .env; then
        awk '/# VPN settings \(optional\)/,/^$/' .env.example >> .env || true
        echo "" >> .env
    fi
    if ! grep -qE '^VPN_SERVICE_PROVIDER=\S' .env; then
        red "VPN_SERVICE_PROVIDER is empty in .env."
        echo "    Edit .env and fill in your provider credentials, then re-run:"
        echo "      ./setup.sh --vpn"
        echo "    See .env.example for Mullvad / ProtonVPN / NordVPN examples."
        exit 1
    fi
fi

if [ "$USE_TELEGRAM" = "1" ]; then
    cyan "Telegram bot mode enabled (Searcharr)"
    # Append Telegram settings template from .env.example if absent.
    if ! grep -q '^TELEGRAM_BOT_TOKEN=' .env; then
        awk '/# Telegram bot \(optional\)/,/^TELEGRAM_ADMIN_PASSWORD=/' .env.example >> .env || true
        echo "" >> .env
    fi
    # shellcheck source=/dev/null
    set -a; . ./.env; set +a
    if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
        red "TELEGRAM_BOT_TOKEN is empty in .env."
        echo "    1. Open Telegram, message @BotFather, send /newbot, follow prompts."
        echo "    2. Copy the bot token (e.g. 1234567890:AAA-...) into .env:"
        echo "         TELEGRAM_BOT_TOKEN=<paste here>"
        echo "    3. Re-run: ./setup.sh --telegram"
        exit 1
    fi
    # Searcharr is brought up *after* settings.py is generated below.
fi

cyan "Pulling images"
# Heads-up before a potentially slow 10-min download:
pull_extras=""
[ "$USE_VPN" = "1" ]       && pull_extras="$pull_extras + Gluetun"
[ "$USE_TELEGRAM" = "1" ]  && pull_extras="$pull_extras + Searcharr"
[ "$USE_RECYCLARR" = "1" ] && pull_extras="$pull_extras + Recyclarr"
yellow "Initial pull is ~4 GB (Prowlarr + qBit + Sonarr + Radarr + Bazarr + Overseerr${pull_extras})."
yellow "On a typical 50 Mbps connection this takes 10-15 minutes."
yellow "Subsequent re-runs only pull what's changed (usually nothing)."
echo ""
# --quiet hides the per-layer progress that scrolls past too fast to read.
"${COMPOSE[@]}" pull --quiet
cyan "Starting containers"
"${COMPOSE[@]}" up -d

# 5. Wait for services -------------------------------------------------------
wait_for_url() {
    local name="$1" url="$2" deadline=$(( $(date +%s) + 90 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -fsS --max-time 3 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null \
            | grep -qE '^[1-4][0-9][0-9]$'; then
            green "$name ready at $url"; return 0
        fi
        sleep 1
    done
    yellow "$name did not respond within timeout (may still be initialising)."
    return 1
}

cyan "Waiting for services to come up"
wait_for_url "Prowlarr"    "http://localhost:9696" || true
wait_for_url "qBittorrent" "http://localhost:8080" || true
wait_for_url "Sonarr"      "http://localhost:8989" || true
wait_for_url "Radarr"      "http://localhost:7878" || true
wait_for_url "Bazarr"      "http://localhost:6767" || true
wait_for_url "Overseerr"   "http://localhost:5055" || true

# 6. Extract credentials & API keys -----------------------------------------
sleep 5
qbt_pass="$(docker logs qbittorrent 2>&1 | grep -oE 'temporary password[^:]*:[[:space:]]*[^[:space:]]+' \
    | tail -n1 | awk -F: '{print $NF}' | tr -d ' ')"

extract_arr_key() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -oE '<ApiKey>[^<]+</ApiKey>' "$file" | head -n1 | sed -E 's|</?ApiKey>||g'
}

sonarr_key="$(extract_arr_key  "$CONFIG_ROOT/sonarr/config.xml")"
radarr_key="$(extract_arr_key  "$CONFIG_ROOT/radarr/config.xml")"
prowlarr_key="$(extract_arr_key "$CONFIG_ROOT/prowlarr/config.xml")"

# 6b. Telegram bot — generate settings.py and start Searcharr ----------------
if [ "$USE_TELEGRAM" = "1" ]; then
    cyan "Configuring Searcharr"
    if [ -z "$sonarr_key" ] || [ -z "$radarr_key" ]; then
        red "Cannot configure Searcharr: Sonarr/Radarr API keys not found yet."
        echo "    Give the services another minute to initialise, then re-run with --telegram."
    else
        searcharr_settings="$CONFIG_ROOT/searcharr/data/settings.py"
        if [ -f "$searcharr_settings" ]; then
            yellow "Searcharr settings.py already exists — preserving passwords."
            existing_pw=$(grep -E '^searcharr_password' "$searcharr_settings" | sed -E 's/.*"([^"]*)".*/\1/')
            existing_admin_pw=$(grep -E '^searcharr_admin_password' "$searcharr_settings" | sed -E 's/.*"([^"]*)".*/\1/')
            tg_pw="$existing_pw"
            tg_admin_pw="$existing_admin_pw"
        else
            tg_pw="${TELEGRAM_BOT_PASSWORD:-$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-16 || head -c 16 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)}"
            tg_admin_pw="${TELEGRAM_ADMIN_PASSWORD:-$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-16 || head -c 16 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)}"
        fi
        sed -e "s|__SEARCHARR_PASSWORD__|$tg_pw|" \
            -e "s|__SEARCHARR_ADMIN_PASSWORD__|$tg_admin_pw|" \
            -e "s|__TGRAM_TOKEN__|$TELEGRAM_BOT_TOKEN|" \
            -e "s|__SONARR_API_KEY__|$sonarr_key|" \
            -e "s|__RADARR_API_KEY__|$radarr_key|" \
            searcharr-settings.template.py > "$searcharr_settings"
        chmod 600 "$searcharr_settings"
        green "Wrote $searcharr_settings"
        cyan "Starting Searcharr"
        docker compose -f docker-compose.yml \
            $([ "$USE_VPN" = "1" ] && echo "-f docker-compose.vpn.yml") \
            -f docker-compose.telegram.yml up -d searcharr
    fi
fi

# 6c. Recyclarr — generate config and start container -----------------------
if [ "$USE_RECYCLARR" = "1" ]; then
    cyan "Configuring Recyclarr"
    if [ -z "$sonarr_key" ] || [ -z "$radarr_key" ]; then
        red "Cannot configure Recyclarr: Sonarr/Radarr API keys not found yet."
        echo "    Give the services another minute to initialise, then re-run with --recyclarr."
    else
        recyclarr_root="$CONFIG_ROOT/recyclarr"
        mkdir -p "$recyclarr_root/configs"

        # Generate the v8-format starter configs via Recyclarr itself, so the
        # format is always whatever the installed version expects (no
        # external template to maintain or chase upstream changes for).
        # Recyclarr v8 reads every .yml in configs/ automatically.
        for template in web-1080p hd-bluray-web; do
            if [ ! -f "$recyclarr_root/configs/${template}.yml" ]; then
                cyan "  Generating starter config for '${template}'"
                docker run --rm \
                    --user "$(id -u):$(id -g)" \
                    -v "$recyclarr_root":/config \
                    ghcr.io/recyclarr/recyclarr:latest \
                    config create --template "$template" >/dev/null 2>&1 || \
                    yellow "    template '${template}' not generated; check 'recyclarr config list templates'"
            fi
        done

        # Patch base_url and api_key. Re-runs are safe: only these two fields
        # are touched; user edits everywhere else are preserved.
        for cfg in "$recyclarr_root"/configs/*.yml; do
            [ -f "$cfg" ] || continue
            python3 - "$cfg" "$sonarr_key" "$radarr_key" <<'PY'
import re, sys
path, sk, rk = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as fh: content = fh.read()
out, current = [], None
for line in content.splitlines(True):
    stripped = line.lstrip()
    if   re.match(r'sonarr:\s*$', stripped): current = 'sonarr'
    elif re.match(r'radarr:\s*$', stripped): current = 'radarr'
    if re.match(r'\s*base_url:\s*', line):
        url = 'http://sonarr:8989' if current == 'sonarr' else ('http://radarr:7878' if current == 'radarr' else None)
        if url:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}base_url: {url}\n"); continue
    if re.match(r'\s*api_key:\s*', line):
        key = sk if current == 'sonarr' else (rk if current == 'radarr' else None)
        if key:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}api_key: {key}\n"); continue
    out.append(line)
with open(path, 'w') as fh: fh.write(''.join(out))
PY
            chmod 600 "$cfg"
            green "  Patched $(basename "$cfg")"
        done

        cyan "Starting Recyclarr (will run a first sync immediately, then daily at 04:00)"
        compose_args="-f docker-compose.yml"
        [ "$USE_VPN" = "1" ]      && compose_args="$compose_args -f docker-compose.vpn.yml"
        [ "$USE_TELEGRAM" = "1" ] && compose_args="$compose_args -f docker-compose.telegram.yml"
        compose_args="$compose_args -f docker-compose.recyclarr.yml"
        docker compose $compose_args up -d recyclarr

        cyan "Running initial TRaSH-Guides sync (this can take ~30 s)"
        if docker exec recyclarr recyclarr sync 2>&1 | tail -20 | sed 's/^/    /'; then
            green "Initial sync complete. Check Sonarr → Settings → Profiles and Radarr → Settings → Profiles."
        else
            yellow "Initial sync exited non-zero. Check 'docker logs recyclarr' for details."
        fi
    fi
fi

# 7. Summary -----------------------------------------------------------------
yellow "⚠  API keys and passwords follow. Copy them to a password manager, then"
yellow "   clear your terminal history:  history -c  (bash) or  Clear-History  (PowerShell)."
yellow "   Do not share this terminal output."
cat <<EOF

============================================================
 Media server is up. Open these in your browser:
============================================================

  Prowlarr     http://localhost:9696
  qBittorrent  http://localhost:8080
  Sonarr       http://localhost:8989
  Radarr       http://localhost:7878
  Bazarr       http://localhost:6767
  Overseerr    http://localhost:5055

Credentials & API keys
----------------------
EOF
if [ -n "$qbt_pass" ]; then
    echo "  qBittorrent  user: admin"
    echo "  qBittorrent  pass: $qbt_pass   <-- change this on first login!"
else
    yellow "Could not find qBittorrent temp password. Run:"
    echo   "      docker logs qbittorrent | grep -i 'temporary password'"
fi
[ -n "$prowlarr_key" ] && echo "  Prowlarr API key: $prowlarr_key"
[ -n "$sonarr_key"   ] && echo "  Sonarr   API key: $sonarr_key"
[ -n "$radarr_key"   ] && echo "  Radarr   API key: $radarr_key"
if [ "$USE_TELEGRAM" = "1" ] && [ -n "${tg_pw:-}" ]; then
    echo ""
    echo "  Telegram bot password:        $tg_pw"
    echo "  Telegram bot admin password:  $tg_admin_pw"
    echo "  Authenticate by messaging your bot:  /start $tg_pw"
fi

cat <<'EOF'

Paths inside containers (use these in Sonarr/Radarr/qBittorrent UI):
  qBittorrent complete dir   /downloads/complete
  qBittorrent incomplete dir /downloads/incomplete
  Sonarr TV root folder      /tv
  Radarr Movies root folder  /movies

Next steps: see README.md, section "Wire the services together".

EOF

if [ "$USE_VPN" = "1" ]; then
    yellow "VPN is active. Important wiring difference:"
    echo   "    In Sonarr/Radarr -> Download Clients -> qBittorrent, set the"
    echo   "    Host field to 'gluetun' (NOT 'qbittorrent'). qBit shares the"
    echo   "    gluetun container's network and is only reachable via that name."
    echo   "    Verify your public IP with:"
    echo   "      docker exec gluetun wget -qO- https://ifconfig.me"
    echo   ""
fi

if [ "$USE_TELEGRAM" = "1" ]; then
    yellow "Telegram bot is active."
    echo   "    1. Open Telegram and find your bot (search for the name you gave @BotFather)."
    echo   "    2. Send: /start <password shown above>"
    echo   "    3. Then try: /movie inception   or   /series severance"
    echo   "    Logs: docker logs searcharr"
    echo   ""
fi

if [ "$USE_RECYCLARR" = "1" ]; then
    yellow "Recyclarr is active. TRaSH-Guides quality profiles applied to Sonarr and Radarr."
    echo   "    Re-sync schedule:  daily at 04:00"
    echo   "    Force sync now:    docker exec recyclarr recyclarr sync"
    echo   "    Edit configs:      $CONFIG_ROOT/recyclarr/configs/"
    echo   "    Logs:              docker logs recyclarr"
    echo   ""
fi
