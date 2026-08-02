# GCP fresh-VM end-to-end test

This is the **only** test surface that exercises the real public remote-access
stack: real Let's Encrypt HTTP-01, real public DNS via Dynu, real GCP firewall,
real DDNS pushes, and real HTTPS through Nginx Proxy Manager. The DinD battery
(`tests/run.sh`) covers everything that runs **inside** the VM — but it cannot
prove that DDNS pushes work, that public DNS resolves to the new IP, or that
GCP's firewall actually blocks admin ports. This test does.

Wall-time: **~10–15 min** for a full wipe + recreate + setup + 15 checks.
(Pre-`--policy missing` runs were ~25–30 min because Stage 2 silently
re-pulled every default-profile image; see `scripts/setup/stack.sh:pull_images`.)

## What it covers

| # | Step                                | Validates                                                  |
|---|-------------------------------------|------------------------------------------------------------|
| 0 | Delete existing VM                  | clean baseline                                             |
| 1 | Create VM (`mediastack-public` tag) | startup-script bootstrap + firewall tag wiring             |
| 2 | Refresh SSH config                  | `gcloud compute config-ssh` works                          |
| 3 | Wait for SSH                        | startup-script completed (rsync/git/curl present)          |
| 4 | Rsync repo to `/opt/MediaStack`     | repo lands intact                                          |
| 5 | Pre-seed Stage 1 `.env` + DDNS config | `tests/.env.gcp` inputs stay local/untracked; DDNS config is ready for Stage 2 |
| 6 | `DEMO=1 ./setup.sh --full`          | Stage 1 LAN-safe non-interactive baseline + completion banner |
| 7 | Restore remote inputs + DDNS push   | real domain, `NPM_LE_SERVER`, and DDNS provider publish the VM IP |
| 8 | `./setup.sh --remote`               | real Stage 2 route, WireGuard/NPM/DDNS setup, HTTP-01 readiness |
| 9 | Whitelist tester IP in fail2ban     | probes don't self-ban                                      |
| 10 | Containers healthy (≥16, WG, DDNS) | profiles auto-activate when `DOMAIN` + WG hash present     |
| 11 | Fail2ban: 3 jails                  | NPM/Jellyfin/Seerr jails active (ratelimit disabled by default) |
| 12 | `tests/assertions/npm.sh`          | NPM proxy hosts have rendered `.conf` + cert files on disk |
| 13 | External HTTPS + cert issuer       | DDNS push → real public DNS → public HTTPS reaches the proxy |
| 14 | LAN-only TCP ports blocked from WAN | UFW + DOCKER-USER + GCP firewall hide every Docker LAN-only TCP port from `setup_ufw_docker_rules` |
| 15 | Public ports open (80/443/6881)    | external reachability for the user-facing services         |

## Prerequisites (one-time)

### 1. gcloud CLI

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud compute config-ssh
```

### 2. GCP firewall rules

The harness creates the VM with the `mediastack-public` network tag. You need
a rule that opens 80/443/6881 to the world for that tag, and (optionally) a
rule that opens admin SSH to your IP only:

```bash
# Public ports — required
gcloud compute firewall-rules create mediastack-public \
  --direction=INGRESS --action=ALLOW --rules=tcp:80,tcp:443,tcp:6881 \
  --target-tags=mediastack-public --source-ranges=0.0.0.0/0

# SSH from your home IP — recommended (gcloud SSH bypasses this via IAP,
# but a direct ssh client will need it). Use 0.0.0.0/0 if you don't have
# a static IP, but understand the risk surface.
gcloud compute firewall-rules create mediastack-ssh \
  --direction=INGRESS --action=ALLOW --rules=tcp:22 \
  --target-tags=mediastack-public --source-ranges=YOUR.IP.HERE/32
```

> LAN-only Docker TCP ports (NPM 81, Homepage 3000, Uptime Kuma 3001,
> Seerr 5055, Bazarr 6767, Radarr 7878, ddns-updater 8000,
> qBittorrent WebUI 8080, Beszel 8090, Jellyfin 8096, FlareSolverr 8191,
> Sonarr 8989, Portainer 9000, Jackett 9117, Beszel Agent 45876, and wg-easy
> admin 51821) are blocked from non-private sources by the host's
> `DOCKER-USER` rules. UFW provides the
> host default-deny baseline, and the GCP firewall is the test rig's router
> boundary: only 80/443/6881 are open to WAN. You reach LAN-only services
> directly on a home LAN or via WireGuard once the VM is up.

### 3. DDNS provider

The harness pre-seeds `config/ddns-updater/config.json` with your DDNS
credentials so the `ddns-updater` container can push the new VM's IP to
the DNS provider. This harness uses **Dynu** (`run-fresh.sh` selects it in the
picker; the wizard's default is now **DuckDNS**, a token provider whose login is
verified during setup — #248).

In your DDNS panel:
- Register your domain (e.g. `yourname.mywire.org`)
- Enable subdomains for `jellyfin.<domain>` and `seerr.<domain>`
- Note the username + password the API uses

To use a different provider, edit the `step "5. Pre-seed"` block in
`run-fresh.sh` to write the appropriate provider config.

### 4. Test config file

Copy the template and fill in your values:

```bash
cp tests/.env.gcp.example tests/.env.gcp
$EDITOR tests/.env.gcp
```

`tests/.env.gcp` is gitignored. The path is referenced by `run-fresh.sh`
as a sibling of the script. `DOMAIN`, `NPM_ADMIN_EMAIL`, `NPM_LE_SERVER`, and
the DDNS credentials in that file are used for the real Stage 2
`setup.sh --remote` proof; they are not committed.

## Running the test

```bash
bash tests/gcp-vm/run-fresh.sh
```

The harness writes the Stage 1 setup output to `/tmp/gcp-fresh-setup.log` and
the Stage 2 `setup.sh --remote` output to `/tmp/gcp-fresh-remote.log` so you
can `tail -f` either file from another shell. The summary at the end prints
either `✓ ALL CHECKS PASSED` or `✗ N FAILURE(S)` with the failing items.

`DEMO=1` is intentionally only a LAN-safe Stage 1 baseline. It does not prove
remote setup. TEST-08's public proof comes from the later real
`./setup.sh --remote` run using the domain, DDNS credentials, and
`NPM_LE_SERVER` from `tests/.env.gcp`.

## Delete + rebuild the VM

`run-fresh.sh` **is** the delete + rebuild flow — step 0 deletes any
existing VM with the configured name, step 1 recreates it from a fresh
Debian 12 image with the `mediastack-public` tag, then steps 2-15 verify.
Just re-run the script whenever you want a clean install:

```bash
bash tests/gcp-vm/run-fresh.sh
```

If you only want to delete (not rebuild), or to delete after debugging:

```bash
# Source the env so $INSTANCE / $ZONE are set
set -a; source tests/.env.gcp; set +a
gcloud compute instances delete "$INSTANCE" --zone="$ZONE" --quiet
```

To rebuild without re-running the full setup + verify (e.g. you want to
SSH in and run setup.sh manually), comment out steps 6-15 in
`run-fresh.sh` — steps 0-5 cover delete → create → SSH-ready → rsync →
seed `.env`. You can then SSH in and run the remote proof explicitly with
`./setup.sh --remote`. Or just run the rebuild steps inline:

```bash
set -a; source tests/.env.gcp; set +a
gcloud compute instances delete "$INSTANCE" --zone="$ZONE" --quiet
gcloud compute instances create "$INSTANCE" --zone="$ZONE" \
  --machine-type="$MACHINE_TYPE" --image-family=debian-12 \
  --image-project=debian-cloud --boot-disk-size="$BOOT_DISK_SIZE" \
  --tags=mediastack-public \
  --metadata-from-file=startup-script=tests/gcp-vm/startup.sh
gcloud compute config-ssh
ssh "$INSTANCE.$ZONE.$PROJECT_ID"   # then setup manually
```

VMs are billed per-second while running. **Don't forget to delete** when
you're done debugging — an e2-medium left up overnight is ~$0.30, an
e2-medium left up for a week is ~$5.

## Staging vs production Let's Encrypt

Default: `NPM_LE_SERVER=https://acme-staging-v02.api.letsencrypt.org/directory`.
Staging certs are signed by **(STAGING) Let's Encrypt** and are not trusted
by browsers — but staging has very high rate limits, so you can repeat the
test loop without burning your prod-LE quota.

For a final trusted-cert run, blank `NPM_LE_SERVER` in `tests/.env.gcp`:

```bash
NPM_LE_SERVER=""
```

Run the production test only after you're confident the staging flow is
correct. This is a deliberate final trusted-cert run, not the default loop:
prod LE allows **5 duplicate certs per identifier set per 168h**. The cert
helpers in `scripts/services/npm/main.sh` are designed to make at most one
POST per heal cycle, but verify in staging first.

When credentials, cost controls, DNS ownership, or LE quota make a live GCP
execution unavailable, record the deferral and the reason in the local
verification notes or review thread. The local syntax and grep checks are not a
substitute for the real public DNS/DDNS/WAN/HTTP-01 proof; they only show that
the harness is ready to run.

## Common gotchas

- **DNS propagation lag.** Steps 7 and 13 poll `dig` before Stage 2 and before
  testing HTTPS. If the test still fails, check the `ddns-updater` log:
  `ssh $SSH_HOST 'docker logs ddns-updater | tail -10'` — Dynu's
  authoritative server can take a few minutes to pick up a fresh push.
- **Idempotent re-runs.** Step 0 deletes the VM, so re-running is always
  a clean install. To run setup twice on the same VM (test idempotency),
  delete only `step "0"` and re-run; setup.sh's `--full` is graceful.
- **Self-ban from probes.** Step 9 whitelists the tester's public IP in
  every fail2ban jail. If you skip step 7 (manual debugging), curl loops
  can ban you out of the VM. Recover with
  `ssh $SSH_HOST 'docker exec fail2ban fail2ban-client unban --all'`.
- **First-run vs re-run.** Many configurators detect existing state and
  skip (e.g. "Seerr already initialized"). A fresh test always starts
  from a brand-new VM so this is moot, but it explains why a manual
  re-run on the same VM looks different from the first.
- **Cost.** An e2-medium runs ~$0.03/hr on-demand. A test run + leaving the
  VM up for an hour of investigation is < $0.10. Don't forget to delete.
- **GCP-internal LE secondary co-location.** Let's Encrypt's multi-perspective
  validation picks a random subset of secondary validators per challenge.
  Occasionally one of those secondaries is hosted in GCP us-central1 (the
  same region as this test VM); the GCP→GCP-external-IP SYN path can drop
  silently and Boulder records `Timeout during connect (likely firewall
  problem)` even though UFW + the GCP firewall allow tcp:80 from 0.0.0.0/0
  and three other validators got HTTP 200 in the same second
  (`/data/logs/letsencrypt-requests_access.log` on the VM proves it). One
  FQDN's POST can fail while the other succeeds — pattern is
  non-deterministic, can flip on re-run, and is structurally identical
  across both POSTs. Stage 2 should classify this as `partial` or
  `transient`, write `REMOTE_WEB_STATE=failed`, and leave
  `config/state/npm-cert-status-last.json` for forensics. There is no
  automatic in-process retry; rerun `./setup.sh --remote` on the VM, or rerun
  the fresh-VM harness, after reading the failure. This affects only the GCP
  test rig; home-server users aren't in a GCP datacenter and never trigger
  the path.
