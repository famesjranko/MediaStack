# Real-Host Testing (LAN / Bare-Metal)

End-to-end testing on a real Debian host via SSH. Complements the DinD suite (`tests/README.md`) by
catching what only manifests on real hardware: **GPU passthrough/transcoding, the NVIDIA driver-mode
install + reboot/finalize cycle**, UFW, systemd, disk I/O timing, and container-image behaviour
differences between DinD's nested Docker and a bare-metal daemon.

Two principles shape this harness:

1. **It drives the real wizard, not a reimplementation.** Wizard-driven runs feed the *actual*
   `./setup.sh --full` through `tests/lib/wizard_pty.py` (the same PTY engine the DinD `wizard-ui-*`
   scenarios use) and assert the outcome.
2. **It calls product code, never duplicates it.** Where the harness needs product behaviour (e.g.
   NVIDIA driver removal) it sources the product module and calls the real function (see
   [Clean wipe](#clean-wipe--the-destructive-guard)), so the test can't drift from the product.

This is an operator-run harness for a disposable box you own. Local connection values live only in
gitignored `tests/.env.lan-host`; remote/provider credentials belong in the GCP harness instead.

## At a glance — the choice matrix

What a run installs is chosen by a **choice matrix** in `tests/.env.lan-host` — a persona, or
individual toggles. Anything that differs from the DEMO defaults drives the real wizard:

| Install path | When | How |
|---|---|---|
| **DEMO baseline** | no persona, all toggles default | `DEMO=1 ./setup.sh --full` — fast, fixed defaults, no wizard, GPU off. Proves the stack. |
| **Wizard-driven** | a persona, or any non-default toggle | drives the **real** wizard via `wizard_pty.py` (Stage 1 choices + Stage 3 GPU). Proves a matrix cell on real silicon. |

Personas (`LANHOST_PERSONA`, expand to a toggle preset; individual toggles override):

| Persona | Exercises | Matrix cell |
|---|---|---|
| `lan-minimal` | LAN baseline, compact quality, no GPU | S1.* |
| `nvidia-existing` | Stage 3 → use the already-installed NVIDIA driver | S3.N3 |
| `nvidia-standard` | Stage 3 → fresh apt NVIDIA driver, **2 reboots + finalize** | S3.N1 |
| `nvidia-unlock` | Stage 3 → Unlock-NVENC patched driver, **2 reboots + finalize** | S3.N1/N2 |
| `remote-nas` | refused before a wipe; redirects the operator to the GCP harness | S2.* |

Personas set a baseline; **individual toggles compose on top** — e.g. `--persona lan-minimal --smb`
or `LANHOST_BAZARR=1 LANHOST_INDEXERS=1`. Any non-default toggle drives the real wizard.

Remote/Stage 2 (real domain + DDNS + LE) is intentionally **not** run here — see the
[LAN caveat](#remote-is-the-gcp-harnesss-job). This surface owns the real-silicon proof; the GCP
suite (`tests/gcp-vm/`) owns the WAN/remote proof; the DinD `wizard-ui-*` suite owns exhaustive
branch coverage.

## Quick start

```bash
# 1. One-time: passwordless SSH to the target (see SSH Key Setup) + passwordless sudo there.
# 2. One-time: create your env file.
cp tests/.env.lan-host.example tests/.env.lan-host
$EDITOR tests/.env.lan-host     # TARGET_HOST / TARGET_USER / LANHOST_EXPECT, then a persona/toggles

# 3. Run
bash tests/lan-host/run-fresh.sh --preflight                         # local checks only; no SSH
bash tests/lan-host/run-fresh.sh --yes                              # DEMO baseline
bash tests/lan-host/run-fresh.sh --persona lan-minimal --yes        # real wizard, LAN baseline
bash tests/lan-host/run-fresh.sh --persona lan-minimal --smb --yes  # + host SMB file share
bash tests/lan-host/run-fresh.sh --persona nvidia-existing --yes    # GPU: use existing driver
bash tests/lan-host/run-fresh.sh --persona nvidia-standard --yes    # GPU: fresh install + reboots
```

`--persona NAME` / `--gpu MODE` on the command line override `tests/.env.lan-host` for that run.
With no local env file, `--preflight` validates the placeholder example and exits before SSH,
rsync, or any destructive action.

## The scripts

All read connection + matrix from `tests/.env.lan-host` (gitignored; copy the `.example`).

| Script | What it does |
|---|---|
| `lib.sh` | Shared helpers: `load_env` + `load_matrix` (persona/toggle resolution), `step/ok/bad` + `FAILS[]`, ssh/rsync wrappers, `drive_wizard` (the `wizard_pty.py`-over-SSH driver), `reboot_and_wait` / `wait_for_gpu_finalize` / `verify_clean_nvidia` (the from-scratch GPU orchestration). |
| `wizard_steps.py` | Generates the `wizard_pty.py` steps-JSON for a full `setup.sh --full` from the `LANHOST_*` toggles (Stage 1 + Stage 3, in the real `stage1→stage3→stage2` order). It's the single source of truth for which cells the LAN drive supports — `run-fresh.sh` runs it **locally before any wipe**, so an unsupported cell (`remote`, `nvidia-unlock`) is refused before anything destructive. |
| `rsync-push.sh` | Push local code to the target (gitignore-driven excludes; fails on a partial sync). `--dry-run`. |
| `clean-wipe.sh` | Full reset (stop containers → drop state → delete generated files, **and clear stale Stage 3 GPU finalize state** — marker + resume unit — so a prior interrupted GPU run can't hijack the next fresh run). `--nvidia` calls the **wizard's own** driver removal (failing loudly if that product code is missing/stale, or if the removal itself fails); `--data`. **Destructive — see the guard.** |
| `probe-services.sh` | Mode-aware verification: container health, service APIs, GPU passthrough, the host **SMB share** (when `LANHOST_SMB=1`), **and the applied choices** (`IMAGE_CHANNEL`, `BAZARR_ENABLED`/container, quality profile in `config.yml`) — gated on the active toggles. `--service NAME` (incl. `channel`/`bazarr`/`smb`/`quality`/`gpu`), `--nvidia-autoheal`. |
| `run-fresh.sh` | Orchestrator: validate cell + generate steps → **push → wipe** → install (DEMO or wizard-driven, incl. the from-scratch GPU reboot cycle) → probe. Pushing before the wipe means a `--nvidia` wipe runs the *current* product driver-removal code. `--persona`, `--gpu`, `--smb`, `--no-wipe`, `--nvidia`, `--yes`. |

Each helper runs standalone, e.g. `bash tests/lan-host/probe-services.sh --service sonarr`.

## Configuration (`tests/.env.lan-host`)

| Var | Purpose |
|---|---|
| `TARGET_HOST`, `TARGET_USER` | SSH target (IP/hostname + user with passwordless login **and** passwordless sudo). |
| `TARGET_PATH` | Where the repo is rsynced (default `/home/$TARGET_USER/MediaStack`). Guarded against root-ish values. |
| `LANHOST_EXPECT` | Destructive-wipe guard. Set equal to `TARGET_HOST` to opt into `--yes`. |
| `LANHOST_PERSONA` | `lan-minimal` / `nvidia-existing` / `nvidia-standard` / `nvidia-unlock` / `remote-nas`, or blank. |
| `LANHOST_GPU` | `none`/`intel`/`amd`/`nvidia-existing`/`nvidia-standard`/`nvidia-unlock` (blank → persona/default). |
| `LANHOST_INDEXERS` / `LANHOST_CHANNEL` / `LANHOST_QUALITY` / `LANHOST_BAZARR` | Stage 1 wizard choices (blank → persona/default). |
| `LANHOST_SMB` | `1` enables the host SMB file share (Stage 1, data scope → `\\<ip>\Media` → `/data`). `0`/blank → off. |
| `LANHOST_REMOTE` | `1` is refused on the LAN drive (remote = GCP). |

Leave toggles **blank** to inherit the persona (or the DEMO baseline). A blank persona + blank
toggles = DEMO. Explicit toggles override the persona.

## Prerequisites

- A Debian 12/13 host with SSH access, passwordless login **and** passwordless `sudo` (the "target")
  — **not** your production stack.
- The MediaStack repo on your dev machine (the "source"); `rsync` + `ssh` on both.

## SSH Key Setup

```bash
ssh-keygen -t ed25519 -C "mediastack-dev"   # skip if you already have a key
ssh-copy-id user@<target-ip>
ssh user@<target-ip> "hostname; sudo -n true && echo passwordless-sudo-ok"
```

If the target has UFW enabled, allow SSH: `sudo ufw allow 22/tcp` (on the target).

## Clean wipe — the destructive guard

`clean-wipe.sh` runs `sudo rm -rf` over SSH. Because your production stack lives on a **different
box** than the test target, a mistyped `TARGET_HOST` must not be wipeable:

- **Interactive** (`./clean-wipe.sh`): you must retype the target hostname to confirm.
- **Non-interactive** (`--yes` / `CONFIRM=1`): refused unless `TARGET_HOST == LANHOST_EXPECT`.

It stops containers **before** deleting config (running containers recreate files like Seerr's
`settings.json`, causing stale next-install state).

**`--nvidia` removes the NVIDIA driver by calling the wizard's own code** — it sources
`scripts/lib/common.sh` + `scripts/setup/gpu.sh` and runs `prepare_nvidia_debian_to_unlock`
(selects the driver stack, protects the container toolkit, `apt-get purge` with dependency cascade),
plus the `.run` driver's own `nvidia-uninstall` for a patched/Unlock driver. No duplicated package
list → no test/product drift. `--data` also removes `/data` (rarely needed).

## Running the installer

### DEMO baseline

```bash
bash tests/lan-host/run-fresh.sh --yes
```

Wipes → pushes → `DEMO=1 ./setup.sh --full` (no wizard, `DOMAIN=example.com`, GPU off) → mode-aware
probe. The fast bare-metal smoke. `--no-wipe` iterates against an existing install.

### Wizard-driven personas

```bash
bash tests/lan-host/run-fresh.sh --persona lan-minimal --yes
```

Wipes → pushes → drives the **real** `./setup.sh --full` via `wizard_pty.py`, answering the live
prompts from the persona/toggles → mode-aware probe. The transcript is pulled back to
`$TMPDIR/lan-host-wizard.plain.log` for review. `wizard_pty`'s per-step expect-timeout turns any
prompt drift into a loud failure instead of a silent desync.

### GPU — existing driver (S3.N3)

```bash
bash tests/lan-host/run-fresh.sh --persona nvidia-existing --yes
```

Drives Stage 3 down the existing-driver path on a box that already has a working NVIDIA driver, then
probes that `JELLYFIN_GPU=nvidia`, `STAGE_3_GPU_STATE=complete`, `NVIDIA_DRIVER_MODE` matches the
chosen mode (`existing`/`standard`/`unlock` — so `nvidia-existing` and `nvidia-standard` can't be
conflated), and **the jellyfin container sees the GPU via `nvidia-smi`** (the real passthrough proof).

### GPU — from-scratch Standard (S3.N1, two reboots)

```bash
bash tests/lan-host/run-fresh.sh --persona nvidia-standard --yes
```

The full driver-install cycle, all on real silicon:

1. `clean-wipe --nvidia` (auto-forced) removes any existing driver via the product's own code.
2. **Reboot #1** into a clean no-driver state, then `verify_clean_nvidia` asserts it (no driver
   packages, no nvidia module, `nvidia-smi` gone, **apt dependency state consistent**).
3. Drive the wizard: Stage 3 → Standard → apt installs the driver → "Reboot now?" → *later*; the
   wizard writes the `.nvidia-finalize-pending` marker + enables `mediastack-setup.service`.
4. **Reboot #2**; the systemd resume service finalizes the GPU on boot (with the F-004 runtime-
   registration self-heal in `gpu.sh`).
5. Probe waits for `STAGE_3_GPU_STATE=complete` and the container-GPU check.

### Remote is the GCP harness's job

> **Mode B (real domain → DDNS → 80/443 + WireGuard → Let's Encrypt) usually can't run on a home
> LAN** — the target collides with the existing stack/reverse-proxy. `LANHOST_REMOTE=1` is refused
> with a pointer to GCP. Remote/WAN proof is owned by `tests/gcp-vm/`, which gets a clean public IP.

### Manual / interactive

The raw flow stays available to drive by hand or watch the wizard:

```bash
bash tests/lan-host/rsync-push.sh
ssh -t user@<target-ip> "cd /home/user/MediaStack && ./setup.sh --full"   # answer the prompts
```

If containers are already up and you only changed a service configurator:

```bash
bash tests/lan-host/rsync-push.sh
ssh user@<target-ip> "bash /home/user/MediaStack/scripts/configure.sh"
```

## Probing services

```bash
bash tests/lan-host/probe-services.sh                 # mode-aware: only asserts what was deployed
bash tests/lan-host/probe-services.sh --service sonarr
bash tests/lan-host/probe-services.sh --nvidia-autoheal
```

The container-health check counts only genuinely-up containers (healthy **or** no healthcheck) and
**fails on any `(unhealthy)`** — an unhealthy service no longer inflates the count. The probe reads
the `LANHOST_*` toggles and only asserts services the install actually deployed: **fail2ban** is
checked only with `LANHOST_REMOTE=1` (profile-gated), **jackett** only with `LANHOST_INDEXERS=1` (no
API key otherwise → 302), the host **SMB share** only with `LANHOST_SMB=1` (host samba via
`hardening/samba.sh:setup_samba`, **not** a container — the probe asserts `SMB_ENABLED`/`SMB_SHARE_SCOPE` in
`.env`, `smbd` active, and — unambiguously even where a `[Media]` share pre-exists — the
**MediaStack-managed include** `/etc/samba/smb.conf.d/mediastack.conf` defines `[Media]` at `DATA_DIR`
and is wired into `smb.conf` via the `# MEDIASTACK include` marker), and a **GPU-passthrough** block
runs only when a GPU mode is set. Beyond
"services are up", it reads back the **applied choices** and compares them to the toggles —
`IMAGE_CHANNEL`, `BAZARR_ENABLED` (plus the bazarr container), and `PUBLIC_INDEXERS_ENABLED` from
`.env`, and the quality profile in `config.yml` against the chosen preset's `profile_name` in
`scripts/setup/presets.yml` (derived, not hardcoded, so it can't drift from the product). For the
choices that touch a running service it adds **live proof** (mirroring the DinD `tests/assertions/`
patterns): the chosen quality profile exists in Sonarr's live API, and — when indexers are enabled —
Sonarr has ≥1 indexer wired. These hold for the DEMO baseline too (`stable`/`balanced`/bazarr-off),
so they strengthen it. The `--nvidia-autoheal` probe shims a failing `nvidia-smi` inside Jellyfin and
confirms the healthcheck trips and autoheal stop/starts the container (`healthy → unhealthy → PID
change → healthy`); it does not break the host driver.

### Service API Endpoints Quick Reference

| Service | Base URL | Auth |
|---|---|---|
| Sonarr | `localhost:8989/api/v3/` | `X-Api-Key` header |
| Radarr | `localhost:7878/api/v3/` | `X-Api-Key` header |
| Jackett | `localhost:9117/api/v2.0/` | `?apikey=` query param |
| Jellyfin | `localhost:8096/` | `Authorization: MediaBrowser Token="..."` |
| Seerr | `localhost:5055/api/v1/` | Cookie session or `X-Api-Key` |
| qBittorrent | `localhost:8080/api/v2/` | localhost/subnet auth bypassed (see gotcha) |
| Portainer | `localhost:9000/api/` | `X-API-Key` header |
| Beszel | `localhost:8090/` | PocketBase REST API |

## Common Gotchas

**qBittorrent auth is bypassed for localhost/subnet.** MediaStack sets `WebUI\LocalHostAuth=false`
+ `AuthSubnetWhitelist=172.16.0.0/12`, so `/api/v2/auth/login` returns an empty body (nothing to
authenticate) — the probe hits an **authed endpoint** (`app/version`) instead of the login dance.

**`docker compose` needs the compose file + `.env`.** Outside the repo dir or with `.env` missing,
`docker compose down` fails; `clean-wipe.sh` falls back to `docker stop/rm` directly.

**Config dirs may be root-owned.** Container mounts create dirs as root; the wipe uses `sudo rm -rf`.

**A half-broken apt state blocks setup's prereq install.** An interrupted install or a driver-mode
switch can leave packages half-configured (`Unmet dependencies`). `setup.sh`'s `install_base_packages`
now self-heals this (`apt-get check` → `dpkg --configure -a` + `apt --fix-broken`); `verify_clean_nvidia`
asserts apt consistency before a from-scratch install so the harness fails early if it recurs.

## Iterating Quickly

1. Edit code locally → `bash tests/lan-host/run-fresh.sh --no-wipe` (or `rsync-push.sh` + `configure.sh`).
2. `bash tests/lan-host/probe-services.sh --service <name>` to verify.

For changes to `setup.sh`, `docker-compose.yml`, or `.env` generation, a full wipe + reinstall is
needed — run `run-fresh.sh` (with a persona for the real wizard).
