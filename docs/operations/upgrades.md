# Upgrades — per-service pin policy & candidate-image preflight

How to reason about bumping a container image. **`docker-compose.yml` is the single source of
truth for image tags** — this file records the *policy* (why a service is pinned or floats), how to
*preflight* a candidate image before editing compose, and where that service is configured. It does
**not** repeat the literal tag.

MediaStack has a scheduled image-drift alert, but image-upgrade confidence still comes from
local/manual DinD scenarios via `./tests/run.sh` (see `docs/project/stack.md`). `docs/operations/image-digests.lock` records
the exact remote digests last accepted by
maintainers. The setup wizard defaults users to the Stable channel, which pins runtime image refs to
that lock file through the generated `docker-compose.override.yml`. The table below is kept honest
by `tests/unit/upgrades-manifest.sh`, which fails if a service is missing a row or if a row's
recorded pin policy disagrees with the live compose tag.

## Pin policy & recovery model

Compose tags remain readable and selective (ADR-24): `latest` is acceptable where the integration
surface is low-risk or covered by tests; major/exact pins are used where an upstream major has broken
us or the API is unstable. Stable-channel installs do not float at runtime: setup generates
`image: tag@sha256:digest` overrides from `docs/operations/image-digests.lock`. Latest-channel installs opt
back into raw compose tags. When an upgrade outruns what the configurator supports, the recovery
model is **clean cutover** (Invariant 2): `docker compose down -v && ./setup.sh --full`. There is no
in-place multi-version support.

## User-facing per-service overrides (ADR-30)

The day-2 `./mediastack` → **Manage updates** menu lets a user float one service from its tested
Stable digest to its compose tag, recorded in the gitignored `config/state/image-policy.tsv`
(`service<TAB>stable|latest`). This is **user intent, not a maintainer signal** — it never edits
`docs/operations/image-digests.lock`. The lock stays the tested record; `_effective_channel`
(`scripts/setup/override.sh`) layers the per-service override on top of the global `IMAGE_CHANNEL`
when generating the compose override. A floated service follows its **compose tag**, so the pin
policy in the manifest below still bounds it (a `major:N` service stays within major N; an
`exact-patch` service can't move). See `docs/operations/day-2.md` for the menu and status semantics.

## Preflight a candidate image (no compose edit, test-only)

Swap a candidate tag into the **DinD copy** of compose (the host file is never touched) and run that
service's oracle:

```
MS_TEST_IMAGE_OVERRIDES="wireguard=ghcr.io/wg-easy/wg-easy:16.0.0" ./tests/run.sh wireguard
```

`MS_TEST_IMAGE_OVERRIDES` takes `svc=ref` pairs (comma/space separated); a typo (unknown service,
empty ref) aborts the run. See the "Bumping a Service Version" playbook in `docs/project/structure.md`.

**Caveat:** preflight only checks API **shape** via the service's scenario/assertions oracle (most
use `tests/assertions/<svc>.sh`; wireguard and npm assert inline; ddns-updater and beszel-agent are
start+healthcheck / running-state only). It does **not** catch config-time / env-contract breaks (e.g. the wg-easy
`INIT_PASSWORD`/`wgpw` shift). For a major or API-unstable bump, run the service's **own** battery
plus `fresh-install` where relevant — note `fresh-install` does **not** start the `remote`
(wireguard) or `subtitles` (bazarr) profiles, so those need their own scenarios. Services marked
`compose-only` / `manual` have no automated oracle — verify by hand.

## CI image drift alert

The `Image Drift Alert` GitHub workflow runs weekly and on demand. It resolves each compose image tag
to its current remote digest with `scripts/image-drift.py`, compares that with
`docs/operations/image-digests.lock`, and fails when a tag moved.

This is an alert only:

- It does not pull image layers.
- It does not start the stack.
- It does not run DinD in GitHub Actions.

When it fails, run the affected service's local DinD preflight from the workflow summary. The command
uses `MS_TEST_IMAGE_OVERRIDES` with the exact new digest so the test is not fooled by stale local or
mirror-cached `:latest` tags. Before preflight, freeze the current digest snapshot locally:

```bash
mkdir -p .tmp
python3 scripts/image-drift.py --snapshot-current .tmp/image-digests.current.tsv
python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv
```

After every affected preflight passes, accept the same snapshot and commit
`docs/operations/image-digests.lock`:

```bash
python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current
```

Stable-channel users receive those newly accepted digests after updating the repo and running
`./scripts/update.sh`. Latest-channel users may already be running the moved upstream digest.

See `docs/operations/image-updates.md` for the full maintainer workflow.

## Manifest

Columns parsed by the unit test use strict tokens; **do not put `|` inside any cell.**
**Pin policy** ∈ `latest` · `major:N` · `exact-patch` · `variant:<tag>`.
**Preflight** ∈ `scenario:<name>` · `unit:tests/unit/<file>.sh` · `compose-only` · `manual`.
**API stability** and **Touchpoint** are human prose (not machine-checked).

<!-- upgrades-manifest:start -->

| Service | Pin policy | API stability | Preflight | Touchpoint | ADR |
|---|---|---|---|---|---|
| autoheal | latest | n/a | compose-only | compose-only | ADR-24 |
| bazarr | latest | stable | manual | scripts/services/bazarr/main.sh (subtitles profile — not started by fresh-install, no automated oracle) | ADR-24 |
| beszel | latest | stable | scenario:fresh-install | scripts/services/beszel/main.sh + tests/assertions/beszel.sh | ADR-24 |
| beszel-agent | variant:alpine | stable | scenario:fresh-install | configured indirectly via beszel; tests/assertions/beszel.sh checks running-state only (no API assertion) | ADR-24 |
| ddns-updater | latest | stable | scenario:ddns-seed | scripts/services/ddns-updater/main.sh + tests/scenarios/ddns-seed.sh | ADR-24 |
| fail2ban | latest | stable | scenario:fail2ban-drift | config/fail2ban/ + tests/assertions/fail2ban.sh | ADR-24 |
| flaresolverr | latest | n/a | compose-only | compose-only | ADR-24 |
| homepage | latest | stable | scenario:fresh-install | scripts/services/homepage/main.sh + tests/assertions/homepage.sh | ADR-13, ADR-24 |
| jackett | latest | stable | scenario:fresh-install | scripts/services/jackett/main.sh + tests/assertions/jackett.sh | ADR-24 |
| jellyfin | latest | stable | scenario:fresh-install | scripts/services/jellyfin/main.sh + tests/assertions/jellyfin.sh | ADR-11, ADR-12, ADR-24 |
| jellyseerr | latest | stable | scenario:fresh-install | scripts/services/jellyseerr/main.sh + tests/assertions/jellyseerr.sh | ADR-24 |
| npm | major:2 | major-gated | scenario:npm-heal | scripts/services/npm/main.sh + tests/assertions/npm.sh | ADR-21, ADR-24 |
| portainer | latest | stable | scenario:fresh-install | scripts/services/portainer/main.sh + tests/assertions/portainer.sh | ADR-24 |
| qbittorrent | latest | stable | scenario:fresh-install | scripts/services/qbittorrent/main.sh + tests/assertions/qbittorrent.sh | ADR-6, ADR-24 |
| radarr | latest | stable | scenario:fresh-install | scripts/services/radarr/main.sh + tests/assertions/radarr.sh | ADR-24 |
| sonarr | latest | stable | scenario:fresh-install | scripts/services/sonarr/main.sh + tests/assertions/sonarr.sh | ADR-24 |
| unpackerr | latest | n/a | compose-only | compose-only | ADR-24 |
| uptime-kuma | major:2 | major-gated | scenario:fresh-install | scripts/services/uptime-kuma/main.sh + tests/assertions/uptime_kuma.sh | ADR-14, ADR-24 |
| wireguard | major:15 | unstable | scenario:wireguard | scripts/services/wireguard/main.sh + tests/unit/wireguard-service.sh + wireguard scenarios | ADR-24, ADR-28, ADR-29 |

<!-- upgrades-manifest:end -->
