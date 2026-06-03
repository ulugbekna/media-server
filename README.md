# Home media server — easy mode

A drop-in, one-command Docker setup for the stack from
[this dev.to article](https://dev.to/rafaelmagalhaes/home-media-server-with-plex-sonarr-radarr-qbitorrent-and-overseerr-2a84):

| Service      | Purpose                              | URL                     |
| ------------ | ------------------------------------ | ----------------------- |
| Jackett      | Indexer proxy for torrent trackers   | http://localhost:9117   |
| qBittorrent  | Torrent download client              | http://localhost:8080   |
| Sonarr       | TV-show automation                   | http://localhost:8989   |
| Radarr       | Movie automation                     | http://localhost:7878   |
| Overseerr    | Pretty request UI on top of *arr     | http://localhost:5055   |
| Plex         | Media server (installed natively)    | http://localhost:32400  |

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
   - the auto-generated **API keys** for Jackett, Sonarr, and Radarr,
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
> by the previous one (Jackett's API key feeds Sonarr/Radarr; Sonarr/Radarr
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

### 4b. Jackett (http://localhost:9117)

1. **Add indexer** → search for the trackers you use (e.g. 1337x, EZTV,
   Nyaa, RARBG-mirrors), click the wrench, save.
2. The **API key** in the top-right is the same one the setup script printed.
3. The unified Torznab feed you'll paste into Sonarr/Radarr next is:
   `http://jackett:9117/api/v2.0/indexers/all/results/torznab`
   Note: inside the Docker network use the hostname `jackett`, **not**
   `127.0.0.1`. Sonarr/Radarr talk to Jackett over the internal network.

### 4c. Sonarr (http://localhost:8989) and Radarr (http://localhost:7878)

Both are configured identically — Radarr just stores movies instead of TV.

1. **Settings → Indexers → +** → **Torznab → Custom**
   - URL: `http://jackett:9117/api/v2.0/indexers/all/results/torznab`
   - API Key: (the Jackett key the script printed)
   - Categories: leave at defaults — Sonarr v4 / Radarr v5 filter
     automatically based on what they're searching for.
   - Click **Test**, then **Save**. A green tick means Jackett answered.
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

### 4d. Overseerr (http://localhost:5055)

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

## Recommended add-ons

- **VPN** — see [VPN](#vpn) below. Strongly recommended for torrent traffic.
- **Prowlarr** instead of Jackett — modern replacement that *auto-syncs*
  indexers to Sonarr/Radarr, eliminating the manual Torznab dance entirely.
  Image: `lscr.io/linuxserver/prowlarr:latest` on port `9696`.
- **Bazarr** for automatic subtitles
  (`lscr.io/linuxserver/bazarr:latest`, port `6767`).

---

## VPN

Routing torrent traffic through a VPN is strongly recommended. This repo
ships a Gluetun-based override that routes **only qBittorrent** through the
VPN, leaving Sonarr/Radarr/Jackett/Overseerr on your LAN. That keeps:

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

## Troubleshooting

| Problem                                        | Fix                                                                                                   |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Docker Desktop won't start (WSL / Hyper-V error) | Virtualization is disabled in BIOS. Reboot, enter BIOS, enable Intel VT-x / AMD-V (often called "SVM"). |
| Docker Desktop hangs at "Starting"             | `wsl --update` in an elevated PowerShell, then restart Docker Desktop.                                |
| `setup.ps1` blocked by execution policy        | `powershell -ExecutionPolicy Bypass -File .\setup.ps1`                                                |
| Sonarr/Radarr can't reach Jackett or qBittorrent | Use the **service name** as the hostname (`jackett`, `qbittorrent`), not `localhost` or `127.0.0.1`. |
| qBittorrent password doesn't work next restart | You must change the temp password in **Settings → Web UI**; otherwise a new one is generated.         |
| Overseerr won't save Sonarr/Radarr connection  | Add at least one Root Folder + Quality Profile in Sonarr/Radarr first, then retry the Overseerr wizard. |
| Sonarr error "Remote path mapping"             | qBittorrent and Sonarr both see `/downloads`, so no mapping is needed — make sure both root folders match. |
| Plex doesn't see new files                     | In Plex: Library → Scan Library Files. Or wire **Sonarr/Radarr → Connect → Plex** to auto-refresh.    |
| Plex unreachable from Sonarr/Radarr (Docker → native Plex) | Use host `host.docker.internal`, port `32400`. Allow Plex through Windows Firewall on private+public networks. |
| **With VPN:** Sonarr can't reach qBittorrent   | Change Host to `gluetun` in Sonarr/Radarr → Download Clients (qBit's network is shared with gluetun). |
| **With VPN:** containers can't reach anything  | Your LAN subnet probably isn't in `LAN_SUBNET`. Check with `ipconfig` (Windows) or `ip a` (Linux), then update `.env` and `docker compose restart gluetun`. |
| **With VPN:** torrents stuck at 0 B/s          | Provider blocks P2P on this server. Change `VPN_COUNTRIES`/`VPN_CITIES` to a P2P-allowed region in `.env`. |
