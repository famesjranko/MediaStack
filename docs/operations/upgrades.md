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

Compose tags remain readable and selective: `latest` is acceptable where the integration
surface is low-risk or covered by tests; major/exact pins are used where an upstream major has broken
us or the API is unstable. `stable`/`latest` is an **install-time** choice: a Stable install
generates `image: tag@sha256:digest` overrides from `docs/operations/image-digests.lock` (the
versions the installer was tested against), a Latest install installs raw compose tags. Post-install
a service stays on its installed image until the user updates it from the day-2 menu — there is no
auto-updater. When an upgrade outruns what the configurator supports, the recovery model is **clean
cutover**: `docker compose down -v && ./setup.sh --full`. There is no in-place
multi-version support.

## User-facing per-service updates

The day-2 `./mediastack` → **Manage updates** menu lets a user update one service to the newest image
for its compose tag, recorded as a sticky `latest` override in the gitignored
`config/state/image-policy.tsv` (`service<TAB>stable|latest|<image>@sha256:<digest>` — a digest value
pins the service to its installed image for "Revert"). This is **user intent, not a
maintainer signal** — it never edits `docs/operations/image-digests.lock`. The lock stays the tested
record; `_effective_channel` (`scripts/setup/override.sh`) layers the per-service override on top of
the global `IMAGE_CHANNEL` when generating the compose override. An updated service follows its
**compose tag**, so the pin policy in the manifest below still bounds it (a `major:N` service stays
within major N; an `exact-patch` service can't move). "Revert a service to its installed image"
re-pins the service to its recorded install digest (falling back to clearing the override if none was
recorded). See `docs/operations/day-2.md` for the menu and status semantics.

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
(wireguard) or `subtitles` (bazarr) profiles, so those use dedicated scenarios. Services marked
`compose-only` / `manual` have no automated oracle — verify by hand.

**What a green `fresh-install` preflight proves — and what it does not.** It boots the full
default-profile stack, runs the real `scripts/configure.sh` (which must exit 0), and reads back each
service's live API to assert the resulting configuration matches `config.yml`/`.env`. So it is a deep
test of the **configurator's write/read contract** against the candidate image — the drift class that
bites most often (an image whose API schema shifts breaks `configure.sh` or a shape assertion). It
also exercises a few live integration paths: qBittorrent WebUI login, Jackett per-indexer `t=caps`,
and an arr→qBittorrent `downloadclient/testall` connect (proves Sonarr/Radarr actually authenticate
to the download client, not just that the client object is shaped right). It does **not** exercise the
media pipeline end to end: no release search, grab, import, rename, Jellyfin media scan, or VPN
routing. Those depend on live trackers and real downloads and are non-deterministic in hermetic DinD,
so they are deliberately excluded — a flaky preflight maintainers learn to ignore is worse than an
honest, narrower one. Read a green preflight as *"boots + configures + connects to its download
client"*, not *"every user workflow works"*.

**fail2ban filters are re-verified when you preflight jellyfin or seerr.** Both are
`scenario:fresh-install`, and `fresh-install.sh` runs `assert_fail2ban_configured`, which
active-probes a real auth failure and confirms that service's fail2ban filter still matches the
**candidate** image's log format. So a jellyfin/seerr log-format change that would silently stop
brute-force bans is caught at preflight, before the digest reaches the stable baseline — this is the
**only** automated signal for that break. fail2ban's own `scenario:fail2ban-drift` row uses static
fixture logs, so it guards the fail2ban engine/filters against a *fail2ban* image bump but does
**not** see a jellyfin/seerr format change. (Vetting-time counterpart of the day-2
"Health & security → fail2ban" check — see [day-2 health & security](day-2.md).)

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

Accepting drifted services is **selective by default**, not all-or-nothing: accept only the rows
whose preflight passed and leave the rest pending until they are fixed, manually verified, or
deliberately deferred.

```bash
python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-services <svc1,svc2,...>
```

`--accept-services` preserves every other row and its timestamp, and refuses if the snapshot adds or
removes a service (full re-baseline needs `--accept-current` instead). Reach for `--accept-current`
only when every drifted service's preflight passed and you want to accept the whole snapshot in one
step:

```bash
python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current
```

**Accept is receipt-gated.** A passing `./tests/run.sh` that applied `MS_TEST_IMAGE_OVERRIDES` records
what it tested to the gitignored `tests/.image-preflight-passed.tsv`. `--accept-services` /
`--accept-current` then refuse to write a drifted digest into the lock unless that receipt vouches for
the exact `image@digest` under the service's manifest scenario — so a digest cannot enter the tested
baseline without a local preflight that actually pulled it and passed. Tiers with no scenario oracle
(`compose-only` / `manual`) warn instead of block; `--no-verify-preflight` overrides the gate for a
hand-verified accept.

Stable-channel users receive newly accepted digests after updating the repo and running
`./scripts/update.sh`. Latest-channel users may already be running the moved upstream digest.

See `docs/operations/image-updates.md` for the full maintainer workflow.

## Manifest

Columns parsed by the unit test use strict tokens; **do not put `|` inside any cell.**
**Pin policy** ∈ `latest` · `major:N` · `exact-patch` · `variant:<tag>`.
**Preflight** ∈ `scenario:<name>` · `unit:tests/unit/<file>.sh` · `compose-only` · `manual`.
**API stability** and **Touchpoint** are human prose (not machine-checked).

These four preflight tokens are not equal confidence. Roughly highest to lowest: a `scenario:`
brings the service up and asserts its configured/API state; a `unit:` check is a narrower,
non-DinD assertion; `compose-only` only proves the tag resolves and parses; `manual` has no
automated oracle at all. Weigh a row's tier, not just whether it "passed", before accepting it —
a `compose-only`/`manual` row carries materially less confidence than a `scenario:`-backed one even
when neither failed.

A passing preflight at the **current** major also does not justify floating a `major:N`-pinned
service past that pin: `npm` (`major:2`), `uptime-kuma` (`major:2`), and `wireguard` (`major:15`)
are pinned because a past major upstream release broke MediaStack's integration with them. Bumping
across one of those majors needs its own deliberate review, not a routine drift-acceptance pass.

### FlareSolverr — confidence boundary

`flaresolverr` is a default-profile service (not profile-gated), so it is brought up and health-waited
by `fresh-install` exactly like the other `scenario:fresh-install` rows in the manifest below — it is
tagged that way, not `compose-only`, because `compose-only` would understate what already happens on
every preflight run: the candidate image pulls, the container starts, and its own healthcheck
(`curl -sf http://localhost:8191/health`) must pass within `start_period`. That already catches an
image that fails to start or whose embedded webserver never comes up.

What makes this row different from its `scenario:fresh-install` siblings is the Touchpoint: theirs
assert real API/config state for their service; this one is deliberately scoped to the health endpoint
only. Its core job — solving a live Cloudflare JS challenge — cannot be made part of that scenario
deterministically: proving it needs an external Cloudflare-protected target, real network reachability
from the test host, and Cloudflare's current challenge/anti-bot policy, none of which MediaStack owns or
controls. So `scenario:fresh-install` for `flaresolverr` proves startup health, not a Cloudflare solve —
treat the two as separate confidence claims even though they share a token.

One existing scenario incidentally drives FlareSolverr against real Cloudflare-protected sites:
`tests/scenarios/wizard-presets.sh` enables the public-indexer preset and then asserts Torznab caps
through Jackett for indexers such as `1337x`, some of which sit behind Cloudflare. That assertion tests
the indexer-preset feature, not the FlareSolverr image — a failure there can just as easily mean an
indexer went down or changed layout, so it must not be read as image-drift coverage for `flaresolverr`.

A deterministic local fixture (e.g. POSTing FlareSolverr's own `/v1` `request.get` command at a
non-Cloudflare local URL) was considered and rejected as an oracle: it would only prove the embedded
Chromium driver can launch and fetch a page, not that the Cloudflare-detection/challenge-solving path —
the part most likely to actually break on an upstream bump — still works. The added test surface is not
worth that little extra confidence, so no dedicated FlareSolverr scenario was added; the health-endpoint
check via `fresh-install` remains the only automated signal, and the Touchpoint cell says so explicitly
rather than implying a stronger guarantee than the check provides.

**Manual verification runbook** — for a maintainer who wants extra live confidence before accepting a
flaresolverr digest bump, beyond the automated preflight:

```bash
# Bring FlareSolverr up (e.g. via fresh-install, or standalone):
docker compose up -d flaresolverr

# Ask it to solve a real Cloudflare-protected page and confirm a clean 200,
# not a challenge/timeout response:
curl -s http://localhost:8191/v1 -H "Content-Type: application/json" -d '{
  "cmd": "request.get",
  "url": "https://<a-known-cloudflare-protected-site>/",
  "maxTimeout": 60000
}' | python3 -c "import sys, json; d = json.load(sys.stdin); print(d['status'], d.get('solution', {}).get('status'))"
```

This step is manual, maintainer-run, and intentionally excluded from CI/DinD — it depends on a live
third-party site and current Cloudflare policy, neither of which this repo can keep deterministic.

<!-- upgrades-manifest:start -->

| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| autoheal | latest | n/a | scenario:autoheal | docker-compose.yml AUTOHEAL_CONTAINER_LABEL=all + tests/scenarios/autoheal.sh — proves Autoheal detects an unhealthy fixture container and restarts it (fresh-install only proves the container starts/runs, not that it acts) |
| bazarr | latest | stable | scenario:bazarr | scripts/services/bazarr/main.sh + tests/assertions/bazarr.sh (subtitles profile) |
| beszel | latest | stable | scenario:fresh-install | scripts/services/beszel/main.sh + tests/assertions/beszel.sh |
| beszel-agent | variant:alpine | stable | scenario:fresh-install | configured indirectly via beszel; tests/assertions/beszel.sh checks running-state only (no API assertion) |
| ddns-updater | latest | stable | scenario:ddns-verify | run tests/scenarios/ddns-verify.sh on every bump — it pins the blackhole force-verify contract (RESOLVER_ADDRESS=127.0.0.1:1 -> // update anyway -> real push -> 500 maps to reject) the whole verify rests on; tests/scenarios/ddns-seed.sh still covers seed + startup; qdm12/ddns-updater#780 (?force=true) is the exit ramp if a digest breaks the fall-through; scripts/services/ddns-updater/main.sh |
| fail2ban | latest | stable | scenario:fail2ban-drift | config/fail2ban/ + tests/assertions/fail2ban.sh |
| flaresolverr | latest | n/a | scenario:fresh-install | healthcheck only (image pulls, container starts, /health passes); no deterministic Cloudflare-solve oracle, see "FlareSolverr — confidence boundary" above |
| homepage | latest | stable | scenario:fresh-install | scripts/services/homepage/main.sh + tests/assertions/homepage.sh |
| jackett | latest | stable | scenario:fresh-install | scripts/services/jackett/main.sh + tests/assertions/jackett.sh |
| jellyfin | latest | stable | scenario:fresh-install | scripts/services/jellyfin/main.sh + tests/assertions/jellyfin.sh + fail2ban filter (assert_fail2ban_configured) |
| seerr | latest | stable | scenario:fresh-install | scripts/services/seerr/main.sh + tests/assertions/seerr.sh + fail2ban filter (assert_fail2ban_configured) |
| npm | major:2 | major-gated | scenario:npm-heal | scripts/services/npm/main.sh + tests/assertions/npm.sh |
| portainer | latest | stable | scenario:fresh-install | scripts/services/portainer/main.sh + tests/assertions/portainer.sh |
| qbittorrent | latest | stable | scenario:fresh-install | scripts/services/qbittorrent/main.sh + tests/assertions/qbittorrent.sh |
| radarr | latest | stable | scenario:fresh-install | scripts/services/radarr/main.sh + tests/assertions/radarr.sh |
| sonarr | latest | stable | scenario:fresh-install | scripts/services/sonarr/main.sh + tests/assertions/sonarr.sh |
| unpackerr | latest | stable | scenario:unpackerr | docker-compose.yml unpackerr environment (UN_SONARR_0_*/UN_RADARR_0_*) + tests/scenarios/unpackerr.sh — proves generated-key/authenticated completed-Radarr-queue → configured torrent-path archive extraction; does not prove a live qBittorrent transfer or Arr import |
| uptime-kuma | major:2 | major-gated | scenario:fresh-install | scripts/services/uptime-kuma/main.sh + tests/assertions/uptime_kuma.sh |
| wireguard | major:15 | unstable | scenario:wireguard | scripts/services/wireguard/main.sh + tests/unit/wireguard-service.sh + wireguard scenarios |
<!-- upgrades-manifest:end -->
