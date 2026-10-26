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
3. Choose **Tail logs (live)** and select the service. Read the last error.
4. Choose **Start a service** and select the service again.

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

Run `ls -la /dev/dri/` and `vainfo`.

If the first command lists no render device, or `vainfo` fails, install the driver for your GPU.

## NAS storage problems

This section applies only if you chose NAS storage.

**Services do not start, and the menu says the NAS is not mounted.**

1. Run `./mediastack`.
2. Choose **View storage & data mount (NAS source, mount health, watchdog)**.
3. Choose **Re-check NAS now**.
4. If the check fails, fix the NAS mount first. Check that the NAS is on and the network works.
5. Start the services again from **Manage stack**.

Do not create `media/` or `torrents/` folders under an unmounted path. This hides the real failure.

You can also check the mount by hand:

```bash
findmnt -rn -M /data -o SOURCE,FSTYPE,OPTIONS
test -e /data/.mediastack-storage-ready
```

If the second command prints nothing and returns an error, the NAS share is not the correct one. MediaStack stops the services that need it until the share returns.

**Watchdog messages.**

```bash
systemctl status mediastack-storage-watchdog.service
journalctl -u mediastack-storage-watchdog.service -f
```

The repair helper detaches only an NFS mount that it owns. If it refuses, read the reason with `journalctl -t mediastack-storage-helper`. Then fix the mount by hand.

To move from local storage to NAS, or to change exports, stop the stack first. MediaStack does not move your media. See [storage](../setup/storage.md).

## After a reboot

Every MediaStack service starts again by itself when Docker starts, unless you stopped it. This includes the optional services: reverse proxy, VPN, subtitles, and autoheal. You do not run `setup.sh` again.

1. Wait two minutes after the server starts.
2. Run `./mediastack`.
3. Choose **Manage stack (status, stop, start, logs)** and check that all services run.

If a service does not run, choose **Start a service**. With NAS storage, services that need the NAS wait until the NAS is mounted. See [NAS storage problems](#nas-storage-problems).

## Recovery

### Jellyfin wizard broken state

**Symptom:** Setup reports that the Jellyfin wizard is complete, but the admin login fails. The setup output says `To recover: stop the stack, delete ./config/jellyfin, and re-run setup.`

> [!WARNING]
> This deletes the Jellyfin database. You lose user accounts, watch history, and metadata. Do this only on a new install.

1. Run `./mediastack`.
2. Choose **Manage stack (status, stop, start, logs)** > **Stop all services**.
3. Delete the Jellyfin settings folder:

   ```bash
   rm -rf ./config/jellyfin
   ```

4. Run `./mediastack` again. Choose **Manage stack (status, stop, start, logs)** > **Start all services**. Wait until Jellyfin answers.
5. Run the Jellyfin wizard step again. It rebuilds only Jellyfin.

   ```bash
   ./scripts/configure.sh --only jellyfin
   ```

On an older install, restore a backup of `./config/jellyfin` instead. Ask for help before you delete it.

### Nginx Proxy Manager (NPM) lockout

**Symptom:** Setup logs `NPM password rotation FAILED` and you cannot log in to NPM.

1. Stop the stack: **Manage stack** > **Stop all services**.
2. Open a shell in the NPM container:

   ```bash
   docker compose run --rm --entrypoint sh npm
   ```

3. In the shell, remove the NPM users:

   ```bash
   cd /data && sqlite3 database.sqlite
   DELETE FROM user;
   .quit
   exit
   ```

4. Choose **Start all services**.
5. Run `./scripts/configure.sh`. It creates the NPM admin again.

### Setup stopped half way

Run `./setup.sh` again. Setup is safe to run again. It skips what is configured.

## Commands for power users

You do not need these commands for a normal install. The menu is the safe way. It starts the correct compose profiles.

```bash
docker compose ps                          # service status
docker compose logs -f jellyfin            # follow logs
docker compose logs --since 1h <service>   # last hour
docker compose restart sonarr              # restart one service
./scripts/configure.sh                     # re-apply service settings after you edit config.yml
./setup.sh --remote                        # add or repair remote access
./setup.sh --transcoding                   # check hardware transcoding again
```

> [!NOTE]
> A bare `docker compose up -d` starts only the default services. It does not start remote access, subtitles, or autoheal. To start those, add `--profile proxy --profile remote --profile subtitles --profile autoheal`. Leave out the profiles you did not enable.

To rename the quality profile, use **Features & settings (quality, bandwidth, subtitles, sharing, indexers)** > **Change quality profile**. Do not edit `config.yml` and run `configure.sh`: this leaves an extra profile.

See also: [install guide](install.md), [remote access](remote-access.md), [using the menu](using-the-menu.md).
