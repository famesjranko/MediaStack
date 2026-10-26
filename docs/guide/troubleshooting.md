# Troubleshooting

This guide is for people who run MediaStack at home and need to fix a problem without reading code.

## First checks

Do these steps before you look for a specific problem.

1. Run `./mediastack`.
2. Choose **Health & security (checks & protection)**.
3. Choose **Run all checks**. Read each warning.
4. Go back and choose **Diagnostics (ports, public IP, DNS, readiness)**.
5. Choose **System readiness check**. It tests disk space, RAM, internet, and GPU.

To see which services run, choose **Manage stack (status, stop, start, logs)**. The menu shows the state of each service.

## Services will not start

**A service is stopped or restarts again and again.**

1. Run `./mediastack`.
2. Choose **Manage stack (status, stop, start, logs)**.
3. Choose **Tail logs (live)**. Read the service-prefixed errors. Press `Ctrl+C` to return.
4. Choose **Start a service** and select the stopped service.

Or use these commands:

```bash
docker compose ps
docker compose logs --tail 100 <service>
```

**A service shows permission errors.**

1. Stop the stack: **Manage stack** > **Stop all services**.
2. Give your user the data folder. The default folder is `/data`.
3. Choose **Start all services**.

```bash
sudo chown -R $(id -u):$(id -g) /data
```

**Files are copied instead of moved.**

Downloads and media must be on one filesystem. Run `df /data/torrents /data/media`. If the lines differ, move the folders onto one filesystem. See [storage](../setup/storage.md).

**A service is unhealthy.**

MediaStack uses the `autoheal` service to restart unhealthy services. Check that `autoheal` runs in **Manage stack**.

**fail2ban blocks you.**

1. Run `./mediastack`.
2. Choose **Manage fail2ban (banned IPs, whitelist, stats)**.
3. Choose **Banned IPs** and select your address.
4. Choose **Unban**. To stop it from happening again, choose **Unban + always allow**.

A ban blocks every MediaStack service, not only the one that triggered it, and one unban clears it everywhere.

## Remote access problems

For setup steps, see the [remote access guide](remote-access.md).

First, check your domain and ports:

1. Run `./mediastack`.
2. Choose **Diagnostics (ports, public IP, DNS, readiness)**.
3. Choose **Check domain DNS**.
4. Go back and choose **Test port forwarding**, then **Test the required MediaStack ports**.

| Symptom | Likely cause | Fix |
|:--------|:-------------|:----|
| "Certificate request failed" | DNS does not point to your public IP, or port 80 is not forwarded | Fix the DNS record. Forward port 80 to the server. Try again. |
| Site does not open from outside | Port 443 is not forwarded, or DNS has not updated | Forward port 443. Wait, then run **Check domain DNS** again. |
| Site works at home but not away | Router forwarding is missing, or your ISP blocks the ports | Check the router rules. Ask your ISP if it blocks ports 80 and 443. |
| Menu shows `propagating?` for DDNS | The domain points to an old IP | Wait a few minutes. Choose **Refresh status (re-check public IP & DDNS)** in the main menu. |
| Certificate expires soon | Renewal failed | In **Health & security**, choose **TLS certificate expiry**. |
| You need a certificate by hand | Automatic request failed | Request it in the NPM page. See the [Nginx Proxy Manager docs](https://nginxproxymanager.com/guide/). |

Your public IP can change. In **Health & security**, choose **DNS / public-IP drift** to compare it with your domain.

## GPU problems

To test hardware transcoding again:

1. Run `./mediastack`.
2. Choose **Manage hardware transcoding (GPU)**.
3. Choose **Configure or change hardware transcoding**.

If the menu shows **Reboot to finish hardware transcoding**, restart the server first.

**NVIDIA GPU is not used.**

Run `nvidia-smi` and `docker exec jellyfin nvidia-smi`.

If the first command fails, repair the host driver and restart the server. If only the second command fails, choose **Configure or change hardware transcoding** again.

**You use NVIDIA Unlock mode and the session limit came back.**

A driver update replaces the patched driver. In **Manage hardware transcoding (GPU)**, choose **Update NVIDIA driver + reapply Unlock patch** or **Reapply Unlock patch only**. Standard mode needs no patch.

**AMD or Intel GPU is not used.**

Choose **Configure or change hardware transcoding** and read the reported failure reason. MediaStack checks the selected render device and probes its capabilities inside Jellyfin.

For a first manual check, run `ls -la /dev/dri/`. A failed bare `vainfo` command does not by itself prove that a driver is missing: display selection, device selection or permissions can also cause it to fail.

## NAS storage problems

This section applies only if you chose NAS storage.

**Services do not start, and the menu says the NAS is not mounted.**

1. Run `./mediastack`.
2. Choose **View storage & data mount (NAS source, mount health, watchdog)**.
3. Choose **Re-check NAS now**.
4. If the check fails, fix the NAS mount first. Check that the NAS is on and the network works.
5. Start the services again from **Manage stack**.

Do not create `media/` or `torrents/` folders under an unmounted path. This hides the real failure.

You can also check the mount by hand. Replace `<mountpoint>` with `STORAGE_MOUNTPOINT` from `.env`, and `<sentinel>` with `STORAGE_SENTINEL` from the same file:

```bash
findmnt -rn -M '<mountpoint>' -o SOURCE,FSTYPE,OPTIONS
timeout -k 1 5 test -e '<sentinel>'
```

Compare the source and filesystem type with the configured NAS share. No mount result means the path is not mounted. The sentinel check prints nothing: exit code 0 means it found the marker, 1 means it did not, and 124 means it timed out. A missing marker alone does not prove that the wrong share is mounted.

Automatic stopping and recovery require the NAS watchdog to be installed, enabled and running. Disabling it also disables the launcher's NAS start guard.

**Watchdog messages.**

```bash
systemctl status mediastack-storage-watchdog.service
journalctl -u mediastack-storage-watchdog.service -f
```

The repair helper detaches only an NFS mount that it owns. If it refuses, read the reason with `journalctl -t mediastack-storage-helper`. Then fix the mount by hand.

To move from local storage to NAS, or to change exports, stop the stack first. MediaStack does not move your media. See [storage](../setup/storage.md).

## After a reboot

Docker restarts installed services unless you stopped them. Optional services must have been enabled and created first. You do not run `setup.sh` again.

On NAS installs, the running watchdog starts missing NAS-dependent services after its startup storage check, including services stopped before reboot. Docker's restart policy does not wait for NAS verification; the watchdog stops affected services after its failure grace period if storage is unavailable.

1. Wait two minutes after the server starts.
2. Run `./mediastack`.
3. Choose **Manage stack (status, stop, start, logs)** and check that all services run.

If a service does not run, choose **Start a service**. With the NAS watchdog enabled, the launcher refuses to start services until the configured mount and sentinel pass verification. See [NAS storage problems](#nas-storage-problems).

## Recovery

### Jellyfin wizard broken state

**Symptom:** Setup reports `Jellyfin admin login could not be verified.`

First retry from the MediaStack folder:

```bash
./scripts/configure.sh --only jellyfin
```

Read the Jellyfin result and warnings. If login still fails, check the Jellyfin logs and the admin credentials in `.env`. Choosing **Continue without changes** in setup does not retry configuration.

If you choose to reset Jellyfin, the commands below keep the old settings in `config/jellyfin.before-reset` and start with empty application state.

> [!WARNING]
> The reset removes active users, settings, library state and watch history from the running service. Media files stay in place. It does not fix an upstream startup-wizard defect. Keep the backup and do not repeat the reset if setup fails again.

Run from the MediaStack folder. If any command fails, stop and read its error.

```bash
test ! -e ./config/jellyfin.before-reset &&
test ! -L ./config/jellyfin.before-reset &&
docker compose stop jellyfin &&
sudo mv -- ./config/jellyfin ./config/jellyfin.before-reset &&
docker compose up -d --no-deps --force-recreate jellyfin &&
./scripts/configure.sh --only jellyfin
```

After Jellyfin configuration succeeds, run `./scripts/configure.sh` to retry dependent services. Existing Jellyfin connections in Sonarr or Radarr are preserved on a re-run; repair any connection that still contains the old API key in the service's settings. Other services may also need their Jellyfin credentials reconnected.

### Nginx Proxy Manager (NPM) lockout

**Symptom:** Setup logs `NPM password rotation FAILED` and you cannot log in to NPM.

Use this reset only for a failed first install. It removes all NPM users and saves a database backup first. For an existing installation, restore a backup or ask for help before resetting accounts.

1. From the MediaStack folder, stop NPM with `docker compose stop npm`.
2. Use host Python to back up the database and remove its user records. The NPM image does not provide the `sqlite3` command.

   ```bash
   sudo python3 - <<'PY'
   import sqlite3
   from pathlib import Path

   backup = Path("config/npm/data/database.before-admin-reset.sqlite")
   if backup.exists():
       raise SystemExit("Backup already exists; keep it and review the earlier reset.")
   with sqlite3.connect("file:config/npm/data/database.sqlite?mode=rw", uri=True) as db:
       with sqlite3.connect(backup) as saved:
           db.backup(saved)
       db.execute("DELETE FROM user")
   PY
   ```

3. Start NPM with `docker compose start npm`.
4. Run `./scripts/configure.sh --only npm`. It creates the NPM admin again.

### Setup stopped half way

Run `./setup.sh` again. Setup is safe to run again. It skips what is configured.

## Commands for power users

You do not need these commands for a normal install. The menu is the safe way. It starts the correct compose profiles.

```bash
docker compose ps                          # service status
docker compose logs -f jellyfin            # follow logs
docker compose logs --since 1h <service>   # last hour
docker compose restart sonarr              # restart one service
./scripts/configure.sh                     # retry incomplete service configuration
./setup.sh --remote                        # add or repair remote access
./setup.sh --transcoding                   # check hardware transcoding again
```

> [!NOTE]
> A bare `docker compose up -d` starts only the default services. It does not start remote access, subtitles, or autoheal. To start those, add `--profile proxy --profile remote --profile subtitles --profile autoheal`. Leave out the profiles you did not enable.

To rename the quality profile, use **Features & settings (quality, bandwidth, subtitles, sharing, indexers)** > **Change quality profile**. Do not edit `config.yml` and run `configure.sh`: this leaves an extra profile.

Configuration re-runs preserve many existing settings and can report drift instead of changing them. Use the supported menu action or service UI for those changes.

See also: [install guide](install.md), [remote access](remote-access.md), [using the menu](using-the-menu.md).
