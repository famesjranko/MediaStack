# Testing

End-to-end tests live under `tests/`. Pure bash, Docker-in-Docker, no pytest or go-test. Matches the project's Debian + bash ethos and keeps the host clean after normal runs — no apt installs, no stray containers, no lingering port bindings on the dev box. The host-side image cache volume persists by design unless explicitly purged.

The DinD image (`ms-dind:debian`, built from `tests/Dockerfile.dind`) is **Debian-based** (`debian:bookworm-slim` + Docker Inc's apt repo), matching production. Earlier revisions used the Alpine-based upstream `docker:dind`; that silently hid prod-vs-test skew (BusyBox grep lacks `-P`, `gettext-base` / `envsubst` not in Alpine's default set, musl diverges from glibc in edge cases) so the environment was switched to Debian.

## Two test surfaces

This document covers **DinD** — the fast in-VM surface. Two further surfaces cover real-world validation on actual hardware:

| Surface | Driver | Scope | Wall time | Cost |
|---------|--------|-------|-----------|------|
| **DinD** | `tests/run.sh` (full battery: `tests/battery.sh`) | Everything that happens *inside* the VM (configurators, fail2ban filters, NPM cert-disk drift heal, wizard flows, compose validation) | ~16 min full battery (252/252 baseline as of f7a7f71) | host CPU only |
| **Live-host** (maintainer-private) | private harnesses (not in this repo) | Real Let's Encrypt HTTP-01, public DNS via Dynu, real firewall/WAN-block proof + DDNS pushes (ephemeral cloud VM), plus real-hardware behaviour DinD can't model — GPU passthrough, UFW, systemd, disk I/O (bare metal). Needs real infra/creds. | minutes per run | cloud ~$0.03/hr or your hardware |

DinD cannot prove DDNS pushes work, that public DNS resolves to the new IP, or that a real firewall actually blocks admin ports — the maintainer-private live-host harnesses cover that (an ephemeral cloud VM for the WAN/DNS/LE proof, bare metal for GPU passthrough and host-specific OS behaviour on real silicon). Conversely, the live-host runs don't exercise every internal scenario (npm-heal, wireguard-{server,containers,streaming}, wizard-presets are DinD-only because they exercise interrupted/corrupted setup paths a real VM should never see).

Pick by what's being validated. The live-host harnesses are maintainer-only — they need real infra/creds and are not published here.

## CI boundary

GitHub Actions stays deliberately focused: committed-secret checks, shell/Python syntax,
compose rendering, focused unit checks, the upgrades manifest guard, and the wizard PTY
scenarios. The wizard PTY job uses DinD with service image preload skipped, so it does not
pull MediaStack service layers. It deliberately does not run the full DinD battery
(`fresh-install`, `smoke`, and the other image-backed scenarios), which pulls ~7GB of
images and stays a local/on-demand pre-merge gate. The scheduled image-drift alert compares
upstream digests with `docs/operations/image-digests.lock`; a failure is a signal to run
the relevant local DinD preflight from `docs/operations/upgrades.md`, then accept the new
digest baseline only after that passes. Stable-channel installs use that accepted baseline
through the generated compose override.

## Entry point

```bash
./tests/run.sh                        # default: smoke
./tests/run.sh smoke                  # ~90s cold
./tests/run.sh fresh-install          # ~15-18 min warm / ~25 min cold
./tests/run.sh smoke fresh-install    # both in order
./tests/run.sh remote-gating          # REMOTE_WEB_STATE publication gates
./tests/run.sh --no-preload nas-storage  # managed NAS/NFS storage fixture (~4s)
./tests/run.sh --no-preload autoheal  # Autoheal functional image-drift oracle (~40s)
./tests/run.sh --no-preload wizard-ui-stage1-local wizard-ui-stage1-nas-retry  # core PTY wizard UX checks
./tests/run.sh smoke remote-gating npm-heal  # focused remote-state verification gate
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready  # focused remote-access gate
./tests/run.sh --keep fresh-install   # leave DinD running on failure
./tests/run.sh --no-preload <scenario>  # skip host image sideload for lightweight scenarios
./tests/run.sh --no-cache fresh-install  # force cold pulls (bypass image cache)
```

`tests/run.sh` orchestrates: validate scenario names, source libs, start cache mirror + DinD (`cache_mirror_up`, `dind_up`, `dind_copy_repo`, `dind_strip_services`, `cache_preload_into_dind`), run each scenario via `source` + `run_scenario`, then tear down runner-owned containers and print the summary on the exit trap (`on_exit`). Exit code non-zero if any hard assertion failed.

## Full battery (`tests/battery.sh`)

`./tests/battery.sh` is the codified full battery — it runs **every**
`tests/scenarios/*.sh`. The scenarios are stateful and `run.sh` copies the repo into
DinD only once (the `wizard-ui-*` scenarios stub `scripts/configure.sh`;
`fresh-install`/`api-matrix`/`wizard-presets` leave a stack running; some scenarios
don't reset themselves), so the battery runs them through **`run.sh --reset-between`**:
one DinD with images sideloaded once, and a full state reset (containers, volumes,
networks cleared + a clean repo restored) between each scenario — so every scenario
starts pristine regardless of order. `image-override` runs on its own DinD (its
`MS_TEST_IMAGE_OVERRIDES` would patch the compose for every other scenario). The
scenario set is discovered by glob, so a newly-added scenario is included automatically.
Exits non-zero if any scenario fails.

```bash
./tests/battery.sh          # run the whole battery (image-backed, local only)
./tests/battery.sh --list   # print the plan, run nothing
```

This is the local/on-demand gate the **CI boundary** above refers to — remote CI never
runs it (it skips image pulls).

## Libraries (`tests/lib/`)

Shell modules are sourced by `run.sh`; executable helpers in this directory are
called directly by scenarios that need them:

### `assert.sh`

Counter-backed assertions. Global `PASS_COUNT` / `FAIL_COUNT` / `SKIP_COUNT` persist across scenarios within a single `run.sh` invocation. Primitives:

- `pass "label"` / `fail "label" ["detail"]` / `skip "label" ["reason"]`
- `assert_eq EXPECTED ACTUAL "label"`
- `assert_contains HAYSTACK NEEDLE "label"`
- `assert_http URL EXPECTED_CODE "label"`
- `scenario_begin NAME` / `scenario_end NAME` / `summary`

`[SKIP]` lines never fail the run.

### `dind.sh`

DinD lifecycle (`tests/lib/dind.sh`):

- `dind_build` — build `ms-dind:debian` from `tests/Dockerfile.dind` on first run; cached by docker's layer cache. All runtime deps (`bash`, `python3`, `python3-yaml`, `curl`, `grep`, `sed`, `gettext-base`, `docker-ce` + `docker-compose-plugin`, `iptables`, `pigz`, `xz-utils`) are pre-baked into the image.
- `dind_up` — `docker rm -fv` any previous `ms-test-dind`, then launch the Debian-based `ms-dind:debian` privileged. If the cache mirror is running, inject `--registry-mirror=http://host.docker.internal:5000` + `--insecure-registry=...` and `--add-host=host.docker.internal:host-gateway`. The image's entrypoint (`tests/dind-entrypoint.sh`) handles the cgroup v2 init dance (move self to `/sys/fs/cgroup/init`, enable subtree controllers) before starting dockerd — without that, nested containers fail with "cgroupv2 ... in threaded mode" on hosts using cgroup v2.
- `dind_copy_repo` — tar-pipe the working tree to `/root/MediaStack`, excluding `.git`, `.env`, `.nvidia-patch`, `backups`, `tests/.dind-state`. Pre-seeded files in `config/{jackett,qbittorrent,fail2ban}` are included because they're tracked.
- `dind_exec "cmd"` / `dind_exec_tty` / `dind_logs <svc>` — run commands inside DinD with `/root/MediaStack` as CWD.
- `dind_strip_services` — if `MS_TEST_STRIP_SERVICES` is set, edit the DinD-internal compose file to remove named services and clean dangling `depends_on`. Useful for subset testing without burning Hub pulls.
- `dind_override_images` — if `MS_TEST_IMAGE_OVERRIDES` is set (`svc=ref` pairs, comma/space separated), swap those services' image tags in the DinD compose copy for candidate-image upgrade preflight; a typo (unknown service, empty ref) aborts the run, and the host compose is never touched. `ms_test_image <svc> <default>` resolves the same override for images launched outside compose (e.g. smoke's standalone NPM). See `docs/operations/upgrades.md` and the "Bumping a Service Version" playbook in `docs/project/structure.md`.
- `dind_down` — `docker rm -fv` to remove container *and* anonymous volume. `KEEP_ON_FAIL=1` + at least one FAIL keeps the container running for inspection.

**The `-v` on removal is essential.** `tests/Dockerfile.dind` declares `/var/lib/docker` as a VOLUME for the nested daemon's graph driver (same as upstream `docker:dind`). Without `-v`, every `dind_up` / `dind_down` cycle leaves a 2–5 GB anonymous volume behind.

### `stack.sh`

Compose / state helpers:

- `wait_healthy SERVICE [timeout]` — poll `docker inspect` until `.State.Health.Status == healthy` (or `State.Status == running` for services without healthcheck).
- `get_api_key_from_xml PATH` — XML regex extract `<ApiKey>` (mirrors `get_api_key` in `scripts/lib/common.sh`).
- `get_jackett_api_key` — JSON parse (mirrors `get_jackett_api_key` in `scripts/lib/common.sh`).
- `env_set KEY VALUE` / `env_get KEY` — write/read `.env` via inline Python so values with `$`, `&`, pipes, etc. survive intact. `sed -i` would corrupt shell-special values such as generated passwords and API keys.
- `create_config_dirs_in_dind` — pre-create all config subdirs + placeholder log files (mirrors `create_config_dirs()` in `scripts/setup/stack.sh`).

### `cache.sh`

Two-tier image cache — explained below in its own section.

### `wizard_pty.py`

Pseudo-terminal driver for interactive wizard UX scenarios. It runs a command
under a PTY, waits for regex patterns in an ANSI-stripped transcript, sends the
configured input, and writes raw/plain logs for failed scenario debugging.

### `wizard_stage1_common.sh`

Shared Stage 1 wizard fixture helpers for PTY scenarios. These helpers stub
image pulls, stack startup, and service configuration while keeping the real
prompt flow and `.env` generation path.

## Scenarios (`tests/scenarios/`)

Each scenario file defines a `run_scenario()` function. `run.sh` sources the file *into the current shell* so `pass`/`fail` counter updates persist. Return 0 = clean finish; non-zero = abort this scenario and move on.

### `smoke.sh` — ~90 seconds

Security-review regression checks. Spawns standalone NPM + wireguard containers inside DinD (no full stack). 9 checks:

| # | Check | Description | Protects against |
|---|-------|-------------|------------------|
| 1 | Plaintext `INIT_PASSWORD` (incl. shell-special chars) survives `.env` → compose → container byte-for-byte | "container receives INIT_PASSWORD byte-for-byte" | v15 takes plaintext; unquoted `$`/`"`/`\` would be interpolated by compose. |
| 2 | Default + remote + proxy compose profiles parse cleanly | "compose config parses (default/remote/proxy profile)" | YAML errors, missing env defaults. |
| 2b | Remote + proxy profiles combined parse cleanly | "compose config parses (remote+proxy combined)" | Profile combination conflicts (a natural first-run path). |
| 3 | `INIT_ALLOWED_IPS` reaches the container from `.env` | "container receives INIT_ALLOWED_IPS from .env" | Comma-separated CIDR list survives YAML/env interpolation. |
| 4 | NPM + fail2ban + ddns-updater on **proxy** profile, not default | "npm/fail2ban/ddns-updater in proxy profile" | Regression that puts proxy services in default profile. |
| 5 | NPM port 81 has no `host_ip` binding | "NPM port 81 is LAN-reachable (no host_ip)" | LAN-only intent silently becoming localhost-only (or worse). |
| 6 | Fresh NPM accepts `POST /api/users` without auth | "POST /api/users seeds admin (HTTP 201)" | The happy path `configure_npm` uses. |
| 7 | New NPM creds authenticate; defaults rejected | "new NPM credentials authenticate" / "NPM defaults never active" | Rotation failure leaving defaults active. |
| 8 | Second `POST /api/users` is rejected | "second POST /api/users rejected — idempotency path" | Idempotency — `configure_npm` re-run path hits the rotation code. |

### `fresh-install.sh` — ~15-18 min warm / ~25 min cold

Full default-profile stack. Brings up all 13 default-profile services, waits for health, runs `configure.sh`, asserts per-step evidence.

Structure (`tests/scenarios/fresh-install.sh`):

| Phase | Description | What it verifies |
|-------|-------------|------------------|
| 0. Prep | Data dirs, config dirs, `.env` setup, resource-limit override | Data dirs chowned to 1000:1000; `.env` populated with known values; `generate_override` produces resource limits. |
| 1. Compose up | `docker compose up -d` with optional Pebble ACME override | `docker compose up -d` exits 0. |
| 2. Health wait | Wait for all 12 services, verify resource limits, start Pebble | All 12 services healthy/running (`wait_healthy` with 360s budget). 11 services checked via healthcheck (flaresolverr, jackett, qbittorrent, jellyfin, npm, sonarr, radarr, seerr, unpackerr, homepage, fail2ban), Portainer by running status (`healthcheck: NONE`). Memory limits verified on all services. |
| 3. configure.sh | Run `configure.sh`, capture log | Exits 0, summary printed. |
| 4. Per-step evidence | Service-by-service API assertions | See below. |
| 4b. Fail2ban | Jail verification, filter regression, ban pipeline | Jails loaded, filters match current log format, DOCKER-USER chain used. |
| 4c. Rate limiting (disabled) | Default-off verification (ADR-35) | No `limit_req_zone` in `http_top.conf`, 0 proxy hosts carry `limit_req`, `npm-ratelimit` jail not loaded. |
| 5. `.env` back-population | API keys written to `.env` | `SONARR_API_KEY` / `RADARR_API_KEY` / `JELLYFIN_API_KEY` written. |
| 6. Drift regression | Mutate `config.yml`, re-run `configure.sh`, assert warnings | 3 expected `[WARN]` lines fire, no false positives. |

Per-step evidence (phase 4):

- **Step 1 qBittorrent:** `tests/assertions/qbittorrent-live.sh` logs into the live API with shared admin credentials, then verifies pause-on-ratio (`max_ratio_act=0`), speed limits, seed-time policy, Docker-subnet auth bypass, managed save/temp paths, and live API categories.
- **Step 2 Jackett:** API key present (>=20 chars); configured indexers, when any are enabled, are verified via Torznab caps request through Jackett (not direct upstream probe). Reports which indexers failed if any.
- **Step 3 Sonarr:** API key, root folder `/data/media/tv`, qBittorrent download client, `1080p Balanced` quality profile (fetched by ID, not grepping the full list). Custom format scores verified against exact config.yml values (all 7 formats: Repack/Proper=5, x264=10, x265 HD=-25, BR-DISK=-10000, LQ=-10000, No-RlsGroup=-25, Obfuscated=-25). Indexer count verified with tolerance for upstream-blocked failures. HDTV-720p `preferredSize` tightened to 30.0 (quality definitions). Forms authentication enabled.
- **Step 4 Radarr:** mirror of Sonarr with `/data/media/movies`. Custom format scores verified against exact config.yml values (same 7 formats). Indexer count, WEBDL-1080p `preferredSize` tightened to 50.0, Forms authentication enabled.
- **Step 5 Jellyfin:** `StartupWizardCompleted:true` in `/System/Info/Public`, admin auth returns `AccessToken` (with adversarial password containing `$`, `"`, `\`), Movies + TV Shows libraries present.
  Focused host-side coverage: `bash tests/unit/jellyfin.sh` checks Jellyfin library creation logs success or warning based on the library POST result; `bash tests/unit/api-matrix-jellyfin.sh` deterministically proves the VirtualFolders read retries transient failures, preserves the successful JSON response, and stops after five failed requests.
- **Step 6 Seerr:** `/api/v1/settings/public` reports `initialized:true`. Sonarr and Radarr connections verified. Jellyfin library sync verified — Movies and TV Shows both present and enabled (catches silent poll-timeout failures).
  Focused host-side coverage: `bash tests/unit/seerr.sh` checks Sonarr/Radarr connection payload profile lookup with quoted/backslash profile names.
- **Step 7 Portainer:** admin user initialized (HTTP 204 from `/api/users/admin/check`), wizard admin username + shared password returns JWT, local Docker endpoint created.
  Focused host-side coverage: `bash tests/unit/portainer.sh` checks that empty JWT auth drift warns and skips endpoint/API-token setup, while successful auth still provisions both.
- **Step 8 Homepage:** services.yaml generated with all service groups, Jellyfin widget configured, Sonarr uses internal URL, ready-state HTTPS URLs used when `REMOTE_WEB_STATE=ready` (`jellyfin.fresh.test`), accessible at port 3000.
- **Step 9 NPM:** shared admin creds authenticate, defaults rejected, ready-state proxy hosts created (>=2 user-facing), `jellyfin.$DOMAIN` routes via proxy, Let's Encrypt certificates issued via Pebble, SSL forced + cert on proxy hosts, HTTPS connectivity, security headers in `advanced_config`, Jellyfin's upstream CSP + `client_max_body_size 20M`.

### `bazarr.sh` — subtitles-profile oracle

The focused Bazarr scenario starts the `subtitles` profile target
(`docker compose --profile subtitles up -d bazarr`) with its Sonarr/Radarr
dependency chain, runs `configure.sh --only bazarr`, then verifies the Bazarr API
settings and SQLite language profile through `tests/assertions/bazarr.sh`.

It exists because `fresh-install` deliberately excludes optional profiles. Use
`./tests/run.sh bazarr` as Bazarr's image-drift preflight; `fresh-install` does
not prove Bazarr startup or configurator compatibility.

### `autoheal.sh` — functional self-heal oracle

This focused image-drift preflight starts Autoheal alone, then launches an
isolated disposable container with an intentionally failing healthcheck. It
requires both that fixture to restart and an Autoheal action log naming the
fixture, so starting the sidecar without a heal cannot pass. Run
`./tests/run.sh --no-preload autoheal`; use `MS_TEST_IMAGE_OVERRIDES` with the
candidate digest when preflighting an image update.

### `unpackerr.sh` — completed-download extraction oracle

The focused Unpackerr scenario configures the real qBittorrent/Sonarr/Radarr
closure, then supplies one deterministic completed-torrent Radarr queue record
through a strict local stub. It proves that Unpackerr retains its production
endpoint, generated API key, `/data/torrents` mapping, and data bind mount while
authenticating the queue request and extracting a real ZIP fixture.

Run it as the image-drift preflight, including for a candidate digest:

```bash
./tests/run.sh unpackerr
MS_TEST_IMAGE_OVERRIDES="unpackerr=ghcr.io/hotio/unpackerr:latest" ./tests/run.sh unpackerr
```

The boundary is intentional: the stub replaces only the unavailable completed
queue event. This is not a real qBittorrent transfer or Arr import pipeline.

### `remote-gating.sh` — focused remote-state gate

Starts proxy-profile services with a real `DOMAIN` while flipping `REMOTE_WEB_STATE` through unchecked, skipped, and ready. Unchecked/skipped must keep Jellyfin, Homepage, and NPM LAN-only while NPM's rate-limit step (disabled by default, ADR-35) and fail2ban validation still run. Ready must publish cert-backed Jellyfin/Seerr proxy hosts through the Pebble ACME override.

Remote-state fast checks:

```bash
bash tests/unit/remote-web-state.sh
./tests/run.sh smoke remote-gating npm-heal
```

### Stage 1 wizard units

Stage 1 setup-wizard behavior that does not need Docker is covered by host-side Bash units:

- `stage1-admin-password` — the admin password is never auto-generated: the prompt offers no default (a bare Enter is rejected), is validated (≥12 chars, no single quote — Portainer's floor), and is confirmed by re-entry.
- `stage1-nas-ordering` — Stage 1 NAS install ordering pauses any previous watchdog before stack stop, then enables/restarts it after the initial stack start.
- `setup-late-watchdog` — interrupted Stage 1 reruns pause stale watchdogs before resuming the staged wizard and never fall through to the markerless late stack install path.
- `stack-health` — setup health gate classification for exited services, missing explicit services, and running containers without healthchecks.
- `stack-network` — adaptive Docker subnet selection for default, fallback, split-default VPN, stale completed `.env`, completed-install conflict, and exhausted `172.16.0.0/12` cases.
- `storage` — managed NAS classification, mount identity, and sentinel checks.

```bash
bash tests/unit/stage1-admin-password.sh && bash tests/unit/stage1-nas-ordering.sh && bash tests/unit/setup-late-watchdog.sh && bash tests/unit/stack-network.sh && bash tests/unit/storage.sh
```

### NAS storage scenario

`nas-storage` is a lightweight DinD scenario for the managed NAS mode. It starts
a disposable kernel NFS server inside the privileged DinD VM, exports a tmpfs
share, mounts it through `scripts/setup/storage.sh`, and verifies:

- mount identity and fstype are recorded from the real mount;
- the sentinel is created and visible only through the mounted export;
- MediaStack directory creation lands on the exported storage;
- sentinel and managed directory creation use the installing user for user-writable exports rather than root-writing into the NAS export;
- `storage_guard_before_start` rejects an unmounted local fallback;
- the storage helper can remount and pass the guard again;
- the watchdog starts the known NAS-dependent service set after a pending
  failure marker or a clean boot with all protected services down.

Run it with image preload disabled because it does not need MediaStack service
images:

```bash
./tests/run.sh --no-preload nas-storage
```

This proves the in-VM NFS client/server and guard behavior. It does not prove
NAS-vendor quirks such as Unraid/Synology export rules, root-squash policy, or
long-running stale file handle behavior.

### Reusable live assertions

Some assertions are intentionally runnable outside DinD after a real stack is
up. `tests/assertions/qbittorrent-live.sh` is the qBittorrent live API guard:

```bash
bash tests/assertions/qbittorrent-live.sh
```

It reads `.env` and `config.yml`, authenticates with the shared admin account,
and verifies qBittorrent's live API state. DinD `fresh-install` calls the same
script through `tests/assertions/qbittorrent.sh`; real-host and remote VM tests
can call it over SSH without duplicating qBittorrent probe logic.

### API-matrix layer

The harness (`tests/scenarios/api-matrix.sh`) plus its per-service modules (`tests/api-matrix/`). Many MediaStack services are configured **through their HTTP APIs**, and the api-matrix layer exploits that: once a module's API-bearing services are up, it drives those config APIs **directly** through a *matrix* of states and asserts each one lands live — amortizing a single (expensive) bring-up across many cheap, in-place API tests. **Today the layer ships modules for Sonarr/Radarr** (`quality`, `quality-rename`)**, qBittorrent** (`qbittorrent`: config-driven setup plus the surgical day-2 speed-limit action)**, Jackett** (`jackett`: indexer enable/skip + FlareSolverr-URL/admin-password set-once cycles)**, Jellyfin** (`jellyfin`: library config match/drift/absent branches plus the Sonarr/Radarr notification wiring)**, and Seerr** (`seerr`: Sonarr/Radarr connection wiring) — #164's full scope now ships (see *Adding a module*).

It exists because `configure.sh` is **idempotent and warn-on-drift**: on a re-run it refuses to overwrite a profile/setting that already differs (it logs a drift WARN, never reconciles). That is correct for the installer, but it means the configure.sh-path scenarios (`fresh-install`, `wizard-presets`) can only prove **one** configured state — the default point. The api-matrix layer mutates the live API across states, so it proves the whole **parameter space**. That makes it the natural test surface for:

- **new features** with an API config surface — assert every variation the renderer can emit actually lands;
- **day-2 actions** that re-push settings to a running service (the `mediastack` menu — change quality, adjust bandwidth, toggle indexers, …);
- **retrospectively, existing API-driven features** — backfill matrix coverage for anything currently proven only at its default point.

**How it's built.** `tests/scenarios/api-matrix.sh` is the harness: it brings up only the services a module needs (the quality module needs just Sonarr + Radarr), reads the API keys, then `source`s and calls per-service **modules** from `tests/api-matrix/`. Each module reuses the **product's** renderers + `api_*` helpers (`scripts/lib/arr/render/*.py`, `scripts/lib/common.sh`) — only the API transport and the assertions are test-owned — and computes its *expected* values from the same product composition, so there is no hardcoded expectation to drift.

**test-1 — `quality`** (`tests/api-matrix/quality.sh` + `apply_cell.py`): loops the six `(resolution × size)` cells, applying each **in place** (`PUT` to the same profile id, renaming the profile across cells) and asserting the live profile name, enabled leaf-quality set, cutoff group, and a global size bound — on both Sonarr and Radarr. The matrix proper runs in ~25s after bring-up. This in-place PUT-rename + global-definition repush is exactly the mechanism the day-2 "change quality profile" action (#71) wraps in UX, so the module also de-risks that work.

**test-2 — `quality-rename`** (`tests/api-matrix/quality-rename.sh`): seeds quality cell A, then changes to cell B via `QP_RENAME_FROM`, asserting the profile is renamed **in place** (same id, the new size's custom-format score re-attached, no orphan profile) through the **product** configurators — the exact path the day-2 "change quality profile" action (#71) takes.

**test-3 — `qbittorrent`** (`tests/api-matrix/qbittorrent.sh` + `push_qbt.sh`): applies the product qBittorrent configurator against a live daemon, asserting config-derived preferences, pause-on-ratio, and categories. It then changes limits to 7/3 MB/s through the product day-2 action and proves paths, categories, and ratio policy remain unchanged.

**test-4 — `jackett`** (`tests/api-matrix/jackett.sh` + `push_jackett.sh`): seeds two already-CI-proven public indexers (`eztv`, `yts` — the same ids `wizard-presets.sh` already drives against live trackers) plus one deliberately bogus id, applies the product configurator, and asserts the two real indexers land `configured:true`, the bogus one is skipped with the product's own "not available in Jackett" log line, the FlareSolverr URL and admin password are set once, and a second unchanged `apply` takes every skip path (asserted via the product's own `log_skip` lines, not just unchanged state). Deliberately scoped to the deterministic, local part of `configure_jackett` — live Torznab/Cloudflare reachability stays `wizard-presets.sh`'s job per the FlareSolverr confidence boundary in [`docs/operations/upgrades.md`](../operations/upgrades.md).

**test-5 — `jellyfin`** (`tests/api-matrix/jellyfin.sh` + `push_jellyfin.sh`): drives the first-run wizard with config.yml-derived libraries, then re-applies with one library unchanged, one with a drifted path, and one brand-new — exercising `configure_jellyfin_libraries`' match/drift/absent branches in a single re-apply (the drift case asserts the live path is *not* overwritten, since Jellyfin has no path-rename endpoint and a re-root would lose watch history). It then drives `configure_arr_jellyfin_connection` for both Sonarr and Radarr, asserting the exact wiring (host, port, `updateLibrary`, and each app's documented trigger — `onImportComplete` for Sonarr, `onDownload` for Radarr; `apiKey` itself is a Sonarr/Radarr-masked field and can't be verified via the API) and that a second unchanged run takes the idempotent skip path with the connection object byte-for-byte unchanged. Deliberately scoped to library/notification states; encoding, streaming, networking, and server name stay covered at their default point by `fresh-install`'s `assert_jellyfin_configured`.

**test-6 — `seerr`** (`tests/api-matrix/seerr.sh` + `push_seerr.sh`): drives the real `configure_seerr` first-run bootstrap (against the Jellyfin admin the `jellyfin` module's bring-up already configures) and asserts the exact `connect_arr_to_seerr` wiring for both Sonarr and Radarr — host, port, `useSsl`, `isDefault`, `is4k`, `syncEnabled`, `preventSearch`, root directory, and each app's documented extra (Sonarr's `enableSeasonFolders` + resolved language profile id, Radarr's `minimumAvailability`). The expected quality-profile id/name is resolved against the **live** Sonarr/Radarr profile list (mirroring `connect_arr_to_seerr`'s own match-or-fallback logic), not a static config.yml snapshot, since the `quality`/`quality-rename` modules earlier in the same run rename profiles in place. It then re-runs the connection directly and asserts the idempotent already-connected skip path with the connection object byte-for-byte unchanged. Deliberately scoped to connection wiring; Jellyfin library-sync membership, default permissions/quotas, and trustProxy stay covered at their default point by `fresh-install`'s `assert_seerr_configured`.

```bash
./tests/run.sh api-matrix
```

Like `fresh-install`, this is an **image-backed local/on-demand gate** — not part of the CI battery (which skips image pulls). It brings up only its services, so it is far cheaper than `fresh-install`.

**Scope.** api-matrix is a **parameter-space gate** for a single service's renderer→API contract — *not* a cross-service interop oracle and *not* an image-drift preflight. `fresh-install` owns those: it asserts each service's configured state plus the Sonarr/Radarr↔qBittorrent download-client wiring, and it is the drift-preflight oracle for the Sonarr/Radarr rows in [`docs/operations/upgrades.md`](../operations/upgrades.md). Do not read api-matrix as proof that Jackett/Jellyfin/Seerr's live cross-service handshakes work end-to-end (e.g. Jellyfin actually rescanning a library when Sonarr/Radarr fire the configured notification, or Seerr's request flow actually reaching Sonarr/Radarr) — the `jellyfin`/`seerr` modules only prove the connection objects themselves are wired correctly, not that the round-trips work live.

**Adding a module.** Drop `tests/api-matrix/<service>.sh` defining a `matrix_<service> …` function that drives the service's API through its states and asserts with `pass`/`fail`/`assert_eq`; `source` it and call it from `api-matrix.sh`, bringing up whatever services it needs. Reuse the product's render/config helpers rather than re-implementing request payloads. Each new day-2 action that mutates a service API should ship with a matrix module here.

### Stage 1 wizard UI scenarios

The `wizard-ui-stage1-*` scenarios are lightweight DinD scenarios that drive
real Stage 1 prompts through `tests/lib/wizard_pty.py`. They stub slow or
destructive install operations, then assert both transcript UX and generated
`.env` state.

- `wizard-ui-stage1-local` covers the local-storage path, selected data
  directory, blank NAS fields, and local sentinel default.
- `wizard-ui-stage1-nas-retry` simulates a first NFS mount failure followed by
  "Retry with the same settings", proving the retry menu and managed NAS state.

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

### Setup prerequisite units

Setup prerequisite and test-harness behavior that does not need Docker is covered by host-side Bash units:

- `packages` — Docker prerequisite repair behavior, including Docker Engine present without Compose v2.
- `test-runner` — `tests/run.sh` scenario loading guards, including empty or truncated scenario files.
- `cache` — registry mirror lifecycle flags, including default cleanup and explicit keep behavior.

```bash
bash tests/unit/packages.sh && bash tests/unit/test-runner.sh && bash tests/unit/cache.sh
```

### Stage 2 remote-access units and scenarios

Stage 2 adds host-side unit coverage for the remote-access collection helpers. These run without Docker and are the fastest feedback loop for setup wizard changes:

- `stage2-domain` — DNS/domain classification, Cloudflare proxy detection, and safe publication routing.
- `stage2-dynu` — Dynu IP Update Protocol response mapping for accepted, unchanged, auth, host, abuse, DNS, and retry states.
- `stage2-ports` — local TCP/UDP port classification without overclaiming public WAN reachability.
- `stage2-wireguard` — ADR-29 access-tier env mapping, `detect_lan_cidr`
  normalization, and the Containers-tier port drift guard against
  `docker-compose.yml`.
- `wireguard-service` — wg-easy peer provisioning uses the wizard admin
  username, enables the v15 per-client firewall, applies exact tier
  `firewallIps`, and preserves the documented full-tunnel escape hatch.
- `stage2-flow` — Stage 2 offer/tell-me-more/skip/confirm flow and `.env` state persistence.
- `stage2-le` — Let's Encrypt gate classification and per-failure user-facing copy.
- `stage2-npm-stale` — stale NPM host warning behavior without automatic reconciliation.

The focused remote-access unit command is:

```bash
bash tests/unit/stage2-domain.sh && bash tests/unit/stage2-dynu.sh && bash tests/unit/stage2-ports.sh && bash tests/unit/stage2-wireguard.sh && bash tests/unit/stage2-flow.sh && bash tests/unit/stage2-le.sh && bash tests/unit/stage2-npm-stale.sh && bash tests/unit/remote-web-state.sh
```

Stage 2 also adds WireGuard/remote-access DinD scenarios:

- `stage2-skip` — runs the skipped HTTPS path and proves LAN consumers stay on LAN URLs with no public proxy publication.
- `stage2-ready` — runs the ready path with the safe in-VM/Pebble ACME fixtures and proves ready state is written only after cert/proxy postconditions.
- `wireguard` — starts wg-easy at the Full LAN tier with the `remote` profile, asserts the ADR-17 capability set, then verifies interface creation, API auth, peer creation, UDP listen port, and NAT/MASQUERADE.
- `wireguard-server`, `wireguard-containers`, `wireguard-streaming` — cover the remaining access tiers (ADR-29). Each enables wg-easy's per-client firewall and verifies the tier's `firewallIps` shape persists through the possibly-500-but-persisted mutation path documented in ADR-28.

Stage 2 now distinguishes `REMOTE_WEB_STATE=skipped` (intentional opt-out)
from `REMOTE_WEB_STATE=failed` (HTTPS requested but Let's Encrypt or NPM
postconditions did not complete). Failed state keeps LAN/VPN usable and makes
`./setup.sh --remote` the explicit retry unit; there is no automatic LE retry
inside one setup run.

The focused remote-access DinD gate is:

```bash
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready
```

This DinD gate does not prove real public WAN reachability, real DDNS propagation, or production Let's Encrypt issuance. That proof is covered on the maintainer-private live-host harnesses — an ephemeral cloud VM exercises real public DNS, DDNS pushes, WAN firewalls, and real Let's Encrypt HTTP-01.

### Hardware transcoding/finalization units

Hardware transcoding behavior is covered by host-side Bash units because DinD does not provide real GPU hardware. The focused unit command is:

```bash
bash tests/unit/gpu-branching.sh && bash tests/unit/nvidia-patch.sh && bash tests/unit/wizard-flow.sh && bash tests/unit/stage3-flow.sh && bash tests/unit/stage3-marker.sh && bash tests/unit/reboot.sh && bash tests/unit/stage3-summary.sh && bash tests/unit/setup-resume-routing.sh && bash tests/unit/stage3-transcode.sh && bash tests/unit/stage3-gpu-content.sh
```

These tests cover GPU branch contracts, nvidia-patch pinning and dirty-tree rejection, wizard sequencing, hardware transcoding state publication, Intel QSV-to-VAAPI fallback routing, NVIDIA marker/reboot/finalize routing, post-reboot banner path rendering, final summary labels, accelerator evidence parsing, codec capability probing, and generated override GPU content. Automated proof uses Bash units, command stubs, API fixtures, automatic FFmpeg smoke-test stubs, `vainfo` parser fixtures, captured Jellyfin FFmpeg/transcode log fallback fixtures, and parser fixtures for `qsv`, `vaapi`, and `nvenc`.

Real Intel/AMD/NVIDIA GPU transcode proof requires a real host and must not be claimed by DinD. DinD can prove that MediaStack chooses the right states, APIs, and fallbacks; it cannot prove that a physical GPU performs a live transcode on a user host.

The focused hardware-transcoding DinD regression gate is:

```bash
./tests/run.sh smoke fresh-install stage2-skip stage2-ready
```

### Recovery hook units

Recovery coverage includes the public recovery hooks and existing-install add-stage menu. The focused unit command is:

```bash
bash tests/unit/recovery-routing.sh && bash tests/unit/setup-resume-routing.sh && bash tests/unit/stage2-flow.sh && bash tests/unit/stage3-flow.sh && bash tests/unit/checks.sh
```

These tests cover `./setup.sh --remote` preconditions and route isolation, ready-state remote idempotency, `./setup.sh --transcoding` GPU re-detection and hardware-transcoding delegation, NVIDIA marker resume ordering with boot-ID gating, and preservation of the typed `DESTROY` destructive reinstall gate.

The focused recovery DinD regression gate is:

```bash
./tests/run.sh smoke stage2-skip stage2-ready
```

This gate is not a real public WAN or production Let's Encrypt proof. Real DNS, DDNS provider pushes, WAN firewall behavior, and production ACME issuance are covered on the maintainer-private live-host harnesses. Real physical Intel/AMD/NVIDIA GPU transcode proof requires a real host because DinD cannot provide a user host GPU.

### Focused staged-setup scenarios

These named scenarios let maintainers test the staged setup and recovery paths without always running the full `fresh-install` battery:

| Scenario | Requirement | Proves | Does not prove |
|----------|-------------|--------|----------------|
| `stage1-lan` | TEST-01 | Stage 1 LAN-only install with blank `DOMAIN`, non-ready remote state, Jellyfin LAN health, no public proxy, and no GPU runtime. | Public DNS, remote HTTPS, or hardware transcoding. |
| `stage2-ready` | TEST-02 | Fixture DNS/Pebble Stage 2 ready path: cert-backed NPM hosts, cert material on disk, and `REMOTE_WEB_STATE=ready` only after postconditions. | Real WAN, real DDNS propagation, or production Let's Encrypt. |
| `stage2-skip` | TEST-03 | Port-gate skip path keeps `REMOTE_WEB_STATE=skipped`, LAN Homepage URLs, and no ready-only Jellyfin proxy config. | Later public recovery. |
| `remote-after-skip` | TEST-04 | Public `./setup.sh --remote` re-entry from skipped state reaches ready state using DinD fixture DNS/Pebble. | Public WAN or real provider behavior. |
| `remote-ready-idempotent` | TEST-05 | Public `./setup.sh --remote` after ready state is idempotent and preserves proxy/cert postconditions. | Real WAN or production cert renewal. |
| `demo-lan` | TEST-06 | Current `DEMO=1` contract is Stage-1/LAN-safe: no remote-ready publication, pre-seeded values preserved. | Full unattended Stage 2 or hardware transcoding setup. |
| `existing-install-nuke` | TEST-07 | Existing-install wipe path requires menu selection plus exact `DESTROY`, uses the all-profile compose down path for proxy/remote/subtitles/autoheal services, regenerates `.env`, and preserves the data bind mount. | Host-level destructive recovery outside DinD. |
| `fail2ban-drift` | TEST-09 | Focused filter drift check for Jellyfin, Seerr, NPM, and NPM rate-limit filters. | Full fail2ban ban pipeline; that remains in `fresh-install`. |

Focused staged-setup DinD gate:

```bash
./tests/run.sh smoke stage1-lan stage2-skip stage2-ready remote-after-skip remote-ready-idempotent demo-lan existing-install-nuke fail2ban-drift
```

TEST-08 is intentionally separate: real public DNS, DDNS pushes, WAN firewall behavior, and real Let's Encrypt HTTP-01 are proven on the maintainer-private live-host harnesses, not in this public repo.

## Two-tier image cache

Without caching, each DinD run pulls all 12 service images fresh — ~3 GB, 12 anonymous Docker Hub pulls. Hub's 100/6h cap is reached after ~8 runs. Two cooperating mechanisms (`tests/lib/cache.sh`):

### Tier 1 — Pull-through registry mirror

Container: `ms-registry-mirror` (function `cache_mirror_up` in `tests/lib/cache.sh`). Image: `ghcr.io/distribution/distribution:3.0.0` — **sourced from GHCR, not Docker Hub**, because bootstrapping a mirror *from* the rate-limited registry it's meant to bypass is impossible.

Lifecycle:

- `cache_mirror_up` — start the container if not already running. Binds on the Docker bridge gateway IP (default `172.17.0.1`, detected via `docker network inspect bridge`) so DinD's nested containers can reach it. Mounts `ms-registry-cache` volume at `/var/lib/registry` for persistence.
- `cache_mirror_down` — used by `tests/run.sh` on normal exit to stop the MediaStack mirror used by the run, **keeping the volume**. Set `MS_CACHE_MIRROR_KEEP=1` to leave it running between runs.
- `cache_mirror_stop` — manual `docker rm -f` cleanup for an existing mirror while preserving the volume.
- `cache_mirror_purge` — nuke container and volume to reclaim disk.
- `--restart no` policy — the mirror is transitory dev infrastructure, not always-on. Started on demand by `run.sh`, torn down on normal exit. `--keep`/`KEEP_ALWAYS=1` intentionally keeps both DinD and the mirror for debugging; `MS_CACHE_MIRROR_KEEP=1` keeps only the mirror on normal exits.

DinD points at it via `--registry-mirror=http://host.docker.internal:5000` (set in `dind_up`). First pull of any image hits Hub once and caches; subsequent DinD runs are network-free.

### Tier 2 — Host sideload

`cache_preload_into_dind` — after DinD boots, scan the pinned image tags in `docker-compose.yml` (via Python YAML parse), and for every image already on the host run `docker save | docker exec -i ms-test-dind docker load`. Zero network, works offline.

If MediaStack is in production on the same box, every image is already there and the first test run costs essentially nothing.

### Disabling

`MS_TEST_NO_CACHE=1` or `--no-cache` bypasses both — forces Hub pulls. Used to verify that a cold-cache install still works.

## Disk-space hazard

`tests/Dockerfile.dind` declares `/var/lib/docker` as a `VOLUME` for the nested daemon (same pattern as upstream `docker:dind`). Every `dind_up` creates an anonymous volume; every `dind_down` uses `docker rm -fv` to clean it up.

But: **if the runner is killed mid-run** (Ctrl+C during a long pull, OOM, disk-full), the container may be removed without its volume. The volume becomes dangling and does *not* show up in `docker ps -a`.

Documented occurrence: one developer session accumulated **133 GB across 68 dangling DinD volumes** over five test runs before noticing a full disk.

Recovery:

```bash
docker system df
docker volume ls --filter dangling=true
docker volume prune -f   # Safe: production named volumes are untouched
```

Always prune between batches of test runs, especially with `--keep` or interrupted runs.

## Debugging with `--keep` and `KEEP_ALWAYS`

`./tests/run.sh --keep fresh-install`. On failure, DinD is left running:

```bash
docker exec -it ms-test-dind sh                              # shell inside DinD
docker exec -w /root/MediaStack -it ms-test-dind sh          # CWD at repo root
docker exec -w /root/MediaStack ms-test-dind \
    docker compose logs sonarr | tail -50                    # service logs
docker rm -fv ms-test-dind                                   # tear down — -v is critical
```

`KEEP_ALWAYS=1 ./tests/run.sh fresh-install` keeps DinD running regardless of outcome (pass or fail). Useful when you want to inspect a passing stack or do live browser testing.

The host-side `/tmp/configure.out` captures the full `configure.sh` log from the last `fresh-install` run.

### Live browser access via socat

DinD services listen on the container's internal IP, which isn't reachable from a browser on another machine. Use `socat` to forward ports from the host to the DinD container. Since the host may already be running the production MediaStack on the standard ports, use a +10000 offset to avoid collisions:

```bash
DIND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ms-test-dind)

for port in 8096 8989 7878 9117 8080 5055 3000 3001 9000 81 8090; do
    host_port=$((port + 10000))
    socat TCP-LISTEN:${host_port},fork,reuseaddr TCP:${DIND_IP}:${port} &
done
```

Then access services at `http://<host-ip>:<port+10000>`:

| Service | Port | URL |
|---|---|---|
| Homepage | 13000 | `http://<host-ip>:13000` |
| Uptime Kuma | 13001 | `http://<host-ip>:13001` |
| Jellyfin | 18096 | `http://<host-ip>:18096` |
| Sonarr | 18989 | `http://<host-ip>:18989` |
| Radarr | 17878 | `http://<host-ip>:17878` |
| Seerr | 15055 | `http://<host-ip>:15055` |
| qBittorrent | 18080 | `http://<host-ip>:18080` |
| Jackett | 19117 | `http://<host-ip>:19117` |
| Portainer | 19000 | `http://<host-ip>:19000` |
| NPM | 10081 | `http://<host-ip>:10081` |
| Beszel | 18090 | `http://<host-ip>:18090` |

Credentials are in the DinD's `.env` — all services share the same admin password (`JELLYFIN_ADMIN_PASSWORD`). NPM and Beszel use `NPM_ADMIN_EMAIL` as the username; everything else uses `JELLYFIN_ADMIN_USER` (default `admin`).

Clean up socat forwarders when done:

```bash
pkill -f 'socat.*TCP:.*fork'
docker rm -fv ms-test-dind
```

## Observations / open questions

- **Core scenarios** include `smoke`, `fresh-install`, `remote-gating`, `npm-heal`, `ddns-seed`, `wireguard`, `wireguard-server`, `wireguard-containers`, `wireguard-streaming`, `stage2-skip`, `stage2-ready`, and `wizard-presets`. `update.sh` has host-side option/default coverage in `tests/unit/update.sh`. `nvidia-repatch.sh` has shared-helper coverage through `tests/unit/nvidia-patch.sh`, but no real NVIDIA hardware execution in DinD. `--full` path (Docker install, GPU driver install, reboot + resume) has no test coverage in DinD; real public DNS, real DDNS pushes, and real Let's Encrypt remain covered on the maintainer-private live-host harnesses.
- **~~No test for configure.sh re-run after config.yml edit.~~** Fixed: the drift-regression block in `fresh-install.sh` (phase 6) mutates three `config.yml` values (`quality_profile.cutoff_id`, `sonarr.download_client_category`, `jellyfin.libraries[0].path`), re-runs `configure.sh`, and asserts the 3 expected `[WARN]` lines fire with no false positives.
- **~~Seerr library-sync polling termination is untested.~~** Fixed: `assert_seerr_configured` now verifies that Movies and TV Shows are both present and enabled in the Jellyfin settings endpoint, catching silent poll-timeout failures.
- **~~Value-level assertions are minimal.~~** Partially fixed: custom format scores are now verified against exact config.yml values (all 7 formats with expected scores) for both Sonarr and Radarr. Quality IDs (`sonarr_qualities`/`radarr_qualities`) are still count-checked only.
- **~~1337x dependency is flaky.~~** Fixed: replaced the `api.1337x.to` NXDOMAIN probe with Torznab caps requests through Jackett for configured indexers, which proves indexers are configured and servable without depending on direct upstream probes.
- **Cache mirror binds on Docker bridge gateway, not localhost.** Necessary so DinD's children can reach it, but accessible from any container on that bridge. No auth. On a shared dev host, another container could poison the cache. Mitigated by the transitory lifecycle but worth noting.
- **GHCR is single point of failure for the cache bootstrap.** If `ghcr.io/distribution/distribution:3.0.0` becomes unavailable, the mirror can't start and tests fall back to direct Hub pulls. A second fallback source (or pinning by digest) would harden this.
- **No per-scenario isolation of counter state.** A scenario that silently bypasses a `fail` (e.g. `return 1` without calling `fail` first) leaves the counter confused. The pass/fail counts are persisted across scenarios by design but it's worth checking that every exit path records a result.
- **~~api-matrix `fail "...";return`/`continue` cascades silently dropped downstream assertions (no skip accounting).~~** Fixed (#179): this is the *within-module* version of the bullet above — a precondition miss partway through a stateful module (e.g. an unreadable API after a failed apply) used to fall straight through to `return`/`continue` with no skip accounting, so a run could report "0 skipped" while dozens of assertions never ran. Every `fail "...";return`/`continue` site across `tests/api-matrix/*.sh` now pairs with one `skip()` call naming the dropped block (not one per dropped assertion — see the convention comment in `tests/scenarios/api-matrix.sh`).
