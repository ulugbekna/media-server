# Home media server — easy mode

A drop-in, one-command Docker setup for the stack from
[this dev.to article](https://dev.to/rafaelmagalhaes/home-media-server-with-plex-sonarr-radarr-qbitorrent-and-overseerr-2a84):

| Service      | Purpose                              | URL                     |
| ------------ | ------------------------------------ | ----------------------- |
| Prowlarr     | Indexer proxy for torrent trackers   | http://localhost:9696   |
| qBittorrent  | Torrent download client              | http://localhost:8080   |
| Sonarr       | TV-show automation                   | http://localhost:8989   |
| Radarr       | Movie automation                     | http://localhost:7878   |
| Bazarr       | Subtitle automation                  | http://localhost:6767   |
| Overseerr    | Pretty request UI on top of *arr     | http://localhost:5055   |
| Plex         | Media server (installed natively)    | http://localhost:32400  |
| Gluetun      | (optional) VPN for qBittorrent       | —                       |
| Searcharr    | (optional) Telegram bot for requests | (Telegram chat)         |
| Disk guard   | (with Telegram) low-space protection | (background service)    |

> The dev.to article uses **Jackett** as the indexer proxy. This stack uses
> **Prowlarr** — Jackett's modern successor from the same *arr family —
> because it auto-syncs indexers into Sonarr and Radarr instead of requiring
> you to copy a Torznab URL into each app by hand. See [step 4b](#4b-prowlarr-httplocalhost9696)
> for the why; see [Recommended add-ons](#recommended-add-ons) if you want
> Jackett back.

What the article asks you to do by hand — install six apps, create folders,
remember which port is which, copy API keys between web UIs — this repo does
in a single `setup.ps1` invocation.

> **Legal:** torrenting copyrighted material is illegal in most jurisdictions.
> This repo only sets up software. Use it for Linux ISOs, your own backups,
> public-domain media, etc. A VPN is strongly recommended; see "VPN" below.

---

## Table of contents

- [Prerequisites](#prerequisites)
- [1. Install Docker Desktop and Plex](#1-install-docker-desktop-and-plex)
- [2. Run the setup script](#2-run-the-setup-script)
  - [Already running Sonarr/Radarr natively on this machine?](#already-running-sonarrradarr-natively-on-this-machine)
- [3. Finish the Plex first-run wizard](#3-finish-the-plex-first-run-wizard)
- [4. Wire the services together](#4-wire-the-services-together)
  - [4a. qBittorrent](#4a-qbittorrent-httplocalhost8080)
  - [4b. Prowlarr](#4b-prowlarr-httplocalhost9696) — picking trackers, FlareSolverr, Sonarr/Radarr auto-sync
  - [4c. Sonarr and Radarr](#4c-sonarr-httplocalhost8989-and-radarr-httplocalhost7878)
  - [4d. Bazarr](#4d-bazarr-httplocalhost6767) — automatic subtitles
  - [4e. Overseerr](#4e-overseerr-httplocalhost5055) — Netflix-style request UI
- [Day-to-day commands](#day-to-day-commands)
  - [Update flow (end-to-end)](#update-flow-end-to-end)
  - [Upgrading (with 7-day quarantine)](#upgrading-with-7-day-quarantine)
  - [Update notifications (optional, via Diun)](#update-notifications-optional-via-diun)
  - [Backup](#backup)
  - [Disk space (hardlinks)](#disk-space-hardlinks)
- [Remote management (SSH)](#remote-management-ssh) — manage the closeted mini-PC from your Mac
- [Reverse proxy (Caddy) — friendly HTTPS hostnames](#reverse-proxy-caddy--friendly-https-hostnames)
- [Recommended add-ons](#recommended-add-ons)
- [VPN](#vpn) — Gluetun for qBittorrent, NordVPN walkthrough
  - [Migrating an existing install to gluetun](#migrating-an-existing-install-to-gluetun)
- [TRaSH-Guides quality profiles (optional, via Recyclarr)](#trash-guides-quality-profiles-optional-via-recyclarr)
- [Telegram requests](#telegram-requests) — Searcharr bot for /movie and /series
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Windows 10/11 64-bit.** Pro, Home, and Enterprise all work.
- **Virtualization enabled in BIOS/UEFI.** Look for "Intel VT-x", "AMD-V",
  or "SVM" in your BIOS. This is the #1 reason Docker Desktop fails to
  start. Verify with `systeminfo | findstr /i "hyper-v"` — all four lines
  should say `Yes`.
- **WSL 2.** Docker Desktop will offer to install it automatically. If you
  hit problems, run `wsl --install` in an elevated PowerShell first.
- **~20 GB free disk** for Docker images, plus however much you want for
  your media library (this can — and should — be on a separate drive).
- Admin rights for the initial installs (Docker, Plex). The setup script
  itself does not need admin.

---

## 1. Install Docker Desktop and Plex

```powershell
winget install Docker.DockerDesktop
winget install Plex.PlexMediaServer
```

Reboot if Docker prompts you. Launch Docker Desktop once, accept the
service agreement, and wait for the whale icon in the system tray to
stop animating before continuing. **Leave the Plex first-run wizard for
step 3** — we need to create the media folders first.

> **Tip:** Open **Docker Desktop → Settings → General** and tick *"Start
> Docker Desktop when you log in"*. That, combined with the
> `restart: unless-stopped` policy on every container, gives you a true
> "boot the mini-PC and everything comes up" setup. Plex installs as a
> Windows service and is already auto-start.

## 2. Run the setup script

From PowerShell, in the folder containing this README:

```powershell
# Defaults: data/ and config/ next to this README
.\setup.ps1

# Or pick your own locations (large drive recommended for -DataRoot):
.\setup.ps1 -DataRoot D:\media-data -ConfigRoot D:\media-server\config
```

> **What is `<DataRoot>`?** Whenever this README writes `<DataRoot>` later
> (e.g. `<DataRoot>\media\movies` in step 3), it means whatever path you
> passed to `-DataRoot` — or `.\data` next to this README if you used the
> defaults. Same idea for `<ConfigRoot>`. The script also writes these
> into `.env` as `DATA_ROOT` and `CONFIG_ROOT` for the containers.

The script will:

1. Verify Docker Desktop is running.
2. Create the folder layout (`data/torrents/{complete,incomplete}`,
   `data/media/{tv,movies}`, per-service `config/`).
3. Verify `data/torrents` and `data/media` share a filesystem so
   Sonarr/Radarr hardlinks work (see [Disk space (hardlinks)](#disk-space-hardlinks)).
4. Write a `.env` file with your paths.
5. `docker compose pull && docker compose up -d`.
6. Wait for every service to respond, then print:
   - the qBittorrent first-run **admin password** (extracted from container logs),
   - the auto-generated **API keys** for Prowlarr, Sonarr, and Radarr,
   - the in-container paths to use when configuring each app.

**Keep the script's final output open in a window** — you'll paste those
values into the web UIs in step 4. If you lose them, just re-run the
script; it's idempotent and will reprint them.

On Linux / macOS, use `./setup.sh` instead.

### Already running Sonarr/Radarr natively on this machine?

The [dev.to article](https://dev.to/rafaelmagalhaes/home-media-server-with-plex-sonarr-radarr-qbitorrent-and-overseerr-2a84)
that inspired this repo also describes a native Windows install of
Sonarr/Radarr. If you followed that path, those native apps will be bound to
ports `8989` / `7878` already (typically as Windows services that auto-start
on boot). Docker Desktop will silently fail to publish the same ports, the
containers will look healthy but be unreachable, and `http://localhost:8989`
will keep opening the **native** UI instead of the container's. Sort it out
*before* running `setup.ps1` so the bootstrap can actually reach the
container APIs.

From an elevated PowerShell:

```powershell
# 1. Confirm the collision: are 8989 / 7878 owned by Sonarr.Console / Radarr.Console?
Get-NetTCPConnection -State Listen -LocalPort 8989,7878 |
  Select-Object LocalPort,OwningProcess,
                @{n='Process';e={(Get-Process -Id $_.OwningProcess).ProcessName}}

# 2. Stop the native services and prevent them from grabbing the ports on next boot.
Stop-Service Sonarr,Radarr -Force -ErrorAction SilentlyContinue
Set-Service  Sonarr -StartupType Disabled -ErrorAction SilentlyContinue
Set-Service  Radarr -StartupType Disabled -ErrorAction SilentlyContinue
```

Then, if you already ran `setup.ps1` once, force-recreate the two containers
so they re-attempt the port bind (containers that started while the ports
were taken keep their broken publish until you recreate them):

```powershell
cd <folder with this README>
docker compose up -d --force-recreate --no-deps sonarr radarr
```

Verify: `docker ps` should now show `127.0.0.1:8989->8989/tcp` (and the
matching 7878 line) instead of just `8989/tcp`, and `localhost:8989` should
open the LinuxServer.io-built Sonarr UI — not your native one. The native
install's config still lives at `%ProgramData%\Sonarr` and
`%ProgramData%\Radarr` if you want to extract indexers / quality profiles
from it later; once you're happy with the Docker stack, you can uninstall
the native apps from **Settings → Apps → Installed apps**.

> **Linux/macOS** equivalent: `sudo systemctl disable --now sonarr radarr`
> (Debian/Ubuntu builds) or `brew services stop sonarr radarr` (macOS
> Homebrew), then the same `docker compose up -d --force-recreate --no-deps
> sonarr radarr`.

## 3. Finish the Plex first-run wizard

Now that the media folders exist, open Plex (it should already be running
as a Windows service; if not, launch *Plex Media Server* from the Start
menu and click the tray icon → *Open Plex*).

1. Sign in with a Plex account (free).
2. **Windows Defender Firewall will prompt for permission** — allow on
   both private and public networks if you want LAN devices (phones, TVs)
   to discover the server.
3. Server name: anything; tick *"Allow me to access my media outside my home"*.
4. **Add Library → Movies** → folder: `<DataRoot>\media\movies`.
5. **Add Library → TV Shows** → folder: `<DataRoot>\media\tv`.
6. Finish the wizard. Plex will be empty for now — files will appear once
   Sonarr/Radarr download something in step 4.

> Prefer Plex in Docker? Uncomment the `plex:` service in
> `docker-compose.yml`, set `PLEX_CLAIM` (get one at https://plex.tv/claim,
> valid for 4 minutes), and re-run `docker compose up -d`. You lose easy
> hardware transcoding on Windows; not recommended.

---

## 4. Wire the services together

> **✅ On a fresh install, most of this section is done automatically**
> by the setup script's bootstrap step. It uses the REST APIs of
> qBittorrent, Prowlarr, Sonarr, and Radarr to:
>
> - rotate qBittorrent's temp password to a stable random one
>   (printed in the setup summary), set its download paths, create
>   `tv` + `movies` categories, and whitelist loopback / Docker /
>   private-LAN subnets so the brute-force ban can never lock you (or
>   Sonarr/Radarr) out from inside
> - register Sonarr + Radarr as Apps in Prowlarr (so any indexer you
>   add later auto-syncs to both)
> - add qBittorrent as a download client in Sonarr + Radarr (with the
>   right host: `qbittorrent`, or `gluetun` if you used `--vpn`)
> - add `/data/media/tv` and `/data/media/movies` as root folders
> - wire **Plex Connect** in Sonarr + Radarr so every import triggers
>   a Plex library scan immediately (skipped if Plex Media Server isn't
>   installed on this host — the script reads your Plex auth token from
>   the registry, so finish Plex's first-run wizard first)
>
> What's still **manual** (because they need your input, your account,
> or your taste):
>
> - **Adding indexers** in Prowlarr — see [step 4b](#4b-prowlarr-httplocalhost9696) (you pick which trackers)
> - **Bazarr** providers and language profile — see [step 4d](#4d-bazarr-httplocalhost6767) (your OpenSubtitles.com account)
> - **Overseerr** first-run wizard — see [step 4e](#4e-overseerr-httplocalhost5055) (Plex OAuth is browser-only)
> - Sonarr/Radarr quality profiles — covered by [Recyclarr](#trash-guides-quality-profiles-optional-via-recyclarr) if you ran `--recyclarr`
>
> Pass `--no-bootstrap` to `setup.sh` (or `-NoBootstrap` to `setup.ps1`)
> if you'd rather do everything below by hand in the web UIs. Each step
> below has the manual instructions for that case.

The infrastructure is up, but four config screens still need linking. The
setup script prints every value you need — keep its output handy. Each step
below maps to a section of the original article, just much shorter.

> **Do these in the order below.** Each step depends on values produced
> by the previous one (Prowlarr pushes indexers into Sonarr/Radarr; Sonarr/Radarr
> Root Folders must exist before Overseerr will accept them).

### 4a. qBittorrent (http://localhost:8080)

> **✅ Auto-configured by bootstrap** (the script does this for you on a
> fresh install). It sets a strong random admin password, sets the
> download paths to `/data/torrents/...`, and creates `tv` + `movies`
> categories. The new password is shown in the setup script's summary
> output. You can skip this whole section unless you ran `--no-bootstrap`
> or want to tweak something.
>
> The only thing you might still want to do manually:
> **Tools → Options → BitTorrent** → tick "Torrent Queueing" and
> "Seeding Limits" (e.g. ratio 1.0, then "Remove torrent") to keep
> seeded torrents from accumulating forever.

If you opted out of bootstrap (`--no-bootstrap`), do it by hand:

1. Log in as `admin` with the **temp password** the script printed.
2. **Tools → Options → Web UI** (or *Settings → Web UI* depending on theme):
   - Set a real **username and password**. Click **Save**.
   - **Important:** the LSIO image generates a new temp password on every
     container restart **unless** you've changed it here. Write your
     new password down now.
3. **Tools → Options → Downloads**:
   - Default Save Path: `/data/torrents/complete`
   - Keep incomplete torrents in: `/data/torrents/incomplete`
   - Tick "Create subfolder for torrents with multiple files".
   - **Do not** change the `/data` prefix — Sonarr/Radarr need the same
     `/data` mount to hardlink completed files instead of copying them
     (see [Disk space (hardlinks)](#disk-space-hardlinks) below).
4. **Tools → Options → BitTorrent**: tick "Torrent Queueing" and "Seeding Limits"
   (e.g. ratio 1.0, then "Remove torrent").
5. **Log out and log back in** with your new credentials to confirm they work.

You can skip the WinRAR/rar-extract step from the article — qBittorrent
runs inside the container, so there's no host-side rar binary to call.
The *arr apps handle .rar imports for you.

### 4b. Prowlarr (http://localhost:9696)

Prowlarr is a **proxy for torrent trackers** — it lets Sonarr/Radarr talk
to ~500 different sites through one consistent API. Unlike Jackett (the
older tool the dev.to article uses), Prowlarr **pushes** indexers into
Sonarr/Radarr automatically: add a tracker once in Prowlarr, and it
appears in both *arr apps within seconds, with the right Torznab URL,
right API key, right categories. No per-app paste-the-URL dance.

The container ships with **zero indexers configured**; you pick which
trackers to enable.

#### First-run wizard

1. Open <http://localhost:9696>.
2. Pick **Authentication Method: Forms (Login Page)** and set a
   username/password. Click **Save**. (You'll log in once and the browser
   remembers it.)
3. The main dashboard appears. The API key is in **Settings → General**
   (and the setup script already printed it).

#### Pick your trackers

There are two flavours of indexer in Prowlarr, and you'll likely want a
mix of both:

**Public trackers** — no signup, no credentials. Lower-quality releases on
average, and many trackers go down or change domains every few months,
but the easiest place to start. Common picks (mileage varies — try a few,
keep the ones that return results):

| Indexer            | What it's good for                  |
| ------------------ | ----------------------------------- |
| 1337x              | General / movies / TV               |
| The Pirate Bay     | General — long-tail catalog         |
| TorrentGalaxy      | General — active community          |
| EZTV               | TV only                             |
| YTS                | Movies (small files, 720p/1080p)    |
| Nyaa               | Anime                               |
| LimeTorrents       | General fallback                    |
| TheRARBG / RARBG2  | Movies/TV (original RARBG died 2023; these are community mirrors of varying quality) |

> The list of *working* public trackers is a moving target. If one
> returns errors, disable it and try another. Prowlarr's per-indexer
> stats (next to each row) tell you who's actually delivering results.

**Private trackers** — require an account (usually invite-only). Vastly
better quality, retention, and seeding ratios, but you need an existing
membership. Popular ones supported by Prowlarr: IPTorrents, TorrentLeech,
HDBits, BroadcasTheNet, PassThePopcorn, Redacted. You'll need your
username/password (or for some, a session cookie or 2FA-token-aware login).

#### Add an indexer (UX walkthrough)

1. **Indexers → Add Indexer (+)**.
2. Search/filter by name (e.g. `1337x`). Click the row.
3. For public trackers, just hit **Test** then **Save**.
4. For private trackers, fill in **Username / Password** (and any cookie
   or 2FA field the form asks for) → **Test** → **Save**.
5. Test result:
   - ✅ Green tick = working, ready to use.
   - ⚠ / ❌ = tracker down, captcha required, or credentials wrong.
     The error message tells you which. Click the row to edit.

#### Cloudflare-protected trackers: FlareSolverr

Several private and some public trackers (e.g. some TorrentLeech mirrors,
1337x at times) sit behind Cloudflare's "checking your browser" page,
which blocks Prowlarr. The fix is **FlareSolverr** — a headless-browser
companion that solves the challenge.

Add this to `docker-compose.yml` (uncommented, alongside Prowlarr):

```yaml
  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ:-UTC}
    ports:
      - "127.0.0.1:8191:8191"
    restart: unless-stopped
```

Then in Prowlarr → **Settings → Indexers → Add Indexer Proxy → FlareSolverr**:
- Name: `flaresolverr`
- Host URL: `http://flaresolverr:8191/`
- Tags: leave blank (applies to all indexers that need it)

Click **Test** → **Save**. Cloudflare-blocked indexers will start returning
results on their next sync.

#### Wire Prowlarr into Sonarr and Radarr (one-time, ~30 seconds)

> **✅ Auto-configured by bootstrap.** On a fresh install the setup
> script registers both apps for you via Prowlarr's REST API. Verify by
> opening Prowlarr → **Settings → Apps** — you should see Sonarr and
> Radarr listed with a green ✓. Skip the manual steps below.

If you opted out of bootstrap (`--no-bootstrap`) or are adding Prowlarr
to an existing stack, do it by hand. This is where Prowlarr earns its
keep — you do this **once**, then every future indexer you add appears
in both *arr apps automatically.

1. **Settings → Apps → Add (+) → Sonarr**.
   - Prowlarr Server: `http://prowlarr:9696` (leave default).
   - Sonarr Server: `http://sonarr:8989`
   - API Key: the Sonarr API key the setup script printed.
   - Click **Test** → **Save**.
2. **Settings → Apps → Add (+) → Radarr**.
   - Prowlarr Server: `http://prowlarr:9696`
   - Radarr Server: `http://radarr:7878`
   - API Key: the Radarr API key the setup script printed.
   - Click **Test** → **Save**.

That's it. Prowlarr now sees Sonarr and Radarr as "Apps" and will push
every configured indexer into them. If you add a new tracker tomorrow,
it shows up in both Sonarr → Settings → Indexers and Radarr → Settings →
Indexers within ~30 seconds — no manual action required.

> Note the hostnames: from inside the Docker network, services reach
> each other by service name (`sonarr`, `radarr`, `prowlarr`), **not**
> `localhost` or `127.0.0.1`.

#### Coming from Jackett?

If you previously ran this stack with Jackett and have a list of
indexers there, you'll need to re-add them in Prowlarr — credentials
don't migrate between the two formats. The `config/jackett/` folder on
your host is untouched, so if you change your mind you can revert this
repo's commit and Jackett will come back with the same config.

### 4c. Sonarr (http://localhost:8989) and Radarr (http://localhost:7878)

Both are configured identically — Radarr just stores movies instead of TV.

> **✅ Auto-configured by bootstrap.** On a fresh install the setup
> script does steps 1, 2, 3, and 5 below for you via Sonarr/Radarr's
> REST APIs. The indexers, qBittorrent download client (with
> `tv`/`movies` categories), `/data/media/tv` + `/data/media/movies`
> root folders, and the Plex auto-scan notifier will all be in place
> when you first open the UI. Verify: Settings → Indexers,
> Settings → Download Clients, Settings → Media Management → Root
> Folders, Settings → Connect (Plex Media Server row). Then skip to
> step 4 (quality profiles) — that's your decision.

If you opted out of bootstrap, do them by hand:

1. *(Skip if Prowlarr is wired in)* **Settings → Indexers** should list
   the indexers Prowlarr pushed. Click any one and **Test** to confirm
   it answers. If you see nothing here, go back to Prowlarr → Settings →
   Apps and click **Sync App Indexers** on the Sonarr/Radarr row.
2. **Settings → Download Clients → +** → **qBittorrent**
   - Host: `qbittorrent`  (the service name, not localhost; or `gluetun` if
     you set up the VPN — see [VPN](#vpn) below)
   - Port: `8080`
   - Username / Password: the ones you set in qBittorrent above.
   - Click **Test** → **Save**.
3. **Settings → Media Management → Root Folders → +**
   - Sonarr: `/data/media/tv`
   - Radarr: `/data/media/movies`
   - Tick "Rename Episodes" / "Rename Movies".
4. **Settings → Profiles** (Sonarr) / **Settings → Quality** (Radarr):
   defaults are fine. If you want 1080p-only or 4K-only, edit the
   "HD-1080p" / "Ultra-HD" profile and use that on new shows/movies.
5. *(Optional)* **Settings → Connect → Plex Media Server** to auto-refresh
   the Plex library when downloads finish. Host: `host.docker.internal`
   (Windows / Mac Docker Desktop reaches your native Plex install through
   this magic hostname; on Linux engine, the `extra_hosts` block in
   `docker-compose.yml` makes the same name work). Port: `32400`. Click
   **Authenticate with Plex.tv**.

   > The bootstrap step wires this up for you automatically — but only if
   > Plex Media Server is running on the same host AND you've completed
   > Plex's first-run wizard (so a Plex auth token exists in
   > `HKCU\Software\Plex, Inc.\Plex Media Server` on Windows, or in
   > `~/Library/Application Support/Plex Media Server/Preferences.xml` on
   > macOS, or `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml`
   > on Linux). If you skipped Plex during first setup, finish [step 3](#3-finish-the-plex-first-run-wizard)
   > and re-run `setup.ps1 -Bootstrap` (or `./setup.sh --bootstrap`) to add
   > the notifier without redoing the rest.

Do **both Sonarr and Radarr** before moving to Overseerr — Overseerr's
wizard won't accept them otherwise.

### 4d. Bazarr (http://localhost:6767)

Bazarr auto-downloads subtitles for every show and movie Sonarr/Radarr
manages. It mounts the same `/data` as Sonarr/Radarr so it can write
subtitle files next to the video files (at
`/data/media/tv/...` and `/data/media/movies/...`).

1. Open <http://localhost:6767>. Set a username/password on the first-run
   page → **Save**.
2. **Settings → Languages → Languages Filter**: tick every language you
   want subtitles for (most users: English + native language). **Save**.
3. **Settings → Languages → Languages Profiles → Add New**:
   - Name: `Default`
   - Languages: add the ones from step 2 in order of preference.
   - **Cutoff**: pick the language that, once found, stops further searches
     (usually English).
   - Tick **Hearing-Impaired: No** unless you want SDH.
   - **Save**.
4. **Settings → Sonarr**:
   - Address: `sonarr`  (service name; not `localhost`)
   - Port: `8989`
   - API Key: the Sonarr key the setup script printed.
   - Click **Test** → green ✓ → **Save**.
   - Tick **Defined Language Profile** = `Default`.
5. **Settings → Radarr**: same as above with `radarr`, port `7878`, the
   Radarr API key, language profile `Default`.
6. **Settings → Providers**: enable a few subtitle providers. Free, good
   defaults: **OpenSubtitles.com** (free account required — sign up first
   at <https://www.opensubtitles.com>), **Podnapisi**, **Subscene**.
   Avoid the legacy "OpenSubtitles.org" — slower and quota-limited.
7. *(Optional)* **Settings → Scheduler** → tune how often Bazarr re-scans
   for missing subtitles. Default (6 h) is fine.

After saving, Bazarr does an initial sync — within a few minutes it'll
populate the **Series** and **Movies** tabs with everything from Sonarr/
Radarr and start hunting subtitles for them. New downloads get subtitles
automatically within seconds of import.

### 4e. Overseerr (http://localhost:5055)

The first-run wizard walks you through it:

1. Sign in with your Plex account.
2. Point at your Plex server. Host: `host.docker.internal`, Port: `32400`.
3. Add Sonarr: `http://sonarr:8989`, API key from the script. After
   Overseerr connects, it asks for a **Default Quality Profile** and
   **Default Root Folder** — pick the ones you set up in step 4c.
4. Same for Radarr: `http://radarr:7878`, then quality + root folder.

Done. Friends and family can now request shows/movies from a Netflix-like UI
and they'll appear in Plex automatically.

> ✅ **Core setup complete!** The stack is running and wired up. From here,
> the remaining sections are independent — pick what you need:
>
> - **Mini-PC in a closet / different room?** → [Remote management (SSH)](#remote-management-ssh)
>   to reach the web UIs from your laptop.
> - **Want pretty URLs like `https://sonarr.miniserver.local`?** →
>   [Reverse proxy (Caddy)](#reverse-proxy-caddy--friendly-https-hostnames)
>   (do SSH first; Caddy builds on top of it).
> - **Torrenting?** → [VPN](#vpn) — strongly recommended.
> - **Day-to-day operation, updates, backups** → [Day-to-day commands](#day-to-day-commands).

---

## Day-to-day commands

```powershell
docker compose ps              # what's running
docker compose logs -f sonarr  # tail a service
docker compose restart radarr  # restart one service
docker compose down            # stop everything (keeps data)
```

To uninstall completely: `docker compose down -v` and delete the `config/`
and `data/` folders (i.e. whatever you passed as `<ConfigRoot>` and
`<DataRoot>` in step 2).

### Update flow (end-to-end)

How keeping the stack up to date works, in order:

```
       ┌─────────────────────────────────────────────────────────────┐
       │  Upstream releases a new image (e.g. lscr.io/.../sonarr)    │
       └─────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │  Diun (optional, runs daily at 09:00 in the stack)                │
    │   - notices the new digest                                        │
    │   - sends you a Telegram / Discord / Slack notification           │
    │     (or just logs it — docker logs diun)                          │
    └───────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │  YOU run update.sh (or update.ps1) — dry-run first                │
    │   - pulls each :latest tag                                        │
    │   - skips anything younger than 7 days (quarantine window)        │
    │   - reports what *would* change                                   │
    └───────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │  YOU run update.sh --apply                                        │
    │   - rewrites the SHA digests in docker-compose*.yml               │
    │   - keeps a .bak copy of each modified file                       │
    └───────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
    ┌───────────────────────────────────────────────────────────────────┐
    │  YOU restart the stack with the new digests                       │
    │   docker compose pull && docker compose up -d                     │
    └───────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                  If anything misbehaves, ROLLBACK:
                  restore the .bak files, docker compose up -d
```

**Typical cadence:** check (or get pinged) once a week, apply once a month.

**Without Diun:** just run `./update.sh` (dry-run) on whatever schedule you
like — weekly is plenty. The script is idempotent and only proposes work
when there's something to do.

**With overrides:** `update.sh` knows about every `docker-compose*.yml` file
in the repo root, so it handles VPN, Telegram, Recyclarr, Diun, and Caddy
digests too — no extra flags. After `--apply`, your `docker compose up -d`
needs the same `-f ...` chain you originally used (the setup script's
`-Vpn -Telegram -Recyclarr -Proxy` flags assemble that for you).

The individual pieces — the update script and Diun — are documented in
the next two subsections.

### Upgrading (with 7-day quarantine)

All images are pinned to specific SHA digests in `docker-compose*.yml`, so
`docker compose pull` alone won't update them — that's intentional supply-chain
hygiene. To roll forward to newer pinned digests, use the included update
script:

```powershell
.\update.ps1            # dry-run: report what could change
.\update.ps1 -Apply     # rewrite the YAML in place (backups: *.bak)
```

On Linux/macOS: `./update.sh` and `./update.sh --apply`.

The script:
1. Reads the `# tag: <ref>:tag` annotation above each pinned image.
2. `docker pull`s that tag, inspects its `Created` timestamp.
3. **Quarantines images younger than 7 days** — protects you from rolling
   onto a fresh upstream release that hasn't been in the wild long enough
   for issues to be reported. Use `--quarantine-days 30` for stricter,
   `--quarantine-days 0` to disable.
4. Only proposes updates when the upstream digest *differs* from your
   pinned one *and* the image is past quarantine.
5. With `--apply`, rewrites the YAML in place and keeps `.bak` copies for
   easy revert.

After applying, restart the stack to pick up the new images:

```powershell
docker compose pull
docker compose up -d
```

If anything misbehaves, restore the backups:

```powershell
Get-ChildItem docker-compose*.yml.bak | ForEach-Object { Move-Item $_ ($_ -replace ".bak$","") -Force }
docker compose up -d
```

Or on Linux/macOS:

```bash
for f in docker-compose*.yml.bak; do mv "$f" "${f%.bak}"; done
docker compose up -d
```

### Update notifications (optional, via Diun)

The update script above is pull-based — you have to remember to run it.
For push-based "hey, there's something new" notifications, this repo
ships an optional **Diun** ([Docker Image Update Notifier](https://crazymax.dev/diun/))
override. Diun watches every container in the stack and pings you when
an upstream image has a newer digest than what's pinned. It does **not**
auto-update; the actual update still goes through `update.sh --apply`
with its 7-day quarantine.

#### Start Diun

1. Pick a notification channel (the easiest is Telegram if you already
   set up the Searcharr bot — you can reuse the bot for these messages
   too, just point it at a different chat).
2. Fill in the relevant `DIUN_NOTIF_*` block in `.env` (see
   `.env.example` — Telegram, Discord, and Slack are wired by default).
3. Start the override:
   ```powershell
   docker compose -f docker-compose.yml -f docker-compose.diun.yml up -d
   ```
4. Verify it started: `docker logs diun` should show
   `Cron initialized with schedule 0 0 9 * * *` and the next run time.

Composable with the VPN and Telegram overrides — chain as many `-f` flags
as you need. With no notification channel configured, Diun still runs
and logs every detected update to `docker logs diun` — that's a usable
fallback if you'd rather just `docker logs diun --since 24h` daily.

#### Other notification channels

The env-var interface only covers Telegram, Discord, and Slack
cleanly — SMTP, Gotify, Matrix, MS Teams, ntfy, etc. have strict
validation that doesn't play well with empty defaults. For those, drop
a YAML config file at `config/diun/diun.yml`; Diun picks it up
automatically. See the [Diun docs](https://crazymax.dev/diun/config/).

### Backup

The `config/` folder contains everything irreplaceable — API keys, indexer
setups, your list of monitored shows, watch history. **Back it up.** Easy
options:

- Copy `config/` to OneDrive / Dropbox once a week.
- Or, after `docker compose down`, zip `config/` and upload it.
- The `data/media/` folder you can re-download; `data/torrents/` is
  throwaway (everything in it is either still seeding or already
  hardlinked into `data/media/`).

### Disk space (hardlinks)

This stack is configured for **hardlinks** between qBittorrent's
completed downloads and Sonarr/Radarr's library. That means:

- **1× disk usage**, not 2×, even while qBittorrent keeps seeding.
- **Instant imports** — Sonarr/Radarr "move" a 30 GB movie to the library
  in milliseconds (it's a `link(2)` syscall, not a copy).
- **No write amplification** on your SSD.

#### How it works

Hardlinks are a kernel feature: two filenames point to the same physical
data on disk. The catch is that both filenames must live on the **same
filesystem** — `link(2)` across mount points fails with `EXDEV`. To
satisfy that requirement, every service in this stack mounts one shared
`DATA_ROOT` as `/data` (instead of separate `/downloads` and `/media`
mounts that would look like different filesystems to the container):

```
DATA_ROOT/                       (one path on one disk on the host)
  ├── torrents/
  │   ├── complete/              ← qBittorrent's "Default Save Path"
  │   └── incomplete/            ← qBittorrent's "Keep incomplete in"
  └── media/
      ├── tv/                    ← Sonarr's Root Folder
      └── movies/                ← Radarr's Root Folder
```

The setup script verifies on every run that `DATA_ROOT/torrents` and
`DATA_ROOT/media` are on the same filesystem and refuses to proceed if
they aren't — silent fallback to copying is exactly the failure mode
hardlinks are meant to prevent.

The bootstrap also enables **Use Hardlinks instead of Copy** and **Skip
Free Space Check** in Sonarr/Radarr. A completed qBittorrent file has already
consumed its space on `/data`; without the latter setting, an Arr app can
incorrectly demand enough free space for a second full copy before it even
attempts the hardlink. Only use this policy with the verified single-root
layout above.

#### Automatic low-space guard (with Telegram)

Enabling `docker-compose.telegram.yml` also starts `disk-guard`. It checks
free space on `/data` once a minute and applies this fixed safety policy:

- **Below 5 GiB free:** call qBittorrent v5's stop API for active,
  incomplete download-side torrents (including queued/stalled downloads).
  Completed and seeding torrents are never targeted, and nothing is deleted.
- **During the same incident:** keep stopping newly started/resumed incomplete
  downloads, but send each authorized Searcharr user only one warning.
- **At 10 GiB free:** send one recovery message and reset the persisted
  incident. The recovery message explicitly says downloads remain stopped.
- **Never auto-resume:** manually resume only the downloads you want after
  confirming enough space is available.

Incident and notification state is stored atomically in
`<ConfigRoot>/disk-guard/incident-state.json`, so container/host restarts do
not repeat an alert. Recipient IDs are represented there only by hashes. The
guard reads Searcharr's existing token and authorized-user database through a
read-only mount; it does not copy either into environment variables or logs.
Repeated HTTP failures are retried with bounded backoff, then logged, and a
stale successful-check heartbeat makes the container unhealthy.

Validate the live integrations without forcing the disk below the threshold:

```powershell
# Read free space, qBittorrent candidates, and Searcharr recipients; change nothing.
docker compose -f docker-compose.yml -f docker-compose.vpn.yml -f docker-compose.telegram.yml run --rm --no-deps disk-guard --dry-run

# Send an explicit test message; do not touch torrents or incident state.
docker compose -f docker-compose.yml -f docker-compose.vpn.yml -f docker-compose.telegram.yml run --rm --no-deps disk-guard --test-alert

# Follow operational logs (counts only; no token, user IDs, names, or hashes).
docker logs -f disk-guard
```

If you do not use the VPN override, omit `docker-compose.vpn.yml`; the guard
falls back from `http://gluetun:8080` to `http://qbittorrent:8080`.

#### Verifying it works (after you've imported something)

On the mini-PC, pick any imported file and inspect its inode + link
count:

```fish
docker exec sonarr stat -c "inode=%i links=%h  %n" \
  "/data/media/tv/<show>/Season 01/<episode>.mkv"
```

If `links=2` (or more), the same on-disk file is reachable from both
`/data/media/tv/...` AND `/data/torrents/complete/...`. That's the
hardlink in action — `du -sh` will count the file once, not twice.

If `links=1`, Sonarr/Radarr fell back to copying. Most common cause:
"Use Hardlinks instead of Copy" is off in Sonarr/Radarr → Settings →
Media Management. Sonarr v4 has this on by default; older Radarr
installs may need it ticked manually.

#### Layout if you want a separate drive for media

If your config + downloads SSD is small and the bulk media library lives
on a slower spinning disk, you have two options:

- **Mount the big disk at `DATA_ROOT` entirely.** Loses the SSD-speed
  scratch space for incomplete downloads but keeps hardlinks. Usually
  fine — torrents are network-bound, not disk-bound.
- **Give up hardlinks and use two paths.** Edit `docker-compose.yml`
  back to split mounts (`${MEDIA_ROOT}:/media` and
  `${DOWNLOADS_ROOT}:/downloads`). You'll pay 2× disk usage for
  whatever you're seeding. The TRaSH Guides have a
  [hardlinks guide](https://trash-guides.info/Hardlinks/Hardlinks-and-Instant-Moves/)
  with all the caveats.

---

## Remote management (SSH)

**What this section gives you:** the ability to open
`http://localhost:8989` on your Mac/laptop and have it actually reach
Sonarr on the mini-PC — without exposing any port to your LAN or the
internet.

**Why you need it:** for security, the admin UIs (Sonarr, Radarr,
Prowlarr, qBittorrent, Bazarr) are bound to `127.0.0.1` on the mini-PC.
That means **they're only reachable from the mini-PC itself** — open a
browser on your laptop and `http://192.168.1.42:8989` will fail by
design. SSH port-forwarding gives your laptop a secure, encrypted
"window" into those local-only services.

**You only need this if** the mini-PC isn't the machine you sit in front
of. If you run a browser directly on the mini-PC, skip the whole
section.

> **Already planning to use the [Caddy reverse proxy](#reverse-proxy-caddy--friendly-https-hostnames) below?**
> Still do steps 1 and 2 here (you need SSH login working either way) —
> but in step 3, you'll forward a single port (`443`) instead of six. The
> Caddy section gives you the alternate `~/.ssh/config` block.

### 1. Enable the built-in OpenSSH server on Windows

PowerShell **as administrator**, on the mini-PC:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# (Optional but recommended) make PowerShell the default login shell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
  -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -PropertyType String -Force | Out-Null

# Verify
Get-Service sshd
```

Find the mini-PC's LAN IP (`ipconfig` → look for IPv4 under your active
adapter). Then **pin a static DHCP lease** for that MAC address in your
router so the IP doesn't drift — most routers have this under
"DHCP reservations" or "Address reservation".

### 2. Key-based login (one-time, from your Mac)

> **"What's my username and password?"** On the mini-PC, run `whoami` in
> PowerShell — the part after `\` is your SSH username. Your **Windows
> PIN does not work over SSH** (PINs only unlock the local device). The
> SSH password is either:
> - your **Microsoft account password** (if you sign in with a Microsoft
>   account), or
> - the **local account password** (if it's a local account).
>
> If your local account has no password set, OpenSSH refuses empty
> passwords. Either set one with `net user <username> *` (PowerShell as
> admin), or skip password auth entirely by using the manual key-copy
> method shown below.

```fish
# If you don't already have one:
ssh-keygen -t ed25519

# Copy your public key to the mini-PC so you don't need a password each time:
ssh-copy-id youruser@192.168.1.42
# If your Mac doesn't have ssh-copy-id (rare), this works too:
#   cat ~/.ssh/id_ed25519.pub | ssh youruser@192.168.1.42 \
#     "powershell -c \"Add-Content -Path $HOME\.ssh\authorized_keys -Value (\$input | Out-String)\""

# Confirm:
ssh youruser@192.168.1.42 "hostname"
```

> **Manual key copy (no password needed).** If `ssh-copy-id` won't work,
> on the mini-PC paste your Mac's `~/.ssh/id_ed25519.pub` into the right
> file:
> - **Non-admin account:** append to `%USERPROFILE%\.ssh\authorized_keys`.
> - **Admin account:** Windows OpenSSH reads
>   `C:\ProgramData\ssh\administrators_authorized_keys` instead. After
>   creating it, lock down permissions or sshd will ignore it:
>   ```powershell
>   icacls C:\ProgramData\ssh\administrators_authorized_keys `
>     /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
>   Restart-Service sshd
>   ```
> Once the key is in place, `ssh youruser@192.168.1.42` from your Mac
> works with no password at all.

### 3. Tunnel every web UI in one command

Each `-L <local-port>:localhost:<remote-port>` flag tells SSH: "open
`<local-port>` on my Mac, and any traffic to it gets forwarded through
the SSH connection to `<remote-port>` on the mini-PC's loopback." So
`-L 8989:localhost:8989` makes the mini-PC's Sonarr available as
`http://localhost:8989` on your Mac.

```fish
ssh -L 8989:localhost:8989 \
    -L 7878:localhost:7878 \
    -L 9696:localhost:9696 \
    -L 8080:localhost:8080 \
    -L 6767:localhost:6767 \
    -L 5055:localhost:5055 \
    -L 8000:localhost:8000 \
    youruser@192.168.1.42
```

While that SSH session stays open, on your Mac:

| Open in your browser  | Hits service on mini-PC   |
| --------------------- | ------------------------- |
| http://localhost:8989 | Sonarr                    |
| http://localhost:7878 | Radarr                    |
| http://localhost:9696 | Prowlarr                  |
| http://localhost:8080 | qBittorrent               |
| http://localhost:6767 | Bazarr                    |
| http://localhost:5055 | Overseerr (also LAN-reachable directly) |
| http://localhost:8000 | Gluetun control API (VPN only) |

> If you already have a service listening on one of these ports on your Mac
> (e.g. local development), pick a different left-hand port:
> `-L 18989:localhost:8989` → browse to `http://localhost:18989`.

### 4. Make it a one-word command: `~/.ssh/config`

Drop this into `~/.ssh/config` on your Mac:

```sshconfig
Host miniserver
    HostName 192.168.1.42
    User youruser
    # Forward every web UI in the media stack.
    # `LocalForward <mac-port> localhost:<mini-pc-port>` is the
    # ssh_config equivalent of `-L <mac-port>:localhost:<mini-pc-port>`.
    LocalForward 8989 localhost:8989   # Sonarr
    LocalForward 7878 localhost:7878   # Radarr
    LocalForward 9696 localhost:9696   # Prowlarr
    LocalForward 8080 localhost:8080   # qBittorrent
    LocalForward 6767 localhost:6767   # Bazarr
    LocalForward 5055 localhost:5055   # Overseerr
    LocalForward 8000 localhost:8000   # Gluetun control API (VPN only)
    # Keep the connection healthy on flaky Wi-Fi:
    ServerAliveInterval 30
    ServerAliveCountMax 4
```

Now you just type `ssh miniserver` and every UI is available on your Mac.
Open the URLs above in your browser; configure Sonarr, add Prowlarr indexers,
manage qBittorrent — all over an encrypted tunnel.

### 5. Don't accidentally lock yourself out

A closeted mini-PC has no keyboard, no monitor, and no one to wake it
up. Windows' default power settings will absolutely brick this setup —
the machine sleeps overnight, drops off the LAN, and you can't reach
it until you physically walk to the closet. Fix it once, the safe way:

**Disable every form of sleep, hibernation, and lid-close-action.**
Run **PowerShell as administrator** on the mini-PC:

```powershell
# Disable sleep on AC and on battery (mini-PCs often pretend to be laptops)
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0

# Disable hibernation entirely (also reclaims ~8 GB of hiberfil.sys)
powercfg /hibernate off

# Disable the disk spinning down (matters for spinning-rust media drives)
powercfg /change disk-timeout-ac 0
powercfg /change disk-timeout-dc 0

# Disable "turn off display" (cosmetic — display is unplugged anyway,
# but a "screen off" event sometimes triggers other power transitions)
powercfg /change monitor-timeout-ac 0
powercfg /change monitor-timeout-dc 0

# Make the lid-close (and power-button) actions do NOTHING. Mini-PCs
# without a lid still pretend to have one; this stops phantom suspends.
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setactive SCHEME_CURRENT
```

> Setup script tip: `setup.ps1`'s pre-flight check warns when
> `standby-timeout-ac` is non-zero, so a quick `.\setup.ps1` re-run
> will tell you if you missed something.

**Verify it stuck.** Two commands:

```powershell
# 1. Check sleep, hibernate, disk, monitor timeouts (all should say 0):
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE       | findstr "Index"
powercfg /query SCHEME_CURRENT SUB_DISK  DISKIDLE          | findstr "Index"
powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE         | findstr "Index"
powercfg /availablesleepstates    # "Hibernate" should appear under "unavailable"

# 2. Check there's no scheduled wake / scheduled sleep:
powercfg /waketimers
powercfg /lastwake
```

**Don't disable the network adapter on lid close / monitor unplug.** Some
mini-PCs ship with this enabled — check Device Manager → your network
adapter → Properties → Power Management, and untick *"Allow the computer
to turn off this device to save power"*.

**Enable auto-login on boot** (Settings → Accounts → Sign-in options →
alternatively `netplwiz` and uncheck "Users must enter a user name and
password"). Necessary so Docker Desktop starts after a power blip without
needing a keyboard plugged in.

**Test reboot-and-recover end-to-end** before you put the PC in the
closet:
```powershell
shutdown /r /t 0
```
…then walk away. From your Mac, after ~2 minutes:
```fish
ssh miniserver "docker compose ps"
```
Every service should be back up. If anything's missing, fix it now —
not when you've already put the lid back on the closet.

### 6. Do not expose SSH (or any of this) to the internet

SSH on port 22 is scanned constantly by botnets. **Do not port-forward 22
on your router.** LAN-only access is what you want.

If you ever need to manage the mini-PC from outside your home:

- Install **[Tailscale](https://tailscale.com/)** (free for personal use)
  on both the mini-PC and your Mac. Each machine gets a stable private
  hostname like `miniserver.tail-abc12.ts.net`. SSH then works identically
  from anywhere — coffee shop, friend's house, holiday — with no router
  config and no exposed ports.
- Replace the `HostName 192.168.1.42` line in `~/.ssh/config` with the
  Tailscale hostname and you're done.

### 7. When you actually need a graphical desktop

99% of the time SSH + the tunneled web UIs are enough. The exceptions —
Plex's first-run wizard, Docker Desktop's tray menu, BIOS-level Windows
updates — need an actual desktop. Use **Microsoft Remote Desktop** (free
on the Mac App Store) over RDP, again LAN-only. Windows 10/11 Home doesn't
ship the RDP server; on Home, install TightVNC or RealVNC instead and
connect with macOS Finder → `⌘K` → `vnc://192.168.1.42`.

---

## Reverse proxy (Caddy) — friendly HTTPS hostnames

**What this section gives you:** instead of remembering
`http://localhost:8989`, `:7878`, `:9696`, … you open
`https://sonarr.miniserver.local`, `https://radarr.miniserver.local`,
etc. — over real HTTPS, with one SSH port forward instead of six.

**Prerequisite:** you've already set up [Remote management (SSH)](#remote-management-ssh)
(steps 1 and 2 — login works). Caddy *replaces* step 3's six `-L` flags
with a single one.

**When to use it:** purely for nicer UX. If `http://localhost:8989`
through an SSH tunnel works for you, skip this section entirely — no
features are lost.

**A reverse proxy** is a server that sits in front of your other
services and routes requests by hostname. Here, Caddy listens on
`127.0.0.1:443` and forwards `sonarr.miniserver.local` → Sonarr,
`radarr.miniserver.local` → Radarr, and so on. It also handles HTTPS
(self-signed, via a local CA).

This repo ships an optional Caddy reverse proxy override that:

- Listens on `127.0.0.1:443` (TLS, loopback only — same security model
  as everything else).
- Uses Caddy's `tls internal` directive to mint its own certs from a
  local CA. No real domain, no Let's Encrypt, no exposed ports.
- Routes by hostname:

  | Hostname                              | Service     |
  | ------------------------------------- | ----------- |
  | `sonarr.miniserver.local`             | Sonarr      |
  | `radarr.miniserver.local`             | Radarr      |
  | `prowlarr.miniserver.local`           | Prowlarr    |
  | `qbittorrent.miniserver.local`        | qBittorrent |
  | `bazarr.miniserver.local`             | Bazarr      |
  | `overseerr.miniserver.local`          | Overseerr   |

The suffix is configurable via `CADDY_DOMAIN_SUFFIX` in `.env` (default
`miniserver.local`).

### Start the proxy

```powershell
.\setup.ps1 -Proxy                      # proxy only
.\setup.ps1 -Vpn -Recyclarr -Proxy      # everything together
```

On Linux/macOS: `./setup.sh --proxy` (compose-able with any other flags).

The script:
1. Copies `caddy/Caddyfile.template` to `config/caddy/Caddyfile` (only on
   first run; subsequent runs preserve your edits).
2. If `--vpn` is active, rewrites the qBittorrent upstream from
   `qbittorrent:8080` to `gluetun:8080` automatically.
3. Starts Caddy, which provisions internal certs for all six hostnames
   (takes ~5 seconds).

### One-time client setup (on your Mac)

After running the proxy override, do these three things on your Mac to
get the full experience:

**1. Add the hostnames to `/etc/hosts`** so they resolve to localhost
(where your SSH tunnel terminates):

```fish
sudo sh -c 'printf "127.0.0.1 %s.miniserver.local\n" sonarr radarr prowlarr qbittorrent bazarr overseerr >> /etc/hosts'
```

**2. SSH-tunnel just port 443** instead of six ports. Replace the
`LocalForward` lines from [Remote management](#remote-management-ssh)
in your `~/.ssh/config` with:

```sshconfig
Host miniserver
    HostName 192.168.1.42
    User youruser
    LocalForward 443 localhost:443
    ServerAliveInterval 30
    ServerAliveCountMax 4
```

> Forwarding local port 443 needs `sudo` because 443 is privileged on
> the Mac side. **Gotcha:** `sudo ssh miniserver` will fail with
> `Could not resolve hostname miniserver` — sudo runs as root, which
> reads root's `~/.ssh/config`, not yours. Two fixes (pick one):
>
> ```fish
> # A. Point sudo at your user's ssh config:
> sudo ssh -F ~/.ssh/config miniserver
>
> # B. Skip the alias entirely:
> sudo ssh -L 443:127.0.0.1:443 youruser@192.168.1.42
> ```
>
> If you'd rather not type `sudo` at all, use a non-privileged local
> port: change the `LocalForward` to `8443 localhost:443` and browse
> to `https://sonarr.miniserver.local:8443`.

**3. Import Caddy's root CA** so the browser stops warning about the
self-signed cert:

```fish
# Pull the cert from the mini-PC over SSH:
ssh miniserver "docker exec caddy cat /data/caddy/pki/authorities/local/root.crt" > ~/caddy-root.crt

# Add it to the macOS system keychain (asks for your password):
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ~/caddy-root.crt
```

Done. Open `https://sonarr.miniserver.local` in any browser, no warnings,
all six services one click away.

### Trade-offs

- **Pro:** one tunnel forward, friendly URLs, real HTTPS, no
  port-number memorisation. Easier to bookmark.
- **Con:** the one-time `/etc/hosts` + root-CA-trust steps. After
  setup it's invisible; before setup it's three commands.
- **No new attack surface:** Caddy listens only on `127.0.0.1`, same
  as the individual services. Anyone on your LAN still can't reach
  it without SSH access to the mini-PC.

### Adding HTTP basic auth (optional)

If you want a password prompt in front of (e.g.) Sonarr beyond just
SSH access, edit `config/caddy/Caddyfile`:

```caddy
sonarr.{$CADDY_DOMAIN_SUFFIX} {
    tls internal
    basicauth {
        admin $2a$14$Hd...hashed-with-caddy-hash-password
    }
    reverse_proxy sonarr:8989
}
```

Generate the password hash: `docker exec caddy caddy hash-password`.
Then `docker compose restart caddy`.

---

## Recommended add-ons

- **VPN** — see [VPN](#vpn) below. Strongly recommended for torrent traffic.
- **Jackett** if you'd rather use it instead of Prowlarr (the dev.to
  article's original choice). Image: `lscr.io/linuxserver/jackett:latest`
  on port `9117`. You'd lose Prowlarr's auto-sync to Sonarr/Radarr; the
  earlier git history of this repo has a working Jackett configuration
  if you want to cherry-pick it back.

---

## VPN

Routing torrent traffic through a VPN is strongly recommended. This repo
ships a Gluetun-based override that routes **only qBittorrent** through the
VPN, leaving Sonarr/Radarr/Prowlarr/Overseerr on your LAN. That keeps:

- indexer queries and TMDB/TVDB lookups fast and unblocked,
- the web UIs reachable at their normal `localhost:*` ports,
- Plex auto-discovery on the LAN working.

If the VPN drops, qBittorrent loses all network access (built-in kill
switch). No IP leaks.

### Other options (and why I don't recommend them)

| Option | Verdict |
| --- | --- |
| **Gluetun container, qBit only** *(this repo)* | ✅ Recommended. Per-app, with kill switch. |
| Provider-specific containers (e.g. `bubuntux/nordlynx`) | ❌ Same idea as gluetun but worse — narrower, smaller community. |
| Windows-level VPN app ("always on") | ❌ Tunnels everything — breaks Sonarr/Radarr lookups, RDP, Plex remote access. |
| Router-level VPN (OpenWRT, pfSense) | ⚠️ Cleanest networking but requires capable router; tunnels everything from the mini-PC. |
| Tailscale / WireGuard | Different problem — for **inbound** remote access. Complementary, not a substitute. |

### Setup

1. Pick a provider [supported by Gluetun](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers) — Mullvad, ProtonVPN, AirVPN, PIA, NordVPN, Surfshark and ~25 more.
2. Get credentials:
   - **WireGuard providers** (Mullvad, ProtonVPN, AirVPN, …): generate a WireGuard config in your provider's dashboard, copy the private key and the assigned address.
   - **OpenVPN providers** (NordVPN, Surfshark, PIA, …): use your provider's *service* credentials (not your account login).
3. Edit `.env` (created by the setup script) and fill in the `VPN_*` block. `.env.example` has copy-paste templates for the three most common providers.
4. Start the stack with VPN enabled:
   ```powershell
   .\setup.ps1 -Vpn
   ```
   …or on Linux/macOS:
   ```bash
   ./setup.sh --vpn
   ```
   Under the hood this runs `docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d`.
5. **Verify the tunnel is up:**
   ```powershell
   docker exec gluetun wget -qO- https://ifconfig.me
   ```
   Should show your provider's IP, not your home IP.

### Migrating an existing install to gluetun

If you've already been running the stack for a while (qBittorrent on the
plain Docker bridge, Sonarr/Radarr configured with `host: qbittorrent`)
and now want to add the VPN, the path is:

1. **Add VPN credentials to `.env`** (see the NordVPN walkthroughs below
   for OpenVPN/WireGuard specifics). Make sure `LAN_SUBNET` matches your
   subnet — e.g. `192.168.1.0/24`.
2. **Disconnect any host-level VPN client** on the same provider before
   step 3 (NordVPN's Windows app, ProtonVPN client, etc.). Otherwise
   gluetun's outbound handshake goes *through* the host tunnel — same
   provider, double-NAT'd — and usually fails or behaves erratically.
   ```powershell
   # NordVPN GUI: tray icon → Disconnect; or use the CLI if you installed it.
   # If you also want it not to auto-connect on boot:
   #   Open NordVPN app → Settings → General → Auto-connect → Off
   ```
3. **Bring up the VPN stack.** This adds gluetun and re-creates the
   qBittorrent container inside gluetun's network namespace:
   ```powershell
   cd <folder with this README>
   docker compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
   ```
4. **Verify the egress.** From the mini-PC:
   ```powershell
   # Should print your provider's IP in the configured country —
   # NOT your home IP.
   docker exec qbittorrent wget -qO- https://ifconfig.me

   # Bonus: prove the kill switch works. Stop gluetun, then re-curl —
   # qBittorrent should lose connectivity instantly.
   docker stop gluetun
   docker exec qbittorrent wget -qO- --timeout=5 https://ifconfig.me   # should fail
   docker start gluetun
   ```
   > **After restarting gluetun, also recreate qBittorrent:** qBit shares
   > gluetun's network namespace, and when gluetun stops the netns is torn
   > down. Even after gluetun comes back, qBit is wedged with a dead
   > network until you recreate it: `docker rm -f qbittorrent && docker
   > compose -f docker-compose.yml -f docker-compose.vpn.yml up -d
   > qbittorrent`. Plain `docker restart` is *not* enough.
5. **Re-point Sonarr & Radarr's download client at `gluetun`** (the
   bootstrap auto-config only runs on first-time setup, so existing
   entries still point at `qbittorrent`). Two options:

   - **GUI:** Sonarr → Settings → Download Clients → click your
     qBittorrent entry → change **Host** from `qbittorrent` to `gluetun`
     → Test → Save. Repeat for Radarr.
   - **API one-liner** (run on the mini-PC; pulls the API keys from
     each service's `config.xml` and patches the existing entry in
     place):
     ```powershell
     foreach ($app in @{Sonarr=8989; Radarr=7878}.GetEnumerator()) {
       $cfg = "C:\Users\Kyle\media-server\config\$($app.Key.ToLower())\config.xml"
       $key = ([xml](Get-Content $cfg)).Config.ApiKey
       $port = $app.Value
       $clients = Invoke-RestMethod "http://127.0.0.1:$port/api/v3/downloadclient" `
                   -Headers @{ "X-Api-Key" = $key }
       foreach ($c in $clients | Where-Object implementation -eq QBittorrent) {
         ($c.fields | Where-Object name -eq host).value = "gluetun"
         Invoke-RestMethod "http://127.0.0.1:$port/api/v3/downloadclient/$($c.id)" `
           -Method Put -Headers @{ "X-Api-Key" = $key } `
           -ContentType "application/json" -Body ($c | ConvertTo-Json -Depth 6) | Out-Null
         "$($app.Key) download client #$($c.id): host -> gluetun"
       }
     }
     ```

6. **Sanity-check Sonarr/Radarr** can still talk to qBit: Settings →
   Download Clients → qBittorrent → **Test** → green ✓.

> #### Two gotchas you may hit during the recreate
>
> **qBittorrent crash-loops with "termination initiated" in
> `config/qbittorrent/qBittorrent/logs/qbittorrent.log` and never binds
> port 8080.** Cause: a *stale lockfile* from the previous (force-killed)
> qBit. New qBit sees the lockfile, assumes another instance is running,
> hands off via IPC, and exits cleanly within ~1 s. Fix:
> ```powershell
> docker stop qbittorrent
> Remove-Item -Force C:\Users\Kyle\media-server\config\qbittorrent\qBittorrent\lockfile,
>                    C:\Users\Kyle\media-server\config\qbittorrent\qBittorrent\ipc-socket
> docker start qbittorrent
> ```
>
> **Sonarr/Radarr show *"download client qBittorrent places downloads in
> /data/torrents/complete/tv but this directory does not appear to exist
> inside the container"*.** The category save paths only get created
> when a torrent first lands in them. Just `mkdir` them on the host:
> ```powershell
> New-Item -ItemType Directory -Force `
>   -Path C:\Users\Kyle\media-server\data\torrents\complete\tv,
>         C:\Users\Kyle\media-server\data\torrents\complete\movies
> ```
> Then in each *arr's UI: System → Health → click the warning → Refresh,
> or just wait for the next scheduled health check.

### Important wiring difference when VPN is on

The qBittorrent container shares Gluetun's network namespace, so it has **no
hostname of its own** on the Docker network. When configuring Sonarr/Radarr →
Download Clients → qBittorrent, set:

- **Host:** `gluetun`  *(not `qbittorrent`)*
- **Port:** `8080`

Everything else is unchanged. `setup.ps1 -Vpn` prints this reminder when it
finishes.

### Port forwarding (if you care about seeding ratio)

Some providers support inbound port forwarding (essential for being a seeder
on private trackers). Mullvad dropped this in 2023. Currently working:
**ProtonVPN, AirVPN, PIA, PrivateVPN**. Gluetun handles the port-forward
negotiation automatically for these; check
[the gluetun wiki](https://github.com/qdm12/gluetun-wiki/blob/main/setup/advanced/vpn-port-forwarding.md)
for how to feed the forwarded port back into qBittorrent.

NordVPN does **not** support port forwarding on any plan — fine for
downloading, but you'll do passive seeding only. If a private tracker
demands an active connection, you'd need to swap providers.

### NordVPN walkthrough

NordVPN supports both protocols. **OpenVPN is the easy path; WireGuard
(NordLynx) is ~50% lower CPU and faster.** Start with OpenVPN, switch
to WireGuard once it's working.

#### NordVPN with OpenVPN (5 minutes)

> These are **service credentials**, not your account email/password — Nord
> generates a separate user/pass for manual setups.

1. Log in to <https://my.nordaccount.com>.
2. Left sidebar → **NordVPN** → **Set up NordVPN manually** → **Service credentials**
   ([direct link](https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/service-credentials/)).
3. Copy the **Username** (long random string) and **Password** (click the eye to reveal).
4. Put them in `.env`:
   ```dotenv
   VPN_SERVICE_PROVIDER=nordvpn
   VPN_TYPE=openvpn
   OPENVPN_USER=<service username>
   OPENVPN_PASSWORD=<service password>
   VPN_COUNTRIES=Switzerland
   VPN_CATEGORIES=P2P
   ```
5. Run `.\setup.ps1 -Vpn`.

#### NordVPN with WireGuard (NordLynx)

NordVPN doesn't expose the WireGuard private key in the dashboard, so you
extract it with a one-shot container.

> **⚠ Security note:** The command below runs a third-party image
> (`ghcr.io/bubuntux/nordlynx`) with `--cap-add=NET_ADMIN` (elevated
> privileges) and passes your NordVPN access token as an environment variable.
> The token grants full access to your NordVPN account. Take these precautions:
>
> - **Use a short-lived token.** Generate a token with a short expiry (1 day
>   is enough — you only need it once to extract the key).
> - **Delete the token immediately** after step 2 from your NordVPN dashboard.
> - **Run the command in a private terminal window** and clear your history
>   afterwards (`Clear-History` in PowerShell; `history -c` in bash).
> - The extracted WireGuard private key is long-lived; store it in your `.env`
>   file (which is git-ignored) and nowhere else.

1. **Get an access token.** <https://my.nordaccount.com> → **NordVPN** →
   **Set up NordVPN manually** → **Access tokens** → **Generate new token**
   ([direct link](https://my.nordaccount.com/dashboard/nordvpn/access-tokens/)).
   Copy the token immediately — it's shown only once.

2. **Extract the WireGuard private key.** On your mini-PC, in PowerShell:
   ```powershell
   docker run --rm --cap-add=NET_ADMIN `
     -e TOKEN='<paste-your-token-here>' `
     ghcr.io/bubuntux/nordlynx:get_private_key
   ```
   After ~20 seconds it prints something like:
   ```
   ############################################################
   IP: 10.5.0.2/32
   Private Key: wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
   ############################################################
   ```
   > Known flakiness: sometimes prints "Connection failed" with an empty key
   > ([issue](https://github.com/qdm12/gluetun-wiki/issues/15)). Just re-run
   > it a couple of times.

3. **Configure `.env`:**
   ```dotenv
   VPN_SERVICE_PROVIDER=nordvpn
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=wOEI9rqqbDwnN8/Bpp22sVz48T71vJ4fYmFWujulwUU=
   WIREGUARD_ADDRESSES=10.5.0.2/32
   VPN_COUNTRIES=Switzerland
   VPN_CATEGORIES=P2P
   ```

4. Run `.\setup.ps1 -Vpn`. You can delete the access token from your
   NordVPN dashboard now — the WireGuard key is permanent (until you
   regenerate it via the same process).

#### Picking a country

NordVPN allows P2P on most countries; for best speeds and tracker
compatibility use: **Netherlands, Switzerland, Canada, Germany, Sweden,
Finland**. Avoid US/UK/AU/NZ/India.

#### Verifying

```powershell
docker exec gluetun wget -qO- https://ifconfig.me
```

Should print a NordVPN IP in your chosen country, **not** your home IP.

---

## TRaSH-Guides quality profiles (optional, via Recyclarr)

The Sonarr/Radarr defaults will happily grab the first 720p that matches
an indexer query. If you want **good** results — a proper 1080p WEB-DL
from a reputable release group, falling back gracefully, skipping known-
bad encoders — there's a community-maintained set of rules called the
**[TRaSH Guides](https://trash-guides.info/)**. Applying them by hand is
tedious; **[Recyclarr](https://recyclarr.dev/)** automates the whole
thing.

This repo ships an optional override that:
- Runs Recyclarr on a schedule (default: daily at 04:00).
- Pre-generates two configs using Recyclarr's own templates: `web-1080p`
  for Sonarr and `hd-bluray-web` for Radarr — sensible defaults for
  most people. Easy to swap if you want 4K/anime/etc.
- Auto-fills your Sonarr and Radarr URLs and API keys, so there's
  literally nothing to configure by hand on first run.

### Start it

```powershell
.\setup.ps1 -Recyclarr               # Recyclarr alone
.\setup.ps1 -Vpn -Telegram -Recyclarr   # everything together
```

On Linux/macOS: `./setup.sh --recyclarr` (compose-able with `--vpn`
and `--telegram`).

The script:
1. Generates `config/recyclarr/configs/web-1080p.yml` and
   `config/recyclarr/configs/hd-bluray-web.yml` from Recyclarr's
   built-in `config create --template`.
2. Patches in your real Sonarr/Radarr URLs and API keys (and only
   those two fields — your other edits in those files are preserved
   on re-runs).
3. Starts the container and runs an immediate first sync so you see
   results in seconds instead of waiting for the cron.

### What changes inside Sonarr/Radarr

After the first sync, open Sonarr → Settings → Profiles. You'll see
new entries:
- **WEB-1080p** in Sonarr (with ~38 custom formats scoring releases
  by quality, release group, etc.)
- **HD Bluray + WEB** in Radarr (similar).

Apply these to your shows/movies (right-click → Edit → set Quality
Profile) and Sonarr/Radarr will start preferring the better releases
on their next search.

### Customizing

Open `config/recyclarr/configs/*.yml` on the host. The files are heavily
commented — uncomment groups under `custom_format_groups:` to enable
extras (HDR scoring, audio preference, optional group), or change the
quality_profiles list. Re-run `docker exec recyclarr recyclarr sync` to
apply, or wait for the next 04:00 cron.

To switch to 4K: replace `web-1080p` with `web-2160p` and
`hd-bluray-web` with `uhd-bluray-web` (template names from
`docker exec recyclarr recyclarr config list templates`).

---

## Telegram requests

Want to add movies and TV shows from your phone without opening Overseerr?
This stack ships an optional [Searcharr](https://github.com/toddrob99/searcharr)
Telegram bot that talks directly to Sonarr and Radarr. Send `/movie inception`
in chat, pick from a carousel of results, hit "Add" — done.

### 1. Create a bot (2 minutes)

1. Open Telegram, search for **@BotFather**, click **Start**.
2. Send `/newbot`. Pick a display name (e.g. `My Media Server`) and a username
   ending in `bot` (e.g. `my_media_server_bot`).
3. BotFather replies with a token like `1234567890:AAH...` — **copy it**.
4. (Recommended) Send `/setjoingroups`, pick your bot, choose **Disable** —
   this prevents random group adds.

### 2. Put the token in `.env`

```dotenv
TELEGRAM_BOT_TOKEN=1234567890:AAH...
```

You can leave `TELEGRAM_BOT_PASSWORD` and `TELEGRAM_ADMIN_PASSWORD` blank —
the setup script generates strong random ones and shows them on completion.

### 3. Start the bot

```powershell
.\setup.ps1 -Telegram          # bot only
.\setup.ps1 -Vpn -Telegram     # bot + VPN
```
On Linux/macOS: `./setup.sh --telegram` (or `--vpn --telegram`).

The script:
- Auto-generates `config/searcharr/data/settings.py` using the Sonarr/Radarr
  API keys it already extracts. **No manual API-key copy-pasting.**
- Wires Searcharr to Sonarr at `http://sonarr:8989` and Radarr at
  `http://radarr:7878` via the internal Docker network (no host networking,
  no LAN IPs).
- Waits for both services to pass their `/ping` healthchecks before launching
  Searcharr, which does not retry a failed client initialization.
- Starts the low-space disk guard documented under
  [Automatic low-space guard](#automatic-low-space-guard-with-telegram).
- Prints the bot password at the end. Save it.

### 4. Use the bot

In Telegram, message your bot:

```
/start <password shown by the setup script>
/movie inception
/series severance
```

Tap the "Add" button on the result; Sonarr/Radarr take over from there.
Every item added via the bot is auto-tagged `telegram` in Sonarr/Radarr so
you can filter or set tag-specific rules later.

### Authentication model (read this)

This is important to understand because there is **no pre-configured
allowlist of Telegram users** — the password is the only thing standing
between your stack and any stranger who guesses your bot's name.

#### How it works

1. **Anyone on Telegram can find and DM your bot.** Bot usernames are
   public; there's no way to hide one.
2. **Without `/start <password>`, the bot ignores every message.** Other
   commands (`/movie`, `/series`, `/users`) silently do nothing for
   unauthenticated users.
3. **`/start <password>` self-enrols the sender.** Their Telegram user ID
   is written to a SQLite database at
   `config/searcharr/data/searcharr.db`, and from that moment on they can
   request content **without** the password.
4. **There are two passwords:**
   - `searcharr_password` — regular user. Can search & add content.
   - `searcharr_admin_password` — admin. Everything above plus `/users`
     (list, promote, revoke).
   Both are generated by the setup script and printed at the end.
5. **Every request is tagged with the requester's Telegram username** in
   Sonarr/Radarr (we set `sonarr_tag_with_username=True` and
   `radarr_tag_with_username=True`). Open any item in Sonarr/Radarr and
   the tag tells you who asked for it — built-in audit trail.

#### Adding a user

There's no GUI flow. To grant someone access:
1. Share the **user password** (not admin) with them privately.
2. Tell them your bot's username (e.g. `@my_media_server_bot`).
3. They DM the bot: `/start <password>`. Done — they're in.

#### Removing a user / changing your mind

DM the bot as an admin and send `/users`. You get an inline keyboard with
every enrolled user and a "Remove access" button per user. The user
remains a Telegram user, but the bot will ignore them again.

For a **full reset** (revoke everyone, force re-enrolment):
```powershell
docker stop searcharr
Remove-Item config\searcharr\data\searcharr.db
docker start searcharr
```
On Linux/macOS: `rm config/searcharr/data/searcharr.db`. Then rotate the
password by editing `config/searcharr/data/settings.py` (or delete it and
re-run the setup script to generate a fresh random one).

#### Lost the password?

It's stored in plaintext at `config/searcharr/data/settings.py`:
```powershell
Select-String -Path config\searcharr\data\settings.py -Pattern '^searcharr'
```
(`grep ^searcharr config/searcharr/data/settings.py` on Linux/macOS.)

#### Rotating the password without locking out existing users

Edit `searcharr_password` in `config/searcharr/data/settings.py`, then
`docker restart searcharr`. **Already-enrolled user IDs are preserved**
because they live in the SQLite DB, not in the settings file. Only new
`/start <password>` attempts need the new password.

#### What about a hardcoded allowlist of Telegram user IDs?

Searcharr doesn't support one out of the box. If you want stricter
control — e.g. only my partner and me, no possibility of self-enrolment
even if the password leaks — set a strong password, enrol the people you
trust, then **blank out the password** in `settings.py` (`searcharr_password = ""`)
and restart Searcharr. With an empty password, every new `/start` attempt
will fail to match, but the SQLite user table keeps your existing users.
Open an issue if you'd like this added as a first-class option.

### Security notes

- **The password is the entire perimeter.** Treat it like the root password
  for your media server — anyone who learns it can self-enrol from any
  Telegram account. See *Authentication model* above.
- **Never authenticate as admin in a group chat** — the password is visible
  to everyone present. Always DM the bot.
- **The bot token equals full control of the bot.** Treat it like a password.
  If leaked, send `/revoke` to BotFather to invalidate it, then update `.env`
  and re-run setup.
- The disk guard reads the token and enrolled user IDs from Searcharr's
  read-only data mount. It logs only recipient/torrent counts, never those
  secrets or identifiers.
- **Searcharr's data folder contains the token in plaintext** (`settings.py`).
  It lives under `config/searcharr/data/`, which is git-ignored. The setup
  script also `chmod 600`s it on Unix.
- Searcharr does **not** expose any inbound ports — it polls Telegram outbound.
  No firewall holes needed.

### Why not Overseerr's built-in Telegram?

Overseerr's Telegram integration only **sends notifications** to a channel
(e.g. "movie X is ready"). It does **not** accept incoming requests via chat.
For two-way request flow you need a separate bot like Searcharr.

If you want both — Searcharr for requesting + Overseerr notifications for
"ready to watch" alerts — that's fine; they don't conflict. Configure
Overseerr's Telegram channel separately under **Settings → Notifications →
Telegram**.

---

## Troubleshooting

| Problem                                        | Fix                                                                                                   |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Docker Desktop won't start (WSL / Hyper-V error) | Virtualization is disabled in BIOS. Reboot, enter BIOS, enable Intel VT-x / AMD-V (often called "SVM"). |
| Docker Desktop hangs at "Starting"             | `wsl --update` in an elevated PowerShell, then restart Docker Desktop.                                |
| Mini-PC unreachable after a few hours / overnight | Windows put it to sleep, hibernated it, or the network adapter powered down. See [Don't accidentally lock yourself out](#5-dont-accidentally-lock-yourself-out) — the `powercfg` block disables all of them. |
| `setup.ps1` blocked by execution policy        | `powershell -ExecutionPolicy Bypass -File .\setup.ps1`                                                |
| Sonarr/Radarr can't reach Prowlarr or qBittorrent | Use the **service name** as the hostname (`prowlarr`, `qbittorrent`), not `localhost` or `127.0.0.1`. |
| `disk-guard` is unhealthy | Run `docker logs disk-guard`. HTTP 403 means qBittorrent did not trust the Compose network; other explicit errors identify unavailable qBittorrent, Telegram, Searcharr DB, or state storage. The guard does not auto-resume anything after recovery. |
| `localhost:8989` / `localhost:7878` keeps opening a **native** Sonarr/Radarr you installed earlier (not the Docker container) | A native install owns the port; Docker silently fails to publish. Fix: [Already running Sonarr/Radarr natively on this machine?](#already-running-sonarrradarr-natively-on-this-machine) |
| Can't reach Sonarr/Radarr/Prowlarr/qBittorrent from another LAN device | By design — admin UIs are bound to `127.0.0.1` on the mini-PC. Use the SSH tunnel pattern in [Remote management](#remote-management-ssh). |
| Prowlarr: indexer red, error "Cloudflare challenge" | Add the FlareSolverr container (see Prowlarr section), then in Prowlarr → Settings → Indexers → Add Indexer Proxy → FlareSolverr with host `http://flaresolverr:8191/`. |
| Prowlarr: added an indexer but Sonarr/Radarr don't see it | Prowlarr → Settings → Apps → click the Sonarr/Radarr row → **Sync App Indexers** (or wait ~30 s for the next auto-sync). If still nothing, Test the connection and re-check the *arr API key. |
| Prowlarr: indexer was working, now red | Public trackers go down or change domains. Edit the indexer row, check for an updated URL; if there's no fix, disable the indexer and add an alternative. |
| Bazarr: no subtitles being downloaded | Check Settings → Sonarr/Radarr show a green ✓ Test result. Then Settings → Languages → Languages Profiles must have at least one profile, and Settings → Sonarr/Radarr must have that profile selected under "Defined Language Profile". |
| Bazarr: subtitle files exist but Plex doesn't show them | Plex picks up subtitle files at next scan. Wire Sonarr/Radarr → Connect → Plex (step 4c.5) so a scan happens on every import, or in Plex run Library → Scan Library Files. |
| `sudo ssh miniserver` fails with `Could not resolve hostname miniserver` | `sudo` runs as root, which reads root's `~/.ssh/config` (empty), not yours. Use `sudo ssh -F ~/.ssh/config miniserver`, or skip the alias: `sudo ssh -L 443:127.0.0.1:443 you@<mini-ip>`. Only needed when forwarding privileged ports (≤1023, e.g. 443 for the Caddy proxy). |
| qBittorrent password doesn't work next restart | The setup script's bootstrap rotates the temp password to a stable random one and prints it — keep that output. If you skipped bootstrap, change the temp password in **Settings → Web UI**; otherwise a new one is generated on every restart. |
| qBittorrent says "your IP has been banned" / you forgot the password | The bootstrap whitelists loopback, Docker, and private-LAN subnets so the brute-force ban never applies to trusted clients. If you ran `--no-bootstrap` (or hand-edited qBit), re-run `setup.ps1 -Bootstrap` (`./setup.sh --bootstrap`) — it'll rotate the password and re-apply the whitelist. To manually unblock: stop the container, edit `config/qbittorrent/qBittorrent/qBittorrent.conf`, clear `WebUI\BannedIPs=`, then start it back up. |
| Overseerr won't save Sonarr/Radarr connection  | Add at least one Root Folder + Quality Profile in Sonarr/Radarr first, then retry the Overseerr wizard. |
| Sonarr error "Remote path mapping"             | qBittorrent and Sonarr both see `/data/torrents/complete`, so no mapping is needed — make sure both root folders match. |
| Plex doesn't see new files                     | The bootstrap wires Sonarr/Radarr → Plex Connect so a scan fires on every import. If you opted out, in Plex run Library → Scan Library Files, then add the notifier by hand (step 4c.5) or re-run `setup.ps1 -Bootstrap`. The bootstrap is idempotent and will only add what's missing. |
| Plex unreachable from Sonarr/Radarr (Docker → native Plex) | Use host `host.docker.internal`, port `32400`. The `extra_hosts: ["host.docker.internal:host-gateway"]` block in `docker-compose.yml` makes that name resolve on Linux too (Docker Desktop maps it automatically). Allow Plex through Windows Firewall on private+public networks. |
| **With VPN:** Sonarr can't reach qBittorrent   | Change Host to `gluetun` in Sonarr/Radarr → Download Clients (qBit's network is shared with gluetun). If you're migrating an existing install, see [Migrating an existing install to gluetun](#migrating-an-existing-install-to-gluetun) for the API one-liner that patches both at once. |
| **With VPN:** containers can't reach anything  | Your LAN subnet probably isn't in `LAN_SUBNET`. Check with `ipconfig` (Windows) or `ip a` (Linux), then update `.env` and `docker compose restart gluetun`. |
| **With VPN:** torrents stuck at 0 B/s          | Provider blocks P2P on this server. Change `VPN_COUNTRIES`/`VPN_CITIES` to a P2P-allowed region in `.env`. |
| **Telegram:** bot doesn't reply                | Wrong token. Verify with `docker logs searcharr` — `InvalidToken` means the value in `.env` is wrong or revoked. |
| **Telegram:** bot ignores `/start`             | You must include the password: `/start <password>`. The password was printed by the setup script; find it in `config/searcharr/data/settings.py` if you lost it. |
| **Telegram:** Searcharr can't reach Sonarr/Radarr | Restart the bot after Sonarr/Radarr regenerate their API keys: `docker compose -f docker-compose.yml -f docker-compose.telegram.yml restart searcharr`. The keys are baked into `settings.py` at setup time. |
| **Telegram:** how do I remove a user I no longer trust? | DM the bot as an admin: `/users`, tap **Remove access**. For a full reset, stop Searcharr and delete `config/searcharr/data/searcharr.db`. |
| **Telegram:** I lost the password | `grep ^searcharr config/searcharr/data/settings.py` (or `Select-String -Path config\searcharr\data\settings.py -Pattern '^searcharr'`). |
