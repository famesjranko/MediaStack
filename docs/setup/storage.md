# Storage Modes

MediaStack supports three Stage 1 storage paths:

| Mode | `.env` state | What MediaStack manages |
|------|--------------|-------------------------|
| Local managed | `STORAGE_MODE=local`, `STORAGE_APP_WIRING=managed` | Creates the standard `/data` layout and configures app storage paths. |
| NFS/NAS managed | `STORAGE_MODE=nas`, `STORAGE_APP_WIRING=managed` | Mounts/verifies an NFS export, creates the standard layout on it, and protects data services with a watchdog. |
| Manual app wiring | `STORAGE_APP_WIRING=manual` | Starts services and configures auth/API integrations, but skips app-level media/download paths. Can still use `STORAGE_MODE=nas` for NAS protection. |

`DATA_DIR` is the path mounted into containers as `/data`. For NAS installs,
`STORAGE_MOUNTPOINT` is the actual NFS mountpoint and `DATA_DIR` may either be
that mountpoint or a subdirectory such as `${STORAGE_MOUNTPOINT}/mediastack`.

## Managed NFS/NAS Flow

Stage 1 collects the connection details first, verifies them, and only then asks
the fiddly options — so nothing tedious is answered before the NAS is proven
reachable:

1. **Local mountpoint** (usually `/data`), **NAS host/IP**, **NFS export path** —
   the three things needed to reach the share.
2. **Verify** the share non-destructively (see below), one line per check.
3. **NFS mount options** — a yes/no accepts the recommended defaults; "no" opens
   an editable field and **re-verifies** with the custom options (the initial
   probe ran on the defaults, so custom options are otherwise unproven), warning
   that custom options are advanced and unsupported.
4. **Whether to enable the NAS mount watchdog** (recommended).
5. A single **review box** lists every choice (NAS server, mount point, NFS
   options, watchdog) with a menu underneath: *Confirm and continue / Change NFS
   options + watchdog / Change NAS address, export or mount point / Change storage
   type / Abort installation*. "Change …" jumps back to that layer; "Change
   storage type" returns to the storage-backend menu. Confirming only locks in the
   choices — nothing is mounted or configured until install.

The sentinel path is internal, always `${DATA_DIR}/.mediastack-storage-ready`,
and not prompted.

Setup installs `nfs-common` only when NAS storage is selected and the NFS mount
helpers are missing.

**Verify, don't mount (during the wizard).** The wizard does **not** mount the
share at the real mountpoint while you are choosing settings. Instead
`storage_probe_nas` verifies it non-destructively — it mounts to a throwaway
temporary directory (never `${STORAGE_MOUNTPOINT}`), runs one check per line, then
unmounts and cleans up. Because the real mountpoint is never touched, changing a
setting can never collide with a prior mount and you are never asked to detach
anything. The checks:

1. **NAS reachable** — TCP to `host:2049` (NFSv4), falling back to `:111`.
2. **NFS export available** — a temporary mount with fail-fast options (`hard`
   swapped for `soft` + a short `timeo`/`retrans`) so a bad target errors quickly
   instead of hanging.
3. **Share readable**.
4. **Share writable** — tested as the installing user (mirrors how MediaStack
   creates directories and the sentinel), so read-only exports and root-squash are
   caught up front.

All green ⇒ the share is classified (see below) and the per-section "Use these
storage choices?" confirm locks it in. Any failed check raises the specific
failure and offers edit / retry / use local storage — never a detach prompt.

The **real** `${STORAGE_MOUNTPOINT}` mount happens later, at install time
(`storage_preflight_nas`, after `.env` is written). It tries `mount -t nfs4`
first, then falls back to generic `nfs` with the same options.

After a successful mount, MediaStack records the live `findmnt` source and
fstype in `.env` as `STORAGE_EXPECTED_SOURCE` and `STORAGE_EXPECTED_FSTYPE`.
Later guards compare the live mount against those recorded values instead of
only checking whether the directory exists. This prevents writes into an empty
local fallback directory when the NAS is not mounted.

The sentinel must be inside `STORAGE_MOUNTPOINT`. Setup creates it if missing
and treats a missing, inaccessible, or out-of-mountpoint sentinel as storage
failure.

## Share Classification

Before creating managed directories, Stage 1 classifies the NAS data root:

| Result | Meaning | Managed-mode behavior |
|--------|---------|----------------------|
| `empty` | No existing entries | Use it directly. |
| `mediastack` | Existing `media/` and `torrents/` directories | Use it directly. |
| `nonempty` | Existing unrelated files/directories | Offer a new `mediastack/` subfolder, local storage, manual app wiring, or quit. |
| `conflict:*` | `media` or `torrents` exists but is not a directory | Offer the same fallback choices. |

Managed NAS mode does not recursively `chown` the NAS root. It creates missing
MediaStack directories and only tries to change ownership for directories it had
to create with `sudo`, so root-squashed exports can still work.

Only NFS is implemented as a managed network-storage backend. The SMB feature
covers LAN file access to MediaStack data, not a second storage backend.

## Guards And Watchdog

The watchdog is opt-out per NAS install (`STORAGE_WATCHDOG`, default on). The
Stage 1 wizard asks "Enable the NAS mount watchdog?" and it can be flipped later
from the day-2 **Features & settings** menu ("NAS storage watchdog", shown only
on NAS installs). When off, NAS storage is still mounted and verified once at
install, but neither protection layer below runs — `storage_guard_before_start`
returns success and no systemd unit is installed. The marker/sentinel path is
internal and no longer user-configurable.

Install needs `visudo` to validate the sudoers rule, and the NFS client needs
`mount.nfs`. Both live in `/usr/sbin`, which a normal user's `PATH` omits on
Debian, so MediaStack looks there too (`host_tool_path` in `scripts/lib/host-tools.sh`).
If the watchdog is wanted but its unit is missing (for example an install made
before that lookup existed), **Apply changes from a MediaStack update** installs it.

When on, NAS mode has two protection layers:

1. `storage_guard_before_start` runs before `start_stack`, the launcher start
   action, and `scripts/update.sh` recreate containers. It refuses to start if
   the expected mount identity or sentinel check fails.
2. `mediastack-storage-watchdog.service` runs as the installing user and checks
   the mount/sentinel continuously. A narrow root-owned helper under
   `/usr/local/libexec/mediastack/` can repair the mount using root-owned
   settings from `/etc/mediastack/storage.env`.

When NAS storage is enabled, generated compose overrides set `restart: "no"`
for NAS-dependent services so Docker does not bring them back before storage is
ready after reboot. The watchdog restarts the known protected set only after the
mount is stable:

- `jellyfin`
- `qbittorrent`
- `sonarr`
- `radarr`
- `seerr`
- `unpackerr`
- `bazarr` when subtitles are enabled

If the NAS becomes unavailable while services are running, the watchdog stops
the same data-dependent services. It records the stop time in
`config/state/storage-watchdog-stopped` and the service names in
`config/state/storage-watchdog-stopped-services`. When storage recovers, it
restarts only those services. If the watchdog started while the NAS was already
down (a host boot), it records every data service, because none was running.

The watchdog does not restart a service the user stopped. On NAS installs the
launcher writes `config/state/user-stopped-services`, one service name per line:

- **Stop a service** adds the service. **Stop all services** adds the whole set above.
- **Start a service** removes the service. **Start all services** empties the file.
- At boot and after an outage the watchdog skips every service in the file, and
  every service that depends on one of them, directly or through another service
  (for example Seerr when Jellyfin is in the file). `docker compose up -d` starts a
  service's dependencies, so starting the dependent would start the stopped service.
  The watchdog reads the dependencies from `docker compose config` once per start
  and logs `leaving <service> stopped: it depends on <service>, which you stopped`.
  If that configuration cannot be read while the file has entries, the watchdog
  starts nothing and retries. Mount identity and sentinel checks still pass first.
  Nothing starts before they do.
- A running service outranks its entry: the watchdog drops the entry.
- A missing or empty file means no user stops. Lines that are not plain service names
  and names that are not data services are ignored. If the file exists but cannot be
  read, the watchdog starts nothing and retries until it can read it.

**Start a service** in the launcher also starts the service's stopped dependencies.
The watchdog then finds them running and drops their entries.

Only launcher actions are tracked. Stops made with direct `docker` commands, and
services that `setup.sh` or `scripts/update.sh` start again, are not. Uninstall
removes the file with the rest of `config/state/`.

## Manual App Wiring

Manual app wiring is independent from NAS protection. With
`STORAGE_APP_WIRING=manual`, `configure.sh` still configures credentials,
auth, indexers, quality profiles, monitoring, and other non-storage services,
but skips:

- qBittorrent save paths and categories.
- Sonarr/Radarr root folders and qBittorrent download clients.
- Jellyfin libraries.
- Seerr Jellyfin/Sonarr/Radarr storage links.
- Unpackerr watched torrent paths.

This is for existing libraries or custom layouts where MediaStack should not
own path choices. If the user also enables NAS guard/watchdog, MediaStack still
protects starts and stops around the selected mount/sentinel.

## Operations

Useful checks on a NAS install:

```bash
findmnt -rn -M /data -o SOURCE,FSTYPE,OPTIONS
test -e /data/.mediastack-storage-ready
systemctl status mediastack-storage-watchdog.service
journalctl -u mediastack-storage-watchdog.service -f
```

If `./mediastack` or `scripts/update.sh` refuses to start services, fix the NAS
mount first, then retry the same command. Do not create `media/` or `torrents/`
under an unmounted local fallback path; that masks the failure the guard is
trying to prevent.

The root-owned repair helper only ever detaches an NFS mount it owns. If the
mountpoint holds a non-NFS filesystem, is listed in `/etc/fstab` for a different
source, or is a live NFS mount that is still in use, the helper logs the refusal
(`journalctl -t mediastack-storage-helper`) and exits non-zero; the watchdog
leaves NAS-dependent services stopped until an operator resolves it by hand.
Lazy detach is used only for a mount that no longer answers.

Changing from local storage to NAS, changing exports, or moving existing media
is not an automatic migration path. Stop the stack first and treat the move as a
manual storage migration; MediaStack will not reconcile app paths or move media
between backends.

## Verification

Fast coverage:

```bash
bash tests/unit/storage.sh
bash tests/unit/watchdog-intent.sh
./tests/run.sh --no-preload nas-storage
./tests/run.sh --no-preload nas-watchdog-intent
```

The DinD `nas-storage` scenario starts a disposable NFS server inside the test
VM, verifies mount identity and sentinel checks, proves directory creation lands
on the export, rejects unmounted fallback writes, exercises wrong-mount repair,
and verifies watchdog restart behavior. The `nas-watchdog-intent` scenario
restarts the DinD host (its Docker daemon, watchdog and mount) with real
containers and shows that a service stopped from the launcher stays stopped, at
boot and after an outage, while the others come back. On a kernel that cannot run
an NFS server in DinD it uses a tmpfs mount with the same identity and sentinel
gate, so it then does not exercise NFS.

DinD does not prove vendor-specific NAS behavior such as Unraid/Synology export
policy, root-squash variants, or long-running stale file handles. The watchdog
proves mount identity plus sentinel availability; it cannot guarantee every NAS
failure mode is recoverable, and a hard NFS hang can still block kernel I/O
longer than a user-space timeout catches.
