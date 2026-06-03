# Roadmap

Planned and deferred features. Not a commitment — a place to preserve design intent so future-us doesn't solve the same problems twice.

## Deferred

### ~~NFS / remote mount watchdog~~ (Implemented)

Implemented as Stage 1 storage modes: local managed, managed NFS NAS, and advanced manual storage. Managed NAS uses `findmnt` source/fstype plus a sentinel file, refuses unsafe starts, and installs `mediastack-storage-watchdog.service`. Manual mode installs services but skips app-level storage wiring.

**Problem.** Users who mount `DATA_DIR` via NFS (Unraid, TrueNAS, Synology) risk data corruption when the mount goes stale while services keep writing. `create_data_dirs()` also creates local fallback directories under the mountpoint, so a silent unmount can route writes to local disk. The default `restart: unless-stopped` policy makes this worse on reboot — containers come back before NFS is ready.

**Sketch.** Two layers:

1. **Pre-start mount guard.** If the user declares `DATA_DIR` is a remote mount during setup, record the expected mount identity (`findmnt` SOURCE + FSTYPE). Refuse `create_data_dirs` and `start_stack` unless that exact mount is present. Guard must run *before* local directory creation, otherwise MediaStack itself creates the fallback tree that makes the failure dangerous.

2. **Opt-in cron watchdog.** Every 5 min, verify mount identity (`findmnt`) and probe the filesystem (timeout-wrapped `test -e` on a sentinel file on the remote FS). When the mount goes bad, stop data-dependent services in order: unpackerr → qbittorrent → sonarr → radarr → bazarr → jellyseerr → jellyfin (highest-throughput writers first, read-only user-facing last). On recovery, restart in dependency order: jellyfin + qbittorrent (mount-only deps, parallel) → sonarr + radarr (need qBittorrent API) → jellyseerr + unpackerr + bazarr. Health-gate restarts on Docker healthchecks, not just `running`. `timeout`-wrap every `docker stop` to survive hard NFS hangs. `flock` for single-instance. Track stopped containers in a state file so user-stopped services aren't auto-restarted.

**Reference implementations.** Maintainer's production scripts at `/home/docker/scripts/` and `~/homelab-rebuild/scripts/` use a similar two-layer approach (continuous mount supervisor + cron-triggered stale check) with probe files, hysteresis timers, and ordered container lifecycle management.

**Key constraints discovered in design.**
- `findmnt` mount-identity check is mandatory — probe-file-only approaches fail when local fallback dirs exist under the mountpoint (the probe gets recreated locally, masking a real outage).
- `soft` vs `hard` NFS mount options are a responsiveness-vs-integrity tradeoff per `nfs(5)`, not a blanket default. `soft` can cause silent data corruption.
- `docker stop` can wedge indefinitely on hard NFS mounts when container processes are blocked on uninterruptible I/O.
- Hysteresis (grace period before stop, stability window before restart) prevents flapping but adds complexity — start without it, add if field reports show flapping.
- Existing installs skip `.env` regeneration, so the enable path must accommodate upgrade.

**Why deferred.** Adds cron jobs, state files, probe files, tuning knobs, and manual upgrade steps to a project whose identity is "one command, zero config editing." NFS users are an advanced subset (Unraid/TrueNAS/Synology homelabbers), not MediaStack's core non-technical audience. The pre-start guard alone provides ~80% of the protection. Reconsider when there's field evidence that NFS users are a first-class audience, or when the first support request lands about silent data corruption from a stale mount.

---

### 4K quality preset

**Problem.** The wizard offers compact (720p cutoff), balanced (720p/1080p), and quality (1080p only). No 4K option. Users with 4K TVs and sufficient storage are an obvious audience segment.

**Sketch.** Add a `4k` preset to `scripts/setup/presets.yml`:
- Profile name: "UHD-2160p"
- Qualities: HDTV-2160p, WEBDL-2160p, WEBRip-2160p, Bluray-2160p, Remux-2160p
- Cutoff: WEB 2160p group (cutoff_id 1003)
- Quality definitions: TRaSH Guides 4K tier (larger size bounds — ~15-60 GB/movie)
- Size hint: "~15-60 GB/movie"

The wizard would show 4 options instead of 3. No infrastructure changes needed — just a new YAML block and the existing `wizard_apply.py` picks it up automatically.

**Why deferred.** Simple to implement. Main hesitation: 4K downloads are large and public indexers have limited 4K availability. Users who want 4K often need private trackers to get reliable results, which is outside the turnkey scope. Consider adding with a clear size/availability warning in the wizard.

---

### Container capability minimization

**Progress.** All 19 compose services now set `security_opt: ["no-new-privileges:true"]` via the shared compose anchor. wg-easy additionally uses `cap_drop: [ALL]` + `cap_add: [NET_ADMIN, NET_RAW, SYS_MODULE]`; see ADR-17.

**Remaining idea.** Services that need no capabilities could specify `cap_drop: [ALL]` after per-image testing.

---

### Indexer minimum seeders

**Problem.** `"minimumSeeders": 1` in the indexer config means Sonarr/Radarr will grab torrents with a single seeder. These downloads often stall or take days, especially on public trackers where lone seeders frequently drop.

**Sketch.** Raise to `3` or `5` in `configure_arr_indexers()` (line 247 of `scripts/lib/arr/main.sh`). Optionally expose in `config.yml` for user tuning. Public trackers have enough seeders on popular content that a minimum of 5 rarely misses anything worth grabbing.

**Why deferred.** Simple one-line change. Worth bundling with the next indexer config update.

---

### Notifications support

**Problem.** Sonarr, Radarr, and Jellyfin all support connect/notification integrations (Discord webhooks, email, Pushover, Gotify, etc.) for events like grab, download, import, upgrade, and health issues. None are configured by the auto-setup. Users have no visibility into what their stack is doing without checking each UI.

**Sketch.** Add an optional `notifications` section to `config.yml`:
```yaml
notifications:
  discord_webhook: ""   # paste a Discord webhook URL to get alerts
```
`configure_sonarr()` and `configure_radarr()` would POST to `/api/v3/notification` if a webhook is set. Jellyfin notifications are more complex (plugin-based).

Discord is the most common choice in the homelab community and requires only a webhook URL — no account setup, no API keys.

**Why deferred.** Optional feature. The zero-config identity means notifications shouldn't be required, and the webhook URL is inherently manual (user creates it in Discord). Consider adding when the wizard or post-setup summary can prompt for it.

---

### update.sh post-update configuration

**Problem.** `scripts/update.sh` pulls new images and recreates containers but doesn't re-run `configure.sh`. After an update, new service features or changed API defaults aren't applied. Users must manually run `./scripts/configure.sh` to catch up.

**Sketch.** Add an optional `./scripts/configure.sh` call at the end of `update.sh`, gated by a flag (`--configure` or `--full`). Default: pull-and-restart only (current behaviour). With flag: also re-apply configuration. This matches the idempotent design — `configure.sh` skips unchanged settings and warns on drift.

**Partly addressed.** ADR-30's "Manage updates" menu now *surfaces* the risk — a service pulled ahead of the tested Stable baseline is labelled "outside the tested Stable baseline" — but still does not auto-re-run `configure.sh`. The flag-gated re-configure remains the open work.

**Why deferred.** Re-running configure.sh after every image update adds time (~2-5 min of API calls and health waits). Most updates don't change API contracts. A flag-gated approach is low-risk but needs testing to confirm configure.sh handles version-upgraded service APIs gracefully.

---

### ~~Uptime Kuma service monitoring~~ (Implemented)

Uptime Kuma (`louislam/uptime-kuma:2`) runs in the default profile. `configure_uptime_kuma()` auto-provisions HTTP monitors for all running services and creates a `mediastack` status page. Homepage dashboard includes an Uptime Kuma widget in the Admin group. Uses an ephemeral `node:22-slim` container with `socket.io-client` for direct Socket.IO provisioning — no npm packages on the host.

---

### ~~Beszel system resource overview~~ (Implemented)

Beszel (`henrygd/beszel` hub + `henrygd/beszel-agent`) runs as part of the default stack. Hub serves a PocketBase-based dashboard on port 8090; agent collects host metrics on port 45876 with `network_mode: host` and Docker socket access for per-container stats. `configure_beszel()` authenticates via PocketBase REST API, retrieves the SSH key, saves it to `.env`, recreates the agent, and registers the host as a monitored system. Homepage widget uses email/password auth. Uptime Kuma monitors the hub health endpoint.

---

### Dozzle container log viewer

**Problem.** The only ways to view container logs are `docker compose logs` on the command line or navigating Portainer's log viewer. Neither is approachable for non-technical users, and tailing multiple services simultaneously is cumbersome.

**Sketch.** Add Dozzle (`amir20/dozzle`) as an optional service. It provides a real-time, browser-based log viewer for all running containers with fuzzy search, regex filtering, and split-screen multi-container tailing. Read-only from a product perspective — no write operations, no API keys, no database, no persistence. Useful for troubleshooting failed downloads, import errors, or transcoding issues without touching the terminal.

**Gotchas.**
- **Docker socket exposure.** Dozzle needs `/var/run/docker.sock:ro` to read logs. While Dozzle itself is read-only, the Docker socket grants broader access than just logs — a compromised Dozzle container could enumerate and control other containers. Consider offering `linuxserver/docker-socket-proxy` as an alternative for hardened installs, or Dozzle's agent mode which avoids direct socket mounts on the dashboard container.
- **Live only, no retention.** Dozzle does not store logs — it streams them in real time. It cannot answer "what happened last Tuesday." For retained/searchable logs, users would need Loki+Grafana or similar, which is outside the turnkey scope. The existing `x-logging` anchor (10 MB, 3 files) determines how far back Dozzle can scroll.
- **LAN-only or behind auth.** Container logs may contain API keys, tokens, or internal URLs. Dozzle should not be internet-exposed without authentication.

---

### FlareSolverr sustainability

**Problem.** FlareSolverr has faced ongoing maintenance challenges as Cloudflare continuously updates their bot detection. The project has had periods of inactivity and several community forks have appeared. Public indexers that previously needed FlareSolverr may stop working if the solver can't keep up with Cloudflare changes.

**Sketch.** Monitor FlareSolverr's upstream health. If the current image stops solving challenges effectively:
- Evaluate active forks (FlareSolverr/FlareSolverr vs. community alternatives).
- Some indexers have dropped Cloudflare or moved to different protection — periodically audit which indexers in `config.yml` actually need it.
- Jackett can function without FlareSolverr (indexers that don't use Cloudflare still work).

**Why deferred.** FlareSolverr currently works for the configured indexers. The `depends_on` relationship (Jackett depends on FlareSolverr healthy) means a broken FlareSolverr blocks Jackett startup entirely — worth monitoring but not acting on preemptively.
