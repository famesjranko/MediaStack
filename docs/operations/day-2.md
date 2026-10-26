# Day-2 internals

Contributor reference for the day-2 scripts under `scripts/` and the launcher
actions that call them. For the user procedures, see the guides:
[Use the MediaStack menu](../guide/using-the-menu.md) and
[Troubleshooting](../guide/troubleshooting.md). Backup and long-term data
protection are intentionally out of scope for MediaStack.

## `./mediastack` → Uninstall MediaStack

User steps: [Remove MediaStack](../guide/install.md#remove-mediastack).

Uninstall is a typed-`DESTROY`, transactional action. It stops every Compose profile, verifies no project containers remain, then removes tagged UFW rules, the live Docker firewall chain, MediaStack APT drop-ins, a MediaStack-written Docker apt source that cannot work on this host (a working one stays, because Docker Engine stays installed and the source keeps it patched), unchanged sysctl hardening, Samba ownership (MediaStack-installed Samba is purged, not just removed, and the Linux account MediaStack created is deleted when nothing outside MediaStack's paths uses it; no autoremove runs, so Samba's dependency packages stay), watchdog units, and setup banners. `data/`, `config/examples/` and the checkout are preserved. `config/` runtime state, `.env`, `config.yml`, the generated compose override, and MediaStack's labelled Docker volumes and networks are removed.

The ownership ledger is `/etc/mediastack/install-state`. Missing or malformed state aborts the recorded teardown and instead offers a best-effort cleanup of the host changes MediaStack can still identify on its own. Docker or host-cleanup failure retains `.env` and the ledger so the same action can be retried. User-modified MediaStack-owned files are preserved and reported instead of overwritten or deleted.

## `scripts/update.sh`

Wrapper around `docker compose pull && up -d` for the configured image channel.

Flow (`scripts/update.sh`):

1. **Override refresh** — reads `IMAGE_CHANNEL` from `.env`, regenerates `docker-compose.override.yml`, and validates `docs/operations/image-digests.lock` for Stable.
2. **Profile selection** — `profiles_build_args` reads the enabled optional profiles from `.env` (the same table the installer and launcher use) and passes their `--profile` flags to the later commands. An enabled service that is stopped or crashed is recreated too. Without the flags, `pull` would skip optional-profile services.
3. **Pull** — `docker compose $PROFILE_ARGS pull`. Stable pulls the tested `tag@sha256:digest` refs from the generated override; Latest pulls the tags in `docker-compose.yml`.
4. **Recreate** — `docker compose $PROFILE_ARGS up -d --remove-orphans`. `--remove-orphans` cleans up containers from services that have been deleted from the compose file.
5. **Optional prune** — only when run with `--prune`, calls `docker image prune -f` to reclaim disk from dangling images. This prune is host-wide, so the default update path skips it.
6. **Converge** — runs the same steps as **Health & security → Apply changes from a MediaStack update** (admin-port filter, qBittorrent legacy whitelist, Beszel system entry, unused Beszel UFW rule, WireGuard UFW rule, missing NAS watchdog; see that section). A failure is reported after the status table and makes the script exit non-zero.
7. **Status** — `ps` summary.

**What it does NOT do:**

- No pre-pull health snapshot — if a new image is broken, you lose the working one before you know it.
- No rollback — `docker compose up -d` with the prior image hash isn't automated. The default path retains dangling images; `--prune` removes them host-wide after the update.
- Stable-channel installs are runtime-pinned to `docs/operations/image-digests.lock`; Latest-channel installs intentionally follow upstream tags.
- No config migration — it assumes images accept existing `config/<svc>/` state. Major-version bumps may need manual `configure.sh` re-runs.
- No stop-first ordering — `pull` then `up -d` recreates containers in dependency order, so there is a brief window where a freshly-recreated service talks to a not-yet-recreated one (e.g. a new Sonarr against an old qBittorrent). Fine for minor bumps; worth watching for API-breaking ones.

## `./mediastack` → Health & security → Apply changes from a MediaStack update

User steps: [Update MediaStack itself](../guide/using-the-menu.md#update-mediastack-itself). After you pull new MediaStack code onto a finished install, run this action once. A finished install never re-runs setup or configure on its own: **Install MediaStack** ends at the existing-install menu with "No changes made", and a re-run with `STAGE_1_COMPLETE=1` skips configure. So a release that changes MediaStack's own host or service state cannot reach the box unless this action applies it. The main-menu "Admin-port filter NOT active" warning and the Health & security firewall check name this action as the fix.

It changes only MediaStack's own artefacts, and each step is idempotent:

1. **Admin-port filter** — runs `setup_admin_filter`. It installs `mediastack-admin-filter.service` and the `docker.service` drop-in, applies and verifies the chain, and only then strips a legacy MediaStack block from `/etc/ufw/after.rules`, `after6.rules` and `after.init`. `ADMIN_PORT_FILTER=false` installs nothing. A failed apply is reported, the legacy block stays in place, and the action returns non-zero.
2. **qBittorrent auth whitelist** — if the live whitelist is exactly MediaStack's old `172.16.0.0/12` (enabled), it is narrowed to the Sonarr, Radarr and Homepage `/32` addresses. Any other value is yours: it is reported as drift and left alone. If qBittorrent is not running the step is skipped with a hint; start the stack and run the action again. An unreadable or unsaved preference makes the action fail so you can retry.
3. **Beszel system entry** — if the hub's "MediaStack" system is exactly MediaStack's old `host.docker.internal` port `45876` entry, it is moved to the agent's unix socket. Any other host or port is yours: it is reported as drift and left alone.
4. **Unused UFW rule** — earlier releases opened port 45876 to the Docker networks with the UFW comment `MediaStack:Beszel-agent`. The agent no longer listens on TCP, so this rule is deleted. Only a rule whose comment is exactly that one is removed; other rules are never touched. The step is silent when UFW is off or the rule is absent.
5. **WireGuard UFW rule** — runs `setup_ufw_wireguard_clients`. While the `remote` profile is enabled (`WG_INIT_PASSWORD` set) and UFW is active, it ensures one rule, `ufw allow from <wireguard container /32> to any` with the comment `MediaStack:WireGuard-clients`. The address is `${MEDIASTACK_NETWORK_PREFIX:-172.28.0}.11`. In every other state (WireGuard removed, UFW off or inactive, `UFW_ENABLED=false`) it removes the rule. Rules are matched by their exact comment; a changed prefix replaces the old source. This is how an install that predates the rule receives it (see [WireGuard host rule](#wireguard-host-rule)).
6. **NAS storage watchdog** — on a NAS install with `STORAGE_WATCHDOG` not `false`, a missing `mediastack-storage-watchdog.service` is installed with `storage_install_watchdog`. Releases before the sbin-aware tool lookup skipped the install with only a warning when `visudo` was not on the user's `PATH`, so a rebooted box stayed unmounted with nothing to repair it. The action fails if the unit is still missing afterwards.

All steps always run, so a filter failure never hides a later step. Your own choices (UFW, quality, DDNS, features) are not touched. `scripts/update.sh` runs the same steps after it recreates the containers, so `git pull` followed by an update converges too. If a step fails there, the update still finishes, then exits non-zero and names this action.

## `./mediastack` → Manage updates (per-service)

User steps: [Manage updates](../guide/using-the-menu.md#manage-updates). This section holds the
state model behind the screen.

`stable`/`latest` is an **install-time** choice only (see
[Stable and latest images](../guide/using-the-menu.md#stable-and-latest-images)); post-install every
update is a uniform, manual opt-in, so detection and apply are channel-agnostic.

**Status scan.** `python3 scripts/image_drift.py --status` (table) / `--status-tsv` (machine)
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

**Policy files.**
- **Update a service / Update all** — a service still on its installed (pinned) digest floats to its
  compose tag, recorded as a sticky per-service `latest` override in `config/state/image-policy.tsv`;
  one already tracking its tag just pulls the newer digest. "Update all" excludes WireGuard; a single
  WireGuard update needs an extra confirm (it can disconnect the VPN client running it).
- **Revert a service to its installed image** — re-pins the service to the digest recorded at install in
  `config/state/image-install.tsv`, on **any** channel, written as a per-service digest pin in
  `config/state/image-policy.tsv`. If the installed image is no longer available upstream, the recreate
  is rolled back onto the service's previous cached image rather than left down.
- **Restore points.** Before an update moves a service off its installed image, a restore point of
  `config/<service>` (up to 256 MiB) is saved while the service is stopped. Revert restores it with the
  old image, then checks service health and MediaStack's logins to qBittorrent, Sonarr, Radarr and
  Jellyfin. A failed check keeps the restore point. With no restore point, Revert warns and asks to
  confirm.
- **Skips.** The Revert list shows only installed services with a manual override. **Update all** skips
  stopped services and lists them as skipped.

There is no day-2 channel toggle: changing the channel means re-running the installer. The CLI
`scripts/update.sh` remains a bulk re-pull per the current override.

Update and revert only **recreate a service that is already running**; a stopped service has its new
image pulled and staged but is **not started** — the change applies the next time the stack starts.

Every apply regenerates `docker-compose.override.yml` (preserving GPU/mem/NAS settings), runs the
storage guard, and recreates only the touched service (no `--remove-orphans`). "latest" follows the
**compose tag**, so the compose tag pins hold (see [pin policy](upgrades.md#pin-policy--recovery-model)): `npm:2`/`uptime-kuma:2`/`wireguard:15` stay within their
pinned major — updating WireGuard pulls the newest 15.x but never v14 or a future v16. The lock
file is never edited by this path.

## `./mediastack` → Manage hardware transcoding

User steps: [Manage hardware transcoding (GPU)](../guide/using-the-menu.md#manage-hardware-transcoding-gpu).
The screen is separate from **Manage updates**, which only manages container images.

- **Configure or change hardware transcoding** delegates to `./setup.sh --transcoding`, which
  re-detects the GPU and runs the Stage 3 hardware engine without rerunning Stage 1/2.
- **Update NVIDIA driver + reapply Unlock patch** is available only for an active NVIDIA/Unlock
  configuration. The guarded setup action defaults to No, downloads before mutation, refuses loaded
  modules, installs once, and patches only after reboot/version verification.
- **Reapply Unlock patch only** uses the same guarded route and the reviewed pinned patch. Both
  Unlock actions stay hidden and fail closed for Standard, externally managed, and non-NVIDIA installs.
- **Reboot to finish hardware transcoding** appears while an NVIDIA finalize marker waits on the
  current boot.

## `./mediastack` → Features & settings → Change quality profile

User steps: [Change the quality profile](../guide/using-the-menu.md#change-the-quality-profile). The
action (under **Features & settings**) re-picks the quality cell without re-running the wizard or
hand-editing `config.yml`.

Flow:

1. **Guards** — Docker reachable and **both Sonarr and Radarr running** (a split rename across the two
   apps is avoided by requiring both up front).
2. **Pick** — the same two-axis picker the wizard uses (`scripts/lib/quality-select.sh`): resolution
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

User steps: [Change the DDNS provider or credentials](../guide/remote-access.md#change-the-ddns-provider-or-credentials).
The action swaps the dynamic-DNS provider, or re-enters its credentials, reusing the provider
picker, JSON renderer and ephemeral verify of the setup wizard (`scripts/lib/ddns-providers.sh` +
`scripts/lib/network.sh`). The row is shown only once remote access uses DDNS; otherwise **Add remote
access** applies.

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

**DDNS status display.** The main-menu `DDNS:` line and the **Manage stack** line show the confirmed
IP against the detected WAN IP; the states are in
[Check it works](../guide/remote-access.md#check-it-works). The banner caches the Public IP and DDNS IP
for the session, so they refresh only through **Refresh status**
([guide](../guide/using-the-menu.md#refresh-status)).

## `./mediastack` → Features & settings → Firewall (UFW) / System hardening

User steps: [Firewall, admin-port filter, and hardening](../guide/using-the-menu.md#firewall-admin-port-filter-and-hardening). Three ON/OFF toggles mirror the Stage 1 wizard's Security prompts, backed by `UFW_ENABLED`,
`ADMIN_PORT_FILTER` and `HARDENING_ENABLED` in `.env`:

- **Firewall (UFW)** — ON runs `setup_ufw` (default-deny inbound, LAN/SSH/web allowed),
  reopening remote service ports only on a real-domain install, then converges the
  [WireGuard host rule](#wireguard-host-rule). It does not touch the admin-port
  filter chain (see the next toggle). OFF runs `_uninstall_ufw`,
  then resets the ownership latches so a later ON reconfigures cleanly. If you added your own UFW
  rules or changed the defaults after install, OFF removes only MediaStack's rules and **leaves UFW
  active**, telling you so — and because that removal also drops MediaStack's SSH allows, it
  re-asserts an SSH allow (RFC1918 LAN ranges + your current SSH session) so a remote/headless box
  can never be locked out. Run `sudo ufw disable` yourself if you want the firewall fully off.
- **Admin-port filter** — ON (the default) runs `setup_admin_filter`, which installs the
  `MEDIASTACK-DOCKER-RESTRICT` chain (via `mediastack-admin-filter.service` and a `docker.service`
  drop-in) so the admin UIs answer only to loopback, private and Tailscale sources. It works with UFW
  on or off. OFF runs `admin_filter_disable` and asks first, because ports 81, 51821, 8000, 3001, 9000,
  the *arr and download UIs and 7359/udp then answer any source your router forwards. Docker keeps
  running during both. When the filter is wanted but not active, Health shows it and the main menu
  prints a warning line.
- **System hardening** — ON applies unattended security upgrades + kernel sysctl hardening; OFF
  reverts both (`_uninstall_sysctl` + `_uninstall_apt`), restoring pre-install sysctl values it still
  owns and removing the MediaStack drop-ins. ON applies only MediaStack's own sysctl file and fails loudly if a key does not take effect or
  `ip_forward` changes. UFW's `/etc/ufw/sysctl.conf` can override `log_martians` on each UFW reload;
  setup and the OFF message then say that UFW owns the key.

- **File sharing (SMB)** — OFF removes MediaStack's share block and its `MediaStack:SMB-LAN` firewall
  rules and resets `SMB_SHARE_SCOPE` to `data`. It stops and disables `smbd`/`nmbd` only when
  MediaStack installed Samba; a Samba that was already there keeps running with the user's own shares.
  User steps: [Share files on your LAN](../guide/using-the-menu.md#share-files-on-your-lan).

Both ON actions refuse (warn + skip) when no valid ownership ledger exists — run a full install or
reset first. Toggling is add-only: turning a feature off never deletes user data or user-owned
firewall/kernel settings.

### WireGuard host rule

With UFW on, the `wireguard` container masquerades every peer behind its own address
(`${MEDIASTACK_NETWORK_PREFIX:-172.28.0}.11`). Peer traffic to host services and to published
ports (docker-proxy) reaches the host's INPUT path from that one address, where UFW's default
deny drops it. MediaStack therefore owns one rule, `ufw allow from <that /32> to any` with the
comment `MediaStack:WireGuard-clients`. It exists only while the `remote` profile is enabled and
UFW is active, and it is never widened to the Docker range. The rule does not grant peers
access: wg-easy's per-peer `firewallIps` still decide which addresses and ports each tier reaches.

| Event | Effect on the rule |
|---|---|
| Stage 2 / **Add remote access** with WireGuard accepted | Added |
| Stage 2 / **Add remote access** with WireGuard declined | Removed |
| Firewall (UFW) toggled ON | Added if WireGuard is enabled |
| Firewall (UFW) toggled OFF, or uninstall | Removed with the other `MediaStack:*` rules |
| **Apply changes from a MediaStack update** | Added, replaced or removed to match the state above |

## `./mediastack` → View storage & data mount

Shown **only on NAS installs** (`STORAGE_MODE=nas`) as a top-level menu item — local
installs have no mount to inspect (data dir + free space already show in **Manage stack**).
A read-only status box built entirely from the `storage_*` getters in
`scripts/setup/storage.sh`. User steps: [View storage & data mount](../guide/using-the-menu.md#view-storage--data-mount). Fields:

- **NAS source** — the expected `host:/export` (`storage_expected_source`).
- **Filesystem** — expected type plus live state: `mounted, healthy`; `mounted, verifying…`
  (sentinel not yet present); `WRONG: <live source> (<live fstype>) — expected nfs4` when a
  different disk is mounted at the mountpoint; `not mounted`; or `NAS unreachable` when the
  mount does not answer. Every probe that touches the mount has a deadline
  (`STORAGE_PROBE_TIMEOUT`, default 5 s), so a hard NFS mount that stalls while the server is
  down cannot hang the screen.
- **Data** — the data dir and free space (`df -h`); skipped while the NAS is unreachable.
- **Watchdog** — `running`, `running (services paused — NAS down since <ts>)`, `installed but
  stopped`, `not installed (nothing will remount the NAS)`, or `disabled`, from the unit file,
  its `systemctl is-active` state and the `config/state/storage-watchdog-stopped` flag.
- **Services** — how many of the NAS-dependent services (`storage_data_services`) are running.

The one action, **Re-check NAS now**, re-runs `storage_nas_ok` (mount + sentinel) and reports a
verdict; the box then redraws with the live mount state. Remount/restart are intentionally not
offered here — a running watchdog already auto-repairs the mount and restarts paused services.
When the check fails, the message states the real watchdog state: running (it keeps retrying),
installed but stopped, turned off, or not installed (run **Apply changes from a MediaStack update**).

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

Repatch wrapper for after NVIDIA driver updates — relevant **only in Unlock NVENC mode** (`NVIDIA_DRIVER_MODE=unlock`). Standard (Debian-managed) and `existing` installs are not patched and are maintained by apt, so the script is a no-op there with guidance (override with `--force`). See [GPU detection + Hardware Transcoding ownership](../setup/setup-flow.md#gpu-detection--hardware-transcoding-ownership) for how the driver mode is chosen.

Flow:

0. Parse args (`--force` to patch regardless of mode; unknown args error with usage). Read `NVIDIA_DRIVER_MODE` from `.env`; if it is not `unlock` and `--force` was not given, print "nothing to repatch" and exit 0.
1. Refuse if `nvidia-smi` is missing — no drivers loaded.
2. Read current driver version.
3. Verify `keylase/nvidia-patch` in `$SCRIPT_DIR/.nvidia-patch` (gitignored) at the reviewed commit pinned in `scripts/lib/nvidia-patch.sh`. Dirty local trees and unexpected origins are rejected.
4. Export that pinned commit to a temporary execution directory; root never executes files from a moving branch checkout. The `.nvidia-patch` clone itself lives in the repo working tree (gitignored, so it never gets committed) rather than a cache directory like `~/.cache/` — it shows up in a plain `ls` of the checkout, which is expected.
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
  The **Manage fail2ban** menu views and releases bans; see
  [Manage fail2ban](../guide/using-the-menu.md#manage-fail2ban). A ban blocks **all** services, and one
  unban clears the address from **every** jail.

  The menu and health checks tell two cases apart: with no real `DOMAIN` in `.env`, fail2ban is *not
  installed (LAN-only install)*; with a domain set, it is *installed but not running*, because a stopped
  fail2ban on a remote-access host leaves the logins unprotected.

  Daily log rotation needs no action. Jellyfin and Seerr write a new dated log file each day; the
  `mediastack-fail2ban-reload.service` watcher reloads fail2ban whenever a new file appears. If the
  watcher stops, the Health & security *fail2ban jellyfin watch* check reports a jail left on a stale file.
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

### Adding an indexer or a Jellyfin library

User steps: [Add an indexer or a library](../guide/using-the-menu.md#add-an-indexer-or-a-library).
`./scripts/configure.sh` Step 2 adds an indexer to Jackett and Steps 3/4 add it to Sonarr/Radarr as
Torznab; Step 5 creates a library via `/Library/VirtualFolders`. Replacing a dead indexer stays manual:
delete it from `config.yml`, Jackett and Sonarr/Radarr, then re-run configure.sh.

### Log rotation

User steps: [Troubleshooting](../guide/troubleshooting.md#first-checks). The `x-logging` anchor (`&default-logging` in `docker-compose.yml`) caps each service at 3 x 10 MB rotated json-files.

## Recovery

User steps are in [Troubleshooting](../guide/troubleshooting.md). This section keeps the code behind them.

### After host reboot

Every service has `restart: unless-stopped`, including the optional profiles, so Docker brings all of
them back. No re-run of `setup.sh` or `configure.sh` is needed; existing `config/` state is preserved.
User steps: [After a reboot](../guide/troubleshooting.md#after-a-reboot).

### After partial configure.sh run

Each step checks for existing state first (`log_skip` paths) and only creates missing pieces, so a
re-run is safe on any mixture of configured and unconfigured services. User steps:
[Setup stopped half way](../guide/troubleshooting.md#setup-stopped-half-way).

### Jellyfin wizard broken state

`configure_jellyfin()` in `scripts/services/jellyfin/main.sh` flags this when the wizard reports
complete but admin auth fails, and prints `To recover: stop the stack, delete ./config/jellyfin, and
re-run setup.` That discards Jellyfin's database. User steps:
[Jellyfin wizard broken state](../guide/troubleshooting.md#jellyfin-wizard-broken-state).

### NPM locked out

`scripts/services/npm/main.sh` logs `NPM password rotation FAILED` when it cannot rotate the admin
password. Emptying the `user` table lets the next configure.sh seed the admin from
`JELLYFIN_ADMIN_PASSWORD` + `NPM_ADMIN_EMAIL`. User steps:
[Nginx Proxy Manager (NPM) lockout](../guide/troubleshooting.md#nginx-proxy-manager-npm-lockout).
