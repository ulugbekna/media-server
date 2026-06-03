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
# Defaults: media/, downloads/, config/ next to this README
.\setup.ps1

# Or pick your own locations (large drives recommended):
.\setup.ps1 -MediaRoot D:\media -DownloadsRoot D:\downloads -ConfigRoot D:\media-server\config
```

The script will:

1. Verify Docker Desktop is running.
2. Create the folder layout (`movies/`, `tv/`, `downloads/{complete,incomplete}`, per-service `config/`).
3. Write a `.env` file with your paths.
4. `docker compose pull && docker compose up -d`.
5. Wait for every service to respond, then print:
   - the qBittorrent first-run **admin password** (extracted from container logs),
   - the auto-generated **API keys** for Prowlarr, Sonarr, and Radarr,
   - the in-container paths to use when configuring each app.

**Keep the script's final output open in a window** — you'll paste those
values into the web UIs in step 4. If you lose them, just re-run the
script; it's idempotent and will reprint them.

On Linux / macOS, use `./setup.sh` instead.

## 3. Finish the Plex first-run wizard

Now that the media folders exist, open Plex (it should already be running
as a Windows service; if not, launch *Plex Media Server* from the Start
menu and click the tray icon → *Open Plex*).

1. Sign in with a Plex account (free).
2. **Windows Defender Firewall will prompt for permission** — allow on
   both private and public networks if you want LAN devices (phones, TVs)
   to discover the server.
3. Server name: anything; tick *"Allow me to access my media outside my home"*.
4. **Add Library → Movies** → folder: `<MediaRoot>\movies`.
5. **Add Library → TV Shows** → folder: `<MediaRoot>\tv`.
6. Finish the wizard. Plex will be empty for now — files will appear once
   Sonarr/Radarr download something in step 4.

> Prefer Plex in Docker? Uncomment the `plex:` service in
> `docker-compose.yml`, set `PLEX_CLAIM` (get one at https://plex.tv/claim,
> valid for 4 minutes), and re-run `docker compose up -d`. You lose easy
> hardware transcoding on Windows; not recommended.

---

## 4. Wire the services together

The infrastructure is up, but four config screens still need linking. The
setup script prints every value you need — keep its output handy. Each step
below maps to a section of the original article, just much shorter.

> **Do these in the order below.** Each step depends on values produced
> by the previous one (Prowlarr pushes indexers into Sonarr/Radarr; Sonarr/Radarr
> Root Folders must exist before Overseerr will accept them).

### 4a. qBittorrent (http://localhost:8080)

1. Log in as `admin` with the **temp password** the script printed.
2. **Tools → Options → Web UI** (or *Settings → Web UI* depending on theme):
   - Set a real **username and password**. Click **Save**.
   - **Important:** the LSIO image generates a new temp password on every
     container restart **unless** you've changed it here. Write your
     new password down now.
3. **Tools → Options → Downloads**:
   - Default Save Path: `/downloads/complete`
   - Keep incomplete torrents in: `/downloads/incomplete`
   - Tick "Create subfolder for torrents with multiple files".
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

This is where Prowlarr earns its keep — you do this **once**, then every
future indexer you add appears in both *arr apps automatically.

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

> **Indexers are auto-added by Prowlarr** if you completed step 4b's
> "Wire Prowlarr into Sonarr and Radarr" section. Skip step 1 below if
> so — Settings → Indexers should already show what you set up in Prowlarr.

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
   - Sonarr: `/tv`
   - Radarr: `/movies`
   - Tick "Rename Episodes" / "Rename Movies".
4. **Settings → Profiles** (Sonarr) / **Settings → Quality** (Radarr):
   defaults are fine. If you want 1080p-only or 4K-only, edit the
   "HD-1080p" / "Ultra-HD" profile and use that on new shows/movies.
5. *(Optional)* **Settings → Connect → Plex Media Server** to auto-refresh
   the Plex library when downloads finish. Host: `host.docker.internal`
   (Windows / Mac Docker Desktop reaches your native Plex install through
   this magic hostname). Port: `32400`. Click **Authenticate with Plex.tv**.

Do **both Sonarr and Radarr** before moving to Overseerr — Overseerr's
wizard won't accept them otherwise.

### 4d. Bazarr (http://localhost:6767)

Bazarr auto-downloads subtitles for every show and movie Sonarr/Radarr
manages. It mounts the same `/tv` and `/movies` folders so it can write
subtitle files next to the video files.

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

---

## Day-to-day commands

```powershell
docker compose ps              # what's running
docker compose logs -f sonarr  # tail a service
docker compose restart radarr  # restart one service
docker compose down            # stop everything (keeps data)
docker compose pull; docker compose up -d   # upgrade all images
```

To uninstall completely: `docker compose down -v` and delete the `config/`,
`downloads/`, and `media/` folders.

### Backup

The `config/` folder contains everything irreplaceable — API keys, indexer
setups, your list of monitored shows, watch history. **Back it up.** Easy
options:

- Copy `config/` to OneDrive / Dropbox once a week.
- Or, after `docker compose down`, zip `config/` and upload it.
- The `media/` folder you can re-download; `downloads/` is throwaway.

---

## Remote management (SSH)

> **You'll need this.** The security hardening binds Sonarr, Radarr, Prowlarr
> and qBittorrent to `127.0.0.1` on the mini-PC — they're not reachable from
> other LAN devices by design. If the mini-PC lives in a closet, this section
> is how you reach those UIs from your Mac/laptop.

The idea: **SSH into the mini-PC and tunnel each web UI back to your local
machine**, so opening `http://localhost:8989` on your Mac actually hits
Sonarr on the mini-PC, end-to-end encrypted, with no exposed ports.

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

### 3. Tunnel every web UI in one command

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
    # Forward every web UI in the media stack:
    LocalForward 8989 localhost:8989
    LocalForward 7878 localhost:7878
    LocalForward 9696 localhost:9696
    LocalForward 8080 localhost:8080
    LocalForward 6767 localhost:6767
    LocalForward 5055 localhost:5055
    LocalForward 8000 localhost:8000
    # Keep the connection healthy on flaky Wi-Fi:
    ServerAliveInterval 30
    ServerAliveCountMax 4
```

Now you just type `ssh miniserver` and every UI is available on your Mac.
Open the URLs above in your browser; configure Sonarr, add Prowlarr indexers,
manage qBittorrent — all over an encrypted tunnel.

### 5. Don't accidentally lock yourself out

- **Disable sleep** on the mini-PC (Control Panel → Power Options → set
  "Put the computer to sleep" to **Never** on the active plan). Otherwise
  it'll go unreachable until you walk to the closet to nudge the mouse.
- **Don't disable the network adapter on lid close / monitor unplug.** Some
  mini-PCs ship with this enabled — check Device Manager → your network
  adapter → Properties → Power Management.
- **Enable auto-login on boot** (Settings → Accounts → Sign-in options →
  alternatively `netplwiz` and uncheck "Users must enter a user name and
  password"). Necessary so Docker Desktop starts after a power blip without
  needing a keyboard plugged in.
- **Test reboot-and-recover end-to-end** before you put the PC in the
  closet: reboot it, walk away, and confirm everything comes back up over
  SSH within ~2 minutes.

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
| `setup.ps1` blocked by execution policy        | `powershell -ExecutionPolicy Bypass -File .\setup.ps1`                                                |
| Sonarr/Radarr can't reach Prowlarr or qBittorrent | Use the **service name** as the hostname (`prowlarr`, `qbittorrent`), not `localhost` or `127.0.0.1`. |
| Can't reach Sonarr/Radarr/Prowlarr/qBittorrent from another LAN device | By design — admin UIs are bound to `127.0.0.1` on the mini-PC. Use the SSH tunnel pattern in [Remote management](#remote-management-ssh). |
| Prowlarr: indexer red, error "Cloudflare challenge" | Add the FlareSolverr container (see Prowlarr section), then in Prowlarr → Settings → Indexers → Add Indexer Proxy → FlareSolverr with host `http://flaresolverr:8191/`. |
| Prowlarr: added an indexer but Sonarr/Radarr don't see it | Prowlarr → Settings → Apps → click the Sonarr/Radarr row → **Sync App Indexers** (or wait ~30 s for the next auto-sync). If still nothing, Test the connection and re-check the *arr API key. |
| Prowlarr: indexer was working, now red | Public trackers go down or change domains. Edit the indexer row, check for an updated URL; if there's no fix, disable the indexer and add an alternative. |
| Bazarr: no subtitles being downloaded | Check Settings → Sonarr/Radarr show a green ✓ Test result. Then Settings → Languages → Languages Profiles must have at least one profile, and Settings → Sonarr/Radarr must have that profile selected under "Defined Language Profile". |
| Bazarr: subtitle files exist but Plex doesn't show them | Plex picks up subtitle files at next scan. Wire Sonarr/Radarr → Connect → Plex (step 4c.5) so a scan happens on every import, or in Plex run Library → Scan Library Files. |
| qBittorrent password doesn't work next restart | You must change the temp password in **Settings → Web UI**; otherwise a new one is generated.         |
| Overseerr won't save Sonarr/Radarr connection  | Add at least one Root Folder + Quality Profile in Sonarr/Radarr first, then retry the Overseerr wizard. |
| Sonarr error "Remote path mapping"             | qBittorrent and Sonarr both see `/downloads`, so no mapping is needed — make sure both root folders match. |
| Plex doesn't see new files                     | In Plex: Library → Scan Library Files. Or wire **Sonarr/Radarr → Connect → Plex** to auto-refresh.    |
| Plex unreachable from Sonarr/Radarr (Docker → native Plex) | Use host `host.docker.internal`, port `32400`. Allow Plex through Windows Firewall on private+public networks. |
| **With VPN:** Sonarr can't reach qBittorrent   | Change Host to `gluetun` in Sonarr/Radarr → Download Clients (qBit's network is shared with gluetun). |
| **With VPN:** containers can't reach anything  | Your LAN subnet probably isn't in `LAN_SUBNET`. Check with `ipconfig` (Windows) or `ip a` (Linux), then update `.env` and `docker compose restart gluetun`. |
| **With VPN:** torrents stuck at 0 B/s          | Provider blocks P2P on this server. Change `VPN_COUNTRIES`/`VPN_CITIES` to a P2P-allowed region in `.env`. |
| **Telegram:** bot doesn't reply                | Wrong token. Verify with `docker logs searcharr` — `InvalidToken` means the value in `.env` is wrong or revoked. |
| **Telegram:** bot ignores `/start`             | You must include the password: `/start <password>`. The password was printed by the setup script; find it in `config/searcharr/data/settings.py` if you lost it. |
| **Telegram:** Searcharr can't reach Sonarr/Radarr | Restart the bot after Sonarr/Radarr regenerate their API keys: `docker compose -f docker-compose.yml -f docker-compose.telegram.yml restart searcharr`. The keys are baked into `settings.py` at setup time. |
| **Telegram:** how do I remove a user I no longer trust? | DM the bot as an admin: `/users`, tap **Remove access**. For a full reset, stop Searcharr and delete `config/searcharr/data/searcharr.db`. |
| **Telegram:** I lost the password | `grep ^searcharr config/searcharr/data/settings.py` (or `Select-String -Path config\searcharr\data\settings.py -Pattern '^searcharr'`). |
