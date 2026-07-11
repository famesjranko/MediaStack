# Operations

Day-2 scripts under `scripts/` and routine operational tasks. Backup and
long-term data protection are intentionally out of scope for MediaStack.

## `./mediastack` → Uninstall MediaStack

Uninstall is a typed-`DESTROY`, transactional action. It stops every Compose profile, verifies no project containers remain, then removes tagged UFW rules, the live Docker firewall chain, MediaStack APT drop-ins, unchanged sysctl hardening, Samba ownership, watchdog units, and setup banners. `data/`, `config/`, and the checkout are preserved.

The ownership ledger is `/etc/mediastack/install-state`. Missing or malformed state aborts before teardown. Docker or host-cleanup failure retains `.env` and the ledger so the same action can be retried. User-modified MediaStack-owned files are preserved and reported instead of overwritten or deleted.

## `scripts/update.sh`

Wrapper around `docker compose pull && up -d` for the configured image channel.

Flow (`scripts/update.sh`):

1. **Override refresh** — reads `IMAGE_CHANNEL` from `.env`, regenerates `docker-compose.override.yml`, and validates `docs/operations/image-digests.lock` for Stable.
2. **Profile detection** — checks for running `proxy` profile services (`npm`/`fail2ban`/`ddns-updater`), `remote` profile services (`wireguard`), `subtitles` profile services (`bazarr`), and `autoheal`. If those services are running, appends the corresponding `--profile` flag so subsequent commands include them. Without this, `pull` would skip optional-profile services on boxes using those profiles.
3. **Pull** — `docker compose $PROFILE_ARGS pull`. Stable pulls the tested `tag@sha256:digest` refs from the generated override; Latest pulls the tags in `docker-compose.yml`.
4. **Recreate** — `docker compose $PROFILE_ARGS up -d --remove-orphans`. `--remove-orphans` cleans up containers from services that have been deleted from the compose file.
5. **Optional prune** — only when run with `--prune`, calls `docker image prune -f` to reclaim disk from dangling images. This prune is host-wide, so the default update path skips it.
6. **Status** — `ps` summary.

**What it does NOT do:**

- No pre-pull health snapshot — if a new image is broken, you lose the working one before you know it.
- No rollback — `docker compose up -d` with the prior image hash isn't automated. The default path retains dangling images; `--prune` removes them host-wide after the update.
- Stable-channel installs are runtime-pinned to `docs/operations/image-digests.lock`; Latest-channel installs intentionally follow upstream tags.
- No config migration — it assumes images accept existing `config/<svc>/` state. Major-version bumps may need manual `configure.sh` re-runs.

## `./mediastack` → Manage updates (per-service)

The launcher's post-install **"Manage updates"** screen is the day-2 update surface for
non-technical users — per-image visibility and selective control, without SSH or Portainer
(ADR-30). `stable`/`latest` is an **install-time** choice only (which image versions the installer
was tested against); post-install every update is a uniform, manual opt-in, so detection and apply
are fully channel-agnostic — an update is an update.

**Status scan.** `python3 scripts/image-drift.py --status` (table) / `--status-tsv` (machine)
reports, per service, a **Policy** (`Pinned` = still on its installed digest / `Tracking tag` =
following its compose tag, with `*` marking a service you've updated) and a **Status**:

| Status | Meaning |
|---|---|
| `Up to date` | running the newest image for its compose tag |
| `Update available` | a newer image exists for its compose tag than the one running |
| `Not installed` | no container exists for this service |
| `Unknown local digest` | container running, but its repo digest can't be resolved (locally built/imported) |
| `Unknown (offline)` | registry unreachable, can't compare upstream |

A freshly Stable-installed box shows most services as `Update available` — the pinned install
digests trail the moving upstream tags, and applying is entirely up to you. The TSV is
`service<TAB>policy<TAB>override<TAB>status<TAB>updatable`, where `override` is `manual` (a service
you've updated — an explicit per-service row) or `default`. The running digest is read from the
**image object** (`docker image inspect … RepoDigests`, repo-matched), not the container; both it
and the upstream digest are manifest-list digests, so the comparison is multi-arch safe.

**Menu actions.**
- **Update a service / Update all** — pull the newest image for the service(s). A service still on
  its installed (pinned) digest floats to its compose tag — a sticky per-service `latest` override
  in `config/state/image-policy.tsv` — while one already tracking its tag just pulls the newer
  digest. "Update all" covers every updatable service and **excludes WireGuard**; a single WireGuard
  update needs an extra confirm (it can disconnect the VPN client running it).
- **Revert a service to its installed image** — re-pins the service to the digest it was installed
  running (recorded in `config/state/image-install.tsv`), on **any** channel — written as a per-service
  digest pin in `config/state/image-policy.tsv`. Lists only services you've updated (a manual override),
  excluding `Not installed`. If the installed image is no longer available upstream the recreate is
  rolled back onto the service's previous cached image rather than left down.
- **Re-check for updates now** — re-runs the registry scan.

To change the global install channel after install, re-run the installer (`./mediastack` → Install)
and pick the other channel; there is no day-2 channel toggle. The CLI `scripts/update.sh` remains a
bulk re-pull per the current override.

Update and revert only **recreate a service that is already running**; a stopped service has its new
image pulled and staged but is **not started** — the change applies the next time the stack starts.

Every apply regenerates `docker-compose.override.yml` (preserving GPU/mem/NAS settings), runs the
storage guard, and recreates only the touched service (no `--remove-orphans`). "latest" follows the
**compose tag**, so ADR-24 pins hold: `npm:2`/`uptime-kuma:2`/`wireguard:15` stay within their
pinned major — updating WireGuard pulls the newest 15.x but never v14 or a future v16. The lock
file is never edited by this path.

## `./mediastack` → Manage hardware transcoding

The launcher's post-install **"Manage hardware transcoding (GPU)"** screen is the
day-2 surface for GPU driver/encoder changes. It is intentionally separate from
**Manage updates**, which only manages container images.

Actions:

- **Configure or change hardware transcoding** — delegates to `./setup.sh --transcoding`.
  This re-detects the GPU and runs the Stage 3 hardware engine without rerunning Stage 1/2.
  NVIDIA users can choose **Standard driver** or **Unlock NVENC limit (advanced)** here.
- **Update NVIDIA driver + reapply Unlock patch** — available only for an active
  NVIDIA/Unlock configuration. The guarded setup action defaults to No, downloads before
  mutation, refuses loaded modules, installs once, and patches only after reboot/version verification.
- **Reapply Unlock patch only** — uses the same guarded setup route and reviewed pinned patch.
  Both Unlock actions stay hidden and fail closed for Standard, externally managed, and non-NVIDIA installs.
- **Reboot to finish hardware transcoding** — appears when an NVIDIA finalize marker is
  waiting on the current boot.

## `./mediastack` → Features & settings → Change quality profile

The launcher's post-install **"Change quality profile (resolution & size)"** action (under
**Features & settings**) re-picks the quality cell after install — the day-2 counterpart of the
wizard's two-prompt quality step — without re-running the whole wizard or hand-editing `config.yml`.

Flow:

1. **Guards** — Docker reachable and **both Sonarr and Radarr running** (a split rename across the two
   apps is avoided by requiring both up front).
2. **Pick** — the same two-axis picker the wizard uses (`scripts/lib/quality_select.sh`): resolution
   ceiling, then size envelope. The current cell is pre-selected.
3. **No-change / confirm** — re-picking the current cell short-circuits. Otherwise you are warned that
   raising the ceiling or size makes Sonarr/Radarr **re-search and upgrade existing media** (extra
   downloads and disk), and asked to confirm (default: no).
4. **Apply** — `wizard_apply.py --quality-only` rewrites **only** the three quality sections of
   `config.yml` (quality profile, definitions, custom formats); indexers, subtitles and bandwidth are
   left untouched.
5. **Re-push** — `configure.sh --only sonarr,radarr` with `QP_RENAME_FROM` set to the old profile
   name, so `configure_quality_profile` **renames the existing profile in place** (same profile id)
   instead of creating a duplicate. Existing series/movies follow the change automatically and **no
   orphaned profile is left behind**.

If you renamed the quality profile yourself in the Sonarr/Radarr UI (so the live name no longer matches
`config.yml`), the re-push refuses to create a duplicate and warns instead — rename it back, or rebuild.

## `./mediastack` → Features & settings → Update DDNS provider / credentials

The **"Update DDNS provider / credentials"** action (under **Features & settings**) swaps the
dynamic-DNS provider — or just re-enters its credentials — after install, reusing the exact provider
picker, JSON renderer and ephemeral verify the setup wizard uses (`scripts/lib/ddns_providers.sh` +
`scripts/lib/network.sh`). The row is shown only once remote access is set up **and** uses DDNS (a
static-IP remote has no provider to change); when remote access is not configured yet, use **Add remote
access** instead.

This action keeps your **existing domain** — so it only covers switches where the domain doesn't move:
re-entering the current provider's credentials, or switching between the two bring-your-own-domain
providers (Cloudflare ↔ Porkbun) on a domain you own. Switching **to or from a free-hostname provider**
(DuckDNS/Dynu/deSEC/dynv6) needs a **new hostname** in that provider's namespace, which also changes
your HTTPS certificate names, WireGuard `WG_HOST` and service URLs — so the action detects that case and
offers to hand off to **Add remote access** (the full domain re-config) rather than dead-ending.

Flow:

1. **Guards** — Docker reachable, remote access configured via DDNS, and `ddns-updater` running.
2. **Pick** — the same curated provider picker the wizard uses; the current provider is pre-selected.
   Choosing "Skip for now" leaves everything unchanged.
3. **Domain-change check** — if the chosen provider can't manage your current domain (any switch
   involving a free-hostname provider), you're told a new hostname is needed and offered a jump to
   **Add remote access**; nothing is changed here.
4. **Collect + verify** — you enter the new provider's credentials, which are checked in a throwaway
   `ddns-updater` container with **zero blast radius** (the live service is not touched). Rejected
   credentials re-prompt; if verification can't run (Docker/network issue), nothing changes.
5. **Confirm** — you are warned that switching restarts `ddns-updater`, and told the current config is
   backed up and restored if the restart fails (default: no).
6. **Apply (verify-first)** — only after the credentials verify: the current `config.json` is
   snapshotted, the new one is written (chmod 600), `ddns-updater` is restarted, and its startup is
   confirmed. If it fails to come up, the previous config is **restored** and the `DDNS_PROVIDER` key in
   `.env` is left unchanged.

Credentials live only in the chmod-600 `config/ddns-updater/config.json`; `.env` keeps just the
non-secret `DDNS_PROVIDER` key. The `:8000` web UI is view-only status, not a place to configure.

**Seeing DDNS status.** When a provider is configured and `ddns-updater` is running, the main-menu
header shows a `DDNS:` line with the **confirmed IP** (what your domain currently resolves to). It is
green when that IP matches your detected WAN IP (the record is up to date), **yellow** when it resolves
to a different IP (`propagating?` — the record is stale or still catching up), or plain `not resolving
yet` when there's no A-record. The
same status appears in **Manage stack** (next to *Remote access*) as `DDNS: <provider> · <ip> ·
<state>`. For an active, on-demand check, **Diagnostics → DNS check** resolves your subdomains and
compares them to your live WAN IP (and shows the provider + container health when DDNS is set up).

The banner's Public IP and DDNS IP are cached for the session (so the menu doesn't re-probe on every
redraw), so a record propagating from `propagating?` to up-to-date won't update mid-session on its own.
The main-menu **Refresh status** option re-checks both and redraws — use it to watch a DDNS change take
effect after switching providers.

## `./mediastack` → Features & settings → Firewall (UFW) / System hardening

Two ON/OFF toggles mirror the Stage 1 wizard's Security prompts (ADR-40), backed by `UFW_ENABLED`
and `HARDENING_ENABLED` in `.env`:

- **Firewall (UFW)** — ON runs `setup_ufw` (default-deny inbound, LAN/SSH/web allowed, plus the
  `DOCKER-USER` restriction chain), reopening remote service ports only on a real-domain install.
  Requires Docker to be reachable (the chain lives in `DOCKER-USER`). OFF runs `_uninstall_ufw`,
  then resets the ownership latches so a later ON reconfigures cleanly. If you added your own UFW
  rules or changed the defaults after install, OFF removes only MediaStack's rules and **leaves UFW
  active**, telling you so — and because that removal also drops MediaStack's SSH allows, it
  re-asserts an SSH allow (RFC1918 LAN ranges + your current SSH session) so a remote/headless box
  can never be locked out. Run `sudo ufw disable` yourself if you want the firewall fully off.
- **System hardening** — ON applies unattended security upgrades + kernel sysctl hardening; OFF
  reverts both (`_uninstall_sysctl` + `_uninstall_apt`), restoring pre-install sysctl values it still
  owns and removing the MediaStack drop-ins.

Both ON actions refuse (warn + skip) when no valid ownership ledger exists — run a full install or
reset first. Toggling is add-only: turning a feature off never deletes user data or user-owned
firewall/kernel settings.

## `./mediastack` → View storage & data mount

Shown **only on NAS installs** (`STORAGE_MODE=nas`) as a top-level menu item — local
installs have no mount to inspect (data dir + free space already show in **Manage stack**).
A read-only status box built entirely from the `storage_*` getters in
`scripts/setup/storage.sh`, so a non-technical user can see their mount at a glance:

- **NAS source** — the expected `host:/export` (`storage_expected_source`).
- **Filesystem** — expected type plus live state: `mounted, healthy`; `mounted, verifying…`
  (sentinel not yet present); `WRONG: <live source> (<live fstype>) — expected nfs4` when a
  different disk is mounted at the mountpoint; or `not mounted`.
- **Data** — the data dir and free space (`df -h`).
- **Watchdog** — `running`, `running (services paused — NAS down since <ts>)`, `stopped`, or
  `disabled`, from the unit's `systemctl is-active` state + the `config/state/storage-watchdog-stopped` flag.
- **Services** — how many of the NAS-dependent services (`storage_data_services`) are running.

The one action, **Re-check NAS now**, re-runs `storage_nas_ok` (mount + sentinel) and reports a
verdict; the box then redraws with the live mount state. Remount/restart are intentionally not
offered here — the watchdog already auto-repairs the mount and restarts paused services.

## `./mediastack` → Features & settings → NAS storage watchdog

Shown **only on NAS installs** (`STORAGE_MODE=nas`), backed by `STORAGE_WATCHDOG` in `.env`
(absent = ON, so pre-existing NAS installs stay protected):

- **ON** runs `storage_install_watchdog` — installs the root helper, sudoers rule, and
  `mediastack-storage-watchdog.service`, and re-enables the pre-start guard.
- **OFF** runs `storage_pause_watchdog_for_install` (stop + disable the unit) and makes
  `storage_guard_before_start` a no-op. NAS storage stays mounted and verified; only the automatic
  stop/restart-on-mount-loss protection is removed.

No `docker compose` restart is involved — it is a host systemd unit, not a Compose service.

## `scripts/nvidia-repatch.sh`

Repatch wrapper for after NVIDIA driver updates — relevant **only in Unlock NVENC mode** (`NVIDIA_DRIVER_MODE=unlock`). Standard (Debian-managed) and `existing` installs are not patched and are maintained by apt, so the script is a no-op there with guidance (override with `--force`). See ADR-31.

Flow:

0. Parse args (`--force` to patch regardless of mode; unknown args error with usage). Read `NVIDIA_DRIVER_MODE` from `.env`; if it is not `unlock` and `--force` was not given, print "nothing to repatch" and exit 0.
1. Refuse if `nvidia-smi` is missing — no drivers loaded.
2. Read current driver version.
3. Verify `keylase/nvidia-patch` in `$SCRIPT_DIR/.nvidia-patch` (gitignored) at the reviewed commit pinned in `scripts/lib/nvidia_patch.sh`. Dirty local trees and unexpected origins are rejected.
4. Export that pinned commit to a temporary execution directory; root never executes files from a moving branch checkout.
5. **Compatibility check** — runs exported `patch.sh -c $DRIVER_VER` to confirm the reviewed commit supports this driver version. Exits cleanly with guidance if MediaStack needs a newer reviewed nvidia-patch commit.
6. `sudo bash patch.sh` from the exported tree — removes NVENC encoding session limits on consumer GPUs.
7. `sudo bash patch-fbc.sh` from the exported tree if present — enables NvFBC framebuffer capture.

**When to run:** only in **Unlock mode**, after any `apt upgrade`/driver change that touches the patched driver — the patches are linked to specific driver versions, so a driver bump leaves the new binary unpatched and silently reintroduces session limits. In **Standard mode** there is nothing to run: apt manages the driver and no binaries are patched. This script is independent of `setup.sh` — setup.sh's hardware step applies the same patch during an Unlock install but won't fire on every boot.

## Day-2 ops

### Re-running configure.sh after editing config.yml

```bash
vim config.yml
./scripts/configure.sh
```

Safe to re-run. Each step is idempotent — existing resources are detected by name/path and skipped. Added indexers/libraries are created; removed ones stay in place (the script doesn't reconcile — it only adds).

**Caveats:**

- **qBittorrent** (Step 1) short-circuits on re-runs because the temp password no longer exists (`configure_qbittorrent()` auth-fallback logic). Editing `qbittorrent.max_ratio` in `config.yml` will NOT push to a running instance.
- **Quality profile edits** are name-keyed. If you hand-edit `quality_profile.name` in `config.yml` and run `configure.sh`, it creates a *new* profile alongside the old one (you must delete the old one manually and re-point existing series). To change the quality cell **without** orphaning the profile, use the launcher's **Features & settings → Change quality profile** action instead — it renames the profile in place (see above).
- **Removed indexers** stay registered. Delete via Jackett UI manually.

### Config changes that require container restart

- Anything in `.env` that's interpolated into `docker-compose.yml` (PUID, PGID, TZ, paths, `SONARR_API_KEY` for unpackerr).
  ```bash
  docker compose up -d       # picks up new env for changed services
  ```
- Changes to fail2ban jails or filters:
  ```bash
  docker compose restart fail2ban
  ```
  To view or release bans without shelling into the container, use `./mediastack` → **Manage fail2ban**:
    - **Banned IPs** — the hub. Every currently-banned address is one row (collapsed across jails); pick one, then **Unban** to release it, or **Unban + always allow** to release it *and* add it to the whitelist so it is never banned again. With more than one address banned, **Unban all** releases everything at once (each can still be re-banned on its next failed login).
    - **Whitelist (always-allow IPs)** — the addresses/ranges fail2ban never bans. Add or remove your own entries; the four private-network defaults are locked.
    - **Jail stats & history** — per-jail ban counts and all-time totals, a drill-down into any jail (with its watched log path), and the recent Ban/Unban log.

  Two things to know: a ban blocks **all** services, not just the jail that fired it; and one unban clears the address from **every** jail at once.
- GPU override file regeneration (new GPU hardware):
  ```bash
  ./setup.sh                 # re-detects GPU, regenerates override.yml
  docker compose up -d       # applies the new runtime/devices
  ```
- NVIDIA healthcheck override changes:
  ```bash
  ./setup.sh --transcoding
  docker compose up -d --force-recreate jellyfin
  docker inspect jellyfin --format '{{.Config.Healthcheck.Test}}'
  ```
  Docker restart policies do not restart on `unhealthy`; MediaStack relies on the autoheal sidecar for healthcheck-triggered recovery.

### Adding a new indexer

1. `vim config.yml` — add `- id: <jackett-id>\n  type: <general|tv|movies>`.
2. `./scripts/configure.sh` — Step 2 adds to Jackett, Step 3/4 add to Sonarr/Radarr as Torznab.

To *replace* a dead indexer: delete the old entry from `config.yml`, manually delete from Jackett + Sonarr/Radarr UI, then run configure.sh to add the replacement.

### Adding a new Jellyfin library

1. `vim config.yml` — add to `jellyfin.libraries`.
2. `./scripts/configure.sh` — Step 5 creates it via `/Library/VirtualFolders`.
3. Jellyfin scans the new folder asynchronously.

### Log viewing

```bash
docker compose logs -f <service>          # tail all
docker compose logs --since 1h <service>  # last hour
docker compose logs --tail 100 <service>  # last 100 lines
```

Log rotation: `x-logging` anchor (`&default-logging` in `docker-compose.yml`) caps each service at 3 x 10 MB rotated json-files.

## Recovery

### After host reboot

Services with `restart: unless-stopped` (all default-profile services) come back automatically with Docker. wg-easy (remote profile) needs:

```bash
docker compose --profile remote up -d
```

No re-run of `setup.sh` or `configure.sh` is needed — existing `config/` state is preserved and `restart: unless-stopped` handles the rest.

### After partial configure.sh run

Re-run it:

```bash
./scripts/configure.sh
```

Each step checks for existing state first (`log_skip` paths) and only creates missing pieces. Safe on any mixture of configured/unconfigured services.

### Jellyfin wizard broken state

`configure_jellyfin()` in `scripts/services/jellyfin/main.sh` flags this when the wizard reports complete but admin auth fails:

```
To recover: stop the stack, delete ./config/jellyfin, and re-run setup.
```

**This discards Jellyfin's database** — watched state, user accounts, metadata. If the user has only just set things up, the cost is low. For an established install, manual recovery (restore DB, diff log lines) is preferable to the sledgehammer.

### NPM locked out

If `scripts/services/npm/main.sh` logs `NPM password rotation FAILED`:

- Stop the stack.
- `docker compose run --rm --entrypoint sh npm` → `cd /data && sqlite3 database.sqlite` → `DELETE FROM user;` → exit.
- Restart. NPM rebuilds as empty-user state, next configure.sh will seed correctly with `JELLYFIN_ADMIN_PASSWORD` + `NPM_ADMIN_EMAIL`.

## Observations / open questions

- **No rollback in update.sh.** Pull + recreate is one-way. The default path now leaves dangling images in place, but there is still no scripted rollback to a prior image hash. Stable-channel digest pins make installs more reproducible, but rollback to a prior accepted digest is not automated.
- **Update script doesn't stop services first.** `docker compose up -d` after `pull` recreates in dependency order, but there's a brief window where a new Sonarr is talking to an old qBittorrent (or vice versa). For minor updates this is fine; for API-breaking bumps, not.
- **Backups are out of scope.** MediaStack does not ship backup or restore tooling. Users should use their NAS, filesystem snapshots, or another backup system for long-term data protection.
- **`.nvidia-patch` clone is in the repo working tree.** `.gitignore` excludes it, but it's still in `ls`. Arguably better under `~/.cache/` or `/var/lib/`.
- **nvidia-patch compatibility now requires explicit MediaStack updates.** This reduces the root-executed upstream-code risk, but a brand-new NVIDIA driver may remain unsupported until `NVIDIA_PATCH_REPO_COMMIT` is reviewed and bumped.
- **Re-run of configure.sh after indexer removal leaves stale state.** No reconciliation. Users who edit `config.yml` to *remove* things are not served. Documented explicitly here but likely to surprise.
