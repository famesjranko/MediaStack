# Operations

Day-2 scripts under `scripts/` and routine operational tasks. Backup and
long-term data protection are intentionally out of scope for MediaStack.

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
(ADR-30). It is channel-agnostic in detection and policy-aware in apply.

**Status scan.** `python3 scripts/image-drift.py --status` (table) / `--status-tsv` (machine)
reports, per service, a **Policy** (`Stable (tested)` / `Upstream tag`, with `*` marking a manual
override) and a **Status**:

| Status | Meaning |
|---|---|
| `On tested Stable` | running the maintainer-tested digest; nothing newer upstream |
| `Tested Stable update available` | the lock advanced (after `git pull`) — apply to get the tested digest |
| `Untested upstream update available` | on the tested digest, but upstream moved past it |
| `Up to date` | upstream-tag service already on the newest tag digest |
| `Upstream update available` | upstream-tag service has a newer tag digest |
| `Not installed` | no container exists for this service |
| `Unknown local digest` | container running, but its repo digest can't be resolved (locally built/imported) |
| `Unknown (offline)` | registry unreachable, can't compare upstream |

The TSV is `service<TAB>policy<TAB>override<TAB>status<TAB>updatable`, where `override` is `manual`
(explicit per-service row) or `default` (inherits the global channel). The running digest is read
from the **image object** (`docker image inspect … RepoDigests`, repo-matched), not the container;
both it and the upstream digest are manifest-list digests, so the comparison is multi-arch safe. The
command reads `IMAGE_CHANNEL` from the exported env (the launcher sources `.env`) or, when run
directly, from the `.env` beside the compose file — so a Latest install is labelled correctly either
way.

**Menu actions.**
- **Update a service / Update all upstream-tag services** — float the service(s) to their compose
  tag. On a Stable install this records a sticky per-service `latest` override in
  `config/state/image-policy.tsv` and labels them "outside the tested Stable baseline." A service
  showing a *tested* Stable update instead applies in-channel (no float). "Update all" targets only
  services with an *upstream* (ahead-of-tested) update and **excludes WireGuard**; a single
  WireGuard update needs an extra confirm (it can disconnect the VPN client running it).
- **Pull tested Stable updates (recommended)** — runs `scripts/update.sh` (the safe path that pulls
  new *tested* digests after a repo update).
- **Reset a service to the default channel** — clears the service's explicit override so it follows
  the global channel again (re-pins to the lock under Stable). Lists only services with a manual
  override (excluding `Not installed`).
- **Switch default channel** — toggles `IMAGE_CHANNEL`; affects only services without an override.

Update and reset only **recreate a service that is already running**; a stopped service has its new
image pulled and staged but is **not started** — the change applies the next time the stack starts.

Every apply regenerates `docker-compose.override.yml` (preserving GPU/mem/NAS settings), runs the
storage guard, and recreates only the touched service (no `--remove-orphans`). "latest" follows the
**compose tag**, so ADR-24 pins hold: `npm:2`/`uptime-kuma:2`/`wireguard:15` stay within their
pinned major — floating WireGuard pulls the newest 15.x but never v14 or a future v16. The lock
file is never edited by this path.

## `./mediastack` → Manage hardware transcoding

The launcher's post-install **"Manage hardware transcoding (GPU)"** screen is the
day-2 surface for GPU driver/encoder changes. It is intentionally separate from
**Manage updates**, which only manages container images.

Actions:

- **Configure or change hardware transcoding** — delegates to `./setup.sh --transcoding`.
  This re-detects the GPU and runs the Stage 3 hardware engine without rerunning Stage 1/2.
  NVIDIA users can choose **Standard driver** or **Unlock NVENC limit (advanced)** here.
- **Repatch NVIDIA driver (Unlock mode)** — runs `scripts/nvidia-repatch.sh` when the
  current install is NVIDIA/Unlock. Standard and `existing` driver modes are no-ops.
- **Reboot to finish hardware transcoding** — appears when an NVIDIA finalize marker is
  waiting on the current boot.

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
- **Quality profile edits** are name-keyed. If you change `quality_profile.name` in `config.yml`, configure.sh creates a *new* profile alongside the old one. You must delete the old one manually via Sonarr/Radarr UI and switch existing series to the new profile.
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
