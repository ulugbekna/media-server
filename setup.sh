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
USE_PROXY=0
# Bootstrap: auto-configure qBittorrent + Prowlarr Apps + Sonarr/Radarr download
# client/root folder via REST APIs. Default: AUTO (run only on fresh installs
# where config/sonarr/config.xml is freshly written, so we don't disturb a
# stack you've already hand-tweaked).
BOOTSTRAP=auto
for arg in "$@"; do
    case "$arg" in
        --vpn) USE_VPN=1 ;;
        --telegram) USE_TELEGRAM=1 ;;
        --recyclarr) USE_RECYCLARR=1 ;;
        --proxy) USE_PROXY=1 ;;
        --bootstrap)    BOOTSTRAP=force ;;
        --no-bootstrap) BOOTSTRAP=skip ;;
        -h|--help)
            echo "Usage: $0 [--vpn] [--telegram] [--recyclarr] [--proxy] [--bootstrap|--no-bootstrap]"
            echo "  --vpn          Route qBittorrent through Gluetun (fill VPN_* in .env first)"
            echo "  --telegram     Run Searcharr (fill TELEGRAM_BOT_TOKEN in .env first)"
            echo "  --recyclarr    Apply TRaSH-Guides quality profiles to Sonarr/Radarr"
            echo "  --proxy        Run Caddy as a reverse proxy for all web UIs over HTTPS"
            echo "  --bootstrap    Force REST-API config of qBit/Prowlarr/Sonarr/Radarr (default: only on fresh install)"
            echo "  --no-bootstrap Skip REST-API config even on fresh install (leave everything for the web UIs)"
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
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR/data}"
CONFIG_ROOT="${CONFIG_ROOT:-$SCRIPT_DIR/config}"
TZ_VALUE="${TZ:-$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo UTC)}"

# Single-root data layout — see docker-compose.yml header for the rationale
# (Sonarr/Radarr hardlinks across torrents/ -> media/ require one mount).
mkdir -p "$DATA_ROOT"/torrents/{complete,incomplete}
mkdir -p "$DATA_ROOT"/media/{tv,movies}
mkdir -p "$CONFIG_ROOT"/{prowlarr,qbittorrent,sonarr,radarr,bazarr,overseerr}
mkdir -p "$CONFIG_ROOT"/searcharr/{data,logs}
mkdir -p "$CONFIG_ROOT"/disk-guard
mkdir -p "$CONFIG_ROOT"/recyclarr
mkdir -p "$CONFIG_ROOT"/caddy/{data,config}

green "Data:      $DATA_ROOT"
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
    echo "    Free up space or set CONFIG_ROOT/DATA_ROOT to a larger drive."
    exit 1
fi
green "Disk:      ${DISK_FREE_GB} GB free"

# --- Same-filesystem check for hardlink correctness ---
# Sonarr/Radarr hardlink completed downloads from /data/torrents/... to
# /data/media/... — that only works if both live on the same mount point.
# Catch this early instead of silently letting users degrade to 2×-space copies.
torrents_dev=$(df -P "$DATA_ROOT/torrents" 2>/dev/null | awk 'NR==2 {print $1}')
media_dev=$(df -P "$DATA_ROOT/media"    2>/dev/null | awk 'NR==2 {print $1}')
if [ -n "$torrents_dev" ] && [ -n "$media_dev" ] && [ "$torrents_dev" != "$media_dev" ]; then
    red "DATA_ROOT/torrents and DATA_ROOT/media are on DIFFERENT filesystems:"
    red "    torrents: $torrents_dev"
    red "    media:    $media_dev"
    red "Sonarr/Radarr will fall back to copies (2× disk usage). Move both"
    red "under a single mount point and re-run."
    exit 1
fi
green "Hardlinks: torrents and media share one filesystem ($torrents_dev)"

# --- Port conflicts ---
# Detect anything already listening on a port we're about to publish — but
# ignore ports already held by *our* stack (running container), so re-runs
# with new flags don't trip on themselves.
check_port() {
    local port="$1" service="$2"
    # -iTCP:<port> + -sTCP:LISTEN restricts to TCP listeners only (LSOF will
    # otherwise list UDP traffic matching the port, e.g. MS Teams on 443).
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$port" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
        # If Docker is the one holding it AND a container of ours is publishing
        # exactly this port, treat it as "ours" — re-run with a new flag should
        # not abort.
        local owner_cmd
        owner_cmd=$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2 {print $1}')
        if [ "$owner_cmd" = "com.docke" ] || [ "$owner_cmd" = "docker-pr" ] || [ "$owner_cmd" = "dockerd" ]; then
            local ours
            ours=$(docker ps --format '{{.Ports}}' 2>/dev/null \
                   | grep -E "(^|,)[^,]*:${port}->" || true)
            if [ -n "$ours" ]; then
                green "Port $port: already held by a running container in this stack (re-run safe)"
                return 0
            fi
        fi
        red "Port $port (needed for $service) is already in use:"
        lsof -iTCP:"$port" -sTCP:LISTEN -n -P | tail -n +1 | head -3 | sed 's/^/        /'
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
if [ "$USE_PROXY" = "1" ]; then
    check_port 443 "Caddy (reverse proxy HTTPS)" || PORT_CONFLICT=1
fi
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
    update_env_var TZ          "$TZ_VALUE"
    update_env_var PUID        "$(id -u)"
    update_env_var PGID        "$(id -g)"
    update_env_var CONFIG_ROOT "$CONFIG_ROOT"
    update_env_var DATA_ROOT   "$DATA_ROOT"
else
    cat > .env <<EOF
# Generated by setup.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')
TZ=$TZ_VALUE
PUID=$(id -u)
PGID=$(id -g)
CONFIG_ROOT=$CONFIG_ROOT
DATA_ROOT=$DATA_ROOT
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
[ "$USE_PROXY" = "1" ]     && pull_extras="$pull_extras + Caddy"
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

# 6a. Bootstrap — REST-API auto-config so step 4 of README is mostly already done
# ----------------------------------------------------------------------------
# Eliminates ~15 minutes of UI clicking after first boot:
#   - qBittorrent: change temp password to a stable one, set categories,
#                  whitelist trusted subnets (loopback / Docker / LAN) so
#                  the brute-force ban can never lock us out from inside
#                  (paths already set via WEBUI_PORT env; nothing to do there)
#   - Prowlarr:    register Sonarr + Radarr as Apps (so Prowlarr auto-syncs
#                  indexers into them — eliminates the manual "Apps → Add"
#                  step in README 4b)
#   - Sonarr & Radarr: add qBittorrent as download client, add root folder
#                      under /data/media/, enable hardlinks without a duplicate
#                      import free-space check, and wire Plex Connect so every
#                      import triggers an immediate Plex library scan
#                      (eliminates README 4c steps 2, 3, and 5).
# Idempotent: each step GETs first and skips if already configured.
# Honest scope: we DO NOT add indexers (you pick), DO NOT touch Bazarr
# (provider creds are your account), DO NOT touch Overseerr (Plex OAuth
# requires a browser).

run_bootstrap=0
case "$BOOTSTRAP" in
    force) run_bootstrap=1 ;;
    skip)  run_bootstrap=0 ;;
    auto)
        # "fresh install" heuristic: Sonarr's config.xml was just written
        # in the last 5 minutes (since the API key extraction we just did
        # implies Sonarr only just booted, an existing Sonarr install will
        # have a much older config.xml mtime).
        if [ -f "$CONFIG_ROOT/sonarr/config.xml" ]; then
            cfg_age=$(( $(date +%s) - $(stat -f %m "$CONFIG_ROOT/sonarr/config.xml" 2>/dev/null \
                                       || stat -c %Y "$CONFIG_ROOT/sonarr/config.xml") ))
            [ "$cfg_age" -lt 300 ] && run_bootstrap=1
        fi
        ;;
esac

# Variables set by bootstrap and read later in the summary output.
qbit_new_pw=""

if [ "$run_bootstrap" = "1" ]; then
    cyan "Bootstrap: auto-configuring qBittorrent, Prowlarr, Sonarr, Radarr via REST API"
    if [ -z "$sonarr_key" ] || [ -z "$radarr_key" ] || [ -z "$prowlarr_key" ]; then
        yellow "Skipping bootstrap: not all API keys are available yet."
        yellow "Re-run with --bootstrap once Sonarr/Radarr/Prowlarr have finished initialising."
    else
        # --- 6a.1 qBittorrent ----------------------------------------------
        # Extract temp pw from logs (same as the summary step further down).
        qbit_temp_pw=$(docker logs qbittorrent 2>&1 \
            | grep -oE 'temporary password[^:]*:[[:space:]]*[^[:space:]]+' \
            | tail -n1 | awk -F: '{print $NF}' | tr -d ' ' || true)

        # Strong random password unless user supplied one in .env.
        qbit_new_pw="${QBIT_ADMIN_PASSWORD:-}"
        if [ -z "$qbit_new_pw" ]; then
            qbit_new_pw=$(openssl rand -base64 24 2>/dev/null \
                          | tr -d '/+=' | cut -c1-20 \
                          || head -c 32 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)
        fi

        if [ -n "$qbit_temp_pw" ]; then
            # Login with temp pw, save cookie jar.
            qbit_jar=$(mktemp)
            if curl -fsS -c "$qbit_jar" -o /dev/null \
                --data-urlencode "username=admin" \
                --data-urlencode "password=$qbit_temp_pw" \
                http://localhost:8080/api/v2/auth/login 2>/dev/null; then
                # qBit's setPreferences takes 'json=<encoded>'. Build payload
                # with python so embedded quotes don't break.
                qbit_payload=$(python3 - <<PY
import json
print('json=' + json.dumps({
  "save_path": "/data/torrents/complete",
  "temp_path": "/data/torrents/incomplete",
  "temp_path_enabled": True,
  "web_ui_password": "$qbit_new_pw",
  # Auth-bypass for trusted subnets so containers (172.16/12), the
  # host loopback, and other LAN clients never get tarred by qBit's
  # brute-force ban. Without this, a few failed logins (e.g. from a
  # forgotten password) lock OUT every client on those subnets —
  # including the Docker network Sonarr/Radarr talk to qBit through.
  # Bans still apply to anyone outside these ranges.
  "bypass_auth_subnet_whitelist_enabled": True,
  "bypass_auth_subnet_whitelist": "127.0.0.1/32,172.16.0.0/12,192.168.0.0/16,10.0.0.0/8",
}))
PY
)
                if curl -fsS -b "$qbit_jar" -o /dev/null \
                    --data "$qbit_payload" \
                    http://localhost:8080/api/v2/app/setPreferences 2>/dev/null; then
                    green "  qBittorrent: paths set, admin password rotated, LAN/Docker subnets auth-bypassed (lockout-proof)"
                else
                    yellow "  qBittorrent: setPreferences failed (config will be defaulted)"
                    qbit_new_pw=""
                fi

                # Re-login with new password to create categories.
                qbit_jar2=$(mktemp)
                if curl -fsS -c "$qbit_jar2" -o /dev/null \
                    --data-urlencode "username=admin" \
                    --data-urlencode "password=$qbit_new_pw" \
                    http://localhost:8080/api/v2/auth/login 2>/dev/null; then
                    for cat in tv movies; do
                        curl -fsS -b "$qbit_jar2" -o /dev/null \
                            --data-urlencode "category=$cat" \
                            --data-urlencode "savePath=/data/torrents/complete/$cat" \
                            http://localhost:8080/api/v2/torrents/createCategory 2>/dev/null \
                            && green "  qBittorrent: category '$cat' added" \
                            || yellow "  qBittorrent: category '$cat' add failed (probably already exists)"
                    done
                    rm -f "$qbit_jar2"
                fi
            else
                yellow "  qBittorrent: API login failed; leaving config alone."
                qbit_new_pw=""
            fi
            rm -f "$qbit_jar"
        else
            yellow "  qBittorrent: no temp password in logs yet; skipping API config."
        fi

        # --- 6a.2 Prowlarr → register Sonarr & Radarr as Apps ----------------
        # GET current applications; only POST what's missing.
        existing_apps=$(curl -fsS -H "X-Api-Key: $prowlarr_key" \
            http://localhost:9696/api/v1/applications 2>/dev/null \
            | python3 -c "import sys,json; print(' '.join(a['name'] for a in json.load(sys.stdin)))" \
            2>/dev/null || echo "")

        add_prowlarr_app() {
            local name="$1" impl="$2" base_url="$3" api_key="$4" cats="$5" extra_field="$6"
            if echo " $existing_apps " | grep -q " $name "; then
                green "  Prowlarr: $name already registered"; return
            fi
            local payload
            payload=$(python3 - <<PY
import json
fields = [
  {"name":"prowlarrUrl", "value":"http://prowlarr:9696"},
  {"name":"baseUrl",     "value":"$base_url"},
  {"name":"apiKey",      "value":"$api_key"},
  {"name":"syncCategories", "value": $cats},
]
$extra_field
print(json.dumps({
  "syncLevel":"fullSync",
  "name":"$name",
  "implementation":"$impl",
  "implementationName":"$impl",
  "configContract":"${impl}Settings",
  "fields": fields,
  "tags": []
}))
PY
)
            if curl -fsS -o /dev/null -X POST \
                -H "X-Api-Key: $prowlarr_key" -H "Content-Type: application/json" \
                --data "$payload" \
                http://localhost:9696/api/v1/applications 2>/dev/null; then
                green "  Prowlarr: registered $name (auto-sync indexers now active)"
            else
                yellow "  Prowlarr: failed to register $name"
            fi
        }
        add_prowlarr_app Sonarr Sonarr "http://sonarr:8989" "$sonarr_key" \
            "[5000,5010,5020,5030,5040,5045,5050,5090]" \
            'fields += [{"name":"animeSyncCategories","value":[5070]},{"name":"syncAnimeStandardFormatSearch","value":True}]'
        add_prowlarr_app Radarr Radarr "http://radarr:7878" "$radarr_key" \
            "[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080,2090]" \
            ''

        # --- 6a.3 Sonarr & Radarr: download client + root folder -------------
        # Host is "gluetun" when VPN is on (qBit lives in gluetun's namespace),
        # "qbittorrent" otherwise.
        qbit_host="qbittorrent"
        [ "$USE_VPN" = "1" ] && qbit_host="gluetun"

        add_arr_dc() {
            local app="$1" key="$2" port="$3" category="$4"
            # Check if a qBittorrent download client already exists.
            local existing
            existing=$(curl -fsS -H "X-Api-Key: $key" "http://localhost:$port/api/v3/downloadclient" 2>/dev/null \
                | python3 -c "import sys,json; print(' '.join(d['implementation'] for d in json.load(sys.stdin)))" \
                2>/dev/null || echo "")
            if echo " $existing " | grep -q " QBittorrent "; then
                green "  $app: qBittorrent download client already configured"; return
            fi
            local payload
            payload=$(python3 - <<PY
import json
print(json.dumps({
  "enable": True, "protocol": "torrent", "priority": 1,
  "removeCompletedDownloads": True, "removeFailedDownloads": True,
  "name": "qBittorrent",
  "implementation": "QBittorrent", "implementationName": "qBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name":"host","value":"$qbit_host"},
    {"name":"port","value":8080},
    {"name":"useSsl","value":False},
    {"name":"username","value":"admin"},
    {"name":"password","value":"$qbit_new_pw"},
    {"name":"tvCategory" if "$app"=="Sonarr" else "movieCategory","value":"$category"},
    {"name":"initialState","value":0},
    {"name":"contentLayout","value":2}
  ],
  "tags": []
}))
PY
)
            if curl -fsS -o /dev/null -X POST \
                -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                --data "$payload" \
                "http://localhost:$port/api/v3/downloadclient" 2>/dev/null; then
                green "  $app: qBittorrent download client added (host=$qbit_host, category=$category)"
            else
                yellow "  $app: failed to add qBittorrent download client"
            fi
        }

        add_arr_root() {
            local app="$1" key="$2" port="$3" path="$4"
            local existing
            existing=$(curl -fsS -H "X-Api-Key: $key" "http://localhost:$port/api/v3/rootfolder" 2>/dev/null \
                | python3 -c "import sys,json; print(' '.join(r['path'] for r in json.load(sys.stdin)))" \
                2>/dev/null || echo "")
            if echo " $existing " | grep -q " $path "; then
                green "  $app: root folder $path already configured"; return
            fi
            if curl -fsS -o /dev/null -X POST \
                -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                --data "{\"path\":\"$path\"}" \
                "http://localhost:$port/api/v3/rootfolder" 2>/dev/null; then
                green "  $app: root folder $path added"
            else
                yellow "  $app: failed to add root folder $path"
            fi
        }

        if [ -n "$qbit_new_pw" ]; then
            add_arr_dc Sonarr "$sonarr_key" 8989 tv
            add_arr_dc Radarr "$radarr_key" 7878 movies
        else
            yellow "  Skipping Sonarr/Radarr download client (qBit password not known)."
        fi
        add_arr_root Sonarr "$sonarr_key" 8989 "/data/media/tv"
        add_arr_root Radarr "$radarr_key" 7878 "/data/media/movies"

        # qBittorrent has already allocated completed downloads on /data. The
        # Arr default precheck otherwise demands the full file size a second
        # time before it attempts the hardlink, blocking valid low-space
        # imports. This is safe because preflight requires torrents and media
        # to share one filesystem.
        configure_arr_hardlink_imports() {
            local app="$1" key="$2" port="$3"
            local config payload config_id
            if ! config=$(curl -fsS -H "X-Api-Key: $key" \
                "http://localhost:$port/api/v3/config/mediamanagement" 2>/dev/null); then
                yellow "  $app: failed to read media-management config"
                return
            fi
            if ! payload=$(printf '%s' "$config" | python3 -c \
                'import json,sys; c=json.load(sys.stdin); c["copyUsingHardlinks"]=True; c["skipFreeSpaceCheckWhenImporting"]=True; print(json.dumps(c))'); then
                yellow "  $app: failed to prepare hardlink import config"
                return
            fi
            config_id=$(printf '%s' "$config" | python3 -c \
                'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)
            if [ -z "$config_id" ]; then
                yellow "  $app: media-management config has no id"
                return
            fi
            if curl -fsS -o /dev/null -X PUT \
                -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                --data "$payload" \
                "http://localhost:$port/api/v3/config/mediamanagement/$config_id" 2>/dev/null; then
                green "  $app: hardlinks enabled; duplicate import free-space check disabled"
            else
                yellow "  $app: failed to configure hardlink import policy"
            fi
        }
        configure_arr_hardlink_imports Sonarr "$sonarr_key" 8989
        configure_arr_hardlink_imports Radarr "$radarr_key" 7878

        # --- 6a.4 Sonarr & Radarr: Plex auto-scan notifier -------------------
        # Wires Sonarr/Radarr → Plex Connect so every import triggers a Plex
        # library scan immediately (no waiting 1h for Plex's own discovery,
        # no manual "Scan Library Files" click). Idempotent — skipped if a
        # PlexServer notifier is already present, or if Plex isn't reachable
        # on this host, or if no token can be located. Plex stores its token
        # in different spots per OS, hence the path probe.
        get_plex_token() {
            local prefs candidates=(
                "$HOME/Library/Application Support/Plex Media Server/Preferences.xml"  # macOS
                "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"  # Linux native
                "$HOME/.config/Plex Media Server/Preferences.xml"  # some Linux distros
            )
            for prefs in "${candidates[@]}"; do
                if [ -r "$prefs" ]; then
                    grep -oE 'PlexOnlineToken="[^"]+"' "$prefs" 2>/dev/null \
                        | head -n1 | sed -E 's/.*"([^"]+)"/\1/' \
                        && return 0
                fi
            done
            return 1
        }

        plex_reachable() {
            curl -fsS --max-time 3 -o /dev/null http://127.0.0.1:32400/identity 2>/dev/null
        }

        add_arr_plex() {
            local app="$1" key="$2" port="$3" token="$4"
            local existing
            existing=$(curl -fsS -H "X-Api-Key: $key" "http://localhost:$port/api/v3/notification" 2>/dev/null \
                | python3 -c "import sys,json; print(' '.join(n['implementation'] for n in json.load(sys.stdin)))" \
                2>/dev/null || echo "")
            if echo " $existing " | grep -q " PlexServer "; then
                green "  $app: Plex notifier already configured"; return
            fi
            local payload
            payload=$(python3 - <<PY
import json
p = {
  "name": "Plex",
  "implementation": "PlexServer",
  "implementationName": "Plex Media Server",
  "configContract": "PlexServerSettings",
  "onDownload": True, "onUpgrade": True, "onRename": True,
  "fields": [
    {"name":"host", "value":"host.docker.internal"},
    {"name":"port", "value":32400},
    {"name":"useSsl", "value":False},
    {"name":"authToken", "value":"$token"},
    {"name":"updateLibrary", "value":True},
  ],
  "tags": []
}
if "$app" == "Sonarr":
    p["onImportComplete"] = True
    p["onEpisodeFileDeleteForUpgrade"] = True
else:
    p["onMovieFileDeleteForUpgrade"] = True
print(json.dumps(p))
PY
)
            if curl -fsS -o /dev/null -X POST \
                -H "X-Api-Key: $key" -H "Content-Type: application/json" \
                --data "$payload" \
                "http://localhost:$port/api/v3/notification" 2>/dev/null; then
                green "  $app: Plex notifier added (auto-scan on import)"
            else
                yellow "  $app: failed to add Plex notifier"
            fi
        }

        plex_token=$(get_plex_token || true)
        if [ -z "$plex_token" ]; then
            yellow "  Plex notifier skipped: no Plex token found in Preferences.xml"
            yellow "    (open Plex once, sign in with your Plex account, then re-run --bootstrap)"
        elif ! plex_reachable; then
            yellow "  Plex notifier skipped: Plex Media Server not reachable on 127.0.0.1:32400"
        else
            add_arr_plex Sonarr "$sonarr_key" 8989 "$plex_token"
            add_arr_plex Radarr "$radarr_key" 7878 "$plex_token"
        fi

        green "Bootstrap complete."
    fi
elif [ "$BOOTSTRAP" = "skip" ]; then
    yellow "Bootstrap skipped (--no-bootstrap). Configure qBit/Prowlarr/Sonarr/Radarr via their web UIs."
fi

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
        cyan "Starting Searcharr and disk guard"
        docker compose -f docker-compose.yml \
            $([ "$USE_VPN" = "1" ] && echo "-f docker-compose.vpn.yml") \
            -f docker-compose.telegram.yml up -d searcharr disk-guard
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

# 6d. Caddy reverse proxy — copy Caddyfile and start container --------------
if [ "$USE_PROXY" = "1" ]; then
    cyan "Configuring Caddy reverse proxy"
    caddy_file="$CONFIG_ROOT/caddy/Caddyfile"
    if [ ! -f "$caddy_file" ]; then
        cp caddy/Caddyfile.template "$caddy_file"
        green "Copied Caddyfile template to $caddy_file"
    else
        yellow "Caddyfile already exists — preserving your edits."
    fi
    # Adjust qBittorrent upstream if VPN is enabled (qBit lives in gluetun ns).
    if [ "$USE_VPN" = "1" ] && grep -q '^  reverse_proxy qbittorrent:8080' "$caddy_file"; then
        python3 -c "
import re
p='$caddy_file'
with open(p) as f: c=f.read()
c=c.replace('reverse_proxy qbittorrent:8080', 'reverse_proxy gluetun:8080')
with open(p,'w') as f: f.write(c)
"
        green "VPN mode: pointed qBittorrent reverse_proxy at gluetun:8080"
    fi

    cyan "Starting Caddy"
    proxy_args="-f docker-compose.yml"
    [ "$USE_VPN" = "1" ]       && proxy_args="$proxy_args -f docker-compose.vpn.yml"
    [ "$USE_TELEGRAM" = "1" ]  && proxy_args="$proxy_args -f docker-compose.telegram.yml"
    [ "$USE_RECYCLARR" = "1" ] && proxy_args="$proxy_args -f docker-compose.recyclarr.yml"
    proxy_args="$proxy_args -f docker-compose.proxy.yml"
    docker compose $proxy_args up -d caddy

    # Give Caddy a moment to provision its internal CA.
    sleep 4
    cyan "Caddy is up. Internal root CA cert (import into Mac keychain to silence browser warnings):"
    cert_path_in_container="/data/caddy/pki/authorities/local/root.crt"
    if docker exec caddy test -f "$cert_path_in_container"; then
        green "    docker cp caddy:$cert_path_in_container ./caddy-root.crt"
        green "    On your Mac:"
        green "      sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt"
    else
        yellow "Caddy's root cert not generated yet — give it another 30 s then check ${cert_path_in_container#/}."
    fi
fi
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
if [ -n "$qbit_new_pw" ]; then
    echo "  qBittorrent  user: admin"
    echo "  qBittorrent  pass: $qbit_new_pw   (set by bootstrap — stable across restarts)"
elif [ -n "$qbt_pass" ]; then
    echo "  qBittorrent  user: admin"
    echo "  qBittorrent  pass: $qbt_pass   <-- TEMP only! Change on first login or a new one is generated next restart."
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
  qBittorrent complete dir   /data/torrents/complete
  qBittorrent incomplete dir /data/torrents/incomplete
  Sonarr TV root folder      /data/media/tv
  Radarr Movies root folder  /data/media/movies

These all live under the SAME /data mount inside every container — that's
what makes hardlinking (instant import, 1× disk usage) work.

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

if [ "$USE_PROXY" = "1" ]; then
    suffix="${CADDY_DOMAIN_SUFFIX:-miniserver.local}"
    yellow "Caddy reverse proxy is active. Friendly HTTPS hostnames:"
    echo   "    https://sonarr.$suffix     -> Sonarr"
    echo   "    https://radarr.$suffix     -> Radarr"
    echo   "    https://prowlarr.$suffix   -> Prowlarr"
    echo   "    https://qbittorrent.$suffix -> qBittorrent"
    echo   "    https://bazarr.$suffix     -> Bazarr"
    echo   "    https://overseerr.$suffix  -> Overseerr"
    echo   ""
    echo   "    Setup steps on your Mac (one-time):"
    echo   "      1. Add the hostnames to /etc/hosts so they resolve to 127.0.0.1:"
    echo   "         sudo sh -c 'printf \"127.0.0.1 %s.$suffix\\n\" sonarr radarr prowlarr qbittorrent bazarr overseerr >> /etc/hosts'"
    echo   "      2. SSH-tunnel port 443 from your Mac. Two options:"
    echo   "         sudo ssh -F ~/.ssh/config miniserver       # uses your alias"
    echo   "         sudo ssh -L 443:127.0.0.1:443 you@<mini>   # no alias needed"
    echo   "         (sudo runs as root which ignores YOUR ~/.ssh/config — hence -F.)"
    echo   "      3. Import Caddy's root CA so the browser stops warning:"
    echo   "         docker cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt"
    echo   "         (then copy caddy-root.crt to your Mac and add-trusted-cert it — see README)"
    echo   ""
fi
