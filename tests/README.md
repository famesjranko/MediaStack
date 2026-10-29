# MediaStack E2E Test Framework

End-to-end tests that run inside a Docker-in-Docker container so your host stays clean after normal runs — no apt-installs, no stray containers, no lingering port bindings. The host-side image cache volume persists by design unless explicitly purged.

DinD is a **Debian-based** image (`ms-dind:debian`, built from `tests/Dockerfile.dind`), matching the production distro. First `./tests/run.sh` invocation builds it (~40s); subsequent runs use the docker layer cache.

> **Three complementary surfaces.** DinD runs everything that happens inside the VM. The operator-run [`gcp-vm/`](gcp-vm/) harness proves real public DNS, DDNS, Let's Encrypt HTTP-01, HTTPS, and WAN firewall behavior on a disposable cloud VM. The [`lan-host/`](lan-host/) harness proves real Debian hardware, UFW/systemd, and GPU passthrough on a dedicated test box. Credentials and target values stay in gitignored local env files; neither live-host harness runs in CI.

GitHub Actions runs a deliberately small PR gate: committed-secret checks, shell/Python
syntax checks, compose rendering, focused host unit tests, and the `wizard-ui-*` PTY
scenarios in DinD with service image preload skipped. The full image-backed DinD battery
(`fresh-install`, `smoke`, remote-access scenarios, and service startup checks) stays a
local/on-demand gate. The hosted image preflight also runs required scenarios on
disposable hosted VMs and refreshes a digest PR for maintainer review. It runs
weekly, one hour after the lightweight image-drift alert, and by manual dispatch.
`tests/unit/hosted-preflight-schedule.sh` proves which jobs each trigger runs. See
[hosted image preflight](../docs/operations/hosted-image-preflight.md). Stable-channel installs
use the accepted digest record through the generated compose override; Latest-channel
installs intentionally follow upstream tags.

## What reaches DinD

`dind_copy_repo` (`tests/lib/dind.sh`) exports the pristine source tree: every tracked file plus every untracked file git does not ignore, from `git ls-files --cached --others --exclude-standard`. Uncommitted edits and new scenario files travel; the gitignored runtime state of a live install or an earlier run on the host (`.env`, `config.yml`, `docker-compose.override.yml`, the `config/<service>/` databases, completion markers, receipts, override records) never does, so a "fresh" scenario cannot inherit a completed setup. The tracked templates under `config/examples/` do reach DinD, and scenarios seed the live copies from them (`create_config_dirs_in_dind`). A non-git directory or an empty population is refused. `tests/unit/dind.sh` proves the exclusion set.

## Prerequisites

- Docker on the host (Compose v2 not required inside DinD; it's pre-baked in the image).
- `uv` on the host (runs the pinned Ruff and mypy versions without a project virtualenv).
- Free disk: ~6 GB for `fresh-install` (image pulls inside DinD) + ~500 MB for the DinD image itself.
- Network: first run downloads base images (debian:bookworm-slim + Docker CE apt repo); subsequent runs can go fully offline if the host already has the MediaStack images (see image cache below).

## Live-host acceptance harnesses

These are explicit operator actions, not automated gates. Read the co-located
README before using either one, review the ignored env file, and never target a
production host.

```bash
# Safe structural/config checks: no cloud, SSH, rsync, or destructive action.
bash tests/gcp-vm/run-fresh.sh --preflight
bash tests/lan-host/run-fresh.sh --preflight

# Live runs only after reviewing target, credentials, cost, and cleanup.
bash tests/gcp-vm/run-fresh.sh
bash tests/lan-host/run-fresh.sh --yes
```

The GCP runner deletes and recreates one VM. It requires
`GCP_EXPECT_TARGET=PROJECT_ID/ZONE/INSTANCE`, passes the project explicitly to
every `gcloud` command, and incurs charges until the VM is deleted. The LAN
runner can remove containers, volumes, generated configuration, drivers, and
optionally `/data` on its SSH target. Interactive wipes require retyping the
target hostname; `--yes` is refused unless `TARGET_HOST == LANHOST_EXPECT`.
See [`gcp-vm/README.md`](gcp-vm/README.md) and
[`lan-host/README.md`](lan-host/README.md) for prerequisites and cleanup.

## Running

```bash
./tests/run.sh                       # default: smoke
./tests/run.sh smoke                 # ~90s cold
./tests/run.sh fresh-install         # ~15-18 min (images cached) / ~25 min (cold)
./tests/run.sh smoke fresh-install   # both, in order
./tests/run.sh remote-gating         # REMOTE_WEB_STATE publication gates
./tests/run.sh --no-preload nas-storage  # managed NAS/NFS fixture (~4s)
./tests/run.sh --no-preload nas-watchdog-intent  # user stop kept across reboot and outage (~1 min)
./tests/run.sh --no-preload wizard-ui-stage1-local wizard-ui-stage1-nas-retry  # core PTY wizard UX checks
./tests/run.sh smoke remote-gating npm-heal  # focused remote-state gate
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready  # focused remote-access gate
./tests/run.sh --keep fresh-install  # leave DinD running on failure for debugging
./tests/run.sh --no-preload <scenario>  # skip host image sideload for lightweight scenarios
```

Exit code is non-zero if any hard assertion failed. `[SKIP]` lines do not fail
the scenario exit, but withhold all image receipts for that scenario. Hosted
acceptance also rejects skips, empty results and missing required scenarios.

## Exploring the UI safely — `--dry-run`

`./mediastack --dry-run` and `./setup.sh --dry-run` walk the **real** setup wizard
and day-2 launcher — every menu, prompt, branch, and banner — as a **genuine
no-op**: any action that would change the system instead prints `DRY-RUN: would …`
and does nothing. Use it to find/verify wizard + launcher UX warts in minutes
instead of a slow DinD scenario or a destructive install.

```bash
./mediastack --dry-run          # explore the day-2 launcher menus
./setup.sh   --dry-run          # explore the wizard (Stage 1 → 2 → 3)
./setup.sh   --dry-run --remote # explore the remote-access recovery flow
```

It is **container-isolated** for safety: the flow runs inside a throwaway,
non-privileged, `--network none` container as a non-root user, with the repo
**copied in** (never bind-mounted read-write). So even a missed stub cannot touch
the host, reach the network, or start a service — the dev host stays untouched.
(`--ui-preview` is an alias. Docker is required; the slim image builds once.)

Distinct from `./setup.sh --demo` (`UI_DEMO=1`), which short-circuits every prompt
to showcase the UI **components**. `--dry-run` runs the real **branching flow**.

**Explore any pathway** with the simulate-as knobs (the wizard auto-detects
hardware/state, so these pick which branch you walk; each defaults sensibly):

```bash
MS_DRYRUN_GPU=intel   ./setup.sh --dry-run   # nvidia | intel | amd | none → Stage 3 branch
MS_DRYRUN_INSTALLED=0 ./mediastack --dry-run # 0=fresh (pre-install menu), 1=installed (default)
```

Scripted transcript (the same flow the unit test drives, under a PTY so the
non-TTY validated-input prompts don't hang):

```bash
printf '%s\n' '[{"expect":"What would you like to do"},{"send":"12\n"}]' > /tmp/steps.json  # 12 = Quit (non-NAS/no-GUM post-install menu)
python3 tests/lib/wizard_pty.py --command './mediastack --dry-run' --steps /tmp/steps.json \
    --cwd "$PWD" --raw-log /tmp/raw.log --plain-log /tmp/plain.log --expect-exit 0
```

The driver + fidelity stubs live in `scripts/lib/dry-run.sh`; `tests/unit/dry-run.sh`
asserts the safety invariants (no bind mount, `--network none`, non-root,
recursion guard) and walks the launcher when Docker is available.

## Linting

`./tests/lint.sh` is the shell lint runner (shellcheck). Config and the curated
false-positive suppressions live in `.shellcheckrc` (repo root), so the runner
needs no special flags — and neither do you.

```bash
./tests/lint.sh                          # lint every tracked *.sh + mediastack (--severity=info, matches CI)
./tests/lint.sh scripts/lib/validators.sh  # lint only the named file(s)
./tests/lint.sh --severity=error         # stricter: only fail on errors
```

It prefers a native `shellcheck` at the pinned version, then the sha256-verified
cached pin (`./tests/lint.sh install`, fetched per `tools.toml [shellcheck]`), and
falls back to the pinned `koalaman/shellcheck:v0.11.0` docker image — the analysing
engine is identical on every rung.
The default severity is `--severity=info` — the same gate CI's
`lint-shellcheck` job uses via `./tests/check.sh lint`.
A bare `./tests/lint.sh` therefore gives the same pass/fail result as CI; no flag needed.

Repo-wide suppressions live in `.shellcheckrc`, with a reason beside each one.
Keep shared architectural suppressions there instead of scattering inline
directives through individual files.

### Bounded analysis

The full sweep can take several minutes (about 160 seconds in the report for
[#141](https://github.com/famesjranko/MediaStack/issues/141)). Allow more than
two minutes when you run `lint`, `fast`, or the default tier. Before each file,
the runner prints `lint: [current/total] path` to stderr, including when output
is redirected or there are no findings. For quick feedback, pass the changed
files to `tests/lint.sh` as shown above.

The runner starts a separate ShellCheck process for each tracked shell file,
so the previous root's analysis heap is released before the next file starts.
Findings do not skip later files; an engine or invocation error stops the run
with its original exit status. The same loop serves the native, cached and
Docker engines. The Docker fallback starts one container per file because the
pinned image contains ShellCheck but no command shell for a process loop.
Install the cached pin (`./tests/lint.sh install`) to avoid that startup cost.

Source following remains enabled for modules. `mediastack` and `setup.sh`
disable it locally because expanding either dispatcher's whole-project tree
is expensive, including when a test sources that dispatcher. Their modules
still receive their own analysis through tracked-file discovery. Analysis
across a dispatcher and its imports is therefore limited; module checks and
runtime tests cover those boundaries.

Info severity and extended dataflow analysis remain enabled. Do not disable
extended analysis in the shared configuration or CI to reduce memory use.

## Shell formatting

`./tests/format.sh` is the shell formatter gate (shfmt, pinned in `tools.toml`
`[shfmt]`). It is a gate, not advice: `check` exits 1 on any difference and is
what `./tests/check.sh shfmt` and the `format-shfmt` CI job run.

```bash
./tests/format.sh check                  # diff mode over every tracked shell file
./tests/format.sh check scripts/lib/ui.sh  # only the named file(s)
./tests/format.sh write                  # rewrite in place
```

Discovery is `git ls-files '*.sh' 'mediastack'` — the same definition of "what
is shell here" that `tests/lint.sh` and the unit tier use, rather than shfmt's
own directory walk, which would also read a live install's generated config. It
fails closed on an empty population, re-verifies the cached binary's sha256
against `tools.toml` on every run (re-fetching on a mismatch), and refuses to
run at all if an `.editorconfig` appears, because shfmt would silently prefer it
over every pinned flag.

## Python linting and formatting

`ruff` (pinned in `tools.toml` `[ruff]`, configured in `pyproject.toml`) runs as
`./tests/check.sh ruff` and the `lint-ruff` CI job: lint first, then format
check, over the same non-empty `git ls-files '*.py'` population. Both halves
are blocking.

## Python type checking

`./tests/unit.sh` runs mypy (pinned version + stub, recorded in `tools.toml`
`[mypy]`) with
`check_untyped_defs` and `disallow_untyped_defs` over every tracked `*.py`,
configured in `pyproject.toml` `[tool.mypy]`. The standalone selector rejects an
empty population or a missing/false strict setting and passes the Python 3.9
floor explicitly. The executable shell runners repeat those versions; keep
their invocations aligned when changing a pin.

The gate is mypy exiting 0 — every finding was fixed rather than shipping a
suppression baseline, so there is nothing to compare against and nothing to
keep shrinking.

> **Deferred, not enforced:** Python structural checks (cyclomatic complexity,
> duplication) and Bash function/complexity limits are not gated anywhere in
> this repo. mypy and ruff catch type and style issues; nothing here catches a
> function that has grown too large or too tangled. This is a named limitation,
> deliberately left out of scope, not a gap to route around with an inline
> suppression.

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
7. New credentials authenticate; NPM's stock `changeme` admin login is never active.
8. Second `POST /api/users` is rejected → `configure.sh`'s re-run path falls through to the rotation/idempotency branch.

### `fresh-install` — ~15-18 min warm / ~25 min cold

Full default-profile stack: `docker compose up -d`, wait for health, `configure.sh`, per-step evidence assertions, `.env` back-population check.

Proves:
- All 12 default-profile services come up healthy/running.
- `configure.sh` exits 0 (does not abort mid-run on a recoverable API error).
- Each of the 8 configure steps produced the expected side-effect (API key present, root folder registered, etc.).
- qBittorrent's live API accepts the shared admin credentials and reports configured preferences/categories through `tests/assertions/qbittorrent-live.sh`.
- A deterministic Torznab indexer is seeded before the stack starts (`torznab_fixture_seed`, `tests/fixtures/torznab/`): a custom Jackett definition `mstest` plus a static tracker site (`torznab-fixture`, `python:3.12-alpine` on the stack network) that serves four fixed releases. `config.yml` in DinD names that indexer, so `configure.sh` enables it in Jackett and registers it into Sonarr and Radarr exactly as it would a public tracker — with no public tracker, Cloudflare or FlareSolverr solve involved.
- Sonarr + Radarr indexer wiring is checked against the `config.yml` inside DinD (the scenario's own fixture, read fail-closed by `tests/assertions/arr-indexers.sh`): a fixture that cannot be read, a failed `GET /indexer` or a malformed response is a FAIL, an empty fixture is an explicit SKIP, and with indexers present the registered count must reach the fixture floor, every registered indexer must pass the app's own `POST /indexer/test` connection test (a real search through Jackett to the fixture site), and every indexer must carry MediaStack's seed criteria. `wizard-presets.sh` still seeds the opt-in public-indexer preset against real Cloudflare-protected trackers; that is a preset test, not a deterministic image-drift oracle for FlareSolverr — see `docs/operations/upgrades.md` "FlareSolverr — confidence boundary".
- Jackett: the fixture indexer list is read from the DinD `config.yml` the same way, and every configured indexer must serve Torznab caps with at least one category (what Sonarr and Radarr consume on registration).
- Jackett re-run after a dropped FlareSolverr URL: the scenario clears `FlareSolverrUrl` and runs `configure.sh --only jackett` again. The configurator must restore the URL through the server-config API, authenticate again with the admin password after the restart that the save causes, and find every fixture indexer already configured, with no "not available in Jackett" warning. The contract gate traces this run, so it sees the server-config calls on the candidate.
- Seerr with a changed movie quota in `config.yml`: a traced re-run of `configure.sh --only seerr` must write the quota through `settings/main` and read it back. A fresh install skips that write, so without this step the contract gate cannot see it. `config.yml` is then restored on every path, and a second traced re-run must write the restored quotas back to Seerr.
- Product probes that a real install makes on whatever image runs: the Stage 1 Jellyfin gate (`_stage1_jellyfin_probe`) must authenticate on `/Users` with the saved API key, and without a key must reach `/health` and refuse the marker; the post-Revert login check (`_service_login_check`) must succeed for Sonarr and Radarr. The scenario sources the real modules in DinD with tracing on, so the contract gate sees these calls on the candidate.
- Seerr: each Sonarr/Radarr entry must name the intended container, port, root folder and configured quality profile, carry the app's real API key, and pass Seerr's own `POST /settings/<app>/test` connection test with those stored values (the answer must offer that profile and root folder). An entry that merely exists never passes.
- No public-network dependency: `NPM_LE_SERVER` names the in-VM Pebble endpoint, so the NPM configurator skips its public-IP fetch and DNS-propagation wait.
- Quality definitions were tightened from upstream defaults (HDTV-720p preferredSize on Sonarr, Bluray-1080p preferredSize on Radarr — both differ noticeably from stock; no Remux-1080p ships at all — see [quality bounds](../docs/setup/quality-bounds.md)).
- `SONARR_API_KEY`, `RADARR_API_KEY`, `JELLYFIN_API_KEY`, and ready-state `REMOTE_WEB_STATE` are back-populated into `.env`.

Total: 54 hard assertions at current scope.

If you add new assertions that detect a known `configure.sh` bug, use `skip` with a bug-ref so the scenario still runs. Convert back to `pass`/`fail` once the bug is fixed.

The per-service part of that block is `fresh_install_assert_services` in
`tests/scenarios/fresh-install.sh`. `install-e2e` calls it in `lan` mode, where the
ready-state HTTPS checks become the LAN-state checks from
`tests/assertions/remote-gating.sh`. `install-e2e` also runs the Jellyfin
encoding and drift checks. It omits the NPM, fail2ban, rate-limit and port checks,
because a LAN-only install starts no NPM or fail2ban. It replaces the install-digest
check with a check of the installer's own record, and the Uptime Kuma re-run check
with the same check on its user-run `configure.sh`.

### `install-e2e` — real installer and Manage updates menu

```bash
./tests/run.sh install-e2e   # ~15 min warm / 25+ min cold
```

Nothing in the product is stubbed. A non-root user with sudo runs
`DEMO=1 ./setup.sh --full`, which installs base packages, generates the Stable
override, and pulls, starts and configures the LAN stack. The scenario then:

1. checks that every default-profile and autoheal-profile service is healthy, runs
   its Stable lock image and has a recorded install digest, and that no proxy,
   remote or subtitles service started;
2. runs the installer again through `tests/lib/wizard_pty.py` (**Use existing
   install**, **Continue without changes**) and requires unchanged containers
   (ID and start time), `.env`, `config.yml`, override and install record, and
   unchanged user state (`tests/fixtures/upgrade_state.py`). This branch runs no
   configurator;
3. runs `./scripts/configure.sh` as the user and requires a drift warning for the
   deliberately changed Sonarr profile, that change still in place, no new Uptime
   Kuma monitors, unchanged user state, and a clean summary;
4. opens `./mediastack` → **Manage updates** in a pseudo-terminal, checks each
   data-owning service's status, and moves each one that has a different
   candidate through **Update a service**, **Revert a service to its installed
   image** and **Update a service** again. After each move it also requires Torznab
   categories from Jackett through the stored API key;
5. runs the `fresh-install` service checks in `lan` mode on the final stack, then
   the Jellyfin encoding and drift checks.

The PTY steps choose menu items by label (`"choose"` steps), because item numbers
change with install state. Jellyfin, Sonarr, Radarr, Jackett, qBittorrent and Seerr
install on their accepted digest and reach their candidate through the menu. Every
other candidate is pulled by the installer. DinD has no systemd host, so the admin-port
filter, UFW and kernel hardening are off. GPU, NAS, remote access and host
hardening stay out of scope. See
[image compatibility evidence](../docs/operations/image-compatibility.md#real-installer-and-day-2-menu-install-e2e).

### `bazarr` — subtitles-profile oracle

Starts the `subtitles` profile target (`docker compose --profile subtitles up -d bazarr`)
with Bazarr's Sonarr/Radarr dependency chain, runs `configure.sh --only bazarr`,
then verifies the Bazarr API settings and SQLite language profile through
`tests/assertions/bazarr.sh`.

This is the image-drift preflight for Bazarr. `fresh-install` still excludes the
subtitles profile, so it does not prove Bazarr startup or configurator
compatibility.

### `autoheal` — functional self-heal oracle

Starts Autoheal alone and a disposable container with an intentional failing
healthcheck. The oracle requires both a restart of that exact fixture and an
Autoheal action log that names it, so a healthy sidecar or a heal of another
container cannot pass. Run it as `./tests/run.sh --no-preload autoheal`, adding
an exact `MS_TEST_IMAGE_OVERRIDES` digest when preflighting Autoheal.

### `unpackerr` — completed-download extraction oracle

`./tests/run.sh unpackerr` configures qBittorrent, Sonarr, and Radarr, then
replaces only Radarr's completed-download queue event with a strict local stub.
It verifies the generated API-key request, configured `/data/torrents` path,
and extraction of a real ZIP archive by the Compose Unpackerr container.

Use a candidate image override when preflighting a new Unpackerr digest:

```bash
MS_TEST_IMAGE_OVERRIDES="unpackerr=ghcr.io/hotio/unpackerr:latest" ./tests/run.sh unpackerr
```

It does not prove an end-to-end qBittorrent transfer or Arr import; those
systems are configured and asserted before the deterministic queue event is
substituted.

### `remote-gating` — remote publication gates

Starts proxy-profile services with a real `DOMAIN` while `REMOTE_WEB_STATE` is unchecked or skipped, then switches to ready for the Pebble-backed HTTPS path.

Proves:
1. `DOMAIN` still starts proxy infrastructure before remote web is ready.
2. Unchecked/skipped state creates no public NPM proxy hosts.
3. Jellyfin omits the managed NPM `KnownProxies` entry and external HTTPS URLs until ready.
4. Homepage uses LAN hrefs until ready.
5. NPM's rate-limit step (disabled by default) and fail2ban validation still run outside the ready gate.
6. Ready state preserves cert-backed Jellyfin/Seerr proxy publication with the Pebble ACME override.

### Stage 2 remote-access scenarios

Stage 2 adds WireGuard/remote-access DinD scenarios:

- `stage2-skip` proves the user can skip HTTPS setup, `REMOTE_WEB_STATE=skipped` is persisted, LAN URLs remain in Jellyfin/Homepage, and public NPM proxy hosts are not published.
- `stage2-ready` proves the ready path with safe in-VM/Pebble ACME fixtures: NPM renders cert-backed hosts, Jellyfin HTTPS responds, and `REMOTE_WEB_STATE=ready` is written only after proxy/cert postconditions.
- `wireguard` starts wg-easy v15 at the Full LAN tier with the `remote` profile, asserts the major-`15` image pin (digest-locked under stable) and bridge-network `.11` placement plus the capability set, and verifies interface creation, Basic Auth on `/api/client`, peer creation via the v15 API, `wg-easy.db` persistence, NAT/MASQUERADE, and custom `WG_PORT` propagation end-to-end (compose binding, container listen-port, `wg0.conf`).
- `wireguard-server`, `wireguard-containers`, `wireguard-streaming` cover the Server / Containers / Streaming access tiers. Each enables wg-easy's per-client firewall and verifies the tier's `firewallIps` shape persists through wg-easy's possibly-500-but-persisted mutation path (classified on read-back, never on HTTP status). Server tier asserts the bare `/32` shape, Containers asserts the MediaStack port enumeration (51821 excluded), Streaming asserts the Jellyfin-only shape. The `streaming-requests` (Jellyfin + Seerr) shape is unit-covered in `tests/unit/stage2-wireguard.sh`; multi-entry persistence is already proven here by `wireguard-containers`.
- Stage 2 distinguishes failed HTTPS attempts from intentional skips with `REMOTE_WEB_STATE=failed`; a failed LE gate keeps LAN/VPN usable and is retried by rerunning `./setup.sh --remote`, never by an automatic in-process retry.

Run the focused remote-access DinD gate with:

```bash
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready
```

This gate is intentionally not a real public WAN proof. Real public DNS, DDNS provider pushes, firewall behavior, and real Let's Encrypt HTTP-01 are covered by the operator-run `tests/gcp-vm/` harness.

### `service-start-staged` — Start a service applies a staged update

Runs the real launcher functions against a throwaway two-service Compose project in
DinD. It proves that an update staged for a stopped service leaves it stopped, and that
**Start a service** then runs the new image (image ID changes) or the new config. It
also covers the failed storage guard, an optional-profile service, a stopped dependency
that must start with the selected service, and a failed
recreate that must not report success. It needs `python:3.12-alpine` on the host.

```bash
./tests/run.sh --no-preload service-start-staged
```

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

### `nas-watchdog-intent` — user stops across reboot and outage

Reuses the `nas-storage` fixture helpers and runs six alpine stand-ins named
like the NAS data services, started from the override MediaStack generates for
a NAS install (`restart: "no"`), plus a `probe` container with the default
`unless-stopped`. The seerr stand-in depends on the jellyfin stand-in. A host
reboot is `docker restart` of the DinD container.
The scenario stops jellyfin the way the launcher does, reboots, and checks
that Docker restores only the probe, that the watchdog then starts every data
service but jellyfin, that seerr starts without it, that jellyfin stays stopped
and the intent entry survives later polls, that an outage stops and restores the same
set, and that Start a service lets the next reboot bring jellyfin back. Where the kernel
cannot run an NFS server in DinD, it uses a tmpfs mount with the same mount
identity and sentinel gate (a skip line says so). Unit coverage:
`bash tests/unit/watchdog-intent.sh`.

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

### `api-matrix` — direct-API matrix layer

```bash
./tests/run.sh api-matrix
```

Many services are configured through their HTTP APIs, so they can get a
dedicated layer: `tests/scenarios/api-matrix.sh` brings up only the services a
module needs, then drives those config APIs **directly** through a matrix of
states, asserting each lands live — one bring-up, many cheap in-place API tests.
Unlike `configure.sh` (idempotent, warn-on-drift, proves only the default
point), it covers the full parameter space, so it's the surface for new
API-driven features, day-2 re-push actions, and backfilling existing ones.
Modules live in `tests/api-matrix/<service>.sh` and reuse the product renderers
and `api_*` helpers. **Today Sonarr/Radarr, qBittorrent, Jackett, Jellyfin, and
Seerr modules exist**: `quality` loops the six
resolution×size cells in place, `quality-rename` exercises the day-2
change-quality rename, `qbittorrent` covers setup plus its surgical day-2
speed-limit action, `jackett` covers indexer enable/skip plus the
FlareSolverr-URL/admin-password set-once cycles (live Torznab/Cloudflare
reachability stays `wizard-presets.sh`'s job), `jellyfin` covers library
config match/drift/absent branches plus the Sonarr/Radarr notification
wiring (including idempotent re-run), and `seerr` covers the Sonarr/Radarr
connection wiring plus its idempotent re-run. It's a parameter-space gate, not
a cross-service interop oracle and not an image-drift preflight — `fresh-install`
owns those. Image-backed local gate, not in CI.

**Adding a module.** Drop `tests/api-matrix/<service>.sh` defining a
`matrix_<service> …` function that drives the service's API through its states
and asserts with `pass`/`fail`/`assert_eq`; `source` it and call it from
`api-matrix.sh`, bringing up whatever services it needs. Reuse the product's
render/config helpers rather than re-implementing request payloads. Each new
day-2 action that mutates a service API should ship with a matrix module here.

### Contract mocks and drift checks

```bash
./tests/run.sh --no-preload contract-mock   # image-free, PR gate
python3 tests/contracts/replay.py spec      # offline-friendly, run anywhere
```

The `tests/contracts/<service>.yml` files (schema:
`tests/contracts/README.md`) are the single source of truth for what
MediaStack calls; two consumers keep them honest without ever reimplementing
service behavior:

- **`tests/mock/serve.py`** — one generic, stdlib-only (`http.server` +
  PyYAML) contract-driven mock. Zero per-service branches: it loads a
  contract, matches each request to a declared endpoint, shape-checks the
  declared auth (header/cookie/bearer/basic/query/form present — never a
  simulated token dance), and answers from
  `tests/mock/fixtures/<service>/<endpoint-id>.json`. A missing fixture
  falls back to a minimal placeholder built from the endpoint's `reads`
  fields. Stateless by design: every request is also appended to a JSONL
  journal so a scenario can assert on the request sequence, and the only
  per-fixture ordering is an optional `responses:` list consumed one entry
  per call (the whole retry/failure-injection mechanism — see
  `tests/mock/README.md`). `tests/scenarios/contract-mock.sh` binds it to
  the exact fixed ports `service_local_url()` always resolves
  (`localhost:8989` sonarr, `localhost:7878` radarr) and runs
  `scripts/configure.sh --only sonarr,radarr` unmodified against it — no
  test hook in `scripts/`. Image-free; joins the `wizard-ui-*` PR-gate set.
- **`tests/contracts/replay.py spec`** — checks that every endpoint of a
  contract with an `openapi:` URL still exists in the upstream spec (cached
  locally; offline is a reported SKIP, never a failure).
- **Contract capture** — the traced scenarios (`fresh-install`,
  `upgrade-path`, `install-e2e`) record each product request and each
  product `docker exec` in DinD when `MS_CONTRACTS_FILE` is set
  (`tests/lib/contract-trace.sh`), and `tests/contracts/observe.py` reduces
  them to `contracts.json`. The real configurators send the real requests, so
  every declared `reads` field is checked against a real response, writes
  included. The hosted preflight's contract gate judges it
  (`docs/operations/hosted-image-preflight.md`).

Division of labor is a hard constraint: contracts declare data only, the mock proves our scripts speak the
contract, capture and spec mode prove the contract still matches reality, and
`tests/api-matrix/` keeps proving live behavior none of the above can (auth
dances, seeding, retries, day-2 effects). Logic in a contract, a
per-service branch in `serve.py`, or a mock asserting service-side behavior
is a redesign, not a patch.

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
   - **DinD control** (`lib/dind.sh`): `dind_exec "<cmd>"` (runs inside DinD with `/root/MediaStack` as CWD), `dind_python ARG... <<'PY'` (a Python program on stdin, run with `-I` inside DinD — no shell quoting of the source), `dind_write_file <path>` (stdin to a file inside DinD), `dind_logs <service>`, `dind_exec_tty` for manual poking.
   - **Reading expectations**: read them from the DinD copy (`config.yml` seeded by `create_config_dirs_in_dind`), never from the host tree, and treat a failed read as a FAIL — see `tests/assertions/arr-indexers.sh` for the shape. `tests/unit/assertions.sh` proves the fresh-install assertions fail closed.
   - **Stack helpers** (`lib/stack.sh`): `wait_healthy <svc> [timeout]`, `get_api_key_from_xml <path>`, `api_get_jackett_key`, `env_set KEY VALUE` (writes to `.env` via Python — safe with `$` and special chars), `env_get KEY`, `create_config_dirs_in_dind`.
   - **PTY wizard driver** (`lib/wizard_pty.py`): drive interactive prompt
     flows from JSON steps when pipe-based input would miss terminal behavior.
   - **Stage 1 wizard fixtures** (`lib/wizard-stage1-common.sh`): shared stubs
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

Most services have no dedicated scenario — use `fresh-install` (which does **not** start the `remote`/wireguard or `subtitles`/bazarr profiles; those use `wireguard` and `bazarr`). Rows that name `fresh-install+install-e2e` also need the real-installer run. Autoheal uses its own focused `autoheal` scenario because a running-state check cannot prove a heal. `docs/operations/upgrades.md` lists each
service's pin policy and preflight command; the "Bumping a Service Version" playbook in `docs/project/structure.md`
walks the full ritual. The `image-override` scenario is a fast (~15s, config-only) proof that an
override actually reaches compose:

```bash
MS_TEST_IMAGE_OVERRIDES="wireguard=example.invalid/wg:0" ./tests/run.sh --no-preload image-override
```

`MS_TEST_STRIP_SERVICES` (comma or space separated service names) is the sibling mechanism: it
removes those services from the DinD copy of compose and cleans the dangling `depends_on`, so a
scenario can skip services it does not assert on rather than pulling their images. Setting a
service in both variables aborts the run — the override would be stripped.

```bash
MS_TEST_STRIP_SERVICES="homepage,npm,fail2ban" ./tests/run.sh fresh-install
```

A digest override also writes a row to `tests/.image-preflight-passed.tsv` for each scenario that passed
and ran that service from that digest, judged from the DinD container events of that scenario alone
(`tests/lib/receipts.sh`). The row is withheld when the scenario failed an assertion, the latest container
of the service never started, it crashed (a `die` with no earlier stop or kill, even if it restarted), it
ran another image, or it ended stopped or unhealthy. The run prints a `[receipts]` line for each override
that got none, naming the reason.

Rows use receipt format v2: `service image digest scenario source run_id arch recorded_at_utc`, tab
separated, under a two-line `#` header. `source` is the host checkout's `git rev-parse HEAD` at run
start; it gets a `-dirty` suffix when the tree has uncommitted or untracked changes, and reads
`unknown` without git. `run_id` is one id per `tests/run.sh` invocation (`run-<UTC time>-<8 hex>`),
printed on a `[receipts] run id:` line at run start and again at the end. `MS_TEST_RUN_ID` overrides
it; a malformed value is refused and the run writes no receipts. `image_drift.py` accepts a row only
when its `source` equals the commit the accept names (so `-dirty` and `unknown` never qualify) and,
with `--receipt-run-id`, only from the listed runs. Rows with any other column count are legacy or
malformed: they never qualify, and the accept prints how many it ignored. Delete the file once after
updating past receipt v1 and re-run the preflight.

With `MS_CONTRACTS_FILE=<host path>` and a digest override, the run also records contract-coverage
evidence (`tests/lib/contract-trace.sh`). A `curl` wrapper in DinD traces the product requests of the
commands that `fresh-install`, `upgrade-path` and `install-e2e` start with `MS_CONTRACT_TRACE`. At
scenario end, `tests/contracts/observe.py` reduces the traces inside DinD and writes only
`contracts.json` to that path; the raw traces are deleted in DinD. Each scenario replaces the file, so
run one scenario per run. A `[contracts]` line names any reason the file was withheld. The hosted
verifier judges it; see `docs/operations/hosted-image-preflight.md` "Contract gate".

Preflight checks API **shape** only — for a major/API-unstable bump, also run the service's own battery plus `fresh-install` where relevant (note `fresh-install` excludes the `remote`/wireguard and `subtitles`/bazarr profiles). Host
image sideload reads the host compose, so a candidate ref may need a network pull inside DinD.

## Standalone unit tests (`tests/unit/`)

Not every test needs DinD. Pure-bash units — function-level checks that can run on the host without Docker — live under `tests/unit/` and are invoked directly:

```bash
./tests/unit/gpu-branching.sh
```

`./tests/unit.sh` runs the whole host-unit tier in one shot — static validation
(shell syntax, ShellCheck, `py_compile`, mypy, compose render) **plus** every
`tests/unit/*.sh` below. It is one stage of the PR gate, whose full local
equivalent is `./tests/check.sh`. A direct local invocation runs every tier. CI
and cumulative `default`/`full` checks call this runner with the ShellCheck and
mypy tiers visibly skipped because those same gates have already passed.
Unlike the individual units, the complete direct tier needs the Docker CLI
(compose render and the pinned ShellCheck image unless version 0.11.0 is
installed natively or cached via `./tests/lint.sh install`) and `uv` for mypy.

No host unit may touch real host state. The runner puts a `sudo` shim first on
`PATH` that refuses every call and fails the file that made it, so a unit must
stub `sudo` (a shell function, exported when it runs `bash -c` children) and
point every `/etc`, `/usr/local` and systemd path variable at a temp root.
CI runners have passwordless sudo; a developer machine usually does not, so
only the shim shows the difference.

```bash
./tests/unit.sh        # static validation + every host unit
```

These rules keep a unit's verdict honest:

### Unit files must end with summary

The runner gates each file on its exit code, and only `summary`
(`tests/lib/assert.sh`) turns a failed assertion into a nonzero exit. A
top-level `tests/unit/*.sh` file therefore ends with a bare `summary` line.
The runner also fails a file that exits 0 without reaching `summary`:
`summary` writes a verdict file (`MS_UNIT_VERDICT_FILE`), so sourced code
that calls `exit 0` part-way through cannot pass with the remaining checks
unrun.
`tests/structure.sh` fails on a file that does not. Fragments under
`tests/unit/<dir>/` are sourced by a parent that owns the verdict and are
exempt.

### Units run with stdin from /dev/null

The runner starts every unit with `</dev/null`, so no test depends on the
caller's stdin. A product path that reads stdin (the typed `DESTROY`
confirmation of `main --uninstall`) must get its input from the test: stub the
prompt function, or redirect `</dev/null` at the call site, as
`uninstall-system-cleanup` does. A direct `bash tests/unit/<file>.sh` run
inherits your stdin, so give it `</dev/null` as well.

Current units:

- **gpu-branching** — exercises the split GPU helpers under `scripts/setup/gpu/` (through the `scripts/setup/gpu.sh` entry) by shimming `lspci`/`mokutil`/`nvidia-smi`/`docker` and render-device helpers as in-shell functions. Catches regressions in GPU selection logic, including no-GPU `set -e` behavior and vendor-aware Intel/AMD render-node routing, without needing real hardware.
- **qbittorrent** — checks qBittorrent login form encoding, first-run temp-password handling, shared-admin credential alignment, manual-storage behavior, and the reusable live assertion parser.
- **portainer** — checks Portainer auth drift handling, including a warning when admin auth returns no JWT and the normal endpoint/API-token setup path when auth succeeds.
- **bazarr** — checks Bazarr config-file write success/failure handling without needing a running Bazarr container.
- **jellyfin** — checks Jellyfin library creation logging for successful and failed API POSTs without needing a running Jellyfin container.
- **api-matrix-jellyfin** — deterministically checks the api-matrix Jellyfin VirtualFolders helper retries transient failures, preserves successful JSON, and stops after five failed requests without requiring DinD.
- **seerr** — checks Sonarr/Radarr connection payload profile lookup with quoted/backslash profile names.
- **json-helpers** — exercises `json_get`, `json_path`, `json_has_name`, `json_array_nonempty` from `scripts/lib/json.sh` with representative inputs (missing keys, nested paths, case-insensitive matching, empty/invalid JSON).
- **common** — exercises shared `.env` API-key persistence helpers, including values with `&`, `|`, `/`, append behavior, sourceability, and rejection of unsupported newline/quote values.
- **gcp-wan-ports** — keeps the GCP external blocked-port probe aligned with the Docker LAN-only port set enforced by `scripts/setup/hardening/admin-filter.sh`.
- **preflight-receipts** — proves a row in `tests/.image-preflight-passed.tsv` is written only for a scenario that passed and whose container events show the service ran from the candidate digest: teardown after a healthy run, a crash hidden by a restart-policy start, a recreate that never started, a wrong digest, an unreadable log and the `[receipts]` reasons (`preflight-receipts/evidence.sh`); and that every row carries the v2 columns, a `-dirty` or `unknown` source when the tree or git warrants it, and the run id, generated or from a well-formed `MS_TEST_RUN_ID` (`preflight-receipts/provenance.sh`). Pure bash with a fake `docker` and a fake `git` on `PATH`, no DinD and no real repository; run directly with `./tests/unit/preflight-receipts.sh`.
- **image-drift** — verifies that digest acceptance requires a frozen `--current-file`, preventing maintainers from recording a tag digest that was not the one preflighted; the receipt gate (no receipt, wrong scenario, bypass, non-scenario tiers); and that the generated README Stable-baseline badge stays derived from the lock file.
- **image-drift-install** — checks install-digest records for running services, omission of absent services, and normalization of already pinned Compose references into valid Revert pins. Pure Python and shell; no Docker.
- **upgrade-baseline** — checks that the full battery uses an exact accepted qBittorrent target without leaking overrides or claiming candidate evidence, while identical explicit candidates fail before setup.
- **qbittorrent-live** — runs the real assertion against a local HTTP server: 200/204 session login, rejection of an HTTP error with an `Ok.` body, and total request deadlines for login and preferences.
- **image-drift-receipts** — verifies the receipt provenance rules of `scripts/image_drift.py`: a legacy four-column row never vouches and is counted on stderr; a receipt from another commit, a `-dirty` tree, an unknown source or a run outside `--receipt-run-id` is refused with a message that says which; a matching v2 row is accepted and leaves every other lock row byte-identical; a `scenario:X+Y` token needs one receipt per scenario and the summary prints one command per scenario; and `--preflight-plan` groups drifted services by scenario, puts a `+` service in both groups and lists non-scenario tiers under `pending_non_scenario`. Pure bash + python3, no git; run directly with `./tests/unit/image-drift-receipts.sh`.
- **launcher-service-start** — checks that **Start a service** reconciles with `docker compose up -d` (not `start`), runs the storage guard first, passes the optional-profile flag, does not pass `--no-deps` (stopped dependencies start), reports a failed recreate without a success line, and that staging for a stopped service starts nothing. Docker is shimmed.
- **manage-updates** — covers the day-2 "Manage updates" feature: `override.sh` per-service policy (floating one service drops only its digest pin; clearing re-pins; global-latest pins nothing), `image_drift.py --status` channel-agnostic 2-state truth table and hardened running-digest extraction, and the launcher's apply/flip/revert helpers (a pinned service floats to its tag decided by effective channel, not status text; WireGuard exclusion from "Update all"). Sources `mediastack` + `override.sh`; pure bash + python3, no Docker/network.
- **launcher-features-wireguard** — covers when Features & settings offers **Add WireGuard VPN** (HTTPS ready and WireGuard absent only; **Add remote access** keeps its own rule) and that the row runs `setup.sh --wireguard`. The recovery side (decline or cancel at every prompt leaves `.env` and `config.yml` byte-identical; accept writes only the `WG_*` keys) is in `recovery-routing/remote.sh`.
- **launcher-hardware / nvidia-maintenance** — cover the day-2 hardware surface, Unlock-only visibility/dispatch guards, default-No cancellation, resolve-before-stop ordering, unload failure cleanup, one installer/toolkit execution, and expected-version marker persistence. Pure bash; no Docker/network.
- **launcher-uninstall / uninstall-system-cleanup** — cover launcher routing/result reporting, root-only ledger reads, selective UFW/APT/sysctl/Samba cleanup, teardown failure rollback, and Stage 3 routing precedence.
- **recovery-advice** — guards that no runtime message under `scripts/` recommends `docker compose down -v`, and that each drift notice (root folder, download category, quality profile, rename, format scores) and the completed-install skip names a keep path and a reapply path. Pure bash; no Docker/network.
- **test-runner** — checks that `tests/run.sh` rejects empty or truncated scenario files instead of reusing a stale `run_scenario`.
- **lint-sweep** — proves bounded ShellCheck roots, complete tracked-file coverage after findings, progress before each analysis, filenames with spaces, caller flags, and engine-error propagation. Real-engine fixtures prove the two dispatchers do not expand their imports while defects in tracked helpers still fail the gate. Uses the same pinned-engine resolution as lint; run directly with `./tests/unit/lint-sweep.sh`.
- **structure-gate** — proves `tests/structure.sh` fails on a fabricated violation: a `scripts/services/<svc>/main.sh` missing its `configure_<svc>()` (including the hyphen→underscore mapping a literal comparison would get wrong), a service module sourcing another service, a `scripts/setup/` module sourcing a peer top-level module, a service module sourcing a top-level `scripts/setup/*.sh` module (including behind an if-guarded directory-variable assignment), a sanctioned seam whose import has gone, the closing-`summary` rule for top-level `tests/unit/*.sh` files (a missing `summary`, a `summary` that is not the last command, and an exempt fragment), and the shellcheck source-directive rule (a path that escapes the repo root fails; a repo-root-relative path stays clean). The fixture is a throwaway git repo built from `git archive HEAD` with the working-tree gate copied in; the real tree is never written to. Pure bash + git, no Docker and no network; run directly with `./tests/unit/structure-gate.sh`.
- **contracts-gate** — proves the failure paths of `tests/contracts/check.py` route to a remedy: a fabricated API call no contract covers must report `missing contract`, say the call needs an entry (or is malformed) and name `tests/contracts/`; a fabricated endpoint nothing calls must report `dead contract entry` and steer to deleting it; a readiness probe whose URL names no service must report `unrecognised probe`, and one whose service has no entry must report `missing contract`; a braced variable in a `service_local_url` suffix keeps the rest of the route; a service URL variable assigned in one function does not attribute a call in another; and an `expect` status outside 100-599, an `unexercised` reason outside the closed set, or `held-profile` on a service that is not held must report a `schema:` error that names the entry. The fixture is a throwaway copy of `git archive HEAD` with the working-tree checker and inventory copied in. Pure bash + python3 + git, no Docker and no network; run directly with `./tests/unit/contracts-gate.sh`.
- **contracts-exec-scan** — proves that `tests/contracts/exec_scan.py` fails closed: `docker compose exec`, `docker container exec`, an unknown exec flag and `exec` in a `for` list are refused; a docker exec in `"$( ... )"`, a container variable bound to one name and an array behind `sudo` are read; `sh -c "docker exec ..."`, `eval`, `$DOCKER exec`, docker global flags and `docker-compose exec` fail as a possible call not parsed; a container variable with two values or set by `read` is unparseable; a comment is passed over, and a listed message only in its own file; and the dry-run sandbox exclusion holds only for `$cname` in `scripts/lib/dry-run.sh`. Pure python3, no Docker; run directly with `./tests/unit/contracts-exec-scan.sh`.
- **contracts-observe** — runs real `/usr/bin/curl` through `tests/lib/contract-trace-curl.sh` against a stdlib `http.server` fixture that answers as Sonarr, in each product call style (`-o` with `-w '%{http_code}'`, `-K -` on stdin, `--data-binary @-`, a chunked response, a 100 Continue POST, `-L` through a 302), then reduces the traces with `tests/contracts/observe.py`. It asserts the matched entries, final statuses and reads seen; that a query string is not part of the route; that a request with no response counts as `000`; that a non-2xx body proves no read; that an empty list or empty nested array proves no read; that an unlisted route is reported with its long segment redacted; that a request before the candidate's start event binds to the other image; that the report counts every traced request and names its candidate refs; that the report holds no values, headers or bodies; and that the shim keeps curl's output and exit code and traces nothing without `MS_CONTRACT_TRACE`. A Sonarr, a Radarr and a stray fixture prove that a reused connection and a `-L` redirect back to the first server are attributed by the Host header, and that a local port no service owns counts as unparsed. When Docker works, the same suite runs again in a `debian:bookworm-slim` container with curl 7.88, the DinD image's curl; without Docker that step is skipped. Run directly with `./tests/unit/contracts-observe.sh`.
- **contracts-observe-rules** — proves the `tests/contracts/observe.py` rules that curl on 127.0.0.1 cannot reach: a request to a public address is ignored, an unlisted path keeps only route literals, short plain words and numbers, and a request at exactly a container's start time binds to that image. Pure python3, no Docker; run directly with `./tests/unit/contracts-observe-rules.sh`.
- **contract-trace** — proves the DinD hooks in `tests/lib/contract-trace.sh` with a stub `docker`: without `MS_CONTRACTS_FILE` no shim is installed and no reducer runs; `begin` removes a stale `contracts.json`; the reducer gets `MS_CONTRACT_CANDIDATES`, not every override; only `contracts.json` leaves DinD and no call besides the reducer and the removal names the raw traces; `end` removes the shim and raw traces; and a failed event-log sync writes no `contracts.json`. Pure bash, no Docker; run directly with `./tests/unit/contract-trace.sh`.
- **contracts-inventory** — proves the shared format rules in `tests/contracts/inventory.py`: `{id}` matches one generated-id segment and never a word, `{key}` matches any one segment, the unlisted Seerr `/settings/about` route has no entry, null and empty values prove no read while `0` and `false` do, an empty `expect` list and an unknown placeholder are refused, and the fingerprint changes with file content. Pure python3, no Docker; run directly with `./tests/unit/contracts-inventory.sh`.
- **hosted-preflight-contracts** — proves the hosted wiring of that verdict over synthetic artifacts: a traced job without `contracts.json` fails its candidate as an image failure, a phase-1 contract failure removes the candidate and the status report names the entry and read, an entry covered only by the union of a candidate's jobs passes, a phase-2 contract failure blocks acceptance and is named in the status report, a candidate without entries is reported in the digest PR body and the status report, the report command names a phase-2 contract failure, a job's evidence problem fails every candidate it ran, a service with entries but no traced job fails, an unsafe unlisted path is filtered, contract messages are capped per service, the digest PR body lists the exempt entries, an exercised exemption is reported as stale, a traced job's environment names its own `contracts.json` and only its combination's candidates while an untraced job gets neither, `MS_CONTRACT_TRACE` is set only on an explicit list of product commands and named helpers in `tests/scenarios/` and `tests/assertions/`, the traced-scenario set matches the scenarios that reach those sites, a changed fail2ban candidate plans exactly its drift, fresh-install and upgrade-path jobs, and the exported `events.json` keeps only bare actions, so no exec command line reaches the artifact. Pure python3, no Docker; run directly with `./tests/unit/hosted-preflight-contracts.sh`.
- **preflight-contracts** — proves each contract-coverage acceptance rule in `tests/preflight/contracts.py` can fail over contracts.json data: a 404, a missing read, an empty list, an unlisted call, a call only on a non-candidate image, no traced product request (`contract trace inactive`), an inventory fingerprint mismatch, an unknown entry, an undeclared read, another run, scenario or candidate ref, a boolean schema, an entry record without reads, an unparsed request, a 302 on an entry without `expect`, an unlisted call made on another image, a 1 MB evidence file and a symlinked one. A job that traced requests only to other services is active, and a job for another service does not count. It also shows that reads combine across two jobs, that an exempt entry does not block and is listed with its reason, that an exercised exempt entry is reported as stale, that a held service's entries and calls do not block another service, and that a candidate without entries passes and is reported in `uncovered`. Pure python3, no Docker; run directly with `./tests/unit/preflight-contracts.sh`.
- **line-cap-gate** — proves the two ratchet refusals in `tests/shell-line-cap.sh` (`new allowlist entry is not permitted`, `allowlist count increased`) carry the same routing as the main violation: shrink-only grandfather list, split the file, see `docs/conventions.md` "Shell structure". The tree's allowlist was emptied and deleted, so neither refusal is reproducible here; both are probed against a fabricated allowlist in a throwaway repository, and nothing recreates one in the tree. Pure bash + git, no Docker and no network; run directly with `./tests/unit/line-cap-gate.sh`.
- **wizard-prompts** — guards the shared wizard-prompt SSOT (`tests/lib/wizard_prompts.json`): every regex compiles, the step-builder (`wizard_steps_build.py`) renders name/`@timeout`/`ENTER`/`NONE` and rejects unknown names, no `wizard-ui-*` scenario that builds from the SSOT re-inlines a prompt regex or references an undefined name, and any scenario calling the builder sources a lib that defines it.
- **remote-web-state** (`tests/unit/remote-web-state.sh`) — exercises `write_env()` remote marker rules and `print_access_info` output for unchecked, ready, skipped, and LAN-only states.
- **ddns-config** — exercises the shared DDNS provider registry + `config.json` renderer (`scripts/lib/ddns-providers.sh`): all 6 providers render valid typed JSON (Cloudflare `ttl`/`proxied` typed, dynv6 carries no inert `ipv4` key), missing/unknown inputs fail, the Dynu render stays byte-identical to the inline writer it replaced, and the registry accessors (`pick`/`fields`/`verify_tier`/`category`) map correctly. No credentials.
- **stage2-domain** — exercises domain/DNS classification, Cloudflare proxy detection, and safe routing before publication.
- **stage2-ports** — exercises local port checks and failure classification without claiming public WAN reachability.
- **stage2-wireguard** — exercises the access-tier env mapping (Full LAN / Server / Containers / Streaming / Streaming + requests) plus `net_detect_lan_cidr` normalization. Tier semantics: [VPN access tiers](../docs/setup/configuration-schema.md).
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
- **upgrades-manifest** — keeps `docs/operations/upgrades.md` in sync with `docker-compose.yml`: every service has a row, each row's pin-policy token matches the live image tag, and each preflight token resolves to a real scenario/unit (every part of a `scenario:X+Y` token must be a real scenario that starts the service). Pure bash + python3; run directly with `./tests/unit/upgrades-manifest.sh`.
- **repository-safety** — fixture proof for `tests/lib/repo_guard.py`, the publication-safety guard: forbidden private artifacts, tracked host artifacts, secret files and credential patterns, and config/workflow YAML validity. Exit codes are `0` clean, `1` findings, `2` guard error — an unreadable file, an empty population or an empty rule list is a guard error, never a silent pass. Findings print `<RULE-ID>`, path and detail, and never echo the matched text: a credential finding names the pattern and the line number, not the value. Rules split by population — host artifacts and content scanning read the git index; the private-directory, analyzer-cache, log and secret-file rules read the working tree, because a gitignored `.ua/` is invisible to `git ls-files` and an untracked private key can still be `git add`-ed later. Worktree rules skip the gitignored live-install state that the host-artifact rule already rejects in the index, so a real install is not a wall of findings. History is out of scope: the guard reads the tree as it stands. Every entry of every rule list has its own probe fixture and an `EXPECTED_*` set assertion, so deleting one turns the suite red. Pure bash + python3 + git, no Docker and no network; run directly with `./tests/unit/repository-safety.sh`.
- **workflow-caches** — proves that no tracked GitHub workflow can restore an Actions cache. Every `uses:` must be on a cache-free allowlist (`checkout`, `upload-artifact`, `download-artifact`), or be `setup-uv` with `enable-cache: false`. Other actions, local composite actions and reusable workflows are reported, because many actions cache by default and nested steps are hidden from the check. A forged cache entry from a privileged image job could otherwise overwrite verifier scripts in later runs. Pure python3 + PyYAML; run directly with `./tests/unit/workflow-caches.sh`.
- **workflow-pins** — proves that every `uses:` in a tracked workflow, in a step or a reusable-workflow call, names a full 40-hex commit SHA; a tag, branch, short SHA or local path is reported. Pure python3 + PyYAML; run directly with `./tests/unit/workflow-pins.sh`.
- **hosted-preflight-schedule** — simulates which jobs of `image-drift.yml` run for each trigger and job outcome, from the workflow's own `if:`/`needs:` conditions and its real `mode` step: one failed phase-1 job, a plan without work, a failed planner and a failed phase 2. The expression evaluator accepts only an allowlisted token set, refuses reads of undeclared `needs`, and passes `github.event.inputs` as strings. It also proves the concurrency groups, the image-job bounds and that the publisher never merges or approves a PR. Pure python3 + PyYAML; run directly with `./tests/unit/hosted-preflight-schedule.sh`.
- **hosted-preflight-gates** — proves that a failed combination keeps a digest PR that proposes only part of it and closes one that proposes all of it, that a phase-1 failure at the exact digest closes the PR, that the publisher refuses a PR from a user named like the bot, that an uninspected candidate does not qualify, that the runner counts skips, keeps `GITHUB_TOKEN`/`GH_TOKEN` out of the scenario, prints the log tail between `::stop-commands::` markers, and that the headroom minimum is exactly 2 GiB. Pure python3, no Docker; run directly with `./tests/unit/hosted-preflight-gates.sh`.
- **hosted-preflight-notify** — proves that the drift alert comments only when the drift set differs from the issue body, and that the preflight report comments only when its per-service status table, without run links, differs from the newest report by `github-actions[bot]`; a failure notice always comments, and a malformed comment reply fails. Pure python3 + PyYAML; run directly with `./tests/unit/hosted-preflight-notify.sh`.
- **secret-scan** — regression proof for `tests/secret-scan.sh`, the pinned gitleaks wrapper: the `0`/`1`/`2` exit-code contract, both scan modes, and every guard that stands between a weakened scan and a confident "clean". Covers the canary self-test (an emptied ruleset, a catch-all allowlist and a single disabled rule all fail closed), the `binary_sha256` check, the `.gitleaksignore` pre-flight on disk and in history, the bytes-scanned and commits-scanned guards, symlinked and real scan roots agreeing, archive traversal, merge-resolution content, commit and annotated-tag messages, and redaction. Fixtures are temp dirs and temp git repos; canary literals are assembled at runtime from split halves so the file is not itself a finding, and only rule IDs are asserted on. Reconciliation itself lives in `tests/lib/secret_scan_reconcile.py` and is proved directly by its own suite, **secret-scan-reconcile** (`tests/unit/secret-scan-reconcile.sh`) — a hand-written report plus a declaration file, no scanner and no network — over the whole steering matrix: tree and history, each with an undeclared finding, a stale declaration, and both at once, plus the green path, a declaration-free file, an unreadable report, an unreadable declaration file, a short argument list and an unknown mode. The anti-rewrite assertion is case-folded, so no capitalisation of "rewrite" can reach the history steering. That is why the gitleaks-backed probes here prove only that a real scan reaches the gate. Also covers the two blocking `gate-*` modes: a missing or declaration-free expectation file is an error, an undeclared finding and a declaration nothing produced both fail, one declaration file satisfies both modes, an edit that moves a finding's line does not invalidate it, and a substituted secret at the same rule, path and finding count does. It **fails closed rather than skipping** when the scanner is missing, and calls `secret-scan.sh install` itself — idempotent on a warm cache, one network fetch on a cold one. Pure bash + python3 + git, no Docker; run directly with `./tests/unit/secret-scan.sh`.
- **docs** — contract suite for the public control surface: `LICENSE`, `README.md`, `CONTRIBUTING.md`, `docs/README.md`, `.github/SECURITY.md` and `.github/ISSUE_TEMPLATE/`. Asserts each one exists, that every file under `.github/ISSUE_TEMPLATE/` parses as YAML — the whole file for `.yml`/`.yaml`, the front matter for a markdown template — using the same `yaml.safe_load` mechanism `repo_guard.py` uses, and that the chooser's `config.yml` carries a contact link whose name or `about` text names security, and whose URL is a known private GitHub route (`security/policy`, `security/advisories/new`) backed by a file that exists here. The route is matched on the URL path tail, not the literal URL, so an org or repo rename does not break it. Every relative markdown link in the control files and in every `docs/guide/*.md` must resolve, and `docs/README.md` must link each guide; that scope is deliberate — a tree-wide link check is separate work. `CONTRIBUTING.md` must exist exactly once in the tree, at the repository root, so a second copy under `.github/` fails. Fails closed on the declared control-file list, the issue-template population, the guide population and the link population: an empty population is a failure, not a vacuous pass. `MS_TEST_DOCS_ROOT` points it at a fixture tree instead of the real repository. Pure bash + python3, no Docker and no network; run directly with `./tests/unit/docs.sh`.
- **wizard-flow** — exercises the full wizard interactive flow (`detect_env`, `run_wizard`, `write_env`) in `UI_DEMO=1` mode. Verifies `.env` is written with correct values and permissions, `config.yml` gets the wizard preset and completion marker, re-run skips correctly, and interrupted-run defaults are preserved from a previous `.env`.

Focused remote-access units:

```bash
bash tests/unit/stage2-domain.sh && bash tests/unit/stage2-ports.sh && bash tests/unit/stage2-wireguard.sh && bash tests/unit/stage2-flow.sh && bash tests/unit/stage2-npm-stale.sh && bash tests/unit/remote-web-state.sh
```

GPU-flow integration isn't covered by `fresh-install` (DinD has no GPU passthrough); the unit test is the practical substitute for the detection/verification branches. End-to-end driver install + patch still needs a VM or bare-metal box with real NVIDIA hardware.

Focused hardware transcoding units:

```bash
bash tests/unit/gpu-branching.sh && bash tests/unit/nvidia-patch.sh && bash tests/unit/nvidia-maintenance.sh && bash tests/unit/launcher-hardware.sh && bash tests/unit/wizard-flow.sh && bash tests/unit/stage3-flow.sh && bash tests/unit/stage3-marker.sh && bash tests/unit/reboot.sh && bash tests/unit/stage3-summary.sh && bash tests/unit/setup-resume-routing.sh && bash tests/unit/stage3-transcode.sh && bash tests/unit/stage3-gpu-content.sh
```

Hardware transcoding coverage uses Bash units, stubs, API fixtures, automatic FFmpeg smoke-test stubs, `vainfo` parser fixtures, and captured Jellyfin FFmpeg/transcode log fallback fixtures. `stage3-transcode.sh` verifies parser evidence, automatic proof, and codec capability probing for `qsv`, `vaapi`, and `nvenc`; `stage3-flow.sh` verifies Intel QSV-to-VAAPI fallback routing and Jellyfin codec-specific API fields. Real GPU transcode proof still requires a real host because DinD has no physical Intel/AMD/NVIDIA GPU passthrough.

Focused Stage 3 PTY coverage includes the single-vendor paths, NVIDIA ownership states,
and `wizard-ui-stage3-multi-gpu`, which proves the detected-only vendor menu routes to the selection:

```bash
./tests/run.sh --no-preload wizard-ui-stage3-intel wizard-ui-stage3-amd wizard-ui-stage3-nvidia-standard wizard-ui-stage3-nvidia-existing wizard-ui-stage3-multi-gpu
```

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

## Secret scanning (`tests/secret-scan.sh`)

`tests/lib/repo_guard.py` reads the tree as it stands with a hand-written credential
grammar. `tests/secret-scan.sh` is the formal scanner that complements it: a pinned
[gitleaks](https://github.com/gitleaks/gitleaks) with the tool's own maintained ruleset,
run in two modes. It is a **blocking gate over this repository**, not only a review step:
`./tests/check.sh secrets` — the `fast` tier and the `secret-scan` CI context — scans the
working tree on every PR. The history mode is deliberately **not** in any tier: it re-reads
every commit, so a declared benign finding is reported once per revision of its file and an
unrelated edit turns the tier red. It guards publication rather than the edit loop — run
`./tests/check.sh secrets-history` before any push that makes new history public. Its
guards are covered by
`tests/unit/secret-scan.sh`, which is in `./tests/unit.sh` and needs network on a cold tool
cache. Tree mode excludes and announces registered child Git worktrees under the root `.wt/`
directory; direct child scans and ordinary `.wt` directories are still scanned.

```bash
./tests/secret-scan.sh install                  # fetch + verify the pinned binary
./tests/secret-scan.sh tree .                   # the tree as it stands
./tests/secret-scan.sh history . --all          # every reachable commit
./tests/secret-scan.sh history . "main..HEAD"   # one range
./tests/secret-scan.sh gate-tree                # tree, reconciled (blocking)
./tests/secret-scan.sh gate-history             # history, reconciled (blocking)
```

### The declared finding set (`tests/secret-scan.expected`)

This repository carries four findings, all `generic-api-key` on empty values or prose, none
a credential. The two gate modes reconcile what they find against
`tests/secret-scan.expected` as a **multiset, in both directions**: an undeclared finding
fails, and a declaration nothing produced fails too. That second direction is the shrink
path — fixing a false positive means deleting its line in the same commit, so the set cannot
grow silently and cannot rot into a rubber stamp.

**The declared set grows only under human review, never to make a run pass.** Appending the
finding a red run just printed is the one move that is always wrong. Remediation branches by
mode, and the gate says which it is: a **tree** finding is removed from the tree — and
rotated if the value was ever real — because removal is the fix and declaring it is not; a
**history** finding is in a commit that cannot be taken back, so rotating the credential is
the only real remediation, and only after that does declaring it become a question a human
answers. A `DECLARED-BUT-ABSENT` line is the opposite direction: the declaration is stale,
so delete it.

A declaration is `<rule-id>`, the repo-relative path, and a fingerprint hashing the rule, the
path, gitleaks' **redacted** match text and its entropy. It is deliberately not derived from
a line number: an ordinary edit elsewhere in one of those files must not invalidate the
declaration, or whoever hits the false red loosens the check instead of reading it. Because
the fingerprint covers the finding's own content, a real secret appearing in a file that
already carries a declared false positive — same rule, same path, even the same finding
count — produces an identity the file does not contain, and the gate goes red. No matched
value is ever written to the declaration file or printed; regenerate a changed fingerprint
from the gate's own `UNEXPECTED` output.

The declaration file is written for the tree mode, whose multiset describes one snapshot.
History multiplicity counts revisions instead, so the same declared finding is reported once
per revision of its file and a shared declaration set cannot satisfy both modes at once —
removing a declared false positive obliges the tree mode to drop its line while append-only
history still produces it. `gate-history` therefore takes its own declaration file as its
first argument; pass one when the counts diverge rather than editing the tree's set to make
red go green.

Both gate modes fail closed before reconciling anything: a missing declaration file, a file
holding only comments, and every scanner-level failure listed below (missing binary, gutted
ruleset, zero bytes read, empty revision range) exit `2`. Findings in commit or tag messages
are never declarable — a message is written by hand, so a secret in one is always a defect.

The whole-history scan sits in the same always-on tier as the tree scan rather than a slower
one: it costs ~0.6s over 128 commits today, and the cost of catching a leaked credential one
tier later is that it has already been pushed. History grows, so revisit the tier placement
if that figure ever approaches the tier's other stages.

**Tree mode does not cover removed history.** `tree` walks the filesystem, so it sees
untracked and gitignored files a `git ls-files` scan would miss — but a secret that was
committed and later deleted is absent from the tree and present forever in the object
store. Only `history` reaches those blobs. Both modes, every time; neither substitutes
for the other.

The pin lives in `tools.toml`: version, download URL, the sha256 recorded there, upstream's
published checksums file, and `binary_sha256` for the extracted executable. `install` verifies
the download against both checksums and fails if they disagree; `binary_sha256` is re-checked on
every scan, because a version string is self-reported and a three-line shell script can print
one. The binary is cached under `MS_TOOL_CACHE` (default `~/.cache/mediastack-tools`). Reports
go to `MS_SCAN_REPORT_DIR` (default a temp dir) — that override moves reports and nothing else;
every working file the scan needs comes from an unconditional `mktemp -d`.

Before each scan the wrapper runs a **self-test**: it writes synthetic canaries covering
`aws-access-token`, `private-key` and `generic-api-key` to a temp dir and scans them with the
pinned binary and the pinned `--config`. If any of the three does not fire, the scan is an error
(`2`), not a result. A gutted `.gitleaks.toml`, a catch-all allowlist, a disabled rule and a
substituted binary all land here instead of printing `clean`. Canary literals are assembled at
runtime from split halves so the scanner's own source is not a finding, and the values are chosen
to clear the default ruleset's entropy and base32 checks — a canary that never fires would make
the self-test vacuous.

Exit codes match the guards: `0` clean, `1` findings, `2` scanner or usage error.
Findings print `FINDING`, the rule ID, path, line and commit, never the matched value
(the scanner runs with `--redact=100`). Suppression is deliberately hard: the ruleset comes from
`.gitleaks.toml`, which extends the default set and allowlists nothing, and inline
`gitleaks:allow` comments are disabled with `--ignore-gitleaks-allow`. A `.gitleaksignore` cannot
be disabled by any flag — `-i` only *adds* a second location — so the wrapper refuses to scan at
all if one exists anywhere in the target on disk, or is reachable in any commit in the selected
range. A false positive is a reviewed diff to `.gitleaks.toml` or it is a finding.

Failing closed matters more here than anywhere else, because this scan is the last check
before something becomes public and permanent:

- gitleaks exits `1` for a leak *and* for an internal error, so the wrapper asks for
  `--exit-code 7` and treats every other nonzero code as an error.
- `gitleaks git` exits `0` when its revision range selects nothing, so the wrapper
  resolves the range with `git rev-list --count` first and errors on an empty selection,
  and errors again if the scanner then reports zero commits scanned.
- `gitleaks dir` exits `0` after reading nothing, so the wrapper errors when the scanner
  reports zero bytes scanned — an empty tree, or a scan root that read as present but was
  never walked.
- `gitleaks dir` does not follow a symlinked scan root while `[ -e ]` does, so the two
  spellings of one path disagreed. The target is resolved with `realpath -e` before anything
  else, which also normalises `.` so the report-dir-inside-target check works for it.

Three things gitleaks does not cover by default, and what the wrapper does about each:

- **Archives.** `--max-archive-depth` defaults to `0`, so a secret inside a committed `.zip`
  or `.tar.gz` is never read. The wrapper sets depth `4`.
- **Merge diffs.** `git log -p` omits them, so content introduced only by a merge resolution
  is invisible. The wrapper appends `--diff-merges=first-parent` to the log options, which puts
  the resolution back in scope. Content already scanned on a side branch can be reported twice;
  the counts are assertions, not totals.
- **Commit and annotated-tag messages.** No gitleaks mode reads them, and both are published
  by the same push as the blobs. History mode dumps them to a temp dir outside the target, one
  file per object, and scans that too — a finding names `commit-<sha>` or `tag-<name>`.

`git log -p` reports **additions only**, so "commits scanned" is normally lower than the number
selected: a pure-deletion commit contributes nothing to scan.

## Command contract

`tests/check.sh` is the wrapper over these tiers — one command surface over the lint,
type, unit, wizard, and DinD runners above, so nobody has to remember the equivalent
command by hand:

```bash
./tests/check.sh          # default: fast + tests/unit.sh + image-free wizard scenarios
./tests/check.sh fast     # static tier: shellcheck, line cap, naming, structure, shfmt, ruff, mypy, contracts, secrets.
./tests/check.sh full     # default + the complete DinD battery (tests/battery.sh)
./tests/check.sh install  # one-time per machine: fetch + verify every pinned dev
                          # tool (shellcheck, shfmt, gitleaks) into the local cache
```

Stages run in the documented order and stop at the first failure, naming the tier and
the exact underlying command so it can be re-run in isolation. It wraps the runners
below; it does not reimplement their file discovery or logic:

- **fast** — `./tests/lint.sh --severity=info` (shellcheck),
  `./tests/shell-line-cap.sh` (the 500-line ratchet), `./tests/naming.sh`
  (tracked shell/python filename casing, plus declared `<prefix>_*` function
  conformance for any `scripts/*.sh` module that opts in via its `# Owns:`
  line), `./tests/structure.sh` (every `scripts/services/<svc>/main.sh` defines
  its `configure_<svc>()`, plus the import-direction rules over
  `scripts/services/` and `scripts/setup/`), `./tests/dead-code.sh` (every
  function defined under `scripts/` has a reference elsewhere in the tracked
  tree), `./tests/format.sh check`
  (shfmt), the pinned ruff lint + format check (findings reconciled by
  `./tests/python-complexity.sh` against the C901 shrink-only allowlist), the
  pinned mypy invocation, and the
  pinned gitleaks over this repository's tree. It starts
  no DinD or service containers; ShellCheck runs from a native or cached pinned
  binary (`./tests/check.sh install`) and only falls back to Docker when neither
  is present, but its whole-tree sweep can still take several minutes. Use
  the touched-file lint/format commands above for quick feedback. The pinned tools
  need network on a cold tool cache. History is the separate
  `./tests/check.sh secrets-history` pre-push selector.
- **default** (`fast` plus) — the coverage GitHub Actions runs on push to `main`
  and on every pull request (`.github/workflows/ci.yml`): the host-unit stages
  (shell syntax, `py_compile`, compose render, every host unit) and the
  image-free wizard scenarios in DinD. CI runs ShellCheck and mypy in separate
  required jobs, then skips their duplicate `tests/unit.sh` tiers. Locally,
  `./tests/check.sh` runs the same coverage serially and likewise skips those
  duplicate tiers after `fast` has passed.
- **full** (`default` plus) — the complete local/on-demand gate, adding
  `./tests/battery.sh`. `battery.sh` alone is not the default tier's superset — it
  never invokes `unit.sh`, and it runs every scenario under `tests/scenarios/`,
  image-free `wizard-ui-*` included, not only image-backed ones. Maintainer-run
  before accepting an image update (see `docs/operations/upgrades.md`).

`./tests/battery.sh` (`--list` prints the plan without running anything) is
the standalone entry point for that same full scenario set: every scenario
shares one DinD via `run.sh --reset-between` — images sideloaded once, state
(containers/volumes/networks, repo copy) reset between scenarios — except
`image-override`, which patches the compose for the whole DinD and so runs
alone on its own DinD. Discovery is by glob, so a new scenario file is picked
up without editing the runner.

### DinD state between scenarios

Any multi-scenario run that passes `--reset-between` to `tests/run.sh`
(`tests/battery.sh`'s main run, and `tests/check.sh`'s `default`/`wizard`
tiers over `tests/ci-scenarios.sh`) restores a pristine DinD before every
scenario after the first: `dind_reset` (`tests/lib/dind.sh`) removes every
container, prunes anonymous volumes and custom networks, and re-copies the
pristine source tree from the host checkout — undoing anything a prior scenario stubbed
(`scripts/configure.sh`, via `tests/lib/wizard-stub-common.sh`) or rewrote
(`config.yml`, `.env`, any other file under the repo copy) — then re-applies
image overrides/strips so those survive the reset too.

That guarantee is what lets a scenario be written without worrying about
what an *earlier* scenario in the same battery left behind. It does not cover:

- **A scenario's own runtime state within its run.** Starting/stopping a
  background process it launched (e.g. `contract-mock`'s mock server) is
  still that scenario's job.
- **Preconditions that were never part of the pristine repo copy.** e.g.
  `config.yml`/`.env` don't exist until a scenario copies them from their
  `config/examples/`/`.env.example` templates — a scenario still seeds those
  itself; the reset only guarantees they're back to that pristine (absent or
  template) state, not populated.
- **Runs without `--reset-between`.** A bare `tests/run.sh a b c` (no flag)
  shares one DinD with no reset, matching the historical behavior — pick this
  only when the scenarios are known not to mutate shared state.
  `tests/ci-scenarios.sh`'s header documents scenarios it deliberately
  excludes from the shared image-free run for this reason (`demo-lan`,
  `existing-install-nuke`, `nas-storage`, `image-override`).

A scenario that mutates `scripts/configure.sh`, `config.yml`, `.env`, or other
repo-copy state must NOT carry its own defensive docker-cp/restore logic —
that duplicates what the runner already guarantees under `--reset-between`
and silently masks a reset regression instead of failing loudly. Rely on the
runner reset and make sure the scenario only runs in a `--reset-between`
battery (`tests/battery.sh`'s glob-discovered `MAIN` set, or
`tests/check.sh`'s wizard tier via `tests/ci-scenarios.sh`).

## Existing-install image checks

`upgrade-path` boots the accepted lock, records persistent users and settings, then
runs the real update script against exact candidate overrides. It checks persistence,
safe reconfiguration and the launcher's qBittorrent Update/Revert functions. Every
state check also requires each stored credential to authenticate on the running
image, and the saved state (`tests/fixtures/upgrade_state.py`) holds fingerprints and
booleans, never a secret. The first check after the update runs before reconfiguration,
which would apply some values again. Before the update the scenario proves that its comparison
detects a changed profile, a deleted Seerr user and a deleted Jellyfin API key. After
the update it runs the Stage 1 Jellyfin probes and the post-Revert login checks again
on the candidate. At least one digest must differ from the accepted lock. See the
[compatibility matrix](../docs/operations/image-compatibility.md) for service coverage
and remaining boundaries.

## Focused staged-setup scenarios

Use these when changing staged setup, recovery hooks, demo mode, destructive reinstall, or fail2ban filters:

```bash
./tests/run.sh smoke stage1-lan stage2-skip stage2-ready remote-after-skip remote-ready-idempotent demo-lan existing-install-nuke fail2ban-drift
```

Scenario catalog. Requirement IDs are historical and not contiguous — a gap means a
requirement is covered outside this suite, not that a scenario is missing.

| Scenario | Requirement | Scope |
|----------|-------------|-------|
| `stage1-lan` | TEST-01 | Stage 1 LAN-only path with blank `DOMAIN`, non-ready remote state, Jellyfin LAN response, no public proxy, no GPU state. |
| `stage2-ready` | TEST-02 | Fixture DNS/Pebble ready path; proves proxy/cert postconditions and `REMOTE_WEB_STATE=ready`. |
| `stage2-skip` | TEST-03 | Skipped HTTPS path; proves LAN URLs and no ready-only proxy publication. |
| `remote-after-skip` | TEST-04 | Public `./setup.sh --remote` after skipped state, with fixture DNS/Pebble, reaches ready postconditions. |
| `remote-ready-idempotent` | TEST-05 | Public `./setup.sh --remote` after ready state preserves ready proxy/cert postconditions. |
| `wireguard-add-after-https` | Issue #98 | `./setup.sh --wireguard` on a ready-HTTPS install with UFW on: declining changes nothing, accepting starts wg-easy with the chosen tier and UFW rules, and a re-run keeps credentials and peers. |
| `wizard-ui-features-add-wireguard` | Issue #98 | Image-free PTY drive of Features & settings → **Add WireGuard VPN**: the row, the decline path (files unchanged) and the accept path. |
| `demo-lan` | TEST-06 | Current `DEMO=1` Stage-1/LAN-safe contract; no full unattended remote or GPU setup. |
| `existing-install-nuke` | TEST-07 | Existing-install wipe menu plus exact `DESTROY`; all-profile compose down is used; data bind-mount sentinel survives reinstall. |
| `drift-recovery` | #105 | Finished Jellyfin, Sonarr, Radarr and qBittorrent install with stale persisted configuration. Follows each drift notice's keep and reapply routes, shows `down -v` keeps `config/`, and proves Uninstall removes it while media stays. Needs service images. |
| `fail2ban-drift` | TEST-09 | Focused regex drift checks for `jellyfin`, `seerr`, `npm`, and `npm-ratelimit`. |

Boundary: these are DinD proofs. `stage2-ready`, `remote-after-skip`, and `remote-ready-idempotent` use fixture DNS and Pebble, not public WAN. Real public DNS, DDNS updates, WAN firewall behavior, and real Let's Encrypt HTTP-01 are proven by the separately invoked `tests/gcp-vm/` harness.

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

### Live browser access via socat

DinD services listen on the container's internal IP, unreachable from a browser
on another machine. Forward ports from the host with `socat`. Since the host
may already run production MediaStack on the standard ports, use a +10000
offset to avoid collisions:

```bash
DIND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ms-test-dind)

for port in 8096 8989 7878 9117 8080 5055 3000 3001 9000 81 8090; do
    host_port=$((port + 10000))
    socat TCP-LISTEN:${host_port},fork,reuseaddr TCP:${DIND_IP}:${port} &
done
```

Then access services at `http://<host-ip>:<port+10000>` — e.g. Jellyfin at
`18096`, Sonarr at `18989`, Radarr at `17878`, Seerr at `15055`, qBittorrent at
`18080`, Jackett at `19117`, Portainer at `19000`, NPM at `10081`, Homepage at
`13000`, Uptime Kuma at `13001`, Beszel at `18090`. Credentials are in the
DinD's `.env` — all services share `JELLYFIN_ADMIN_PASSWORD`; NPM and Beszel
use `NPM_ADMIN_EMAIL` as the username, everything else uses
`JELLYFIN_ADMIN_USER` (default `admin`).

```bash
pkill -f 'socat.*TCP:.*fork'   # clean up forwarders when done
docker rm -fv ms-test-dind
```

## Targeted configure.sh re-runs

`configure.sh` accepts `--only svc1,svc2,...` to run only the named services (docker-compose names). The test suite uses this for re-run assertions (encoding, drift, idempotency) so they don't pay the cost of all 14 services each time.

Service names match docker-compose: `qbittorrent`, `jackett`, `sonarr`, `radarr`, `bazarr`, `jellyfin`, `seerr`, `portainer`, `homepage`, `npm`, `ddns-updater`, `uptime-kuma`, `beszel`.

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

1. **Pull-through registry mirror** (`ms-registry-mirror` container on the Docker bridge gateway, usually `172.17.0.1:5000`). Image `ghcr.io/distribution/distribution:3.0.0` — sourced from GHCR, not Docker Hub, since bootstrapping a mirror *from* the rate-limited registry it exists to bypass would be circular. Started on demand by `tests/run.sh`. Configured as a mirror for `registry-1.docker.io` via `REGISTRY_PROXY_REMOTEURL`. DinD's inner dockerd points at it via `--registry-mirror=http://host.docker.internal:5000`. First pull of any image hits Hub once and caches in the `ms-registry-cache` Docker volume; every subsequent DinD run is free. Treated as **transitory dev infrastructure** (`--restart no`) — auto-starts when you run tests and is removed on normal runner exit, even when a previous test left it running. The volume persists across teardowns so the cache is intact next session. Set `MS_CACHE_MIRROR_KEEP=1` to leave only the mirror container running between normal test exits.
   The mirror binds on the bridge gateway (not localhost) so DinD's nested containers can reach it, with no auth — on a shared dev host another container on that bridge could poison the cache. Mitigated by the transitory lifecycle, but worth knowing. GHCR is a single point of failure for the cache bootstrap: if that image becomes unavailable the mirror can't start and tests fall back to direct Hub pulls.

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
- **Counters are global across scenarios.** Final summary is a sum of all scenarios. A scenario that silently bypasses a `fail` (e.g. `return 1` without calling `fail` first) leaves the counter confused — every exit path should record a result.

Without image overrides, the full battery runs `upgrade-path` as an accepted-image
management check. It pins qBittorrent Update/Revert to the accepted digest and
produces no candidate receipts. With explicit overrides, an unchanged candidate
lock is rejected; only a changed exact combination can produce upgrade evidence.
