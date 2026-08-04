# MediaStack E2E Test Framework

End-to-end tests that run inside a Docker-in-Docker container so your host stays clean after normal runs — no apt-installs, no stray containers, no lingering port bindings. The host-side image cache volume persists by design unless explicitly purged.

DinD is a **Debian-based** image (`ms-dind:debian`, built from `tests/Dockerfile.dind`), matching the production distro. First `./tests/run.sh` invocation builds it (~40s); subsequent runs use the docker layer cache.

> **Three complementary surfaces.** DinD runs everything that happens inside the VM. The operator-run [`gcp-vm/`](gcp-vm/) harness proves real public DNS, DDNS, Let's Encrypt HTTP-01, HTTPS, and WAN firewall behavior on a disposable cloud VM. The [`lan-host/`](lan-host/) harness proves real Debian hardware, UFW/systemd, and GPU passthrough on a dedicated test box. Credentials and target values stay in gitignored local env files; neither live-host harness runs in CI.

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
./tests/run.sh --no-preload wizard-ui-stage1-local wizard-ui-stage1-nas-retry  # core PTY wizard UX checks
./tests/run.sh smoke remote-gating npm-heal  # focused remote-state gate
./tests/run.sh smoke remote-gating npm-heal ddns-seed wireguard wireguard-server wireguard-containers wireguard-streaming stage2-skip stage2-ready  # focused remote-access gate
./tests/run.sh --keep fresh-install  # leave DinD running on failure for debugging
./tests/run.sh --no-preload <scenario>  # skip host image sideload for lightweight scenarios
```

Exit code is non-zero if any hard assertion failed. `[SKIP]` lines never fail.

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

The driver + fidelity stubs live in `scripts/lib/dry_run.sh`; `tests/unit/dry-run.sh`
asserts the safety invariants (no bind mount, `--network none`, non-root,
recursion guard) and walks the launcher when Docker is available.

## Linting

`./tests/lint.sh` is the shell lint runner (shellcheck). Config and the curated
false-positive suppressions live in `.shellcheckrc` (repo root), so the runner
needs no special flags — and neither do you.

```bash
./tests/lint.sh                          # lint every tracked *.sh + mediastack (--severity=warning, matches CI)
./tests/lint.sh scripts/lib/validators.sh  # lint only the named file(s)
./tests/lint.sh --severity=error         # stricter: only fail on errors
```

It prefers a native `shellcheck` at the pinned version, then the sha256-verified
cached pin (`./tests/lint.sh install`, fetched per `tools.toml [shellcheck]`), and
falls back to the pinned `koalaman/shellcheck:v0.11.0` docker image — the analysing
engine is identical on every rung.
The default severity is `--severity=warning` — the same gate CI's
`lint-shellcheck` job uses via `./tests/check.sh lint`.
A bare `./tests/lint.sh` therefore gives the same pass/fail result as CI; no flag needed.

Repo-wide suppressions live in `.shellcheckrc`, with a reason beside each one.
Keep shared architectural suppressions there instead of scattering inline
directives through individual files.

### Fast tier for the two expensive roots

`tests/unit/wizard-flow.sh` (1m45s) and `mediastack` (47s) are pathological
ShellCheck roots — the rest of the tree lints in under two seconds each. While
iterating on either file, pass `--extended-analysis=false` to cut them to 22s
and 18s respectively:

```bash
./tests/lint.sh --extended-analysis=false tests/unit/wizard-flow.sh
./tests/lint.sh --extended-analysis=false mediastack
```

This is a speed convenience for the edit loop on those two files, not a
weaker gate:

```
fast touched-file check  → quick feedback
full touched-root check  → pre-handoff confidence
full whole-tree check    → CI authority
```

Never add `--extended-analysis=false` to `.shellcheckrc` or a CI job — it
must stay an explicit, opt-in flag on those two files, never a default.

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
- Sonarr + Radarr indexer wiring is checked against whatever `config.yml` lists — the default ships `indexers: []`, so this is a no-op skip here; `wizard-presets.sh` is the scenario that actually seeds indexers (via the opt-in public-indexer preset) and exercises the FlareSolverr cold-start retry path, against real Cloudflare-protected trackers, so it is not a deterministic image-drift oracle for FlareSolverr — see `docs/operations/upgrades.md` "FlareSolverr — confidence boundary".
- Quality definitions were tightened from upstream defaults (HDTV-720p preferredSize on Sonarr, Bluray-1080p preferredSize on Radarr — both differ noticeably from stock; no Remux-1080p ships at all — see [quality bounds](../docs/reference/quality-bounds.md)).
- `SONARR_API_KEY`, `RADARR_API_KEY`, `JELLYFIN_API_KEY`, and ready-state `REMOTE_WEB_STATE` are back-populated into `.env`.

Total: 46 hard assertions at current scope.

If you add new assertions that detect a known `configure.sh` bug, use `skip` with a bug-ref so the scenario still runs. Convert back to `pass`/`fail` once the bug is fixed.

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

Most services have no dedicated scenario — use `fresh-install` (which does **not** start the `remote`/wireguard or `subtitles`/bazarr profiles; those use `wireguard` and `bazarr`). Autoheal uses its own focused `autoheal` scenario because a running-state check cannot prove a heal. `docs/operations/upgrades.md` lists each
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

```bash
./tests/unit.sh        # static validation + every host unit
```

Current units:

- **gpu-branching** — exercises `detect_gpu`, `check_secure_boot`, `verify_gpu_usable` from `scripts/setup/gpu.sh` by shimming `lspci`/`mokutil`/`nvidia-smi`/`docker` and render-device helpers as in-shell functions. Catches regressions in GPU selection logic, including no-GPU `set -e` behavior and vendor-aware Intel/AMD render-node routing, without needing real hardware.
- **qbittorrent** — checks qBittorrent login form encoding, first-run temp-password handling, shared-admin credential alignment, manual-storage behavior, and the reusable live assertion parser.
- **portainer** — checks Portainer auth drift handling, including a warning when admin auth returns no JWT and the normal endpoint/API-token setup path when auth succeeds.
- **bazarr** — checks Bazarr config-file write success/failure handling without needing a running Bazarr container.
- **jellyfin** — checks Jellyfin library creation logging for successful and failed API POSTs without needing a running Jellyfin container.
- **api-matrix-jellyfin** — deterministically checks the api-matrix Jellyfin VirtualFolders helper retries transient failures, preserves successful JSON, and stops after five failed requests without requiring DinD.
- **seerr** — checks Sonarr/Radarr connection payload profile lookup with quoted/backslash profile names.
- **json-helpers** — exercises `json_get`, `json_path`, `json_has_name`, `json_array_nonempty` from `scripts/lib/json.sh` with representative inputs (missing keys, nested paths, case-insensitive matching, empty/invalid JSON).
- **common** — exercises shared `.env` API-key persistence helpers, including values with `&`, `|`, `/`, append behavior, sourceability, and rejection of unsupported newline/quote values.
- **gcp-wan-ports** — keeps the GCP external blocked-port probe aligned with the Docker LAN-only port set enforced by `scripts/setup/hardening.sh`.
- **image-drift** — verifies that digest acceptance requires a frozen `--current-file`, preventing maintainers from recording a tag digest that was not the one preflighted; also checks the generated README Stable-baseline badge stays derived from the lock file.
- **manage-updates** — covers the day-2 "Manage updates" feature: `override.sh` per-service policy (floating one service drops only its digest pin; clearing re-pins; global-latest pins nothing), `image-drift.py --status` channel-agnostic 2-state truth table and hardened running-digest extraction, and the launcher's apply/flip/revert helpers (a pinned service floats to its tag decided by effective channel, not status text; WireGuard exclusion from "Update all"). Sources `mediastack` + `override.sh`; pure bash + python3, no Docker/network.
- **launcher-hardware / nvidia-maintenance** — cover the day-2 hardware surface, Unlock-only visibility/dispatch guards, default-No cancellation, resolve-before-stop ordering, unload failure cleanup, one installer/toolkit execution, and expected-version marker persistence. Pure bash; no Docker/network.
- **launcher-uninstall / uninstall-system-cleanup** — cover launcher routing/result reporting, root-only ledger reads, selective UFW/APT/sysctl/Samba cleanup, teardown failure rollback, and Stage 3 routing precedence.
- **test-runner** — checks that `tests/run.sh` rejects empty or truncated scenario files instead of reusing a stale `run_scenario`.
- **lint-sweep** — checks the `tests/lint.sh` single-sweep contract against a fixture repo with a stub shellcheck: the sweep is invoked exactly once over the whole discovered file list, covers every file in it, and still propagates a non-zero result. Pure bash + git, no Docker and no network; run directly with `./tests/unit/lint-sweep.sh`.
- **wizard-prompts** — guards the shared wizard-prompt SSOT (`tests/lib/wizard_prompts.json`): every regex compiles, the step-builder (`wizard_steps_build.py`) renders name/`@timeout`/`ENTER`/`NONE` and rejects unknown names, no `wizard-ui-*` scenario that builds from the SSOT re-inlines a prompt regex or references an undefined name, and any scenario calling the builder sources a lib that defines it.
- **remote-web-state** (`tests/unit/remote-web-state.sh`) — exercises `write_env()` remote marker rules and `print_access_info` output for unchecked, ready, skipped, and LAN-only states.
- **ddns-config** — exercises the shared DDNS provider registry + `config.json` renderer (`scripts/lib/ddns_providers.sh`): all 6 providers render valid typed JSON (Cloudflare `ttl`/`proxied` typed, dynv6 carries no inert `ipv4` key), missing/unknown inputs fail, the Dynu render stays byte-identical to the inline writer it replaced, and the registry accessors (`pick`/`fields`/`verify_tier`/`category`) map correctly. No credentials.
- **stage2-domain** — exercises domain/DNS classification, Cloudflare proxy detection, and safe routing before publication.
- **stage2-ports** — exercises local port checks and failure classification without claiming public WAN reachability.
- **stage2-wireguard** — exercises the access-tier env mapping (Full LAN / Server / Containers / Streaming / Streaming + requests) plus `detect_lan_cidr` normalization. Tier semantics: [VPN access tiers](../docs/setup/configuration-schema.md).
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
- **repository-safety** — fixture proof for `tests/lib/repo_guard.py`, the publication-safety guard: forbidden private artifacts, tracked host artifacts, secret files and credential patterns, and config/workflow YAML validity. Exit codes are `0` clean, `1` findings, `2` guard error — an unreadable file, an empty population or an empty rule list is a guard error, never a silent pass. Findings print `<RULE-ID>`, path and detail, and never echo the matched text: a credential finding names the pattern and the line number, not the value. Rules split by population — host artifacts and content scanning read the git index; the private-directory, analyzer-cache, log and secret-file rules read the working tree, because a gitignored `.ua/` is invisible to `git ls-files` and an untracked private key can still be `git add`-ed later. Worktree rules skip the gitignored live-install state that the host-artifact rule already rejects in the index, so a real install is not a wall of findings. History is out of scope: the guard reads the tree as it stands. Every entry of every rule list has its own probe fixture and an `EXPECTED_*` set assertion, so deleting one turns the suite red. Pure bash + python3 + git, no Docker and no network; run directly with `./tests/unit/repository-safety.sh`.
- **secret-scan** — regression proof for `tests/secret-scan.sh`, the pinned gitleaks wrapper: the `0`/`1`/`2` exit-code contract, both scan modes, and every guard that stands between a weakened scan and a confident "clean". Covers the canary self-test (an emptied ruleset, a catch-all allowlist and a single disabled rule all fail closed), the `binary_sha256` check, the `.gitleaksignore` pre-flight on disk and in history, the bytes-scanned and commits-scanned guards, symlinked and real scan roots agreeing, archive traversal, merge-resolution content, commit and annotated-tag messages, and redaction. Fixtures are temp dirs and temp git repos; canary literals are assembled at runtime from split halves so the file is not itself a finding, and only rule IDs are asserted on. Also covers the two blocking `gate-*` modes: a missing or declaration-free expectation file is an error, an undeclared finding and a declaration nothing produced both fail, one declaration file satisfies both modes, an edit that moves a finding's line does not invalidate it, and a substituted secret at the same rule, path and finding count does. It **fails closed rather than skipping** when the scanner is missing, and calls `secret-scan.sh install` itself — idempotent on a warm cache, one network fetch on a cold one. Pure bash + python3 + git, no Docker; run directly with `./tests/unit/secret-scan.sh`.
- **docs** — contract suite for the public control surface: `LICENSE`, `README.md`, `CONTRIBUTING.md`, `docs/README.md`, `.github/SECURITY.md` and `.github/ISSUE_TEMPLATE/`. Asserts each one exists, that every file under `.github/ISSUE_TEMPLATE/` parses as YAML — the whole file for `.yml`/`.yaml`, the front matter for a markdown template — using the same `yaml.safe_load` mechanism `repo_guard.py` uses, and that the chooser's `config.yml` carries a contact link whose name or `about` text names security, and whose URL is a known private GitHub route (`security/policy`, `security/advisories/new`) backed by a file that exists here. The route is matched on the URL path tail, not the literal URL, so an org or repo rename does not break it. Every relative markdown link in the control files must resolve; that scope is deliberate — a tree-wide link check is separate work. `CONTRIBUTING.md` must exist exactly once in the tree, at the repository root, so a second copy under `.github/` fails. Fails closed on the declared control-file list, the issue-template population and the link population: an empty population is a failure, not a vacuous pass. `MS_TEST_DOCS_ROOT` points it at a fixture tree instead of the real repository. Pure bash + python3, no Docker and no network; run directly with `./tests/unit/docs.sh`.
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
cache.

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
./tests/check.sh fast     # static tier: shellcheck, shfmt, ruff, mypy, secrets.
./tests/check.sh full     # default + the complete DinD battery (tests/battery.sh)
./tests/check.sh install  # one-time per machine: fetch + verify every pinned dev
                          # tool (shellcheck, shfmt, gitleaks) into the local cache
```

Stages run in the documented order and stop at the first failure, naming the tier and
the exact underlying command so it can be re-run in isolation. It wraps the runners
below; it does not reimplement their file discovery or logic:

- **fast** — `./tests/lint.sh --severity=warning` (shellcheck), `./tests/format.sh check`
  (shfmt), the pinned ruff lint + format check, the pinned mypy invocation, and the
  pinned gitleaks over this repository's tree — all five from `tools.toml`. It starts
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
| `demo-lan` | TEST-06 | Current `DEMO=1` Stage-1/LAN-safe contract; no full unattended remote or GPU setup. |
| `existing-install-nuke` | TEST-07 | Existing-install wipe menu plus exact `DESTROY`; all-profile compose down is used; data bind-mount sentinel survives reinstall. |
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
