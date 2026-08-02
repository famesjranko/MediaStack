# Configuration Schema

Reference for everything a user (or maintainer) can change about a running MediaStack.

## `config.yml` — service wiring

Top-level source of truth for service configuration. `scripts/configure.sh` reads it via Python YAML helpers ([configure-flow.md](configure-flow.md)).

`config.yml` is a **gitignored live copy** seeded from the tracked template `config/examples/config.yml` on first run (`seed_root_config`, first line of `run_wizard` in `scripts/setup/wizard.sh`), then mutated in place by the wizard (quality preset, `min_free_space_gb`, Jellyfin bitrate, `wizard_completed`). Re-runs keep your edits (seed is "only if absent"); uninstall removes it so a reinstall re-seeds the pristine template. To edit defaults for everyone, edit the template.

### `indexers`

List of Jackett indexers. Public releases default this to `[]`; add entries only for indexers you are legally allowed to use, or apply the optional preset from `config/examples/public-indexers.yml`. Each entry has `id` (Jackett's internal indexer ID) and `type` — one of `general`, `tv`, `movies`. Consumed by:

- Step 2 Jackett (`cfg_indexers` in `scripts/lib/common.sh`) — adds to Jackett.
- `configure_arr_indexers` (`scripts/lib/arr/main.sh`) — filters by type: Sonarr gets `general`+`tv`, Radarr gets `general`+`movies`. Each add is retried up to 3× with 8s backoff to absorb FlareSolverr cold-start timeouts during first-run setup.

An empty list is valid. Jackett still receives its admin password and FlareSolverr URL, while Sonarr/Radarr skip Torznab wiring.

### `categories`

Fallback Torznab category IDs for Sonarr/Radarr indexer registration.

- `tv: "5000,5030,5040"` — TV, TV/SD, TV/HD.
- `movies: "2000,2030,2040"` — Movies, Movies/SD, Movies/HD.

`configure_arr_indexers` (`scripts/lib/arr/main.sh`, delegating to `scripts/lib/arr/render/torznab_caps.py`) **auto-discovers categories from each indexer's Torznab caps** first. Radarr gets 2xxx + movie-native IDs, Sonarr gets 5xxx + TV-native IDs. Many trackers use native 100xxx IDs that standard Torznab doesn't cover — without them, the *arr app's add-time test rejects the indexer. These `config.yml` values are the fallback when caps discovery fails.

Stored as a stringified comma-list (`"5000,5030,5040"`), parsed via inline Python split in `configure_arr_indexers`; that keeps the shared-helper contract a single string field instead of a YAML list of integers.

### `quality_profile`

> See [`docs/reference/quality-bounds.md`](../reference/quality-bounds.md) for the actual file-size and format-score numbers across all cells, the resolution × size model, and the SD floor.

Shared between Sonarr and Radarr. The setup wizard (`scripts/setup/wizard.sh`) **composes** this section from a `(resolution × size)` cell the user picks — a resolution (the ceiling) × a size (the file-size envelope). The profile name is `"{resolution} {size}"` (e.g. `1080p Balanced`, the shipped default). The **authoring** model lives in `scripts/setup/presets.yml` (three top-level maps: `quality_ids`, `resolutions`, `sizes`) and is composed by `scripts/setup/wizard_apply.py:compose_cell`; the `config.yml` **output shape below is unchanged** from the old single-preset model, so the renderer (`render/*.py`) is untouched.

| | Compact | Balanced | Large |
|---|---|---|---|
| **720p** (cutoff 1001) | `720p Compact` | `720p Balanced` | `720p Large` |
| **1080p** (cutoff 1002) | `1080p Compact` | `1080p Balanced` (default) | `1080p Large` |

Each cell enables every tier from the **SD floor** (SDTV/DVD/480p) up to the resolution's ceiling, all sources; the cutoff (a WEB group) stops upgrades at the ceiling, so SD/720p are fallbacks that upgrade away. The size axis sets only the per-tier bounds + scores (source-agnostic).

| Field | Meaning |
|-------|---------|
| `name` | Profile display name, also the key used for idempotency checks. |
| `cutoff_id` | **Group** ID (1000+), not a quality ID. Sonarr/Radarr reject sub-quality IDs as cutoffs. The mapping table is in the `quality_profile` section comments in `config.yml`. |
| `upgrade_allowed` | Whether upgrades continue above the currently-matched quality. |
| `sonarr_qualities` | List of quality IDs allowed for TV. |
| `radarr_qualities` | List of quality IDs allowed for movies. |

Remux-1080p (ID 30) is deliberately excluded across all presets — see [`docs/reference/quality-bounds.md`](../reference/quality-bounds.md) for rationale.

Consumed by `configure_quality_profile` (`scripts/lib/arr/main.sh`, with Python profile transform at `scripts/lib/arr/render/quality_profile.py`) and the Seerr *arr connection helpers (`scripts/services/seerr/main.sh`) which look up the profile by name.

### `quality_definitions`

> See [`docs/reference/quality-bounds.md`](../reference/quality-bounds.md) for the per-size bounds tables.

Per-tier file-size bounds (MB per minute of runtime — Sonarr per episode, Radarr per movie). Overrides Sonarr/Radarr's stock defaults, which are loose enough to let in both 400 MB cam rips and 25 GB bloat releases. Values come from the chosen **size** axis (`compact ≈ 0.7×`, `balanced 1.0×`, `large ≈ 1.2×`), masked to the resolution's enabled tiers — calibrated to real-world WEB-DL/Bluray ranges, not the TRaSH max-quality values, which target much larger files.

Structure: `quality_definitions.{sonarr,radarr}.<QualityName>: { min, preferred, max }`. Keys must match Sonarr/Radarr's internal quality names exactly (case-sensitive): `SDTV`, `WEBDL-480p`, `HDTV-720p`, `WEBDL-1080p`, `Bluray-1080p`, etc. Tiers not listed keep their upstream defaults. Delete or comment the whole section to opt out entirely.

Example (`1080p Balanced`, SD floor → 1080p):
```yaml
quality_definitions:
  sonarr:
    SDTV:         { min: 1.0,  preferred: 8.0,  max: 25.0 }   # SD floor
    HDTV-720p:    { min: 12.0, preferred: 30.0, max: 50.0 }
    WEBDL-1080p:  { min: 12.0, preferred: 45.0, max: 75.0 }
    Bluray-1080p: { min: 30.0, preferred: 60.0, max: 90.0 }
  radarr:
    SDTV:         { min: 1.0,  preferred: 8.0,  max: 25.0 }   # SD floor
    WEBDL-1080p:  { min: 4.0,  preferred: 50.0, max: 80.0 }
    Bluray-1080p: { min: 10.0, preferred: 65.0, max: 90.0 }
```

Consumed by `configure_quality_definitions` (`scripts/lib/arr/main.sh`, with diff helper at `scripts/lib/arr/render/quality_definitions.py`) during steps 3 and 4, after `configure_quality_profile`. Idempotent — reads the live set via `GET /api/v3/qualitydefinition`, compares with a small float tolerance, `PUT`s only the tiers that differ.

### `custom_formats`

Release-attribute scoring that **steers** selection within a quality tier. A simple `name: score` mapping where higher scores are preferred and negative scores penalise. Scores do **not** gate file size (the `quality_definitions` bounds do) and, by default, nothing is hard-blocked — the neutral baseline penalises low-quality re-encode groups and nudges toward named releases, without ever refusing a grab. Set a format's score to `0` to make it neutral, or to `-10000` to **hard-block** it (no default format does). Delete the entire section to skip custom format configuration. See [`quality-bounds.md`](../reference/quality-bounds.md#custom-format-scores).

Format *definitions* (regex conditions, implementation type) are developer-managed in `scripts/lib/arr/custom_formats.yml` — users only tune scores here.

Example:
```yaml
custom_formats:
  "Repack/Proper":  5
  "x264":           0
  "x265 (HD)":      0
  "BR-DISK":        0
  "LQ":             -100
  "No-RlsGroup":    -10
  "Obfuscated":     -10
```

Consumed by `configure_arr_custom_formats` and `configure_arr_format_scores` (`scripts/lib/arr/main.sh`) during steps 3 and 4. `configure_arr_custom_formats` creates format definitions via `POST /api/v3/customformat` (skips if already present by name). `configure_arr_format_scores` attaches scores to the quality profile via `PUT /api/v3/qualityprofile/{id}` — only when the profile's `formatItems` is empty (treated as CREATE). Non-empty `formatItems` that differ triggers a drift warning, not reconciliation.

The setup wizard writes size-appropriate scores via `wizard_apply.py`. Per-size values are defined in `scripts/setup/presets.yml` under each size's `custom_format_scores` key.

### `min_free_space_gb`

Minimum free disk space (in GB) before Sonarr and Radarr stop importing and grabbing new releases. Applied as `minimumFreeSpaceWhenImporting` (in MB) in each app's global Media Management config (`/api/v3/config/mediamanagement`). This is a global setting, not per-root-folder.

| Field | Value |
|-------|-------|
| Type | integer |
| Default | `20` (= 20480 MB) |
| Disable | Set to `0` (restores the upstream 100 MB default) |

Consumed by `configure_arr_disk_threshold` (`scripts/lib/arr/main.sh`) during steps 3 and 4. Only applied on first run (when the value is the API default of 100 MB). If the user has changed the value in the UI, configure.sh warns on drift but does not reconcile.

### `qbittorrent`

Passed directly to `POST /api/v2/app/setPreferences`:

| Field | Consumed as |
|-------|-------------|
| `save_path` | `save_path` |
| `temp_path` | `temp_path` (with `temp_path_enabled:true`) |
| `max_ratio` | `max_ratio` (with `max_ratio_enabled:true`) |
| `max_seeding_time` | `max_seeding_time` (minutes; with `max_seeding_time_enabled:true`) |
| `max_active_downloads` | `max_active_downloads` |
| `max_active_uploads` | `max_active_uploads` |
| `max_active_torrents` | `max_active_torrents` |
| `dl_speed_limit` | `dl_limit` (converted from MB/s to bytes/s; `.env QBT_DL_LIMIT` overrides) |
| `ul_speed_limit` | `up_limit` (converted from MB/s to bytes/s; `.env QBT_UL_LIMIT` overrides) |
| `categories` | `name:path` pairs → `POST /api/v2/torrents/createCategory` per entry |

**Not configurable here:** `max_ratio_act`, `bypass_auth_subnet_whitelist`, connection limits — hardcoded in the `setPreferences` payload in `scripts/services/qbittorrent/main.sh`. See [configure-flow.md](configure-flow.md) Step 1 for why `max_ratio_act` is pinned to pause.

### `sonarr` / `radarr`

Minimal per-*arr settings — the rest comes from `quality_profile` / `categories` / `indexers`:

- `root_folder` — `/data/media/tv` or `/data/media/movies`. Must exist; `setup.sh` creates it during directory initialization.
- `download_client_category` — the qBittorrent category name. Must match a key in `qbittorrent.categories`.

### `bazarr`

Bazarr subtitle management settings. Only active when the `subtitles` profile is enabled (`BAZARR_ENABLED=true` in `.env`).

| Field | Meaning |
|-------|---------|
| `languages` | List of subtitle languages to enable (e.g. `english`). Used to seed the language profile in Bazarr's SQLite database on first run. |

Consumed by `configure_bazarr` (`scripts/services/bazarr/main.sh`) and `cfg_bazarr_languages` (`scripts/lib/common.sh`).

### `jellyfin.server_name`

Display name shown in the Jellyfin Dashboard header and browser tab. Defaults to `"MediaStack"`. Consumed by `configure_jellyfin_server_name` (`scripts/services/jellyfin/main.sh`) which applies the value via GET-merge-POST on `/System/Configuration`. On re-run, if the name has been changed in the UI to something other than the docker default, configure.sh warns about drift and does not overwrite.

### `jellyfin.remote_bitrate_limit`

Per-remote-viewer streaming bitrate cap in Mbps. `0` means unlimited. Set by the setup wizard (speed test → viewer count → recommendation) or manually in `config.yml`. Maps to Jellyfin's `RemoteClientBitrateLimit` (in bits/sec, so the configured Mbps value is multiplied by 1,000,000).

Consumed by `configure_jellyfin_streaming` (`scripts/services/jellyfin/main.sh`) which applies the value via GET-merge-POST on `/System/Configuration`. This setting is authoritative — config.yml always wins (unlike GPU encoding, which warns on drift).

### `jellyfin.libraries`

List of `{name, type, path}`. `type` is Jellyfin's `collectionType` (`movies`, `tvshows`). Consumed by `configure_jellyfin_libraries` (`scripts/services/jellyfin/main.sh`). Library name is URL-encoded when posted.

### `rate_limiting`

Optional nginx rate limiting for internet-facing proxy hosts (Jellyfin, Seerr) via NPM's advanced config. **Disabled by default** (`enabled: false`) for parity with upstream Jellyfin/Seerr, neither of which rate-limits — a blanket server-level limit applies to every path including media streaming, so a multi-device household behind one NAT'd residential IP can hit 429s mid-playback (and the `[npm-ratelimit]` jail could then ban the household's own public IP). Login brute-force is covered regardless by the 401/403 auth jails.

| Field | Default | Meaning |
|-------|---------|---------|
| `enabled` | `false` | Master switch. When `false`, no `limit_req_zone` is written, no `limit_req` is injected into proxy hosts, and the `[npm-ratelimit]` jail-verify is skipped. The fields below apply only when `true`. |
| `requests_per_second` | `15` | Sustained request rate per IP. Written as an nginx `limit_req_zone` directive in NPM's `http_top.conf`. |
| `burst` | `60` | Burst bucket size. Absorbs page-load spikes via `limit_req burst=N nodelay` in each proxy host's advanced config. |
| `ban_maxretry` | `10` | Number of 429 responses within `ban_findtime` that triggers a fail2ban ban. Validated against the `[npm-ratelimit]` jail in `mediastack.conf` (drift is warned, not reconciled). |
| `ban_findtime` | `60` | Window in seconds for accumulating `ban_maxretry` 429s. |

Consumed by `configure_npm` (`scripts/services/npm/main.sh`). When `enabled: true` it:
1. Writes the `limit_req_zone` directive to NPM's `http_top.conf`.
2. Injects `limit_req` directives into each proxy host's `advanced_config`.
3. Reloads nginx inside the NPM container to activate.
4. Checks that the `[npm-ratelimit]` jail values in `config/fail2ban/jail.d/mediastack.conf` match `ban_maxretry` / `ban_findtime`.

When `enabled: false` (the default), each of those steps logs a skip. To re-enable, set `enabled: true` **and** set `enabled = true` on the `[npm-ratelimit]` jail in `config/fail2ban/jail.d/mediastack.conf`. The proper future fix is per-path exemption (a second zone + per-`location` config) so streaming/image paths are never limited.

---

## `.env.example` — secrets and host values

`.env.example` is the template; `.env` is generated by `setup.sh` (chmod 600). The API-key fields near the end of `.env.example` ship empty; `configure.sh` populates them on install. A user who copies `.env.example` to `.env` directly, skipping `setup.sh`, still ends up with a working file — but `.env.example` is then documenting "initial state" as much as "template", which is worth remembering when editing it.

### User-set (interactive prompts in `setup.sh`)

| Key | Default source | Example |
|-----|---------------|---------|
| `TZ` | `timedatectl` | `America/Los_Angeles` |
| `PUID` / `PGID` | `id -u` / `id -g` | `1000` / `1000` |
| `DATA_DIR` | prompt, default `/data` | `/mnt/media` |
| `HOST_ADDRESS` | `hostname -I` | `192.168.1.50` |
| `IMAGE_CHANNEL` | wizard prompt, default `stable` | `stable` or `latest` |
| `MEDIASTACK_NETWORK_PREFIX` | setup network collision check | `172.28.0` |
| `MEDIASTACK_SUBNET` | derived from prefix | `172.28.0.0/24` |
| `MEDIASTACK_GATEWAY` | derived from prefix | `172.28.0.1` |
| `MEDIASTACK_NPM_IP` | derived from prefix | `172.28.0.10`; Jellyfin `KnownProxies` trusts this IP when remote HTTPS is ready |
| `STORAGE_MODE` | prompt, default `local` | `local` or `nas`; controls mount/sentinel protection |
| `STORAGE_APP_WIRING` | prompt, default `managed` | `managed` or `manual`; controls whether MediaStack configures app storage paths |
| `STORAGE_WATCHDOG` | prompt when NAS selected + day-2 toggle, default `true` | `true` or `false`; gates the guard + `mediastack-storage-watchdog.service`. Absent = enabled (existing NAS installs stay protected) |
| `UNPACKERR_TORRENT_PATHS` | setup, default `/data/torrents` | watched torrent path for Unpackerr; blank when `STORAGE_APP_WIRING=manual` |
| `STORAGE_PROTOCOL` | prompt when NAS selected | `nfs` |
| `STORAGE_MOUNTPOINT` | prompt when NAS selected | `/data` |
| `STORAGE_NFS_HOST` / `STORAGE_NFS_EXPORT` | prompt when NAS selected | `192.168.1.10` / `/mnt/tank/media` |
| `STORAGE_SENTINEL` | generated from `DATA_DIR` (not user-set) | `/data/.mediastack-storage-ready` |
| `JELLYFIN_ADMIN_USER` | prompt, default `admin` | `admin` |
| `JELLYFIN_ADMIN_PASSWORD` | `openssl rand -base64 12` — shared across all services | (random) |
| `NPM_ADMIN_EMAIL` | `admin@example.com` (not prompted) | — |
| `JELLYFIN_GPU` | Hardware transcoding proof | `nvidia`, `intel`, `amd`, `none` |
| `NVIDIA_DRIVER_MODE` | Hardware transcoding (NVIDIA) | `standard` (Debian-managed, default), `unlock` (patch-managed `.run` + nvidia-patch), `existing` (a non-Debian driver kept as-is), or empty. Primary NVIDIA driver state; "patch enabled" is **derived** (true iff `unlock`) — there is no separately-settable `NVIDIA_PATCH_ENABLED` (a legacy value migrates to `unlock`). |
| `STAGE_3_GPU_STATE` / `STAGE_3_GPU_VENDOR` / `STAGE_3_GPU_ENCODER` | Hardware transcoding state | `complete` / `nvidia` / `nvenc` |
| `STAGE_3_GPU_HW_DECODING_CODECS` | Hardware codec probes | `h264,hevc,vp9` |
| `STAGE_3_GPU_DECODE_HEVC_10BIT` / `STAGE_3_GPU_DECODE_VP9_10BIT` | Hardware codec probes | `true` or `false` |
| `STAGE_3_GPU_ALLOW_HEVC_ENCODING` / `STAGE_3_GPU_ALLOW_AV1_ENCODING` | Hardware codec probes | `true` or `false` |
| `STAGE_3_GPU_RENDER_DEVICE` | Intel/AMD render-node probe | `/dev/dri/renderD128` |
| `DOMAIN` | prompt, blank to skip remote | `example.com` |
| `DDNS_PROVIDER` | Stage 2 DDNS picker, blank if DDNS skipped | `dynu`, `duckdns`, `desec`, `dynv6`, `cloudflare`, `porkbun` |
| `WG_HOST` | `${DOMAIN}` | `example.com` |
| `WG_INIT_PASSWORD` | plaintext `JELLYFIN_ADMIN_PASSWORD` (first-boot only) | `'GeneratedPassword123'` |
| `WG_DEFAULT_DNS` | default `1.1.1.1` | `1.1.1.1` |
| `WG_ACCESS_TIER` | wizard prompt: `full-lan` / `server` / `containers` (`streaming` / `streaming-requests` are README templates) | `full-lan` |
| `WG_LAN_CIDR` | wizard prompt (Full LAN tier): detected default, RFC1918 only | `192.168.1.0/24` |
| `WG_SERVER_LAN_IP` | mirrors `HOST_ADDRESS`; `/32` target for server/containers/streaming/streaming-requests tiers | `192.168.1.50` |
| `WG_INIT_ALLOWED_IPS` | derived from tier → initial peer routing | `192.168.1.0/24` |
| `WG_PER_CLIENT_FIREWALL` | default `true`; setting to `false` is the documented full-tunnel escape hatch | `true` |
| `BAZARR_ENABLED` | prompt, default `false` | `true` |
| `PUBLIC_INDEXERS_ENABLED` | wizard prompt, default `false` | `true` |
| `SMB_ENABLED` | prompt, default `false` | `true` |
| `SMB_SHARE_SCOPE` | prompt after enabling SMB, default `data` | `data` or `system` |
| `UFW_ENABLED` | Stage 1 prompt + day-2 toggle, default `true` (recommended) | `true` |
| `HARDENING_ENABLED` | Stage 1 prompt + day-2 toggle, default `true` (recommended) | `true` |

**DDNS credentials:** the Stage 2 DDNS picker writes only the non-secret `DDNS_PROVIDER` to `.env`. The provider's credentials (Dynu username/password, DuckDNS/dynv6/deSEC tokens, Cloudflare zone-id + token, Porkbun API keys) live solely in the chmod-600 `config/ddns-updater/config.json` rendered by `ddns_render_config_json` — never in `.env`. A wizard re-run recalls the provider from `DDNS_PROVIDER` and pre-fills its credential prompts from that config.json.

**Single-quoting rule:** `WG_INIT_PASSWORD` MUST be single-quoted because the plaintext value can contain shell-special characters (`$`, `"`, `\`, `#`) that Docker Compose interpolates in unquoted values. `setup.sh` writes the quotes automatically; the smoke test (`tests/scenarios/smoke.sh`) asserts the container receives the password byte-for-byte via `INIT_PASSWORD`. v15 reads `INIT_*` env vars at first boot only — after `/etc/wireguard/wg-easy.db` exists, changes to `WG_INIT_PASSWORD` are inert; rotate the admin password in the wg-easy UI instead.

**SMB scope:** `SMB_SHARE_SCOPE=data` shares `${DATA_DIR}` as `Media` and is the recommended default. `SMB_SHARE_SCOPE=system` keeps the intentional full `/` admin share available as `MediaStackSystem`.

**Host security toggles:** `UFW_ENABLED` gates the UFW firewall (default-deny inbound + the Docker-port restriction chain); `HARDENING_ENABLED` gates unattended security upgrades + kernel sysctl hardening. Both are chosen in the Stage 1 wizard (default *yes*) and are reversible from the day-2 **Features & settings** menu. Reading code treats an **absent** key as `true`, so installs predating these keys stay hardened after an upgrade. Turning a toggle *off* in the day-2 menu reverts via the ownership ledger (`_uninstall_ufw` / `_uninstall_sysctl` / `_uninstall_apt`): it removes only MediaStack-owned rules/files and never touches firewall rules or sysctls the user changed themselves.

**Storage modes:** `local` is the standard managed `/data` layout. `nas` means MediaStack mounts/verifies NFS storage and, when `STORAGE_WATCHDOG` is on (default), runs the guard + storage watchdog. The watchdog is opt-out in the Stage 1 wizard and reversible from the day-2 **Features & settings** menu (NAS installs only); with it off, NAS storage is still mounted and verified once at install but data services are not auto-stopped/restarted if the mount drops. NAS sentinel and managed directory writes are made as the installing user when possible so root-squashed NFS exports work. `manual` is represented by `STORAGE_APP_WIRING=manual`: the stack is installed but storage-facing app configuration is skipped so the user can wire Jellyfin, Sonarr/Radarr, qBittorrent, Seerr, and Unpackerr manually. Manual app wiring can still use `STORAGE_MODE=nas` when the user wants NAS guard/watchdog protection. See [storage.md](storage.md) for the operational flow and guard/watchdog behavior.

**VPN access tiers:** The wizard asks for an access tier instead of a tunnel mode. `WG_INIT_ALLOWED_IPS` (client-side routing) and the wg-easy server-side `firewallIps` for the initial peer are both derived from the tier. Per-client firewall is on for every new install.

| Tier | Client `AllowedIPs` (routing) | Server `firewallIps` (enforcement) | Audience |
|------|-----------------------|--------------------|----------|
| `full-lan` | `<WG_LAN_CIDR>` (detected, RFC1918) | `<WG_LAN_CIDR>` — whole LAN, all ports | Owner/admin |
| `server` | `<WG_SERVER_LAN_IP>/32` | `<WG_SERVER_LAN_IP>/32` — all ports incl. host SSH/SMB | Co-admin |
| `containers` | `<WG_SERVER_LAN_IP>/32` | Enumerated MediaStack container ports at the server IP; **51821 (wg-easy admin) excluded** | Trusted household |
| `streaming` | `<WG_SERVER_LAN_IP>/32` | `<WG_SERVER_LAN_IP>:8096/tcp` — Jellyfin only | Friends/kids, watch-only (README template, not an initial-peer choice) |
| `streaming-requests` | `<WG_SERVER_LAN_IP>/32` | `<WG_SERVER_LAN_IP>:8096/tcp`, `:5055/tcp` — Jellyfin + Seerr | Friends/kids, watch + request (README template, not an initial-peer choice) |

**Advanced — full-tunnel routing.** Set **both** `WG_INIT_ALLOWED_IPS='0.0.0.0/0, ::/0'` AND `WG_PER_CLIENT_FIREWALL=false` in `.env` before first boot. Both are required because per-client firewall would otherwise drop the now-routed traffic. The configurator emits a warning if `WG_PER_CLIENT_FIREWALL=false` is combined with a non-`full-lan` tier (almost certainly user error).

In v15 the per-client firewall is enforced inside the wg-easy container regardless of the WireGuard interface name, and `INIT_PORT` propagates the wizard-chosen `WG_PORT` end-to-end (listen port, `wg0.conf`, compose binding). No host-side iptables FORWARD rules are needed.

### Auto-populated (by `configure.sh`)

| Key | Populated in step | By |
|-----|-------------------|-----|
| `SONARR_API_KEY` | 3 | `scripts/services/sonarr/main.sh` (read from `config/sonarr/config.xml`) |
| `RADARR_API_KEY` | 4 | `scripts/services/radarr/main.sh` (read from `config/radarr/config.xml`) |
| `JELLYFIN_API_KEY` | 5 | `scripts/services/jellyfin/main.sh` (AccessToken from auth response, saved as a permanent API key via `/Auth/Keys`) |
| `JELLYFIN_PUBLISHED_URL` | 5 | `scripts/services/jellyfin/main.sh` (`configure_jellyfin_networking` — `https://jellyfin.<DOMAIN>` when DOMAIN set, else `http://<HOST_ADDRESS>:8096`) |
| `BAZARR_API_KEY` | (conditional) | `scripts/services/bazarr/main.sh` (read from `config/bazarr/config/config.yaml`; only when subtitles profile is active) |
| `SEERR_API_KEY` | 6 | `scripts/services/seerr/main.sh` (from `apiKey` field of `GET /api/v1/settings/main`) |
| `PORTAINER_API_KEY` | 7 | `scripts/services/portainer/main.sh` (persistent access token via `POST /api/users/1/tokens`) |

Unpackerr reads `SONARR_API_KEY` / `RADARR_API_KEY` and `UNPACKERR_TORRENT_PATHS` from env (set in the `unpackerr` service definition in `docker-compose.yml`), which is why `configure.sh` restarts it after API key population for managed app wiring. Homepage reads all seven API keys/credentials from `.env` to generate `services.yaml` with live widgets.

---

## Pre-seeded configs (tracked in git)

These service configs are shipped with the repo. They live under `config/` but survive the `.gitignore` sweep described below.

### `config/fail2ban/jail.d/mediastack.conf`

| Section | Content |
|---------|---------|
| `[DEFAULT]` | `ignoreip`: `127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16`. **10.0.0.0/8 is deliberate** — wg-easy hands out 10.8.0.0/24 to peers, and VPN peers are trusted friends/family. Ban 30 min after 5 failures in 30 min, with progressive ban increments (factor 2, max 24h). `banaction = iptables-allports` on `chain = DOCKER-USER` — single-box, all services behind Docker. |
| `[jellyfin]` | `logpath = /var/log/jellyfin/log_*.log`. |
| `[npm]` | Two log globs: `default-host_*.log` + `proxy-host-*_*.log`. |
| `[seerr]` | `logpath = /var/log/seerr/*.log`. |
| `[npm-ratelimit]` | **Disabled by default** (`enabled = false`) — companion to `config.yml`'s `rate_limiting.enabled`. `logpath = /var/log/npm/proxy-host-*_*.log`. When enabled, catches IPs that accumulate 429 (Too Many Requests) responses from nginx `limit_req`; overrides `[DEFAULT]` with `maxretry = 10`, `findtime = 60` (validated against `config.yml`'s `rate_limiting.ban_maxretry` / `ban_findtime` by `configure_npm` — drift is warned, not reconciled). Uses the `npm-ratelimit` filter (see below). |

Log paths are mounted read-only from the producing service's config dir (fail2ban volume mounts in `docker-compose.yml`).

These globs are resolved to concrete files only at jail start / `fail2ban-client reload`. Jellyfin and Seerr roll to a new date-stamped file (`log_YYYYMMDD.log`) each day, so a long-running host needs a reload after each rollover or the jail keeps tailing the previous day's file. On proxy-profile installs the `mediastack-fail2ban-reload.service` watcher (`scripts/fail2ban-reload-watcher.sh`) does this automatically — it reloads fail2ban whenever a new log file appears. The day-2 health menu's *fail2ban jellyfin watch* metric flags a jail left on a stale file if the watcher ever stops.

### `config/fail2ban/filter.d/jellyfin.conf`

```
failregex = ^.*Authentication request for ".*" has been denied \(IP: "<ADDR>"\).*
```

Matches Jellyfin's auth-failure log format.

### `config/fail2ban/filter.d/npm.conf`

```
failregex = \s(401|403)\s.*\[Client <ADDR>\]
```

Matches NPM's nginx access-log format (v2.12+): `[$time] $cache $upstream_status $status - $method $scheme $host "$uri" [Client $addr]`. The status code appears **before** `[Client]` in the log line, so the regex matches the status first, then extracts the IP. This has drifted before; keep the filter aligned with the current image log format.

### `config/fail2ban/filter.d/seerr.conf`

```
failregex = .*\[warn\]\[(API|Auth)\]\: Failed sign-in attempt.*"ip":"<HOST>"
```

Matches current Seerr warning records for both Jellyfin authentication (`Auth`) and local-password authentication (`API`). The `fail2ban-drift` DinD scenario exercises both forms.

### `config/fail2ban/filter.d/npm-ratelimit.conf`

```
failregex = \s429\s.*\[Client <ADDR>\]
```

Matches 429 (Too Many Requests) responses in NPM's nginx access log. Same log format as `npm.conf` — status appears before `[Client]`. Paired with the `[npm-ratelimit]` jail to ban IPs that repeatedly trigger nginx `limit_req` rate limits (configured via `config.yml`'s `rate_limiting` section). The filter ships in place but is inert by default because rate limiting is disabled, so nginx emits no 429s to match.

### `config/jackett/Jackett/ServerConfig.json`

Pre-seeded with `FlareSolverrUrl: http://flaresolverr:8191` so Jackett knows how to use the Cloudflare bypass immediately. Empty `APIKey`, `AdminPassword`, `InstanceId` fields — Jackett generates them on first start, then `get_api_key` in `scripts/lib/common.sh` reads them.

### `config/qbittorrent/qBittorrent/qBittorrent.conf`

Baseline preferences applied before qBittorrent even starts. `scripts/services/qbittorrent/main.sh` then overwrites managed storage paths via API with values from `config.yml` using a Python `json.dumps` payload. The pre-seeded file intentionally avoids MediaStack-specific save paths so advanced manual app wiring starts neutral.

Notable entries:

| Setting | Why |
|---------|-----|
| `Session\GlobalMaxRatio=1` | 100% share ratio. |
| `Session\MaxRatioAction=0` | `0`=pause, `1`=remove torrent (keep files), `3`=remove everything. Pre-seed matches the API-applied value. Sonarr/Radarr's download-client validator rejects anything other than `0`. |
| `WebUI\AuthSubnetWhitelist=172.16.0.0/12` + `AuthSubnetWhitelistEnabled=true` | Docker bridge IPs. `LocalHostAuth=false` alone only covers 127.0.0.1. |
| CSRF + clickjacking protection headers | Hardened WebUI security defaults. |
| `WebUI\LocalHostAuth=false` | Required for subnet whitelist to be the only auth bypass. |
| `WebUI\ServerDomains=*` | Allows access via NPM's reverse proxy. |

### `config/qbittorrent/qBittorrent/categories.json`

An empty object:

```json
{}
```

Managed app wiring creates category names and save paths from `qbittorrent.categories` in `config.yml`; category *names* must match `sonarr.download_client_category` / `radarr.download_client_category`.

---

## `.gitignore` — the negation gotcha

The problem: service config dirs are gitignored because they hold runtime state, but a few pre-seeded files inside them must be tracked.

Naive attempt (does NOT work):

```gitignore
config/*/
!config/jackett/Jackett/ServerConfig.json
```

Once the parent directory `config/jackett/` is ignored, nothing inside it can be un-ignored — git never descends into ignored directories to find the negation.

Actual pattern (runtime config exclusions in `.gitignore`):

```gitignore
# Service runtime configs (generated by containers)
config/jellyfin/
config/sonarr/
config/radarr/
config/seerr/
config/unpackerr/
config/homepage/services.yaml
config/homepage/logs/
config/npm/
config/wireguard/

# qBittorrent runtime data (keep pre-seeded defaults)
config/qbittorrent/qBittorrent/data/
config/qbittorrent/qBittorrent/ipc-socket
config/qbittorrent/qBittorrent/lockfile
config/qbittorrent/qBittorrent/config/
```

Rule: **list each service dir explicitly**. `config/jackett/`, `config/qbittorrent/` (except the listed subpaths), and `config/fail2ban/` are *not* in the ignore list — so their pre-seeded tracked files stay visible to git.

Adding a new service with tracked config therefore means:

1. Create `config/<service>/` with the files to track.
2. Add exactly the runtime subpaths to `.gitignore` — not the whole service dir.
