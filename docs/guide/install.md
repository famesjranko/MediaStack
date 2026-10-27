# Install MediaStack

This guide is for a person who installs MediaStack for the first time.

## Before you start

You need:

- A Debian 12 or Debian 13 server (headless is fine).
- At least 50 GB of free disk space.
- An internet connection.
- Git and sudo installed.
- A user account that can use `sudo`.

For a NAS install, you also need the NAS address and the NFS export path.

## Install

1. Run these commands from your normal user account:

   ```bash
   git clone https://github.com/famesjranko/MediaStack.git MediaStack
   cd MediaStack
   ./mediastack
   ```

2. Read the menu. It looks like this on a new server:

   ![The MediaStack menu before install](../assets/mediastack-day1-menu.png)

3. Optional: choose **System readiness check (disk, RAM, internet, GPU)**. It tests the server before you install.
4. Choose **Install MediaStack**.
5. Answer the questions in the next section.
6. Choose **Install** on the last screen.

The install takes 5 to 7 minutes. At the end, the installer prints the access URLs.

The menu has two more checks for later: **Test port forwarding (router config)** and **Check domain DNS (verify subdomain A-records)**. You need them only for [remote access](remote-access.md).

For arrow-key menus, choose **Get enhanced menus (install GUM)**. The menu shows this item only when gum is missing.

If you stop the installer, run `./mediastack` again. Setup skips what is already done.

## What the installer asks

The installer detects your GPU and shows it before the first question. It asks the questions below in this order. After most sections, you choose **Use these details** or **Re-enter**.

1. **Admin identity.** Enter an admin username, an admin email, and an admin password.
   - The password needs 12 or more characters.
   - It must mix at least 2 of: lowercase, UPPERCASE, digits, symbols.
   - It must not contain a single quote.
   - MediaStack uses this login for the admin pages of the services.
2. **Storage.** Choose where MediaStack keeps media and downloads:
   - **Local disk** (recommended). MediaStack creates the folders under `/data`.
   - **Network/NAS storage (NFS).** MediaStack mounts the share and protects the services if the mount fails.
   - **Advanced manual storage.** MediaStack starts the apps but does not set their media paths.
   - **Quit installer.**

   For NAS, the installer asks for the mount point, the NAS address, and the export path. It tests the share before it asks anything else. See [Storage Modes](../setup/storage.md) for the NAS checks.
3. **Subtitles (Bazarr).** Choose yes or no for automatic subtitle downloads. If yes, enter the languages.
4. **File sharing (SMB).** Choose yes or no for a LAN file share. If yes, choose **Media files only** (recommended) or **Full system**.
5. **Library quality.** Choose a resolution (720p or 1080p) and a size (compact, balanced or large). The default is 1080p Balanced. See [Quality bounds](../setup/quality-bounds.md) for the file sizes.
6. **Search indexers.** Choose yes or no for the example public-tracker indexers. MediaStack ships with no trackers enabled. Add indexers only where you have the legal right to use them.
7. **Image channel.** Choose how MediaStack gets container images:
   - **Stable** (recommended). You install the image versions that this MediaStack release was tested against.
   - **Latest.** You install the newest upstream images. This is for advanced users. It gives faster updates and more risk. See [Image updates](../operations/upgrades.md).
8. **qBittorrent limits and peer port.** Enter a download limit and an upload limit in MB/s (0 means unlimited). Enter the peer port (default 6881).
9. **Security.** Choose yes or no for each of these:
   - The UFW firewall.
   - The admin-port filter. The installer asks this only if you decline the firewall or turned the filter off before.
   - System hardening (automatic security updates and kernel hardening).
10. **Confirm install plan.** Read the plan. Choose **Install**, **Back** or **Abort**.

Once the core stack is running, setup offers two optional steps:

1. **Hardware transcoding**, if a supported GPU is detected.
2. **Remote access**, including HTTPS and WireGuard. It needs a domain name and port forwarding. See [Remote access](remote-access.md).

You can skip either step. After install, run `./mediastack` to open the day-2 management menu. To add a skipped feature, choose **Manage hardware transcoding (GPU)** or **Features & settings** → **Add remote access (HTTPS, domain, WireGuard)**.

## What you get

MediaStack can run up to 20 containers. The default services start with the install. Other profiles start when you add the matching feature.

| Service | Port | Purpose | Profile |
|:--------|:-----|:--------|:--------|
| Homepage | 3000 | Dashboard with API widgets | default |
| Jellyfin | 8096 (7359/udp discovery) | Media server | default |
| Sonarr | 8989 | TV show management | default |
| Radarr | 7878 | Movie management | default |
| Jackett | 9117 | Torrent indexer proxy | default |
| qBittorrent | 8080 | Torrent client | default |
| FlareSolverr | 8191 | Cloudflare bypass | default |
| Seerr | 5055 | Media requests | default |
| Unpackerr | - | Extract archived downloads | default |
| Portainer | 9000 | Container management UI | default |
| Uptime Kuma | 3001 | Service health monitoring | default |
| Beszel Hub | 8090 | System resource dashboard | default |
| Beszel Agent | - | Host metrics collector (no network port) | default |
| Socket Proxy | - | Filtered Docker API for Beszel Agent and Autoheal | default |
| Autoheal | - | Restart unhealthy containers | autoheal |
| NPM (Nginx Proxy Manager) | 80, 443, 81 | Reverse proxy and SSL | proxy |
| Fail2ban | - | Brute-force protection | proxy |
| DDNS Updater | 8000 | Dynamic DNS | proxy |
| WireGuard | 51820/udp, 51821 | VPN with web UI | remote |
| Bazarr | 6767 | Subtitle management | subtitles |

The Autoheal container runs by default. To turn it off, set `AUTOHEAL_ENABLED=false` in `.env`, then stop the existing container:

```bash
docker compose --profile autoheal stop autoheal
```

Installed services restart after a reboot. Docker normally leaves manually stopped containers stopped; the NAS watchdog restarts missing NAS-dependent services after its startup check, except the ones you stopped from the menu. See [After a reboot](troubleshooting.md#after-a-reboot).

The installer also configures service accounts and connections. Downloads need configured indexers, and automatic subtitles need subtitle providers. Complete these choices under [After install](#after-install).

| Service | What the installer configures |
|:--------|:------------------------------|
| qBittorrent | Download paths, categories (`tv-sonarr`, `radarr`), speed limits, queueing |
| Jackett | FlareSolverr URL, admin password, indexers |
| Sonarr | Root folder, qBittorrent client, quality profile, file-size bounds, naming, optional indexers |
| Radarr | The same as Sonarr, for movies. Remux is excluded from every profile. |
| Bazarr | Connection to Sonarr and Radarr, a profile for your selected languages (subtitles profile only) |
| Jellyfin | Admin account, Movies and TV libraries; hardware transcoding when you enable the optional GPU step and verification succeeds |
| Seerr | Connection to Jellyfin, Sonarr and Radarr, admin approval, per-user quotas |
| Portainer | Admin user, local Docker endpoint |
| Homepage | Service groups with API widgets |
| Uptime Kuma | Admin account, HTTP monitors, status page, Homepage widget |
| NPM | Admin credentials, proxy hosts for `jellyfin.<your-domain>` and `seerr.<your-domain>` (proxy profile only) |
| WireGuard | Admin credentials, endpoint, access tier, one first peer (remote profile only) |

The admin pages use the admin username and password you entered. NPM and Beszel use the admin email with the same password. MediaStack finds the API keys and saves them for you.

Seerr uses the quality profile you chose for all requests. If you add a series or movie directly in Sonarr or Radarr, choose the profile yourself. Their built-in default is "Any".

## Data layout

MediaStack follows the [TRaSH Guides](https://trash-guides.info/) folder layout.

```text
/data/
|-- torrents/          # Download client writes here
|   |-- movies/
|   `-- tv/
`-- media/             # Organized media library
    |-- movies/        # Hardlinked from torrents/
    `-- tv/
```

Both folders must be on the same filesystem. Then a finished download and its library copy share one file on disk.

## After install

1. Open Homepage at `http://<server-ip>:3000`. It links Jellyfin, Seerr, downloads, automation and monitoring.

   ![The Homepage dashboard](../assets/mediastack-homepage.png)

2. If you skipped indexers, configure indexers you have permission to use before requesting downloads. To enable the bundled examples, choose **Features & settings (quality, bandwidth, subtitles, sharing, indexers)** → **Search indexers: OFF**. To add your own, see [Add an indexer or a library](using-the-menu.md#add-an-indexer-or-a-library).
3. If you enabled Bazarr, configure subtitle providers at `http://<server-ip>:6767/settings/providers` before using automatic subtitle downloads.
4. Use Seerr at `http://<server-ip>:5055` to request a show or movie.
5. Watch it in Jellyfin at `http://<server-ip>:8096` when the download finishes.

To see all URLs and logins again, run `./mediastack` and choose **View access info (URLs, logins, remote, ports)**.

### Family accounts

Create one Jellyfin account for each person. Do not share the admin login. For users, roles and Seerr permissions, see the [Jellyfin docs](https://jellyfin.org/docs/) and the [Seerr docs](https://docs.seerr.dev/).

### Seerr request limits

By default, the limits are 0 movies and 0 series per 7 days. In Seerr, 0 means unlimited, but each request still needs approval. To set a cap, change `seerr.quotas` in `config.yml`, then apply it as [Using the menu](using-the-menu.md) describes.

A change to the limit or the period is applied on the next run, and a limit of 0 removes an earlier cap. If Seerr does not keep the change, the run shows a warning.

### Share files on your LAN (SMB)

1. Run `./mediastack`.
2. Choose **Features & settings**.
3. Choose **File sharing (SMB)**.

| Share | Shows | Use for |
|:------|:------|:--------|
| `Media` | Your data folder | Media browsing and file management |
| `MediaStackSystem` | The whole filesystem (`/`) | Advanced use only |

- Windows: `\\<server-ip>\Media`
- macOS and Linux: `smb://<server-ip>/Media`
- Login: the admin username and password.
- With UFW enabled and incoming traffic denied by default, MediaStack permits SMB access from private networks. If you disable UFW, provide equivalent firewall protection. Do not forward port 445.

## Remove MediaStack

1. Run `./mediastack`.
2. Choose **Uninstall MediaStack**.
3. Read the list of what the uninstall removes and keeps.
4. Type `DESTROY` when the screen asks you to confirm.

The uninstall removes:

- The containers and host configuration owned by MediaStack.
- The `config/` runtime state: app databases, watch history and saved credentials.
- The generated `.env` and `config.yml` files.

The uninstall keeps media at your configured data path. Docker stays installed. Some edited host configuration files are preserved and can require manual cleanup, but this protection does not cover every generated file. Back up changes before uninstalling. If host cleanup fails, uninstall stops before removing runtime state so you can correct the problem and retry.

## See also

[Remote access](remote-access.md) · [Using the menu](using-the-menu.md) · [Troubleshooting](troubleshooting.md)
