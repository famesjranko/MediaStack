# `scripts/configure.sh` — Auto-Configuration Flow

Reads `config.yml`, wires up every service via its HTTP API, and writes generated API keys back into `.env`. Safe to re-run after editing `config.yml` — every step is individually idempotent. `--only svc1,svc2,...` restricts the run to named services (docker-compose names); used by the test suite for faster re-runs.

`configure.sh` is a **thin entrypoint**. The work lives in `scripts/lib/*` helpers and one directory per service under `scripts/services/<svc>/`. `main()` in `scripts/configure.sh` runs 11 fixed configure steps in order (after per-service readiness waits), plus conditional Bazarr configuration when the subtitles profile is active, conditional Beszel configuration when its default-stack containers are running, then recreates Unpackerr with the populated API keys.

When `STORAGE_APP_WIRING=manual`, configure.sh still sets credentials, auth, indexers, quality profiles, and non-storage services, but skips storage-facing wiring: qBittorrent save paths/categories, Sonarr/Radarr root folders and download clients, Jellyfin libraries, Seerr setup, Sonarr/Radarr Jellyfin notifications, and Unpackerr recreate. The generated `.env` also leaves `UNPACKERR_TORRENT_PATHS` blank so the compose-level Unpackerr integration does not advertise MediaStack's managed `/data/torrents` path. This is separate from `STORAGE_MODE`: manual app wiring can still use `STORAGE_MODE=nas` so the NAS sentinel guard and watchdog protect containers.

## File layout

```
scripts/
├── configure.sh              # thin entrypoint: env load, lib+service sourcing, main() orchestration
├── lib/
│   ├── common.sh             # colours, logging, cfg_* YAML readers, api_get/api_post/api_put, *_api_key helpers
│   ├── http.sh               # wait_for_service, http_json_body, http_json_post (cookie-session POST with body capture)
│   ├── json.sh               # json_get, json_path, json_has_name, json_array_nonempty
│   └── arr/
│       ├── main.sh           # configure_quality_profile, configure_quality_definitions, configure_arr_custom_formats, configure_arr_format_scores, configure_arr_indexers, configure_arr_disk_threshold
│       ├── custom_formats.yml         # curated TRaSH Guides format definitions
│       ├── render/
│       │   ├── quality_profile.py       # rebuild items[]/formatItems based on enabled quality IDs
│       │   ├── quality_definitions.py   # diff live vs config, emit <id>\t<put-body> per needed update
│       │   ├── custom_formats.py        # diff existing vs defined, emit <name>\t<post-body> per new format
│       │   ├── format_scores.py         # compare profile formatItems, emit match/empty/drift status
│       │   └── torznab_caps.py          # parse caps XML → filtered category list per app
│       └── templates/
│           └── indexer.json  # legacy static template; variable JSON is rendered with Python/http_json_body
└── services/
    ├── qbittorrent/main.sh              # no templates — setPreferences payload built inline via python3 json.dumps
    ├── jackett/main.sh                  # no templates — mostly auth loops, no extractable payloads
    ├── sonarr/main.sh    + templates/download-client.json
    ├── radarr/main.sh    + templates/download-client.json
    ├── bazarr/main.sh                   # no templates — API payloads built via python3 json.dumps
    ├── jellyfin/main.sh, wizard.sh, encoding.sh, server.sh, network.sh + render/network_policy.py + templates/{startup-config,remote-access,library}.json
    ├── seerr/main.sh + templates/{sonarr-server,radarr-server}.json
    ├── portainer/main.sh                # no templates — payloads built inline via python3 json.dumps
    ├── homepage/main.sh
    ├── npm/main.sh       + templates/token-default.json
    ├── uptime-kuma/main.sh
    └── beszel/main.sh
```

**Template rendering convention:** Variable-bearing JSON payloads are built with `python3 json.dumps` or the `http_json_body` helper so quotes, backslashes, `$`, and control characters are escaped safely. Static payload files with no variable substitution may be posted directly with `curl -d @file`.

Growth paths are documented in `docs/project/structure.md`. The service-loader loop in `scripts/configure.sh` supports both `services/<svc>/main.sh` (directory form, used by all services) and legacy flat `services/<svc>.sh`. Genuine cross-service orchestration lands in `scripts/flows/*.sh`.

## Top-level structure

- **`set -uo pipefail`** — **`-e` is deliberately OFF**. The comment above the `set` line explains: each step handles its own errors; a single 4xx from one step must not abort the remaining steps.
- `.env` is sourced early in `scripts/configure.sh`. `config.yml` is validated immediately after — invalid YAML exits immediately.
- `scripts/lib/common.sh` is sourced next, providing colour/log helpers and `cfg_*` YAML readers to every downstream module.

## YAML helpers (`cfg_*` functions in `scripts/lib/common.sh`)

All wrap `python3 -c "import yaml; …"` so the configurator doesn't need a bash YAML parser:

| Helper | Purpose | Returns |
|--------|---------|---------|
| `cfg KEY` | Generic scalar or list | `path.to.key` — prints scalar or joined list values |
| `cfg_field KEY` | Like `cfg` but always scalar (no list flattening) | Single value |
| `cfg_indexers` | Jackett indexer list | `id:type` lines |
| `cfg_quality_ids APP` | Quality IDs for sonarr/radarr | JSON array string `[1,2,3]` consumed by `render/quality_profile.py` |
| `cfg_quality_definitions APP` | Per-tier size bounds (opt-in `quality_definitions:` section) | JSON object `{"HDTV-720p":{...}}` consumed by `render/quality_definitions.py` |
| `cfg_custom_format_scores` | Custom format name→score map (opt-in `custom_formats:` section) | JSON object `{"Repack/Proper":5,...}` consumed by `render/custom_formats.py` and `render/format_scores.py` |
| `cfg_qbt_categories` | qBittorrent categories | `name:path` lines |
| `cfg_jf_libraries` | Jellyfin libraries | `name:type:path` lines |

All are parsed fresh each call — no caching. For a file this small it doesn't matter.

## API / service helpers

Split across `lib/common.sh` (auth + API key management) and `lib/http.sh` (service readiness + response-capture POSTs):

- `wait_for_service NAME URL` in `scripts/lib/http.sh` — 90-second curl loop; used only by `main()` before the 10 steps.
- `api_get URL KEY` / `api_post URL KEY BODY` / `api_put URL KEY BODY` in `scripts/lib/common.sh` — curl wrappers for *arr APIs with `X-Api-Key` header. `api_put` is used by `configure_quality_definitions` to update individual quality definitions; `api_post` for everything else.
- `api_get_key PATH` in `scripts/lib/common.sh` — regex-extract `<ApiKey>` from Sonarr/Radarr `config.xml`.
- `api_get_jackett_key` in `scripts/lib/common.sh` — JSON parse `config/jackett/Jackett/ServerConfig.json`.
- `env_save_api_key NAME VALUE` in `scripts/lib/common.sh` — `sed -i` writes into `.env`, logs if changed. Also `export` so later steps in the same invocation see the new value without re-sourcing.
- `http_json_post LABEL ENDPOINT PAYLOAD COOKIEJAR` in `scripts/lib/http.sh` — POST JSON within a cookie-authenticated session and surface the rejection body on non-2xx. Hoisted from a nested function inside the old Seerr step during the refactor; explicit `COOKIEJAR` arg (4th) because bash dynamic scoping was its only prior binding.

## Pre-step wait (top of `main()` in `scripts/configure.sh`)

`main()` runs `wait_for_service` against the 10 user-facing services (including Portainer and Uptime Kuma). Each times out after 90s (configured in `wait_for_service`) — if any service never comes up, the step still runs and fails its API check later.

## Step 1 — qBittorrent (`configure_qbittorrent` in `scripts/services/qbittorrent/main.sh`)

**Auth:** Three-tier cascade: (1) `JELLYFIN_ADMIN_USER` + `JELLYFIN_ADMIN_PASSWORD` — the shared admin login (re-runs / already unified), with a fallback to qBittorrent's default `admin` username for older installs, (2) temporary `admin` password from container logs (first run), (3) legacy `QBT_ADMIN_PASSWORD` from `.env` (migration from pre-unification installs). Auth via `POST /api/v2/auth/login` to get a `SID` cookie.

**Writes:**

- `POST /api/v2/app/setPreferences` — save path/temp path for managed app wiring, max ratio, connection limits, queueing, `bypass_auth_subnet_whitelist=172.16.0.0/12`. In manual app wiring, save/temp paths are skipped while auth, port, limits, and subnet whitelist are still applied. The `max_ratio_act` field is hardcoded to `0` (pause) — not taken from `config.yml`. This is the documented value; Sonarr/Radarr's download-client validator rejects any non-pause setting.
- WebUI username/password alignment to `JELLYFIN_ADMIN_USER` + `JELLYFIN_ADMIN_PASSWORD` via `setPreferences`. Uses `python3 json.dumps` for credential values.
- Categories via `POST /api/v2/torrents/createCategory` per entry in `cfg_qbt_categories`, skipped for manual app wiring. If `editCategory` reports failure, configure.sh fetches categories again and treats the category as successful when the live save path matches config.yml.

**Idempotency:** Re-runs authenticate with the shared admin login (tier 1) and proceed to re-apply preferences (idempotent by nature of `setPreferences`) and verify categories. Migration from default `admin`, temporary-password, or legacy `QBT_ADMIN_PASSWORD` paths rotates to the shared login automatically. There is no separate "already configured" check beyond re-applying preferences — editing qBittorrent settings in `config.yml` and re-running `configure.sh` re-pushes them from scratch rather than diffing first.

## Step 2 — Jackett indexers + admin password (`configure_jackett` in `scripts/services/jackett/main.sh`)

**Auth:** Jackett's management API requires a session cookie (the `apikey` param alone returns 302). `POST /UI/Dashboard` sets the cookie; on re-run (password already set), the shared admin password is posted to authenticate.

**Flow:** Read `configured=true` indexers; for each `id:type` pair from `cfg_indexers`, fetch default config and POST it back to enable. Jackett's "add indexer" is really "save its default config".

**Admin password:** Set via `POST /api/v2.0/server/adminpassword` with a JSON string body (not an object). Jackett hashes it internally with the API key as salt. Skipped if a hash is already present in `ServerConfig.json`.

**Idempotency:** Skip indexers if already configured. Skip + warn if indexer ID isn't available in Jackett — a typo'd indexer ID in `config.yml` produces a warning and continues, so `configure.sh` can complete successfully with no indexers configured. Skip password if already set.

## Step 3 — Sonarr (`scripts/services/sonarr/main.sh`)

**Auth:** Read API key from `config/sonarr/config.xml` (generated by Sonarr on first start). If missing, `log_error` and `return 1` — Sonarr not ready means we cannot proceed with this step.

**Writes (each check-before-create):**

- Root folder — delegates to shared `configure_arr_root_folder` (see below).
- Download client — delegates to shared `configure_arr_download_client` with `tvCategory` (see below). Payload template at `scripts/services/sonarr/templates/download-client.json`.
- Quality profile — delegates to shared `configure_quality_profile` in `scripts/lib/arr/quality.sh` (loaded by the `arr/main.sh` entry point; see below).
- Quality definitions — delegates to shared `configure_quality_definitions` (see below).
- Custom formats — delegates to shared `configure_arr_custom_formats` (see below). Creates curated format definitions from `scripts/lib/arr/custom_formats.yml`.
- Format scores — delegates to shared `configure_arr_format_scores` (see below). Attaches scores to the quality profile.
- TRaSH Guides naming conventions — `PUT /api/v3/config/naming` with Jellyfin-compatible folder/file naming (`{Series TitleYear} [tvdbid-{TvdbId}]`, etc.). Skipped if `renameEpisodes` is already True. Inline in sonarr/main.sh (not shared — episode formats are structurally different from movie formats).
- Torznab indexers — delegates to shared `configure_arr_indexers` with TV categories from `config.yml`.
- **Forms auth** — delegates to shared `configure_arr_auth` (see below).

**Writeback:** `env_save_api_key "SONARR_API_KEY" "$sonarr_key"`.

## Step 4 — Radarr (`scripts/services/radarr/main.sh`)

Structural mirror of Sonarr — both delegate to the same shared helpers (including `configure_arr_custom_formats` and `configure_arr_format_scores`). Differences:

- Download client uses `movieCategory` field (not `tvCategory`); template at `scripts/services/radarr/templates/download-client.json`.
- Torznab call uses `categories.movies` from `config.yml`.
- Quality-profile *allowed set* matches Sonarr (Remux-1080p deliberately excluded for movies as well — see [`docs/reference/quality-bounds.md`](../reference/quality-bounds.md)).
- Quality definitions set is the same shape as Sonarr's; Remux-1080p is not configured.
- Naming conventions use movie-specific format (`{Movie CleanTitle} ({Release Year}) [imdbid-{ImdbId}]`). Skipped if `renameMovies` is already True. Inline in radarr/main.sh.

**Writeback:** `env_save_api_key "RADARR_API_KEY" "$radarr_key"`.

## Shared *arr helpers (`scripts/lib/arr/main.sh` + topical modules + `render/*.py` + `templates/*.json`)

### `configure_arr_root_folder APP BASE KEY`

Reads `<app>.root_folder` from `config.yml`, `GET /api/v3/rootfolder`, and compares. `log_skip` on match, `log_warn` on drift, `POST /api/v3/rootfolder` on absent.

### `configure_arr_disk_threshold APP BASE KEY`

Reads `min_free_space_gb` from `config.yml` (default 20), converts to MB (×1024), and applies via `GET`/`PUT /api/v3/config/mediamanagement` (field: `minimumFreeSpaceWhenImporting`). The PUT requires the full config object — GET first, mutate the one field, PUT back. Only updates when the current value is the API default (100 MB); warns on drift from user-customized values. `0` disables (skips with `log_skip`).

### `configure_arr_download_client APP BASE KEY CATEGORY_FIELD`

Reads `<app>.download_client_category` from `config.yml`, `GET /api/v3/downloadclient`, and compares the qBittorrent entry's category field (4th arg: `tvCategory` for Sonarr, `movieCategory` for Radarr). `log_skip`/`log_warn`/`POST` pattern. The create payload is built with Python `json.dumps` so configured categories are JSON-escaped safely.

### `configure_arr_auth APP BASE KEY`

Enables Forms authentication using shared Jellyfin admin credentials (`JELLYFIN_ADMIN_USER`/`JELLYFIN_ADMIN_PASSWORD`). Checks `GET /api/v3/config/host`; if `authenticationMethod` is not `forms`, `PUT`s the update, then `docker restart <app>` and polls until the service is back (up to 60s). Port is derived from the base URL.

### `configure_quality_profile APP BASE KEY ENABLED_IDS_JSON`

1. Read `quality_profile.{name, cutoff_id, upgrade_allowed}` from `config.yml`.
2. Look up a profile by name; compare live `cutoff`, `upgradeAllowed`, and the set of enabled leaf quality IDs against `config.yml`. `log_skip` on match, `log_warn` on drift (configure.sh does not reconcile drift — rebuild is the canonical migration path).
3. Absent → fetch the default profile as a template, feed it through `render/quality_profile.py` which rebuilds the `items` array marking each quality as `allowed: true/false` based on `ENABLED_IDS_JSON` (a JSON array from `cfg_quality_ids`).
4. `POST /api/v3/qualityprofile` with the rebuilt profile.

**Non-obvious:** `cutoff_id` is a *group* ID (1000+), not a quality ID. Sonarr rejects sub-quality IDs as cutoffs. See `config.yml` mapping comment.

### `configure_quality_definitions APP BASE KEY`

1. Read `quality_definitions.<app>` from `config.yml` (returns `{}` if absent → log_skip, no writes).
2. `GET /api/v3/qualitydefinition` to snapshot current per-tier sizes.
3. Feed current + desired to `render/quality_definitions.py`, which emits one `<id>\t<put-body-json>` line per tier whose size bounds differ. Unknown quality names go to stderr as `WARN\t<name>` (caller logs non-fatally — Sonarr/Radarr add/remove tiers between versions).
4. For each emitted line, `PUT /api/v3/qualitydefinition/<id>` via `api_put`.

**Float tolerance:** the diff uses `|a - b| <= 0.05` so minor Sonarr/Radarr internal rounding doesn't trigger a no-op rewrite on every re-run.

### `configure_arr_custom_formats APP BASE KEY`

1. Read `custom_formats` scores from `config.yml` via `cfg_custom_format_scores`. If empty/absent → silently skip.
2. `GET /api/v3/customformat` to list existing formats.
3. Feed existing formats + format definitions (`scripts/lib/arr/custom_formats.yml`) + scores to `render/custom_formats.py`, which emits one `<name>\t<post-body-json>` line per format to create (skips formats already present by name, and formats not in the scores).
4. `POST /api/v3/customformat` for each new format.

### `configure_arr_format_scores APP BASE KEY`

1. Read `custom_formats` scores from `config.yml`. If empty/absent → silently skip.
2. `GET /api/v3/customformat` → build name→ID map.
3. Read profile name from `cfg_field "quality_profile.name"`, `GET /api/v3/qualityprofile` → find profile by name.
4. Feed profile JSON + scores + format ID map to `render/format_scores.py`, which returns:
   - `match` — current `formatItems` already match. `log_skip`.
   - `empty\t<put-body>` — `formatItems` was empty; treated as CREATE. `PUT /api/v3/qualityprofile/{id}` with populated `formatItems`.
   - `drift\t<details>` — `formatItems` non-empty and differs. `log_warn` (no reconcile).

### `configure_arr_indexers APP BASE KEY CATEGORIES`

Iterates `cfg_indexers`, filtering:

- `sonarr` gets `general` + `tv` (skip `movies`).
- `radarr` gets `general` + `movies` (skip `tv`).

Dedup by name-substring match. Each addition is `POST /api/v3/indexer` with a Torznab config (template `scripts/lib/arr/templates/indexer.json`) pointing at `http://jackett:9117/api/v2.0/indexers/<id>/results/torznab/`. Categories are auto-discovered from each indexer's Torznab caps via `render/torznab_caps.py` — Radarr gets 2xxx + movie-native IDs, Sonarr gets 5xxx + TV-native IDs. Falls back to `config.yml` values when caps discovery fails.

**Retry-with-backoff:** each POST is attempted up to 3 times with an 8-second backoff between attempts. Sonarr/Radarr run a live `tvsearch`/`search` add-time test that Jackett forwards through FlareSolverr's ClearanceHandler (even for non-CF indexers). The first few adds in a fresh setup routinely lose the 65s HttpClient timeout while FlareSolverr cold-starts. Retrying absorbs the race. On success with attempt > 1, the log notes `(attempt N)`; on final failure, `(3 attempts)`.

## Step 5 — Jellyfin (`configure_jellyfin` in `scripts/services/jellyfin/main.sh`)

**Two paths selected by whether `/Startup/Configuration` returns anything:**

### Path A: wizard not yet run

1. `POST /Startup/Configuration` — UI culture, metadata settings.
2. **`GET /Startup/User`** — critical: this triggers Jellyfin's `UserManager.InitializeAsync()` which creates the initial "root" user. The subsequent POST is UPDATE-only and silently no-ops if no user exists. See the comment above the GET call in the source.
3. `POST /Startup/User` — name + password.
4. `POST /Startup/RemoteAccess` — enables remote, disables UPnP.
5. `POST /Startup/Complete` — marks wizard done.
6. Verify by authenticating. If auth fails the wizard is declared broken; `return 1` with a recovery message telling the user to delete `config/jellyfin`. That recovery path deletes the whole Jellyfin config directory, including the media database — a user with existing watch-state loses it, so it should only be used when Jellyfin genuinely cannot be recovered another way.

### Path B: wizard already completed

Skip straight to `POST /Users/AuthenticateByName`, save the returned `AccessToken` as `JELLYFIN_API_KEY`, and fall through to server name / library sync.

### `configure_jellyfin_server_name` (in `scripts/services/jellyfin/server.sh`)

Sets Jellyfin's display name (Dashboard header, browser tab) via `GET`/`POST /System/Configuration`. Reads `jellyfin.server_name` from `config.yml` (default `"MediaStack"`). Skips on match; warns on drift (non-empty, non-default value — user changed in UI); applies when empty or docker-default hostname `"jellyfin"`.

### `configure_jellyfin_libraries` (in `scripts/services/jellyfin/wizard.sh`)

`POST /Library/VirtualFolders?name=...&collectionType=...` per entry in `cfg_jf_libraries`. Library name is URL-encoded via inline Python.

### `configure_jellyfin_networking` (in `scripts/services/jellyfin/network.sh`)

Configures Jellyfin's network settings via `GET`/`POST /System/Configuration/network` (a different JSON blob from `/System/Configuration` used by streaming). `render/network_policy.py` compares the live JSON with MediaStack's desired policy and emits the skip/drift/apply decision that the shell wrapper logs and posts. Three fields:

- **`AutoDiscovery: true`** — enables UDP 7359 broadcast for LAN device auto-discovery (port exposed in `docker-compose.yml`).
- **`KnownProxies: ["${MEDIASTACK_NPM_IP}"]`** — only when `REMOTE_WEB_STATE=ready` with a real domain. Tells Jellyfin to trust `X-Forwarded-*` from NPM. Uses NPM's pinned IP from `.env` (default `172.28.0.10`, selected by `setup.sh` after LAN/VPN collision checks) — Jellyfin caches DNS lookups at startup, so a hostname goes stale after any network rebuild (see the static-octet map in the `mediastack` network block of `docker-compose.yml`).
- **`PublishedServerUriBySubnet`** — `["internal=http://<HOST_IP>:8096"]` always; adds `"external=https://jellyfin.<DOMAIN>"` only when `REMOTE_WEB_STATE=ready`. Unchecked or skipped remote state stays LAN-only even if `DOMAIN` is real.

**Idempotency:** GET current, compare each field. `log_skip` on match. `log_warn` on drift (non-default values that differ from expected — user changed in UI). POST only when values are at defaults. Writes `JELLYFIN_PUBLISHED_URL` to `.env` via `env_save_api_key`.

**Restart:** `KnownProxies` and `AutoDiscovery` are startup-config (ASP.NET `ForwardedHeadersOptions` and UDP listener, respectively). After successful POST: `docker compose up -d --no-deps --force-recreate jellyfin`, poll `/health` for up to 60s. `--force-recreate` ensures the container is recreated (picks up `.env` changes); `--no-deps` avoids pulling in other services. Skip/drift normally avoids restart, except when `JELLYFIN_PUBLISHED_URL` changes; that value is a compose environment variable, so the Jellyfin container is force-recreated to pick up the new LAN or HTTPS URL even when the network API write itself is skipped or drift-protected.

## Step 6 — Seerr (`configure_seerr` in `scripts/services/seerr/main.sh`)

The longest step — Seerr's bootstrap involves three moving API surfaces (its own, Jellyfin's, and the *arr apps').

1. **Already-initialized check**. If `initialized=True`, log info and continue (no longer short-circuits — library sync and *arr connect are reconciled on re-run).
2. **`POST /api/v1/auth/jellyfin`** — includes `hostname/port/useSsl/urlBase/serverType:2`. If that fails (partial prior run may have stored hostname already), retry without hostname; the retry is silent, so there is no log signal distinguishing a normal first-attempt success from a fallback that masked a real hostname mismatch. Uses a cookie jar for session persistence.
3. **Session verify** via `GET /api/v1/auth/me` — guards against silent auth-cookie failures.
4. **Library readiness poll**. Read the Jellyfin API key Seerr generated for itself (from the `apiKey` field in `GET /api/v1/settings/jellyfin`), then poll Jellyfin's `GET /Library/MediaFolders` with it for 60s until the `Movies` and `TV Shows` folders appear. Poll count is 30 x 2s. This is the correct gate — Seerr's sync calls Jellyfin's `/Library/MediaFolders` internally, *not* the refresh task status.
5. **Library sync** — `GET /api/v1/settings/jellyfin/library?sync=true`. Captures HTTP code + body so real failures (`404 SYNC_ERROR_NO_LIBRARIES`, `501 SYNC_ERROR_GROUPED_FOLDERS`) surface instead of being masked. A previous implementation used `|| echo "[]"` and silently lost errors.
6. **Enable libraries** — `GET /api/v1/settings/jellyfin/library?enable=<comma-ids>`.
7. **Connect Sonarr + Radarr** via `http_json_post` (defined in `scripts/lib/http.sh`), which captures the response body on non-2xx. Payload includes `activeProfileName`, `activeDirectory`, `activeLanguageProfileId` (Sonarr) — Seerr 2.7.x silently accepts an incomplete payload but the connection won't work without these fields.
8. **Mark setup complete** — `POST /api/v1/settings/initialize`, then re-fetch `/api/v1/settings/public` to verify `initialized=true`.
9. **Extract API key** — from the `apiKey` field of `GET /api/v1/settings/main` (fetched for permissions check below). Saved to `.env` as `SEERR_API_KEY` via `env_save_api_key`. Used by the Homepage widget in Step 8.
10. **Set default permissions + quotas** — `POST /api/v1/settings/main` with `defaultPermissions: 32` (REQUEST only) and `defaultQuotas` from `config.yml` (`seerr.quotas.movie` and `seerr.quotas.tv`). Bits 128/256/512 (auto-approve movies/TV/4K) are NOT set, so all requests require admin approval. Quotas default to unlimited (`limit: 0`) in the shipped `config.yml`.

Heredoc-stdin hazard (commented in the source near the `lib_ids` extraction): `python3 - <<'PY'` rebinds stdin, so using it in a pipeline like `echo $libs | python3 - <<'PY'` silently gives Python an EOF — the `echo`'s output never reaches `sys.stdin`. Use `python3 -c '…'` inside pipes.

## Step 7 — Portainer (`configure_portainer` in `scripts/services/portainer/main.sh`)

Portainer CE is distroless (no shell, no curl inside the container), so all configuration happens via external API calls.

**Admin creation:** Check `GET /api/users/admin/check` — HTTP 204 means admin exists (skip), 404 means no admin yet (create), anything else (e.g. init timeout) triggers a `docker restart portainer` to reset the 5-minute admin creation window (Portainer locks itself if no admin is created within 5 minutes of first start).

Create admin via `POST /api/users/admin/init` with `{"Username": "<JELLYFIN_ADMIN_USER>", "Password": "<shared password>"}`. The payload is built via `python3 json.dumps` (not a template) so usernames/passwords with JSON-special characters are properly escaped. HTTP 200 = created, 409 = already exists. If a prior run created Portainer's first admin as `admin`, `configure.sh` authenticates with the shared password and renames user ID 1 to `JELLYFIN_ADMIN_USER` so the login matches the rest of the stack.

**Local Docker endpoint:** After admin creation (or skip), authenticate via `POST /api/auth` to get a JWT, then check `GET /api/endpoints`. If authentication returns no JWT (for example, a manually changed Portainer password), warn and skip endpoint/API-token setup rather than failing the whole configurator silently. If zero endpoints exist, `POST /api/endpoints` with `Name=local&EndpointCreationType=1` to create a local Docker socket endpoint. This makes containers visible in the Portainer UI without requiring the user to complete the web-UI setup wizard.

**Persistent API token:** After JWT auth, creates a persistent API access token via `POST /api/users/1/tokens` with `{"description": "Homepage", "password": "<admin_pw>"}`. The `rawAPIKey` (returned only at creation time) is saved to `.env` as `PORTAINER_API_KEY`. Used by the Homepage Portainer widget in Step 8. Idempotent: if `PORTAINER_API_KEY` is already set in `.env`, validates it against `GET /api/endpoints` — only creates a new token if the existing one is missing or invalid.

**Idempotency:** Skip admin creation if already initialized (204 from admin check). Skip endpoint creation if any endpoint already exists. Skip API token creation if existing token validates.

## Step 8 — Homepage (`scripts/services/homepage/main.sh`)

**No auth needed.** Homepage reads static YAML config files from `/app/config/` and hot-reloads on change. No Docker socket mount — the main security win over the previous Flame dashboard.

**Writes:** Generates `config/homepage/services.yaml` via Python `yaml.safe_dump`. Five service groups: Media (Jellyfin + Seerr), Media Management (Sonarr + Radarr + optional Bazarr), Downloads (qBittorrent + Jackett), Network (NPM + optional WireGuard + optional DDNS Updater), Admin (Portainer + optional Beszel + Uptime Kuma). Nine services get native API widgets showing live data:

| Service | Widget type | Auth source |
|---------|------------|-------------|
| Jellyfin | `jellyfin` | `JELLYFIN_API_KEY` from `.env` |
| Seerr | `seerr` | `SEERR_API_KEY` from `.env` (extracted in Step 6) |
| Sonarr | `sonarr` | `SONARR_API_KEY` from `.env` |
| Radarr | `radarr` | `RADARR_API_KEY` from `.env` |
| qBittorrent | `qbittorrent` | Subnet-whitelisted (no auth needed) |
| NPM | `npm` | `NPM_ADMIN_EMAIL` + `JELLYFIN_ADMIN_PASSWORD` from `.env` |
| Portainer | `portainer` | `PORTAINER_API_KEY` from `.env` (created in Step 7) |
| Beszel | `beszel` | `NPM_ADMIN_EMAIL` + `JELLYFIN_ADMIN_PASSWORD` from `.env` |
| Uptime Kuma | `uptimekuma` | Public status page slug (no auth) |

Widget `url` values use internal container names (`http://sonarr:8989`) — resolved via Docker DNS on the `mediastack` network. Widgets are conditional: omitted if the required key/credential is empty (graceful degradation on partial configuration).

All services get `description` (short role label) and `siteMonitor` (internal URL for health-status dots). Jackett is link-only (no Homepage widget type exists for it).

**Remote-ready URLs:** User-facing services (Jellyfin, Seerr) get subdomain `href` URLs (`https://jellyfin.$DOMAIN`) only when `REMOTE_WEB_STATE=ready` and `DOMAIN` is real. Unchecked or skipped remote state uses LAN URLs. Admin tools always use `http://HOST_ADDRESS:port`.

**Optional services:** Bazarr, WireGuard, DDNS Updater, Beszel detected via `docker compose ps` — included only when running.

**Idempotency:** Compare generated YAML with existing file. `log_skip` if identical, write + `log_ok` if different.

**Pre-seeded configs (tracked in git):** `settings.yaml` (dark theme, background image with glass-card blur, theme-colored icons, status dots, section layout), `docker.yaml` (Docker integration disabled), `widgets.yaml` (greeting, datetime, system resource gauges), `bookmarks.yaml` (empty). Only `services.yaml` is gitignored (contains API keys at runtime).

**Volume mount:** The homepage container mounts `${DATA_DIR}:/data:ro` so the resources widget can report disk usage of the media storage directory.

## Step 9 — NPM (`scripts/services/npm/main.sh`)

NPM ships with an empty user table on first boot. The famous `admin@example.com / changeme` default only appears after the UI first-run wizard completes.

**Primary path:** `POST /api/users` unauthenticated. Succeeds (201) only while the table is empty, creating the admin with the shared `JELLYFIN_ADMIN_PASSWORD` directly.

**Fallback path (HTTP != 201):** Someone already used the UI first-run. Try to rotate the default creds:

1. `POST /api/tokens` with `admin@example.com / changeme`.
2. If that works, `PUT /api/users/me` + `PUT /api/users/me/auth` to rotate.
3. If that *also* fails, declare the user has non-default creds already and `log_skip`.

**Verify:** `POST /api/tokens` with the shared admin creds; warn if they don't authenticate.

**Proxy hosts (requires `REMOTE_WEB_STATE=ready`, or a scoped Stage 2 attempt):** After authentication, public proxy publication normally runs only when `REMOTE_WEB_STATE=ready` and `DOMAIN` is real. During Stage 2, `MEDIASTACK_NPM_ATTEMPT_REMOTE=1` permits one pre-ready certificate/proxy attempt so the wizard can classify the LE result before promoting ready. It creates proxy hosts for user-facing services only:

| Subdomain | Target | WebSocket |
|-----------|--------|-----------|
| `jellyfin.$DOMAIN` | `jellyfin:8096` | Yes |
| `seerr.$DOMAIN` | `seerr:5055` | Yes |

Admin tools (Sonarr, Radarr, Jackett, qBittorrent) are NOT proxied — they stay LAN/VPN-only. Fail2ban protects all proxied traffic via the NPM access log jail (401/403 responses) plus per-service jails for Jellyfin and Seerr.

`DOMAIN` still controls infrastructure startup elsewhere: `scripts/setup/stack.sh::_build_profile_args()` enables the proxy profile whenever `DOMAIN` is real, even while `REMOTE_WEB_STATE` is unchecked, skipped, or failed. That lets NPM, fail2ban, and DDNS run before HTTPS is ready.

NPM admin setup, health healing, default-site hardening, the rate-limit step (which only writes the `limit_req_zone` when `rate_limiting.enabled` is true — otherwise it logs a skip; disabled by default — see [`rate_limiting`](configuration-schema.md#rate_limiting)), reload checks, and fail2ban jail validation run even when remote state is unchecked, skipped, or failed. Only public proxy hosts, certificate requests, and cert-backed HTTPS publication are inside the ready/attempt gate. `NPM_LE_SERVER` remains part of the ready path so DinD/Pebble can exercise certificate issuance without production Let's Encrypt. Each Stage 2 remote cert attempt writes `config/state/npm-cert-status-last.json` for persistent forensics.

**Idempotency:** Skip proxy hosts that already exist (checked by domain name match). In skipped/unchecked states, exact current-domain MediaStack-managed hosts are disabled rather than recreated; unrelated manual hosts are left alone. In failed state, rendered cert-backed hosts are preserved while incomplete/certless hosts are disabled, so the next `./setup.sh --remote` can reuse any successful certificate material.

## Step 10 — DDNS Updater (`configure_ddns_updater` in `scripts/services/ddns-updater/main.sh`)

Only runs if the `ddns-updater` container is running (detected via `docker ps`). Actual DDNS config seeding happens in `setup.sh` before containers start — this step just reports status so `configure.sh` output is consistent.

Checks whether `config/ddns-updater/config.json` exists: if present, `log_ok`; if absent, `log_warn` with guidance to configure at the web UI (`http://<ip>:8000`).

## Step 11 — Uptime Kuma (`configure_uptime_kuma` in `scripts/services/uptime-kuma/main.sh`)

**No config.yml dependency.** Uptime Kuma is fully auto-configured with no user-editable parameters.

**Ephemeral container pattern:** Runs `docker run --rm --network mediastack node:22-slim` to avoid installing npm packages on the host. The container installs `socket.io-client` (official Socket.IO JS client), configures monitors via Kuma v2's Socket.IO event API, and exits.

**Auth:** Checks `needSetup` — if true, calls `setup(username, password)` to create the admin account. Then registers a `monitorList` event listener (must be registered BEFORE login to avoid a race condition — the server emits `monitorList` asynchronously from `afterLogin()`), and calls `login({username, password})`. On re-run, `needSetup` returns false and login succeeds directly.

**Settings:** Disables `checkUpdate` via `setSettings({checkUpdate: false}, password)`.

**Monitor creation:** Builds a monitor list from running containers (`docker compose ps`). Each service maps to an HTTP monitor URL (e.g. `http://sonarr:8989/ping`, `http://jellyfin:8096/health`). Services without HTTP endpoints (Unpackerr, Fail2ban) are omitted. All monitors use `maxredirects=0` with `accepted_statuscodes=["200-299", "300-399"]` and `conditions: []` (required in v2) — several services (Jackett, Seerr, Uptime Kuma itself) return 3xx redirects on their root URL, and following the redirect chain can end in a 400 (Jackett's login redirect loop).

**Idempotency:** Existing monitors are deduplicated by URL from the `monitorList` event data. Monitors already present are skipped (`log_skip`), new monitors are created (`log_ok`). No drift detection — monitors are not reconciled after creation.

**Status page:** Creates (or updates) a public status page at slug `mediastack` with only MediaStack-managed monitors in a single "Services" group (user-added monitors are excluded). `addStatusPage` returns `{ok: false}` if the slug already exists (caught and ignored). `saveStatusPage` requires a config object with at minimum `slug`, `title`, `analyticsType: null`, and `domainNameList: []` — passing `{}` crashes upstream validation. `imgDataUrl` must be `""` (not `null` — upstream calls `.startsWith()` on it). The Homepage widget reads the status page via the public API (no API key needed).

**Stderr handling:** npm install and Node.js errors go to `/tmp/kuma-configure.err`. On failure (empty stdout), the last 5 lines of stderr are logged via `log_warn`.

## Step 12 — Beszel (`configure_beszel` in `scripts/services/beszel/main.sh`)

**Conditional.** Only runs when the `beszel` container is running. Beszel is part of the default stack, but the guard keeps targeted or partial runs graceful. Configures the Beszel hub+agent system resource monitor via PocketBase REST API.

**Auth:** `POST /api/collections/users/auth-with-password` with `NPM_ADMIN_EMAIL` / `JELLYFIN_ADMIN_PASSWORD`. The hub auto-creates this user from `USER_EMAIL`/`USER_PASSWORD` env vars on first container start — no API call needed for initial user creation.

**SSH key retrieval:** `GET /api/beszel/getkey` with Bearer auth returns the hub's ed25519 public key. This key is stable across restarts (generated once, persisted in `/beszel_data`). Saved to `.env` as `BESZEL_AGENT_KEY` via `env_save_api_key`.

**Agent recreate:** When the key changes, `docker compose up -d beszel-agent` recreates the agent container with the new `KEY` env var. `docker restart` would NOT pick up the new key (same pattern as the Unpackerr recreate at the end of `main()`).

**System registration:** `POST /api/collections/systems/records` with `{name: "MediaStack", host: "host.docker.internal", port: 45876, users: [user_id]}`. The `users` field is an **array** of user IDs, not a single string — a single string silently fails.

**Idempotency:** Skip key save if `.env` already has the correct key. Skip system registration if a system named "MediaStack" already exists (checked via `json_has_name`). Graceful failure on auth (`log_warn` + `return 0`) — hub may still be initializing on first run.

## Unpackerr restart (end of `main()` in `scripts/configure.sh`)

After the 11 steps, `docker compose up -d unpackerr` recreates the container so it picks up the `SONARR_API_KEY` + `RADARR_API_KEY` env vars that `configure.sh` just wrote to `.env`. A plain `docker compose restart` would not work — it reuses the original (empty) env. `up -d` detects the env change and recreates with the new values.
