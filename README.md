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

## 1. Install Docker Desktop

```powershell
winget install Docker.DockerDesktop
```

Reboot if prompted, launch Docker Desktop once, and wait for the whale icon in
the system tray to stop animating.

## 2. Install Plex Media Server (native)

The article installs Plex natively on Windows — keep doing that, it gives you
the best hardware transcoding (Quick Sync / NVENC) and zero networking
headaches.

```powershell
winget install Plex.PlexMediaServer
```

When Plex asks for your library folders, point it at:

- **Movies** → `<MediaRoot>\movies`
- **TV Shows** → `<MediaRoot>\tv`

…where `<MediaRoot>` is the folder you'll pass to `setup.ps1` below (defaults
to `.\media` next to this README).

> Prefer Plex in Docker? Uncomment the `plex:` service in
> `docker-compose.yml`, set `PLEX_CLAIM` (get one at https://plex.tv/claim),
> and re-run `docker compose up -d`.

## 3. Run the setup script

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

On Linux / macOS, use `./setup.sh` instead.

---

## 4. Wire the services together

The infrastructure is up, but four config screens still need linking. The
setup script prints every value you need — keep its output handy. Each step
below maps to a section of the original article, just much shorter.

### qBittorrent (http://localhost:8080)

1. Log in as `admin` with the **temp password** the script printed.
2. **Settings → Web UI** → set a real username and password. Apply.
3. **Settings → Downloads**:
   - Default Save Path: `/downloads/complete`
   - Keep incomplete torrents in: `/downloads/incomplete`
   - Tick "Create subfolder for torrents with multiple files".
4. **Settings → BitTorrent**: tick "Torrent Queueing" and "Seeding Limits"
   (e.g. ratio 1.0, then "Remove torrent").

You can skip the WinRAR/rar-extract step from the article — qBittorrent
runs inside the container, so there's no host-side rar binary to call.
The *arr apps handle .rar imports for you.

### Jackett (http://localhost:9117)

1. **Add indexer** → search for the trackers you use (e.g. 1337x, EZTV, RARBG-mirrors), click the wrench, save.
2. The **API key** in the top-right is the same one the setup script printed.
3. Copy the **"All" Torznab feed URL**:
   `http://jackett:9117/api/v2.0/indexers/all/results/torznab`
   Note: inside the Docker network use the hostname `jackett`, **not**
   `127.0.0.1`. Sonarr/Radarr talk to Jackett over the internal network.

### Sonarr (http://localhost:8989) and Radarr (http://localhost:7878)

Both are configured identically — Radarr just stores movies instead of TV.

1. **Settings → Indexers → +** → **Torznab → Custom**
   - URL: `http://jackett:9117/api/v2.0/indexers/all/results/torznab`
   - API Key: (the Jackett key the script printed)
   - Categories: TV / Anime for Sonarr; Movies for Radarr.
2. **Settings → Download Clients → +** → **qBittorrent**
   - Host: `qbittorrent`  (the service name, not localhost)
   - Port: `8080`
   - Username / Password: whatever you set in qBittorrent above.
3. **Settings → Media Management → Root Folders → +**
   - Sonarr: `/tv`
   - Radarr: `/movies`
   - Tick "Rename Episodes" / "Rename Movies".
4. *(Optional)* **Settings → Connect → Plex Media Server** to auto-refresh
   the Plex library when downloads finish. Host `host.docker.internal`
   (Windows / Mac Docker Desktop) reaches your native Plex install.

### Overseerr (http://localhost:5055)

The first-run wizard walks you through it:

1. Sign in with your Plex account.
2. Point at your Plex server (`host.docker.internal:32400` if Plex is native).
3. Add Sonarr (`http://sonarr:8989`, API key from the script).
4. Add Radarr (`http://radarr:7878`, API key from the script).

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
| `setup.ps1` blocked by execution policy        | `powershell -ExecutionPolicy Bypass -File .\setup.ps1`                                                |
| Sonarr/Radarr can't reach Jackett or qBittorrent | Use the **service name** as the hostname (`jackett`, `qbittorrent`), not `localhost` or `127.0.0.1`. |
| qBittorrent password doesn't work next restart | You must change the temp password in **Settings → Web UI**; otherwise a new one is generated.         |
| Sonarr error "Remote path mapping"             | qBittorrent and Sonarr both see `/downloads`, so no mapping is needed — make sure both root folders match. |
| Plex doesn't see new files                     | In Plex: Library → Scan Library Files. Or wire **Sonarr/Radarr → Connect → Plex** to auto-refresh.    |
| **With VPN:** Sonarr can't reach qBittorrent   | Change Host to `gluetun` in Sonarr/Radarr → Download Clients (qBit's network is shared with gluetun). |
| **With VPN:** containers can't reach anything  | Your LAN subnet probably isn't in `LAN_SUBNET`. Check with `ipconfig` (Windows) or `ip a` (Linux), then update `.env` and `docker compose restart gluetun`. |
| **With VPN:** torrents stuck at 0 B/s          | Provider blocks P2P on this server. Change `VPN_COUNTRIES`/`VPN_CITIES` to a P2P-allowed region in `.env`. |
