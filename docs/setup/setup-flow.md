# `setup.sh` — Install Flow

Entry point for the entire project. Common modes:

```bash
./setup.sh          # Stack only (Docker must already be installed)
./setup.sh --full   # Bare Debian → running stack (installs base packages + Docker)
./setup.sh --remote # Retry or verify remote HTTPS/WireGuard after Stage 1
./setup.sh --transcoding # Retry hardware transcoding after skipped/fixed/new GPU
```

`main()` lives in `setup.sh`, which is a thin orchestrator that sources modules from `scripts/setup/`. `set -euo pipefail` is enabled in the orchestrator — failures abort immediately. Modules are pure function-definition files (no shebang, no `set` flags, no `BASH_SOURCE` guard).

## Modules

| Module | Functions | Responsibility |
|--------|-----------|----------------|
| `scripts/setup/checks.sh` | `check_not_root`, `check_debian`, `check_docker`, `check_compose`, `check_disk_space` | Prerequisite validation |
| `scripts/setup/packages.sh` | `install_base_packages`, `install_docker` | Base packages + Docker (--full) |
| `scripts/setup/gpu.sh` | `detect_gpu`, `check_secure_boot`, `nvidia_driver_source`, `ensure_debian_nonfree`, `install_nvidia_drivers_apt` (Standard), `install_nvidia_drivers` + `apply_nvidia_patch` (Unlock), `install_intel_drivers`, `install_amd_drivers`, `verify_gpu_usable` | GPU detection, drivers, patches used by hardware transcoding |
| `scripts/setup/override.sh` | `detect_host_memory`, `compute_mem_limit`, `generate_override` | Host memory + compose override |
| `scripts/setup/env_gen.sh` | `detect_env`, `write_env` | Auto-detect host values + write .env |
| `scripts/setup/storage.sh` | `storage_preflight_nas`, `storage_guard_before_start`, `storage_install_watchdog` | Storage mode state, NFS guard, NAS watchdog installation |
| `scripts/setup/wizard.sh` | `run_wizard` | Core LAN, hardware transcoding add-on, remote access flow (`DEMO=1` non-interactive mode) |
| `scripts/setup/recovery.sh` | `require_stage1_complete`, `run_remote_recovery`, `run_remote_ready_recovery`, `run_transcoding_recovery`, `show_existing_install_menu` | Recovery Hooks routing for `--remote`, `--transcoding`, and existing-install add-stage menu |
| `scripts/setup/stages/stage1.sh` | `run_stage1` | Core LAN account/storage/qBittorrent collection and install |
| `scripts/setup/stages/stage2.sh` | `run_stage2` | Remote access collection/install, `./setup.sh --remote` retry path |
| `scripts/setup/stages/stage3.sh` | `run_stage3`, `run_hardware_transcoding_addon`, `stage3_finalize_nvidia` | Internal hardware transcoding engine, NVIDIA marker/reboot handoff, post-reboot finalize |
| `scripts/setup/wizard_apply.py` | *(CLI)* | Apply wizard preset to config.yml (section-targeted replacement) |
| `scripts/setup/presets.yml` | *(data)* | Quality tier definitions (compact, balanced, quality) |
| `scripts/setup/reboot.sh` | `schedule_post_reboot`, `cleanup_post_reboot` | Systemd oneshot for post-reboot resume |
| `scripts/setup/hardening.sh` | `setup_hardening`, `setup_ufw`, `setup_ufw_docker_rules`, `setup_unattended_upgrades`, `setup_sysctl_hardening`, `verify_gpu_runtime`, `setup_samba` | OS hardening + optional SMB |
| `scripts/setup/stack.sh` | `create_data_dirs`, `create_config_dirs`, `start_stack`, `wait_for_healthy`, `print_access_info`, `print_final_summary` | Data/config dirs, stack lifecycle, setup summary |

## Current staged ordering

Current behavior: `setup.sh` only detects and stashes `GPU_TYPE` before the wizard. In `--full` mode it stashes once during pre-flight, installs base packages and Docker, then stashes again after `pciutils` is available. It does not install GPU drivers, run `verify_gpu_usable`, apply NVIDIA patches, create reboot markers, or prompt for reboot before the wizard. GPU install/skip/finalize decisions belong to the hardware transcoding engine.

The interactive path is:

1. Pre-flight validates the host and runs `stash_gpu_type`.
2. `--full` installs base packages and Docker, validates Docker/Compose, then re-runs `stash_gpu_type` so bare Debian hosts can detect GPUs after `pciutils` is installed.
3. `run_wizard` executes Stage 1 Core LAN, the optional Hardware Transcoding add-on, then Stage 2 Remote Access.
4. Hardware transcoding owns vendor driver install, `verify_gpu_usable`, Jellyfin encoder publication, `.nvidia-finalize-pending` marker creation, and FIN-03 NVIDIA post-reboot finalization.
5. NVIDIA reboot prompts are deferred until the final wizard gate after Stage 2 completes or is skipped. `./setup.sh --transcoding` remains a direct recovery route and may prompt immediately.
6. `scripts/setup/reboot.sh` remains the unchanged scheduling contract. The final reboot gate calls `schedule_post_reboot`, `install_post_reboot_banner`, and `print_reboot_notice` only when `NEEDS_REBOOT=true` and `.nvidia-finalize-pending` exists.

`banner()` stays in `setup.sh` (presentational, 7 lines).

## Phases

| # | Phase | Code | Module |
|---|-------|------|--------|
| 1 | Banner + prerequisite checks | `banner`, `check_not_root`, `check_debian` | setup.sh, checks.sh |
| 2 | Post-reboot marker check | `.nvidia-finalize-pending`, `stage3_finalize_nvidia` | setup.sh, stage3.sh |
| 3 | Optional `--remote` recovery hook | `run_remote_recovery` | recovery.sh |
| 4 | Optional `--transcoding` recovery hook | `run_transcoding_recovery` | recovery.sh |
| 5 | Existing install check + add-stage menu | `detect_existing_install`, `show_existing_install_menu`, `nuke_existing_install` | checks.sh, recovery.sh |
| 6 | Docker/base validation | `check_docker`, `check_compose`, `check_disk_space` | checks.sh |
| 7 | Host detection | `detect_host_memory`, `detect_env`, `stash_gpu_type` | override.sh, env_gen.sh, gpu.sh |
| 8 | *(--full only)* Base packages + Docker | `install_base_packages`, `install_docker` | packages.sh |
| 9 | OS hardening | `setup_hardening` | hardening.sh |
| 10 | Wizard | `run_stage1`, `run_hardware_transcoding_addon`, `run_stage2`, final reboot gate | wizard.sh, stages/*.sh |

Both entry modes converge before the wizard. `--full` installs host prerequisites and Docker, then continues through the same wizard as the default path. GPU reboot/resume only happens through the hardware transcoding engine when `.nvidia-finalize-pending` exists. Day-2 users normally reach the same hardware engine through `./mediastack` → **Manage hardware transcoding (GPU)**, which delegates to `./setup.sh --transcoding`.

## Recovery Hooks

`setup.sh` handles recovery routes before the normal pre-flight/wizard path. The locked route order is:

1. Show the banner and run `check_not_root` / `check_debian`.
2. If `.nvidia-finalize-pending` exists and its recorded boot ID differs from the current boot ID, route directly to `stage3_finalize_nvidia`. Same-boot markers mean NVIDIA is prepared but the machine has not rebooted yet, so setup continues without premature finalization.
3. If `--remote` is passed, run `run_remote_recovery`.
4. If `--transcoding` is passed, run `run_transcoding_recovery`.
5. Run normal pre-flight checks, including disk/network/RAM/sudo/GPU stash and Docker/Compose validation as appropriate.
6. Run `detect_existing_install`. Completed Stage 1 installs can choose "Use existing install" to open `show_existing_install_menu`, which can run Stage 2, run the hardware transcoding add-on, continue without changes, abort, or delegate to the wipe path. If `.env` exists but `STAGE_1_COMPLETE` is not `1`, setup treats it as an interrupted Stage 1 and resumes the wizard instead of showing the existing-install menu.
7. Continue to the full staged wizard only when there is no completed existing install, when Stage 1 is incomplete, or when the user explicitly completed the typed destructive reinstall flow.

State rules stay unchanged across the recovery routes:

- `REMOTE_WEB_STATE=ready` remains the only public HTTPS publication gate. `REMOTE_WEB_STATE=failed` means HTTPS was requested but Let's Encrypt/NPM postconditions did not complete; `--remote` delegates unchecked/skipped/failed states to Stage 2 and ready states to a scoped configure/heal path. No path sets ready without cert/proxy postconditions.
- Detected GPU state alone never publishes `JELLYFIN_GPU`. `--transcoding` re-runs GPU detection and then delegates encoder publication, runtime override, evidence checks, fallback, and NVIDIA marker handling to the hardware transcoding engine.
- Destructive reinstall remains behind the existing typed `DESTROY` confirmation. The contextual add-stage menu is non-destructive by default and preserves user media data bind mounts.

## Prerequisite checks (phase 1)

- `check_not_root` — refuse to run as root; `sudo` is used inside specific functions.
- `check_debian` — refuse non-Debian hosts. Ubuntu is not supported despite apt compatibility (no testing).
- `check_docker` / `check_compose` — only called in phases 5–6 after `--full` has had a chance to install them.
- `check_disk_space` — warns if `<50 GB` free at `${DATA_DIR}`.

## Base packages and Docker install (phase 2, `--full` only)

`install_base_packages` installs: `curl ca-certificates gnupg lsb-release sudo pciutils python3-yaml python3-bcrypt gettext-base ufw unattended-upgrades samba git htop bind9-dnsutils smartmontools`. `python3-yaml` is needed by `configure.sh`'s YAML helpers. `python3-bcrypt` is retained as a harmless legacy dependency, but wg-easy v15 now hashes `INIT_PASSWORD` internally on first boot. Variable JSON payloads are rendered with Python `json.dumps` or the `json_body` helper; `gettext-base` remains installed for legacy shell-template compatibility, not for JSON substitution. `git` is needed for the pinned nvidia-patch fetch/checkout flow. `htop`, `bind9-dnsutils` (dig), and `smartmontools` (smartctl) are diagnostic tools for common media server troubleshooting.

`install_docker` adds the official Docker apt repo, installs `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`, and runs `usermod -aG docker "$USER"`. Group membership needs a new session; the script uses `exec sg docker -c "$0 $*"` to re-invoke itself with the group applied immediately.

## GPU detection + Hardware Transcoding ownership

Pre-wizard setup runs `stash_gpu_type`, which calls `detect_gpu` and stores one of `nvidia`, `amd`, `intel`, or `none` for the wizard. This detection is not enough to publish Jellyfin hardware transcoding; `write_env` keeps `JELLYFIN_GPU=none` until the hardware transcoding engine explicitly completes verification/finalization.

The Hardware Transcoding add-on runs after Stage 1 has started the baseline LAN stack and before Stage 2 remote access. It owns the driver/config paths:

- Intel: install userspace drivers, run `verify_gpu_usable`, configure Jellyfin `qsv` first, then try Intel `vaapi` for older Intel graphics if QSV does not verify. If neither encoder passes the automatic transcode proof, fall back to software.
- AMD: install userspace drivers, run `verify_gpu_usable`, configure Jellyfin `vaapi`, then require automatic transcode proof or fall back to software.
- NVIDIA: the hardware step first asks for a driver-management mode (`_stage3_choose_nvidia_mode`, Standard listed first so it is the non-interactive default). **Standard** installs the Debian-packaged driver via `install_nvidia_drivers_apt` with no patch; **Unlock NVENC limit** (explicit confirm) runs the patch-managed `.run` + `nvidia-patch` flow via `install_nvidia_drivers`. If the box is already on the Debian-managed driver, `prepare_nvidia_debian_to_unlock` removes only the installed Debian NVIDIA driver packages, preserves/repairs the NVIDIA container toolkit, unloads loaded NVIDIA modules when possible, and queues an Unlock resume reboot only when the modules cannot be removed. A pre-existing non-Debian driver routes to a keep-as-`existing`/abort prompt. If reboot is needed, the step writes `.nvidia-finalize-pending` recording `nvidia_driver_mode` + `install_source`, and defers `nvenc` until post-reboot finalization; `stage3_finalize_nvidia` applies the patch **only** when the marker's mode is `unlock`. The user is prompted for that reboot only after Stage 2 completes or is skipped.

Before Jellyfin is configured for an encoder, the hardware engine probes the selected backend's actual codec capability. H.264 hardware encode is the required proof (`h264_qsv`, `h264_vaapi`, or `h264_nvenc`). HEVC and AV1 output encoding are enabled only when short FFmpeg smoke encodes for `hevc_*` and `av1_*` pass. Hardware decode codec lists are probed from `vainfo` for QSV/VAAPI and conservative CUDA decode smoke tests for NVIDIA.

This does not require the user to open Jellyfin or manually play sample media. Captured Jellyfin playback/transcode logs remain a fallback evidence path for tests and unusual hosts.

If hardware configuration or automatic transcode proof fails before the retry limit, the hardware step offers retry verification, software fallback, or skip-for-now. Non-interactive/demo runs fall back to software without prompting.

NVIDIA must not use the old setup-level reboot path without `.nvidia-finalize-pending`.

## GPU helper details

`detect_gpu` — two-stage detection: first filters `lspci` to display-class PCI lines (`VGA|3D|Display`), then vendor-matches for NVIDIA, AMD/Radeon, or Intel. Falls back to `none`. Handles missing `lspci` (non-`--full` runs where `pciutils` is absent).

`install_nvidia_drivers_apt` (Standard mode) — detects the driver source via `nvidia_driver_source`: a Debian-managed driver short-circuits (toolkit only); a non-Debian driver returns a sentinel so the wizard keeps it as `existing` or aborts (no automatic `.run` uninstall in v1). Otherwise it runs the Secure Boot precheck, enables non-free via `ensure_debian_nonfree` (codename-aware: `contrib` + `non-free`[+ `non-free-firmware` on Debian 12+]; managed source file, idempotent), resolves the package with `_resolve_debian_nvidia_driver` (prefers the normal apt candidate; when supportedchips/PCI evidence shows the normal candidate can't drive a too-new GPU, the installer enables a managed `${codename}-backports` source via `ensure_debian_backports` + apt update, and the resolver escalates only if backports then has a newer suitable candidate — no hard-coded versions), installs `nvidia-driver` + `nvidia-container-toolkit`, sets `NVIDIA_DRIVER_MODE=standard`, and sets `NEEDS_REBOOT` so the module loads on reboot. It never applies nvidia-patch.

`prepare_nvidia_debian_to_unlock` (Standard → Unlock) — builds an exact purge list from installed `*nvidia*`, `*cuda*`, and `glx-*` packages while excluding `nvidia-container-toolkit`, `nvidia-container-toolkit-base`, `libnvidia-container-tools`, `libnvidia-container1`, and `glx-alternative-mesa`. It marks the toolkit packages manual, purges the Debian driver/userspace packages, then unloads `nvidia*` modules with `rmmod`. If modules remain loaded, it writes the nouveau blacklist, updates initramfs, and sets `NEEDS_REBOOT=true`; post-reboot finalization resumes the Unlock `.run` installer even when there is no cached `.nvidia-tmp/pending` file yet. `_install_nvidia_container_toolkit` validates the toolkit binary links with `ldd` and repairs/reconfigures the toolkit when the runtime binary exists but `libnvidia-container.so.1` is missing.

`install_nvidia_drivers` (Unlock mode):

1. Check for a `pending` marker from a pre-reboot cache — if found, verify nouveau is gone and install the cached `.run`. See ADR-19.
2. Check Secure Boot state via `check_secure_boot` — if enabled, fall back to software transcoding (unsigned kernel modules won't load).
3. Install kernel headers and DKMS build prerequisites.
4. Blacklist nouveau unconditionally (`/etc/modprobe.d/blacklist-nouveau.conf` + `update-initramfs`). Attempt runtime unload via `try_unload_nouveau()` — stops display manager, unbinds fbcon from vtconsoles, runs `modprobe -r nouveau drm_kms_helper drm`. Checks sysfs PCI binding for success, not just lsmod.
5. Resolve the correct driver via `_resolve_nvidia_driver()`: fetch the keylase/nvidia-patch README from MediaStack's reviewed pinned commit, then check GPU compatibility by curling NVIDIA's `supportedchips.html` for the target driver version (lightweight HTML, no `.run` download yet). The page lists PCI device IDs under "Current NVIDIA GPUs" or `legacy_NNN.xx` sections — a python parser identifies which section the GPU falls in. If legacy, switch to the matching branch from the README. Only then download the correct `.run` file.
6. If nouveau is still active (sysfs check): cache the `.run` in `.nvidia-tmp/pending`, set `NEEDS_REBOOT`, return. The installer is never run while nouveau has the GPU — it would either abort (`--silent`) or compile-then-rollback.
7. If nouveau is gone: install via `.run --silent --dkms --no-nouveau-check`. Sets `NEEDS_REBOOT=true`.
8. Install `nvidia-container-toolkit`, run `nvidia-ctk runtime configure --runtime=docker`, restart Docker.

`install_intel_drivers` — installs `intel-media-va-driver-non-free vainfo` from non-free. No reboot required.

`install_amd_drivers` — installs `mesa-va-drivers vainfo` from non-free. No reboot required. Same verification as Intel (a usable `/dev/dri/renderD*` render device, resolved by GPU vendor when sysfs exposes it).

`apply_nvidia_patch` verifies `github.com/keylase/nvidia-patch` at the pinned commit in `scripts/lib/nvidia_patch.sh`, rejects dirty or unexpected local patch trees, exports the reviewed commit to a temporary execution directory, checks driver version compatibility, then applies NVENC (removes encoding session limit on consumer GPUs) and NvFBC patches from that exported tree. Requires drivers already loaded, so the hardware engine runs it only after NVIDIA runtime verification.

## Reboot and resume

NVIDIA finalization is marker-based:

1. The hardware step writes `.nvidia-finalize-pending` when NVIDIA setup requires reboot. The marker records the current boot ID.
2. The FIN-02 prompt is shown only at the final wizard gate, or immediately for `./setup.sh --transcoding`, when `NEEDS_REBOOT=true` and that marker exists.
3. `scripts/setup/reboot.sh` schedules the existing systemd oneshot unchanged.
4. On resume, `setup.sh` checks `.nvidia-finalize-pending` before `--remote`, pre-flight prompts, existing-install detection, or the normal wizard. It routes directly to `stage3_finalize_nvidia` only when the current boot ID differs from the marker's creation boot ID.
5. `stage3_finalize_nvidia` reads the driver mode from the marker (a mode-less schema-1 marker is treated as `unlock`), verifies `nvidia-smi` and Docker runtime, and — **only for `unlock`** — resumes the `.nvidia-tmp/pending` `.run` install and applies the NVIDIA patch (Standard/Existing skip both and clear any stale `.run` cache). It then writes Jellyfin `nvenc`, runs deferred automatic transcode proof, prints the final summary, and removes the marker after persisted completion or fallback.

The older setup-level "install GPU, run wizard, schedule reboot" path is no longer the owner of NVIDIA reboot behavior.

## Post-reboot service notes

When hardware transcoding needs an NVIDIA reboot, `schedule_post_reboot` writes `/etc/systemd/system/mediastack-setup.service` — a `Type=oneshot` unit that runs `setup.sh` as `$USER` with `WorkingDirectory=$SCRIPT_DIR`. `ExecStartPost` disables and deletes itself so the unit runs exactly once.

On next boot:

- systemd starts `mediastack-setup.service` once `network-online.target` + `docker.service` are up.
- `setup.sh` sees `.nvidia-finalize-pending`, verifies the boot ID changed, and routes directly to `stage3_finalize_nvidia`.
- `cleanup_post_reboot` disables and removes the unit before finalization continues.

## OS hardening

`setup_hardening` (in `scripts/setup/hardening.sh`) runs before the wizard since it has no `.env` dependencies. It orchestrates four sub-functions, all idempotent (check-then-apply, `log_skip` if already done):

- **`setup_ufw`** — installs `ufw` if missing, then configures a default-deny-incoming firewall. Allows detected SSH server port(s) from RFC1918 LAN ranges only, plus the current non-private SSH client IP on its active server port during setup to avoid lockout. It also allows HTTP/HTTPS and the Beszel bridge-to-host agent path. SSH detection uses the active `SSH_CONNECTION`, `sshd -T`, and `/etc/ssh/sshd_config`; if no port is detected it warns during SSH sessions and falls back to `22/tcp`. `setup_ufw_service_ports` later opens qBittorrent and WireGuard ports after the wizard has loaded `.env`. `setup_ufw_docker_rules` appends iptables rules to `/etc/ufw/after.rules` that insert a `MEDIASTACK-DOCKER-RESTRICT` chain into `DOCKER-USER`, restricting LAN-only Docker ports (Jellyfin 8096, Homepage 3000, management ports, etc.) to RFC1918 private networks only. Idempotency: skips only when UFW is active, the `45876/tcp` marker rule exists, the MediaStack Docker rules block is persisted, and the live `DOCKER-USER` jump exists; otherwise it repairs the Docker restriction rules without resetting UFW service rules.
- **`setup_unattended_upgrades`** — installs and configures automatic security-only updates. Blacklists `linux-image*`, `linux-headers*`, `nvidia*` to prevent GPU/kernel breakage. `Automatic-Reboot "false"`. Idempotency: checks for `MediaStack` marker in `20auto-upgrades`.
- **`setup_sysctl_hardening`** — writes `/etc/sysctl.d/90-mediastack-hardening.conf` with SYN cookies, ICMP redirect protection, reverse path filtering, broadcast ICMP ignore, martian logging. Explicitly does NOT touch `ip_forward` (Docker + WireGuard need it). Idempotency: checks if conf file exists.
- **`verify_gpu_runtime`** — only runs when `GPU_TYPE=nvidia`. Checks `/etc/docker/daemon.json` for nvidia runtime registration via Python JSON parse. If missing, attempts `nvidia-ctk runtime configure --runtime=docker` + Docker restart.

## SMB file share

`setup_samba` runs after the wizard and `.env` sourcing, since it needs `SMB_ENABLED`, `SMB_SHARE_SCOPE`, `JELLYFIN_ADMIN_USER`, `JELLYFIN_ADMIN_PASSWORD`, and `DATA_DIR`. Returns immediately if `SMB_ENABLED != "true"`. Creates a system user (no home, no shell) matching the admin username, sets a Samba password from the admin password, writes `/etc/samba/smb.conf.d/mediastack.conf`, and adds LAN-only UFW rules for port 445. `SMB_SHARE_SCOPE=data` is the recommended default and writes a `[Media]` share pointing at `DATA_DIR`; `SMB_SHARE_SCOPE=system` writes `[MediaStackSystem]` pointing at `/` for explicit full filesystem/admin access. If port 445 is occupied by a non-MediaStack process, the wizard offers retry, disable SMB, or quit before asking for share scope. Idempotency: checks for `# MEDIASTACK` include marker in `smb.conf` and warns rather than auto-reconciling if an existing MediaStack include has a different scope.

## Storage modes

Stage 1 offers local managed storage, managed NFS NAS storage, and advanced manual app wiring. Advanced manual app wiring skips app-level library/download path setup; the wizard then asks whether to still enable NAS mount guard/watchdog for that manual storage.

- **Local managed** preserves the original `/data` layout and auto-configures app paths.
- **Managed NAS** mounts/verifies an NFS export before data directories are created. It records the expected `findmnt` source/fstype, verifies a sentinel file inside the mountpoint (`${DATA_DIR}/.mediastack-storage-ready` by default), and installs `mediastack-storage-watchdog.service`. The watchdog service runs as the installing user so it never executes checkout files as root; a narrow root-owned helper under `/usr/local/libexec/mediastack/` handles only mount repair using `/etc/mediastack/storage.env`.
- **Manual storage** starts the stack but `configure.sh` skips all app-level storage wiring: qBittorrent paths/categories, Sonarr/Radarr root folders/download clients, Jellyfin libraries, Jellyseerr links, and Unpackerr path wiring.

If managed NAS preflight cannot install NFS support, the wizard offers retry, local storage, advanced manual app wiring, or quit. If the NAS mount fails, it offers edit-and-retry, retry with the same settings, local storage, advanced manual app wiring, or quit. When advanced manual app wiring is selected, the wizard asks whether to still enable NAS mount guard/watchdog; saying yes keeps `STORAGE_MODE=nas` and sets `STORAGE_APP_WIRING=manual`. A mounted NAS share that is non-empty or has `media`/`torrents` conflicts prompts managed-mode users for a new `mediastack/` subfolder, local storage, manual app wiring, or quit; manual app wiring may keep the existing NAS root because MediaStack will not create managed app paths there. Stage 1 runs a final NAS guard after `.env` is written but before stopping the stack or creating directories; if that guard fails, it offers retry, edit-and-retry, local storage, manual app wiring, or quit and rewrites `.env` before continuing.

Managed NAS mode never recursively `chown`s the NAS root. It creates missing MediaStack subdirectories and only attempts ownership on newly created directories. `start_stack`, the launcher start action, and `update.sh` refuse to start data services if the NAS mount identity or sentinel check fails. NAS-dependent containers have restart policy disabled; the user-mode watchdog starts the known NAS service set only after the mount/sentinel is stable, including after a clean reboot where Docker did not auto-restart those containers.

## Environment detection

`detect_env` (in `scripts/setup/env_gen.sh`) auto-detects host-specific values without user interaction:

- `TZ` via `timedatectl show --property=Timezone` (fallback `Etc/UTC`)
- `PUID`/`PGID` via `id -u`/`id -g`
- `HOST_ADDRESS` via `hostname -I`

These are stored in shell variables (`_ENV_*`) for the wizard to use as defaults. No files are written — `detect_env` is idempotent and side-effect-free.

`write_env` (also in `env_gen.sh`) writes the complete `.env` file from wizard-set globals (`_WIZ_*`) and auto-detected values (`_ENV_*`). Called by the wizard apply phase to materialize the current selections, replacing any pre-seeded `.env` values with the finalized wizard state. It seeds default Docker bridge values (`MEDIASTACK_NETWORK_PREFIX=172.28.0`, `/24` subnet, gateway, and NPM IP); `start_stack` then runs the collision selector and rewrites those values before container start if a LAN/VPN/Docker route already uses the default subnet. Also seeds the DDNS `config.json` after Dynu credentials pass the Stage 2 preflight.

## Setup wizard (after `detect_env`)

`run_wizard` owns the entire interactive flow — all user-facing prompts live here:

| Stage | Title | Questions | Config target |
|------|-------|-----------|---------------|
| 1 | Core LAN | Account/storage, quality, subtitles, torrent limits; install baseline LAN stack | `.env`, `config.yml`, baseline stack |
| 2 | Remote Access | Domain, WireGuard, DDNS, port-forwarding guidance; install remote services only when ready | `.env`, remote/proxy profiles |
| Add-on | Hardware Transcoding | Configure, skip, or defer GPU acceleration after Core LAN; finish NVIDIA after reboot when needed | `.env`, `docker-compose.override.yml`, Jellyfin encoding |

Stage 1 always starts the baseline stack without GPU-specific compose directives. The hardware transcoding engine regenerates `docker-compose.override.yml` with `none`, `intel`, `amd`, or `nvidia` only after the relevant driver/runtime branch reaches the appropriate verification point.

If `.env` exists from an interrupted run, values are sourced as defaults so the user doesn't re-enter everything.

### `DEMO=1` non-interactive mode

`DEMO=1 ./setup.sh ...` bypasses the interactive wizard entirely. This is intended for CI, scripted deploys, and remote-host verification where prompting is a liability, not a feature.

- Pre-seed `.env` with any values you care about before running, especially `DOMAIN` and `NPM_ADMIN_EMAIL` for remote access.
- If `JELLYFIN_ADMIN_PASSWORD` is absent, weak, or still `changeme`, the wizard generates a fresh password with `openssl rand -base64 16`. If `openssl` fails, setup hard-stops instead of falling back to a weak default.
- Defaults are intentionally conservative and reproducible: `balanced` quality, `english` subtitles config, unlimited torrent speeds (`0`/`0`), SMB disabled unless pre-seeded on, and LAN-only mode unless a real domain + email are present.
- In v15, wg-easy takes the plaintext admin password via `INIT_PASSWORD`; there is no separate hash-generation step. If the admin password is empty in `DEMO=1`, the run degrades safely to LAN-only mode by leaving `WG_INIT_PASSWORD=''` rather than starting wg-easy with no admin credential.

`UI_DEMO=1` still exists, but it is a UI simulation mode for screenshots/tests that walks the normal wizard prompts with fake answers. It is not the same thing as `DEMO=1`.

### WireGuard INIT_PASSWORD propagation (v15)

wg-easy v15 reads the admin credentials from the unattended-setup `INIT_*` env block at first boot only (see ADR-28). `_stage2_collect_wireguard` in `scripts/setup/stages/stage2.sh` sets `_WIZ_WG_INIT_PASSWORD` from the just-confirmed admin password; `env_gen.sh` writes it to `.env` as `WG_INIT_PASSWORD='…'`. Single quotes are mandatory because the plaintext value can contain `$`, `"`, or `\` which Docker Compose interpolates inside unquoted values.

After `/etc/wireguard/wg-easy.db` exists, `INIT_*` vars are inert. Subsequent wizard re-runs leave the in-container admin password unchanged; rotate it in the wg-easy UI instead. The configurator (`scripts/services/wireguard/main.sh`) detects this on its readiness probe and logs `[SKIP]` for an existing initial peer.

### Quality presets

Presets are defined in `scripts/setup/presets.yml`:

- **Compact** (`WEB-720p/1080p`): WEB 720p only (no 1080p, no HDTV/Bluray), cutoff WEB 720p (1001). ~2-4 GB/movie.
- **Balanced** (`HD-720p/1080p`): All 720p+1080p (HDTV/WEB/Bluray, no Remux), cutoff WEB 1080p (1002). ~4-8 GB/movie. Matches the shipped `config.yml` defaults.
- **Quality** (`HQ-1080p`): 1080p + 720p fallback (no Remux), cutoff WEB 1080p (1002), higher preferred sizes within real-1080p ranges. ~6-15 GB/movie.

Remux is intentionally excluded across all presets — single grabs of 25-40 GB don't fit the home-server audience. See [`docs/reference/quality-bounds.md`](../reference/quality-bounds.md) for full per-tier numbers.

`wizard_apply.py` performs section-targeted replacement in `config.yml` — only the `quality_profile`, `quality_definitions`, and `bazarr` sections are rewritten; comments in all other sections are preserved. Adds `wizard_completed: true` as a wizard-progress marker. Subsequent runs of `setup.sh` skip the wizard only when this marker is present and `.env` also has `STAGE_1_COMPLETE=1`; if setup was interrupted before Stage 1 proved Jellyfin usable, the wizard resumes with the previous `.env` values as defaults.

## Override generation

`generate_override` writes `docker-compose.override.yml` based on `IMAGE_CHANNEL`, `$GPU_TYPE`, and
host memory. Stable (the default) adds `image: tag@sha256:digest` entries from
`docs/operations/image-digests.lock`; Latest omits image overrides and uses the tags in `docker-compose.yml`.
It then computes proportional memory limits for all 19 services using `compute_mem_limit`
(percentage of `HOST_MEMORY_MB`, clamped to a floor and cap), then writes GPU-specific
configuration:

- **nvidia**: adds `runtime: nvidia`, `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=all`, and a Jellyfin healthcheck override that requires both `/health` and in-container `nvidia-smi` to pass.
- **amd** / **intel**: mounts `/dev/dri:/dev/dri` (entire directory), adds `group_add: ["<render_gid>"]`. Render GID is read via `getent group render` — *not* hardcoded to 109; it varies across distro versions.
- **none**: writes resource limits only, no GPU-specific configuration.

The override is gitignored and regenerated on setup runs. Stage 1 writes resource limits only; the hardware transcoding engine rewrites GPU-specific directives after driver/runtime verification or removes them during software fallback.

## Pull and start

`pull_images` runs `docker compose pull` with the active profile args before any containers start. If a pull fails (transient network error, registry timeout), it retries up to 3 times with exponential backoff (10s, 20s, 40s). On exhaustion it warns but continues — cached images and non-failing services will still start. This prevents a single registry timeout (e.g. ghcr.io for FlareSolverr) from silently cascading through `depends_on` chains into skipped configuration (ADR-20).

`start_stack` then runs `docker compose up -d` with profiles determined by `_build_profile_args`: `--profile subtitles` when `BAZARR_ENABLED=true`, `--profile autoheal` by default unless disabled, `--profile proxy` when `DOMAIN` is set, and `--profile remote` when `WG_INIT_PASSWORD` is set (wizard confirmed the admin password for wg-easy unattended setup). `wait_for_healthy` polls `docker compose ps --format json` for up to 120s, parses each service's `Health`/`State` via inline Python, and reports the set still starting. Warns (not fails) if any service is still unhealthy at the timeout — `configure.sh` will retry its own waits.

## Running configure.sh

`"$SCRIPT_DIR/scripts/configure.sh"` is called directly inside `main()`. Its failure is **non-fatal** to `setup.sh` because `set -e` tolerates script-style failures when the command is a pipeline/block, and `configure.sh` itself disables `-e` (see [configure-flow.md](configure-flow.md)).

`configure_jellyfin` calls `configure_jellyfin_encoding()` after library setup. This reads `$JELLYFIN_GPU`, `$STAGE_3_GPU_ENCODER`, and the hardware transcoding codec capability vars from `.env`, maps nvidia→nvenc, amd→vaapi, and intel→qsv or vaapi depending on the active hardware attempt, then POSTs to Jellyfin's `/System/Configuration/encoding` endpoint (GET-merge-POST to preserve unrelated settings). The hardware engine keeps `JELLYFIN_GPU=none` until hardware proof is complete, verifies the live Jellyfin encoding API fields before writing `STAGE_3_GPU_STATE=complete`, and clears live hardware settings during software fallback when the Jellyfin API key is available. After hardware transcoding is complete, later `configure.sh` runs warn on Jellyfin transcoding drift instead of overwriting manual UI changes; `./setup.sh --transcoding` is the explicit re-verify/apply path.

The hardware transcoding engine writes these codec capability vars:

- `STAGE_3_GPU_HW_DECODING_CODECS` — comma-separated Jellyfin hardware decode codec list, e.g. `h264,hevc,vp9`.
- `STAGE_3_GPU_DECODE_HEVC_10BIT` — enables Jellyfin's HEVC 10-bit decode flag when probed.
- `STAGE_3_GPU_DECODE_VP9_10BIT` — enables Jellyfin's VP9 10-bit decode flag when probed.
- `STAGE_3_GPU_ALLOW_HEVC_ENCODING` — enables HEVC output encoding only when the selected backend's HEVC encoder smoke test passes.
- `STAGE_3_GPU_ALLOW_AV1_ENCODING` — enables AV1 output encoding only when the selected backend's AV1 encoder smoke test passes.
- `STAGE_3_GPU_RENDER_DEVICE` — selected Intel/AMD render node, e.g. `/dev/dri/renderD129`; used for QSV/VAAPI probes and Jellyfin `QsvDevice`/`VaapiDevice`.

## Observations / open questions

- **Post-reboot interactive path.** The final reboot gate schedules the post-reboot unit for both "Reboot now" and "Reboot manually later". A user who later reboots with `.nvidia-finalize-pending` present will enter `stage3_finalize_nvidia` before the normal wizard because the marker boot ID no longer matches the current boot.
- **`set -e` during configure.sh call.** `setup.sh` has `-e` active, but `configure.sh` is invoked at top level inside `main()` — a non-zero exit here would abort `setup.sh`. In practice `configure.sh` disables `-e` internally and returns 0 almost always, but an outright parse error (rare) would stop the user from seeing `print_access_info`.
- **`--full` path is only partially tested end-to-end.** The `fresh-install` scenario exercises the staged install path inside DinD with Docker already available. Real GPU driver install, real NVIDIA reboot, and live hardware transcode proof still need a VM or bare-metal host with matching hardware.
- **Generated-password UX.** The admin password defaults to `openssl rand -base64 12`. A non-technical user pressing Enter through all prompts ends up with a strong password they haven't written down. The final `print_access_info` block directs users to `.env` for the password but does not echo it.
- **~~No idempotence guard across GPU mode switches.~~** Fixed: `setup.sh` syncs `JELLYFIN_GPU` in `.env` after `verify_gpu_usable` (downgrade-only — never overrides user's CPU-only wizard choice). The wizard's choice is authoritative; the sync only fires when `GPU_TYPE == "none"` (hardware gone/broken).
- **Disk-space check runs after `--full` work.** `check_disk_space` is called inside `main()` after GPU work, but only against `$DATA_DIR`; pre-GPU-install it may run against `/` before the user has picked their data dir. The warning reaches the user, but not early enough to refuse installation on a cramped host.
- **Hardcoded 120-second health timeout.** `wait_for_healthy` gives up at 120s. On a slow host doing a cold pull of 5 GB of images, services can still be downloading well beyond that. `configure.sh` retries its own per-service waits up to 90s each (in `wait_for_service` from `scripts/lib/http.sh`), but the UX is that `setup.sh` warns "some services may still be starting" even on a healthy cold install.
