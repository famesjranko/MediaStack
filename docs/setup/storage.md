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

Stage 1 collects:

- Local mountpoint, usually `/data`.
- NAS host/IP.
- NFS export path.
- NFS mount options.
- Sentinel file path, defaulting to `${DATA_DIR}/.mediastack-storage-ready`.

Setup installs `nfs-common` only when NAS storage is selected and the NFS mount
helpers are missing. It tries `mount -t nfs4` first, then falls back to generic
`nfs` with the same options.

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

## Guards And Watchdog

NAS mode has two protection layers:

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
the same data-dependent services and records state in
`config/state/storage-watchdog-stopped`. When storage recovers, it restarts the
services it owns.

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

Changing from local storage to NAS, changing exports, or moving existing media
is not an automatic migration path. Stop the stack first and treat the move as a
manual storage migration; MediaStack will not reconcile app paths or move media
between backends.

## Verification

Fast coverage:

```bash
bash tests/unit/storage.sh
./tests/run.sh --no-preload nas-storage
```

The DinD `nas-storage` scenario starts a disposable NFS server inside the test
VM, verifies mount identity and sentinel checks, proves directory creation lands
on the export, rejects unmounted fallback writes, exercises wrong-mount repair,
and verifies watchdog restart behavior.

DinD does not prove vendor-specific NAS behavior such as Unraid/Synology export
policy, root-squash variants, or long-running stale file handles.

## Observations / open questions

- Only NFS is implemented for managed network storage. The SMB feature is for
  LAN file access to MediaStack data, not as a backend storage protocol.
- There is no automatic storage migration after install. That is deliberate for
  now because moving media and rewriting app libraries/download clients is
  destructive if guessed wrong.
- The watchdog proves mount identity plus sentinel availability, but it cannot
  guarantee all NAS failure modes are recoverable. Hard NFS hangs can still
  block kernel I/O longer than user-space timeouts.
