# MediaStack E2E Test Framework

End-to-end tests that run inside a Docker-in-Docker container so your host stays clean after normal runs — no apt-installs, no stray containers, no lingering port bindings. The host-side image cache volume persists by design unless explicitly purged.

DinD is a **Debian-based** image (`ms-dind:debian`, built from `tests/Dockerfile.dind`), matching the production distro. First `./tests/run.sh` invocation builds it (~40s); subsequent runs use the docker layer cache.

> **Two surfaces, complementary scope.** This README covers DinD — fast (~16 min full battery), runs everything that happens *inside* the VM. Real Let's Encrypt HTTP-01, real public DNS via Dynu, and the WAN-firewall proof for every Docker LAN-only TCP port are validated on **maintainer-private live-host harnesses** (cloud VM + bare metal — they need real infra/creds, so they're maintainer-only and not published here). The surfaces are complementary: DinD cannot prove DDNS pushes / public DNS resolution / firewall behavior, and the live-host runs don't exercise every in-VM scenario (npm-heal, wireguard-{server,containers,streaming}, wizard-presets are DinD-only). Pick by what's being validated.

GitHub Actions runs a deliberately small PR gate: committed-secret checks, shell/Python
syntax checks, compose rendering, focused host unit tests, and the `wizard-ui-*` PTY
scenarios in DinD with service image preload skipped. The full image-backed DinD battery
(`fresh-install`, `smoke`, remote-access scenarios, and service startup checks) stays a
local/on-demand gate. CI also handles the scheduled image-drift alert; maintainers run
the matching local DinD preflight before accepting image updates. Stable-channel installs
use the accepted digest record through the generated compose override; Latest-channel
installs intentionally follow upstream tags.

## Prerequisites

- Docker on the host (Compose v2 not required inside DinD; it's pre-baked in the image).
- Free disk: ~6 GB for `fresh-install` (image pulls inside DinD) + ~500 MB for the DinD image itself.
- Network: first run downloads base images (debian:bookworm-slim + Docker CE apt repo); subsequent runs can go fully offline if the host already has the MediaStack images (see image cache below).

## Running

```bash
./tests/run.sh                       # default: smoke
./tests/run.sh smoke                 # ~90s cold
./tests/run.sh fresh-install         # ~15-18 min (images cached) / ~25 min (cold)
./tests/run.sh smoke fresh-install   # both, in order
./tests/run.sh remote-gating         # REMOTE_WEB_STATE publication gates
./tests/run.sh --no-preload nas-storage  # managed NAS/NFS fixture (~4s)
./tests/run.sh --no-preload wizard-ui-stage1-local wizard-ui-stage1-nas-retry  # core PTY wizard UX checks
./tests/run.sh smoke remote-gating npm-heal  # focused remote-state gate
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready  # focused remote-access gate
./tests/run.sh --keep fresh-install  # leave DinD running on failure for debugging
./tests/run.sh --no-preload <scenario>  # skip host image sideload for lightweight scenarios
```

Exit code is non-zero if any hard assertion failed. `[SKIP]` lines never fail.

## Scenarios

### `smoke` — ~90 seconds

Fast checks of the security-review fixes. Spawns standalone NPM + wireguard containers inside DinD; does not bring up the full stack.

Proves:
1. Default, remote, proxy, and remote+proxy compose configs all parse cleanly with the v15 `INIT_*` env contract.
2. Single-quoted plaintext `WG_INIT_PASSWORD` (including shell-special chars `$`, `"`, `\`) reaches the wireguard container as `INIT_PASSWORD` byte-for-byte (compose-interpolation safety).
3. `WG_INIT_ALLOWED_IPS` in `.env` reaches the container as `INIT_ALLOWED_IPS` byte-for-byte.
4. `npm`, `fail2ban`, and `ddns-updater` live in the **proxy** profile and stay out of the default profile.
5. NPM port 81 has no `host_ip` binding (LAN-reachable).
6. Fresh NPM accepts unauthenticated `POST /api/users` to seed the admin with rotated credentials (the happy path `configure_npm` uses).
7. New credentials authenticate; `admin@example.com / changeme` defaults are never active.
8. Second `POST /api/users` is rejected → `configure.sh`'s re-run path falls through to the rotation/idempotency branch.

### `fresh-install` — ~15-18 min warm / ~25 min cold

Full default-profile stack: `docker compose up -d`, wait for health, `configure.sh`, per-step evidence assertions, `.env` back-population check.

Proves:
- All 12 default-profile services come up healthy/running.
- `configure.sh` exits 0 (does not abort mid-run on a recoverable API error).
- Each of the 8 configure steps produced the expected side-effect (API key present, root folder registered, etc.).
- qBittorrent's live API accepts the shared admin credentials and reports configured preferences/categories through `tests/assertions/qbittorrent-live.sh`.
- Sonarr + Radarr get all expected indexers wired in (7 for Sonarr, 6 for Radarr) — catches regressions in the FlareSolverr cold-start retry path.
- Quality definitions were tightened from upstream defaults (HDTV-720p preferredSize on Sonarr, Bluray-1080p preferredSize on Radarr — both differ noticeably from stock; ADR-25 dropped Remux-1080p entirely).
- `SONARR_API_KEY`, `RADARR_API_KEY`, `JELLYFIN_API_KEY`, and ready-state `REMOTE_WEB_STATE` are back-populated into `.env`.

Total: 46 hard assertions at current scope.

If you add new assertions that detect a known `configure.sh` bug, use `skip` with a bug-ref so the scenario still runs. Convert back to `pass`/`fail` once the bug is fixed.

### `remote-gating` — remote publication gates

Starts proxy-profile services with a real `DOMAIN` while `REMOTE_WEB_STATE` is unchecked or skipped, then switches to ready for the Pebble-backed HTTPS path.

Proves:
1. `DOMAIN` still starts proxy infrastructure before remote web is ready.
2. Unchecked/skipped state creates no public NPM proxy hosts.
3. Jellyfin omits the managed NPM `KnownProxies` entry and external HTTPS URLs until ready.
4. Homepage uses LAN hrefs until ready.
5. NPM rate-limit and fail2ban validation still run outside the ready gate.
6. Ready state preserves cert-backed Jellyfin/Jellyseerr proxy publication with the Pebble ACME override.

### Stage 2 remote-access scenarios

Stage 2 adds WireGuard/remote-access DinD scenarios:

- `stage2-skip` proves the user can skip HTTPS setup, `REMOTE_WEB_STATE=skipped` is persisted, LAN URLs remain in Jellyfin/Homepage, and public NPM proxy hosts are not published.
- `stage2-ready` proves the ready path with safe in-VM/Pebble ACME fixtures: NPM renders cert-backed hosts, Jellyfin HTTPS responds, and `REMOTE_WEB_STATE=ready` is written only after proxy/cert postconditions.
- `wireguard` starts wg-easy v15 at the Full LAN tier with the `remote` profile, asserts the v15.3.0 image pin and bridge-network `.11` placement (ADR-23, ADR-28) plus the ADR-17 capability set, and verifies interface creation, Basic Auth on `/api/client`, peer creation via the v15 API, `wg-easy.db` persistence, NAT/MASQUERADE, and custom `WG_PORT` propagation end-to-end (compose binding, container listen-port, `wg0.conf`).
- `wireguard-server`, `wireguard-containers`, `wireguard-streaming` cover the Server / Containers / Streaming access tiers (ADR-29). Each enables wg-easy's per-client firewall and verifies the tier's `firewallIps` shape persists through wg-easy's possibly-500-but-persisted mutation path (ADR-28). Server tier asserts the bare `/32` shape, Containers asserts the MediaStack port enumeration (51821 excluded), Streaming asserts the Jellyfin+Jellyseerr+Homepage triple.
- Stage 2 distinguishes failed HTTPS attempts from intentional skips with `REMOTE_WEB_STATE=failed`; a failed LE gate keeps LAN/VPN usable and is retried by rerunning `./setup.sh --remote`, never by an automatic in-process retry.

Run the focused remote-access DinD gate with:

```bash
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready
```

This gate is intentionally not a real public WAN proof. Real public DNS, DDNS provider pushes, firewall behavior, and real Let's Encrypt HTTP-01 remain covered on the maintainer-private live-host harnesses.

### `nas-storage` — managed NAS/NFS fixture

Starts a disposable kernel NFS server inside the privileged DinD VM, exports a
tmpfs share, and mounts it through MediaStack's storage helper. This proves
real in-VM NFS mount identity recording, sentinel creation, directory creation
on the exported storage, local fallback rejection, remount recovery, and
watchdog startup of the known NAS-dependent service set after failure or clean
boot recovery. Unit coverage also checks that user-writable NAS exports are
written as the installing user, not through root, so root-squashed NFS exports
do not fail during sentinel or managed directory creation.

Run it with host image preload disabled because no MediaStack service images
are needed:

```bash
./tests/run.sh --no-preload nas-storage
```

Boundary: this is not a vendor NAS proof. Unraid/Synology/TrueNAS export rules,
root-squash policy, and long-running stale file handle behavior still need a
real NAS or VM-host proof.

### Reusable live assertions

`tests/assertions/qbittorrent-live.sh` can run after any real MediaStack stack
is up:

```bash
bash tests/assertions/qbittorrent-live.sh
```

It reads `.env` and `config.yml`, logs into qBittorrent with the shared admin
account, and verifies the live preferences/categories that Sonarr and Radarr
depend on. The DinD `fresh-install` scenario calls this same script through
`tests/assertions/qbittorrent.sh`; real-host/GCP-style host checks can run it
directly or over SSH.

### Stage 1 wizard UI scenarios

The `wizard-ui-stage1-*` scenarios drive real Stage 1 wizard prompts through a
pseudo-terminal with `tests/lib/wizard_pty.py`. They stub image pulls and stack
startup, then assert the transcript plus generated `.env` state.

- `wizard-ui-stage1-local` proves the local-storage path shows the storage
  choice, writes the selected data directory, and keeps NAS fields blank.
- `wizard-ui-stage1-nas-retry` simulates an NFS mount failure, chooses
  "Retry with the same settings", and proves the retry menu plus managed NAS
  state are preserved.

Run them with image preload disabled because they do not need MediaStack
service images:

```bash
./tests/run.sh --no-preload wizard-ui-stage1-local wizard-ui-stage1-nas-retry wizard-ui-stage1-nas-fallback-local wizard-ui-stage1-nas-fallback-manual wizard-ui-stage1-nas-edit-retry wizard-ui-stage1-final-nas-preflight wizard-ui-stage1-nas-existing-share wizard-ui-stage1-smb-retry wizard-ui-stage1-back-abort
```

Current DinD wizard UI coverage:

- [x] `wizard-ui-stage1-nas-fallback-local` - NAS mount fails, user chooses
  "Use local storage instead", stale NAS fields are cleared, and local storage
  state is written.
- [x] `wizard-ui-stage1-nas-fallback-manual` - NAS mount fails, user chooses
  "Advanced manual storage", keeps NAS guard/watchdog enabled, and persists
  `STORAGE_MODE=nas` plus `STORAGE_APP_WIRING=manual`.
- [x] `wizard-ui-stage1-nas-edit-retry` - NAS mount fails, user chooses
  "Edit NAS settings and retry", corrected settings are used, and only the
  corrected NAS identity is persisted.
- [x] `wizard-ui-stage1-final-nas-preflight` - NAS succeeds during collection
  but fails immediately before install; verify retry, edit-settings, local
  fallback, manual fallback, and quit options.
- [x] `wizard-ui-stage1-nas-existing-share` - NAS share classification covers
  empty, existing MediaStack-compatible, and conflicting non-empty structures
  without deleting or rewriting user media.
- [x] `wizard-ui-stage1-smb-retry` - SMB validation fails once and the user can
  retry or disable SMB with the final `.env` matching the selected path.
- [x] `wizard-ui-stage1-back-abort` - back navigation or abort from the install
  confirmation leaves no half-written unsafe storage state.

## Adding a scenario

1. Drop `tests/scenarios/<name>.sh` with a `run_scenario()` function.
2. The function has access to everything sourced by `run.sh`:
   - **Assertions** (`lib/assert.sh`): `pass`, `fail`, `skip`, `assert_eq`, `assert_contains`, `assert_http`.
   - **DinD control** (`lib/dind.sh`): `dind_exec "<cmd>"` (runs inside DinD with `/root/MediaStack` as CWD), `dind_logs <service>`, `dind_exec_tty` for manual poking.
   - **Stack helpers** (`lib/stack.sh`): `wait_healthy <svc> [timeout]`, `get_api_key_from_xml <path>`, `get_jackett_api_key`, `env_set KEY VALUE` (writes to `.env` via Python — safe with `$` and special chars), `env_get KEY`, `create_config_dirs_in_dind`.
   - **PTY wizard driver** (`lib/wizard_pty.py`): drive interactive prompt
     flows from JSON steps when pipe-based input would miss terminal behavior.
   - **Stage 1 wizard fixtures** (`lib/wizard_stage1_common.sh`): shared stubs
     for PTY Stage 1 scenarios that should avoid image pulls and stack startup.
3. Return 0 for clean finish; return non-zero to abort that scenario early. Counter updates persist across scenarios.
4. Run it: `./tests/run.sh <name>`.

A minimal template:

```bash
# tests/scenarios/my-test.sh
run_scenario() {
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    # … setup …

    if dind_exec "docker compose config --quiet"; then
        pass "compose parses"
    else
        fail "compose parses"
    fi
}
```

## Candidate-image upgrade preflight

Test a new image tag against a service's existing oracle **before** editing `docker-compose.yml`.
`MS_TEST_IMAGE_OVERRIDES` (`svc=ref` pairs, comma/space separated) patches the **DinD copy** of
compose — the host file is never touched — and a typo (unknown service, empty ref) aborts the run.
When the ref includes `@sha256:<digest>`, the DinD copy of `docs/operations/image-digests.lock` is patched too
so Stable-channel tests run the candidate digest instead of the existing lock row. Tag-only
overrides switch the DinD copy to `IMAGE_CHANNEL=latest` so the compose patch remains effective:

```bash
MS_TEST_IMAGE_OVERRIDES="wireguard=ghcr.io/wg-easy/wg-easy:16.0.0" ./tests/run.sh wireguard
```

Most services have no dedicated scenario — use `fresh-install` (which does **not** start the `remote`/wireguard or `subtitles`/bazarr profiles; those need their own scenarios). `docs/operations/upgrades.md` lists each
service's pin policy and preflight command; the "Bumping a Service Version" playbook in `docs/project/structure.md`
walks the full ritual. The `image-override` scenario is a fast (~15s, config-only) proof that an
override actually reaches compose:

```bash
MS_TEST_IMAGE_OVERRIDES="wireguard=example.invalid/wg:0" ./tests/run.sh --no-preload image-override
```

Preflight checks API **shape** only — for a major/API-unstable bump, also run the service's own battery plus `fresh-install` where relevant (note `fresh-install` excludes the `remote`/wireguard and `subtitles`/bazarr profiles). Host
image sideload reads the host compose, so a candidate ref may need a network pull inside DinD.

## Standalone unit tests (`tests/unit/`)

Not every test needs DinD. Pure-bash units — function-level checks that can run on the host without Docker — live under `tests/unit/` and are invoked directly:

```bash
./tests/unit/gpu-branching.sh
```

Current units:

- **gpu-branching** — exercises `detect_gpu`, `check_secure_boot`, `verify_gpu_usable` from `scripts/setup/gpu.sh` by shimming `lspci`/`mokutil`/`nvidia-smi`/`docker` and render-device helpers as in-shell functions. Catches regressions in GPU selection logic, including no-GPU `set -e` behavior and vendor-aware Intel/AMD render-node routing, without needing real hardware.
- **qbittorrent** — checks qBittorrent login form encoding, first-run temp-password handling, shared-admin credential alignment, manual-storage behavior, and the reusable live assertion parser.
- **portainer** — checks Portainer auth drift handling, including a warning when admin auth returns no JWT and the normal endpoint/API-token setup path when auth succeeds.
- **bazarr** — checks Bazarr config-file write success/failure handling without needing a running Bazarr container.
- **jellyfin** — checks Jellyfin library creation logging for successful and failed API POSTs without needing a running Jellyfin container.
- **jellyseerr** — checks Sonarr/Radarr connection payload profile lookup with quoted/backslash profile names.
- **json-helpers** — exercises `json_get`, `json_path`, `json_has_name`, `json_array_nonempty` from `scripts/lib/json.sh` with representative inputs (missing keys, nested paths, case-insensitive matching, empty/invalid JSON).
- **common** — exercises shared `.env` API-key persistence helpers, including values with `&`, `|`, `/`, append behavior, sourceability, and rejection of unsupported newline/quote values.
- **image-drift** — verifies that digest acceptance requires a frozen `--current-file`, preventing maintainers from recording a tag digest that was not the one preflighted; also checks the generated README Stable-image badge block stays derived from the lock file.
- **manage-updates** — covers the day-2 "Manage updates" feature (ADR-30): `override.sh` per-service policy (floating one service drops only its digest pin; clearing re-pins; global-latest pins nothing), `image-drift.py --status` truth table and hardened running-digest extraction, and the launcher's WireGuard/non-updatable exclusion from "Update all" (sources `mediastack` via its `BASH_SOURCE` guard). Pure bash + python3; no Docker/network.
- **launcher-hardware** — covers the `./mediastack` day-2 "Manage hardware transcoding" surface: the post-install menu exposes it, the submenu offers configure/change and NVIDIA repatch where relevant, and configure/change dispatches to the transcoding recovery path. Pure bash; no Docker/network.
- **test-runner** — checks that `tests/run.sh` rejects empty or truncated scenario files instead of reusing a stale `run_scenario`.
- **wizard-prompts** — guards the shared wizard-prompt SSOT (`tests/lib/wizard_prompts.json`): every regex compiles, the step-builder (`wizard_steps_build.py`) renders name/`@timeout`/`ENTER`/`NONE` and rejects unknown names, no `wizard-ui-*` scenario that builds from the SSOT re-inlines a prompt regex or references an undefined name, and any scenario calling the builder sources a lib that defines it.
- **remote-web-state** (`tests/unit/remote-web-state.sh`) — exercises `write_env()` remote marker rules and `print_access_info` output for unchecked, ready, skipped, and LAN-only states.
- **stage2-domain** — exercises domain/DNS classification, Cloudflare proxy detection, and safe routing before publication.
- **stage2-dynu** — exercises Dynu IP Update Protocol response-token handling for success, unchanged, auth, host, abuse, DNS, and retry states.
- **stage2-ports** — exercises local port checks and failure classification without claiming public WAN reachability.
- **stage2-wireguard** — exercises the access-tier env mapping (Full LAN / Server / Containers / Streaming) plus `detect_lan_cidr` normalization. See ADR-29.
- **wireguard-service** — checks wg-easy peer provisioning uses the wizard admin username rather than a hardcoded peer name.
- **stage2-flow** — exercises Stage 2 offer/tell-me-more/skip/confirm flow and persisted remote setup state.
- **stage2-npm-stale** — exercises stale NPM host warning behavior without automatic reconciliation.
- **stage1-admin-password** — exercises Stage 1 admin-password default selection, including regeneration of prior passwords below Portainer's 12-character floor.
- **stage1-nas-ordering** — verifies Stage 1 pauses any previous NAS watchdog before stack stop, then enables/restarts it only after the initial stack start.
- **setup-late-watchdog** — verifies interrupted Stage 1 reruns pause stale NAS watchdogs before resuming the staged wizard and never fall through to the markerless late stack install path.
- **stack-health** — exercises setup health-gate classification for exited services, missing explicit services, and running containers without healthchecks.
- **stack-network** — exercises adaptive Docker subnet selection, including default `/24`, LAN/VPN collision fallback, split-default VPN routes, stale completed `.env` correction, completed-install no-migration behavior, and exhausted `172.16.0.0/12` guidance.
- **packages** — exercises `install_docker` repair behavior for Docker Engine present without Compose v2.
- **cache** — checks registry mirror lifecycle flags, including default cleanup and explicit keep behavior.
- **update** — checks `scripts/update.sh` option parsing, default no-prune behavior, and opt-in host-wide `--prune`.
- **reboot** — checks post-reboot profile/result banner rendering for non-default checkout paths.
- **nvidia-patch** — exercises the shared nvidia-patch pinning helper, including pinned checkout, dirty-tree rejection, unexpected-origin rejection, exported execution tree creation, and no `git pull` callers.
- **storage** — exercises NAS root classification, mount identity checks, and sentinel failure handling without touching real mounts.
- **resource-limits** — exercises `detect_host_memory`, `compute_mem_limit`, `generate_override` from `scripts/setup/override.sh` at simulated host sizes (512 MB – 64 GB) and all GPU paths.
- **stage3-gpu-content** — verifies `generate_override` GPU branches stay exclusive, including NVIDIA-only runtime healthcheck content.
- **config-validation** — exercises configure.sh's YAML validation gate with malformed inputs (bad indentation, tabs, missing colons, empty files, special characters in quoted strings). Verifies that parse errors exit non-zero and include a line number in the error message.
- **upgrades-manifest** — keeps `docs/operations/upgrades.md` in sync with `docker-compose.yml`: every service has a row, each row's pin-policy token matches the live image tag, and each preflight token resolves to a real scenario/unit. Pure bash + python3; run directly with `./tests/unit/upgrades-manifest.sh`.
- **wizard-flow** — exercises the full wizard interactive flow (`detect_env`, `run_wizard`, `write_env`) in `UI_DEMO=1` mode. Verifies `.env` is written with correct values and permissions, `config.yml` gets the wizard preset and completion marker, re-run skips correctly, and interrupted-run defaults are preserved from a previous `.env`.

Focused remote-access units:

```bash
bash tests/unit/stage2-domain.sh && bash tests/unit/stage2-dynu.sh && bash tests/unit/stage2-ports.sh && bash tests/unit/stage2-wireguard.sh && bash tests/unit/stage2-flow.sh && bash tests/unit/stage2-npm-stale.sh && bash tests/unit/remote-web-state.sh
```

GPU-flow integration isn't covered by `fresh-install` (DinD has no GPU passthrough); the unit test is the practical substitute for the detection/verification branches. End-to-end driver install + patch still needs a VM or bare-metal box with real NVIDIA hardware.

Focused hardware transcoding units:

```bash
bash tests/unit/gpu-branching.sh && bash tests/unit/nvidia-patch.sh && bash tests/unit/launcher-hardware.sh && bash tests/unit/wizard-flow.sh && bash tests/unit/stage3-flow.sh && bash tests/unit/stage3-marker.sh && bash tests/unit/reboot.sh && bash tests/unit/stage3-summary.sh && bash tests/unit/setup-resume-routing.sh && bash tests/unit/stage3-transcode.sh && bash tests/unit/stage3-gpu-content.sh
```

Hardware transcoding coverage uses Bash units, stubs, API fixtures, automatic FFmpeg smoke-test stubs, `vainfo` parser fixtures, and captured Jellyfin FFmpeg/transcode log fallback fixtures. `stage3-transcode.sh` verifies parser evidence, automatic proof, and codec capability probing for `qsv`, `vaapi`, and `nvenc`; `stage3-flow.sh` verifies Intel QSV-to-VAAPI fallback routing and Jellyfin codec-specific API fields. Real GPU transcode proof still requires a real host because DinD has no physical Intel/AMD/NVIDIA GPU passthrough.

Focused hardware-transcoding DinD regression gate:

```bash
./tests/run.sh smoke fresh-install stage2-skip stage2-ready
```

Focused recovery-hook units:

```bash
bash tests/unit/recovery-routing.sh && bash tests/unit/setup-resume-routing.sh && bash tests/unit/stage2-flow.sh && bash tests/unit/stage3-flow.sh && bash tests/unit/checks.sh
```

These cover `./setup.sh --remote`, `./setup.sh --transcoding`, NVIDIA marker-first resume routing, the existing-install add-stage menu, and preservation of the typed `DESTROY` wipe gate.

Focused recovery DinD regression gate:

```bash
./tests/run.sh smoke stage2-skip stage2-ready
```

This is still an in-VM proof. Public WAN reachability, production Let's Encrypt issuance, DDNS propagation, and firewall behavior remain GCP VM coverage. Real GPU transcode proof requires a real host because DinD has no physical GPU passthrough.

## Focused staged-setup scenarios

Use these when changing staged setup, recovery hooks, demo mode, destructive reinstall, or fail2ban filters:

```bash
./tests/run.sh smoke stage1-lan stage2-skip stage2-ready remote-after-skip remote-ready-idempotent demo-lan existing-install-nuke fail2ban-drift
```

Scenario catalog:

| Scenario | Requirement | Scope |
|----------|-------------|-------|
| `stage1-lan` | TEST-01 | Stage 1 LAN-only path with blank `DOMAIN`, non-ready remote state, Jellyfin LAN response, no public proxy, no GPU state. |
| `stage2-ready` | TEST-02 | Fixture DNS/Pebble ready path; proves proxy/cert postconditions and `REMOTE_WEB_STATE=ready`. |
| `stage2-skip` | TEST-03 | Skipped HTTPS path; proves LAN URLs and no ready-only proxy publication. |
| `remote-after-skip` | TEST-04 | Public `./setup.sh --remote` after skipped state, with fixture DNS/Pebble, reaches ready postconditions. |
| `remote-ready-idempotent` | TEST-05 | Public `./setup.sh --remote` after ready state preserves ready proxy/cert postconditions. |
| `demo-lan` | TEST-06 | Current `DEMO=1` Stage-1/LAN-safe contract; no full unattended remote or GPU setup. |
| `existing-install-nuke` | TEST-07 | Existing-install wipe menu plus exact `DESTROY`; all-profile compose down is used; data bind-mount sentinel survives reinstall. |
| `fail2ban-drift` | TEST-09 | Focused regex drift checks for `jellyfin`, `jellyseerr`, `npm`, and `npm-ratelimit`. |

Boundary: these are DinD proofs. `stage2-ready`, `remote-after-skip`, and `remote-ready-idempotent` use fixture DNS and Pebble, not public WAN. TEST-08 — real public DNS, DDNS updates, WAN firewall behavior, and real Let's Encrypt HTTP-01 — is proven on the maintainer-private live-host harnesses, not in this public repo.

## Debugging with `--keep`

When a scenario fails with `--keep`, the DinD container stays up:

```bash
./tests/run.sh --keep fresh-install     # after failure:
docker exec -it ms-test-dind sh          # shell inside DinD
docker exec -w /root/MediaStack -it ms-test-dind sh   # shell inside the repo
docker exec -w /root/MediaStack ms-test-dind docker compose logs sonarr | tail -50
docker rm -fv ms-test-dind               # when done — the -v is important
```

The host-side `/tmp/configure.out` captures the full `configure.sh` log from the last run.

## Targeted configure.sh re-runs

`configure.sh` accepts `--only svc1,svc2,...` to run only the named services (docker-compose names). The test suite uses this for re-run assertions (encoding, drift, idempotency) so they don't pay the cost of all 14 services each time.

Service names match docker-compose: `qbittorrent`, `jackett`, `sonarr`, `radarr`, `bazarr`, `jellyfin`, `jellyseerr`, `portainer`, `homepage`, `npm`, `ddns-updater`, `uptime-kuma`, `beszel`.

To iterate on a single service manually, keep DinD alive and run configure.sh inside it:

```bash
# Run the full test, keep DinD alive regardless of outcome
KEEP_ALWAYS=1 ./tests/run.sh fresh-install

# Re-run configure.sh for just jellyfin (fast — skips 13 other services)
docker exec -w /root/MediaStack ms-test-dind ./scripts/configure.sh --only jellyfin

# Re-run for multiple services
docker exec -w /root/MediaStack ms-test-dind ./scripts/configure.sh --only sonarr,radarr,jellyfin

# Full configure.sh (no flag = all services, same as production)
docker exec -w /root/MediaStack ms-test-dind ./scripts/configure.sh
```

Without `KEEP_ALWAYS=1`, use `--keep` — DinD stays up only on failure.

## Image cache — avoiding Docker Hub rate limits

Every DinD run starts with an empty nested image store, so without help each run pulls all 12 service images fresh — about 3 GB and 12+ pulls per run against Docker Hub's 100/6h anonymous cap. Two mechanisms together keep that near zero:

1. **Pull-through registry mirror** (`ms-registry-mirror` container on the Docker bridge gateway, usually `172.17.0.1:5000`). Started on demand by `tests/run.sh`. Configured as a mirror for `registry-1.docker.io` via `REGISTRY_PROXY_REMOTEURL`. DinD's inner dockerd points at it via `--registry-mirror=http://host.docker.internal:5000`. First pull of any image hits Hub once and caches in the `ms-registry-cache` Docker volume; every subsequent DinD run is free. Treated as **transitory dev infrastructure** (`--restart no`) — auto-starts when you run tests and is removed on normal runner exit, even when a previous test left it running. The volume persists across teardowns so the cache is intact next session. Set `MS_CACHE_MIRROR_KEEP=1` to leave only the mirror container running between normal test exits.

2. **Host image sideload.** After DinD boots, `cache_preload_into_dind` scans `docker-compose.yml` for pinned image tags, and for every image already present on the host runs `docker save <img> | docker exec -i ms-test-dind docker load`. Zero network. Works offline. If you run MediaStack in production on the same box, every image is already there — first test run costs essentially nothing.

Both run automatically. To bypass (e.g. to verify a cold-cache install works):

```bash
./tests/run.sh --no-cache fresh-install
```

Maintenance:

```bash
# Inspect cache size (registry volume)
docker system df -v | grep ms-registry-cache

# Stop a manually started or --keep-preserved mirror (cache volume preserved)
source tests/lib/cache.sh && cache_mirror_stop

# Keep the mirror warm after a normal test exit
MS_CACHE_MIRROR_KEEP=1 ./tests/run.sh smoke

# Nuke cache (mirror + volume), e.g. to reclaim disk or force re-fetch
source tests/lib/cache.sh && cache_mirror_purge
```

Disk footprint after first full test: ~3 GB in the `ms-registry-cache` volume. That's a one-time cost amortised across every future test run.

## Disk space — IMPORTANT

Each DinD run consumes **~2–5 GB** inside an anonymous Docker volume (`tests/Dockerfile.dind` declares `/var/lib/docker` as a VOLUME for the nested daemon's graph driver — same pattern as upstream `docker:dind`). `dind_up`/`dind_down` use `docker rm -fv` so the volume is removed on teardown — but if the runner is killed mid-run (ctrl-c, OOM, disk full), the container may be removed without its volume and the volume goes dangling.

After repeated runs — especially with `--keep` or interrupted runs — check and prune:

```bash
docker system df                    # Local Volumes row is the tell
docker volume ls --filter dangling=true
docker volume prune -f              # safe — only touches unattached volumes
```

Production containers (jellyfin/sonarr/etc.) attach named volumes that `prune` cannot touch.

A previous pass accumulated **133 GB across 68 dangling DinD volumes** over five test runs on a developer box; always prune between batches of test runs.

## Design notes

- **Pure bash.** No pytest / go-test. Matches the project's Debian + bash ethos.
- **Docker-in-Docker.** DinD is **Debian-based** (`ms-dind:debian`, built from `tests/Dockerfile.dind`) to match production. All deps (`gettext-base`/`envsubst`, GNU grep/sed, python3, docker-ce) are pre-baked in the image. Earlier revisions used Alpine-based `docker:dind`; Alpine's BusyBox + musl quietly diverge from Debian in ways that pass `bash -n` but fail at runtime.
- **Fresh DinD per `run.sh` invocation.** Each run pays the image-pull cost. We chose hermeticity over iteration speed; add a `--reuse-dind` flag if that changes.
- **Scenarios share one DinD.** `run.sh smoke fresh-install` does one DinD setup, runs both, tears down.
- **Counters are global across scenarios.** Final summary is a sum of all scenarios.
