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

- **VPN.** Run qBittorrent behind a VPN container (e.g.
  [`qmcgaw/gluetun`](https://github.com/qdm12/gluetun)) by setting
  `network_mode: "service:gluetun"` on the qbittorrent service. Without one,
  your home IP is visible to every peer.
- **Prowlarr** instead of Jackett — modern replacement that *auto-syncs*
  indexers to Sonarr/Radarr, eliminating the manual Torznab dance entirely.
  Image: `lscr.io/linuxserver/prowlarr:latest` on port `9696`.
- **Bazarr** for automatic subtitles
  (`lscr.io/linuxserver/bazarr:latest`, port `6767`).

---

## Troubleshooting

| Problem                                        | Fix                                                                                                   |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `setup.ps1` blocked by execution policy        | `powershell -ExecutionPolicy Bypass -File .\setup.ps1`                                                |
| Sonarr/Radarr can't reach Jackett or qBittorrent | Use the **service name** as the hostname (`jackett`, `qbittorrent`), not `localhost` or `127.0.0.1`. |
| qBittorrent password doesn't work next restart | You must change the temp password in **Settings → Web UI**; otherwise a new one is generated.         |
| Sonarr error "Remote path mapping"             | qBittorrent and Sonarr both see `/downloads`, so no mapping is needed — make sure both root folders match. |
| Plex doesn't see new files                     | In Plex: Library → Scan Library Files. Or wire **Sonarr/Radarr → Connect → Plex** to auto-refresh.    |
