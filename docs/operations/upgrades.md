# Upgrades — per-service pin policy & candidate-image preflight

How to reason about bumping a container image. **`docker-compose.yml` is the single source of
truth for image tags** — this file records the *policy* (why a service is pinned or floats), how to
*preflight* a candidate image before editing compose, and where that service is configured. It does
**not** repeat the literal tag.

MediaStack has a scheduled image-drift alert, but image-upgrade confidence still comes from
DinD scenarios via `./tests/run.sh` or the
[hosted preflight](hosted-image-preflight.md). `docs/operations/image-digests.lock` records
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
auto-updater. If an updated service cannot use its database, first use **Manage updates →
Revert a service to its installed image**. Revert can restore the saved service configuration
when a restore point exists. `docker compose down -v && ./setup.sh --full` does not resolve an
incompatible database: service configuration and databases are bind-mounted under `config/`, and
setup can skip a completed installation. For a clean reinstall, back up the configuration you
need, run **Uninstall MediaStack** from `./mediastack`, then run `./setup.sh --full`. Uninstall
removes runtime `config/` (service databases, settings, and credentials), `.env`, and `config.yml`;
media at the configured data path remains. See [Remove MediaStack](../guide/install.md#remove-mediastack)
for the complete removal list. There is no in-place multi-version support.

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
recorded).

When a service moves off its install image, MediaStack saves a **restore point** while the old
container is stopped and the new one has not started (a running database is never copied): a
size-bounded (256 MiB) archive of `config/<service>` (never the media or download paths) in
`config/state/restore-points/`, indexed in `config/state/restore-points.tsv`. A service already
floated keeps its first point, because Revert returns to the install image. Revert stops the
service, puts the old config back with the old image, then checks that the service is healthy
and, for qBittorrent, Sonarr, Radarr and Jellyfin, that MediaStack can still log in. A failed
check is reported as a failure and the restore point is kept. Before qBittorrent restores a point
with the newer `[WebUI]` whitelist layout onto a 5.2.x image, it warns that the whitelist will not
take effect and Sonarr and Radarr will get 403; update qBittorrent again to recover. It also warns
when the target image metadata cannot be inspected or is not a usable version. With no restore point (config over
the size limit, or an update from before this feature), Revert warns that the config may be newer
than the image and asks for confirmation. The Revert list shows installed services with an
explicit manual override, regardless of whether their image currently differs from the install
digest. "Update all" skips stopped services and names them; "Update a service" can
still stage one. See `docs/operations/day-2.md` for the menu and status semantics.

## Preflight a candidate image (no compose edit, test-only)

Swap a candidate tag into the **DinD copy** of compose (the host file is never touched) and run that
service's oracle:

```
MS_TEST_IMAGE_OVERRIDES="wireguard=ghcr.io/wg-easy/wg-easy:15@sha256:<digest>" ./tests/run.sh --reset-between wireguard wireguard-upgrade
```

`MS_TEST_IMAGE_OVERRIDES` takes `svc=ref` pairs (comma/space separated); a typo (unknown service,
empty ref) aborts the run. See the "Bumping a Service Version" playbook in `docs/project/structure.md`.

**Contract drift is checked against real traffic.** Run a traced scenario (`fresh-install`,
`upgrade-path` or `install-e2e`) with `MS_CONTRACTS_FILE` set and a digest override. The product's
own configurators call each service's API and run each `docker exec`. The run writes
`contracts.json`: which `tests/contracts/*.yml` entries were called on the candidate, their statuses
or exit statuses, and the declared `reads` seen. The hosted preflight applies the
[contract gate](hosted-image-preflight.md#contract-gate) to it. `python3 tests/contracts/replay.py
spec` separately checks that each declared endpoint's method and path still exist in the upstream
OpenAPI spec, for the services that have one (it works offline against a local cache; a fresh spec
fetch needs network). A contract failure on a bump is resolved in the bump PR itself: update the
contract, and any caller, with the pin change, as an accepted-digest update already travels with
the bump. See `tests/README.md` "Contract mocks and drift checks".

**Caveat:** coverage depends on the scenario. Some scenarios verify configuration writes,
environment contracts, authentication, and service interactions. The WireGuard scenario runs its
production configurator and checks the resulting peer policy; DDNS scenarios check resolver
environment wiring, provider responses, and malformed configuration. None establishes complete
compatibility. For a major or API-unstable bump, run the service's **own** battery plus
`fresh-install` where relevant. `fresh-install` does **not** start the `remote`
(wireguard) or `subtitles` (bazarr) profiles, so those use dedicated scenarios. Services marked
`compose-only` / `manual` have no automated oracle — verify by hand.

**What a green `fresh-install` preflight proves — and what it does not.** It boots the full
default-profile stack, runs the real `scripts/configure.sh` (which must exit 0), and checks
configuration through live APIs or files for the services with assertions. This tests many
**configurator write/read contracts** against the candidate image; a service with only a startup
or health assertion has narrower coverage. It also exercises live integration paths: qBittorrent
WebUI login and an arr→qBittorrent `downloadclient/testall` connect (proves Sonarr/Radarr authenticate
to the download client, not just that the client object is shaped right). It does **not** exercise the
media pipeline end to end: no release search, grab, import, rename, Jellyfin media scan, or VPN
routing. Those depend on live trackers and real downloads and are non-deterministic in hermetic DinD,
so they are deliberately excluded — a flaky preflight maintainers learn to ignore is worse than an
honest, narrower one. Read a green preflight as *"boots + configures + connects to its download
client"*, not *"every user workflow works"*. Its assertions read expectations from the
`config.yml` inside DinD and fail closed: an unreadable fixture, a failed API read or a malformed
response is a FAIL, never a zero. `fresh-install` seeds a deterministic Torznab indexer
(`tests/fixtures/torznab/`: a custom Jackett definition plus a static tracker site inside DinD),
so the Jackett caps check, the Sonarr/Radarr registration count, each app's own indexer
connection test and the persisted seed criteria run on every preflight without a public tracker.
`wizard-presets` separately enables the public-indexer preset against real trackers. Seerr's Sonarr/Radarr entries are
checked field by field (container, port, root folder, quality profile, the app's real API key)
and then proved live through Seerr's own `POST /settings/<app>/test` with the stored values.

**fail2ban filters are re-verified when you preflight jellyfin or seerr.** Both are
`scenario:fresh-install`, and `fresh-install.sh` runs `assert_fail2ban_configured`, which
active-probes a real auth failure and confirms that service's fail2ban filter still matches the
**candidate** image's log format. So a jellyfin/seerr log-format change that would silently stop
brute-force bans is caught at preflight, before the digest reaches the stable baseline — this is the
**only** automated signal for that break. fail2ban's own `scenario:fail2ban-drift` row uses static
fixture logs, so it guards the fail2ban engine/filters against a *fail2ban* image bump but does
**not** see a jellyfin/seerr format change. (Vetting-time counterpart of the day-2
"Health & security → fail2ban protection (regex + jails)" check — see
[day-2 health & security](day-2.md).)

The [compatibility matrix](image-compatibility.md) separates fresh configuration,
existing-install migration, management actions and operator-run checks.

## CI image drift alert

The `Image Drift Alert` GitHub workflow runs weekly and on demand. It resolves each compose image tag
to its current remote digest with `scripts/image_drift.py` and compares that with
`docs/operations/image-digests.lock`. The digest checker exits nonzero when a tag moves. The
workflow opens or updates an image-drift issue; drift alone does not fail the workflow.

The alert runs each Monday at 03:17 UTC:

- It does not pull image layers.
- It does not start the stack.
- It does not run DinD in GitHub Actions.

One hour later, at 04:17 UTC, the same workflow runs the
[hosted preflight](hosted-image-preflight.md) for every drifted service that is
not held. It validates the frozen combination and refreshes one rolling digest
PR. The workflow never merges that PR; the maintainer reviews it, approves its CI
run and merges it. A manual dispatch can run either task at any time. See
[Weekly schedule](hosted-image-preflight.md#weekly-schedule).

Users choose **Stable** or **Latest** at install time; see [Install](../guide/install.md) for what each
means to them. For maintainers, Stable costs more: every upstream image update needs a local preflight
before the lock is restamped. Latest users can outrun the tested record.

When drift is reported:

1. Open the workflow summary and note every changed service.
2. Read the service rows in the [Manifest](#manifest) below.
3. Freeze the digest snapshot that will be tested:

   ```bash
   mkdir -p .tmp
   python3 scripts/image_drift.py --snapshot-current .tmp/image-digests.current.tsv
   python3 scripts/image_drift.py --current-file .tmp/image-digests.current.tsv
   ```

4. Run the exact local preflight shown by that snapshot summary. For scenario-backed services, the
   command uses `MS_TEST_IMAGE_OVERRIDES` with the exact new digest, so the test is not fooled by stale
   local or mirror-cached `:latest` tags, for example:

   ```bash
   MS_TEST_IMAGE_OVERRIDES="jellyfin=jellyfin/jellyfin:latest@sha256:<digest>" ./tests/run.sh fresh-install
   ```

   A service whose token is `scenario:X+Y` needs one run per scenario; the summary prints one
   command per scenario. A hosted workflow can write the same grouping as a file:

   ```bash
   python3 scripts/image_drift.py --current-file .tmp/image-digests.current.tsv --preflight-plan .tmp/preflight-plan.json
   ```

   The plan lists the drifted or added services by scenario, each group with its
   `MS_TEST_IMAGE_OVERRIDES` value, and the `compose-only`/`manual`/`unit:` services under
   `pending_non_scenario`.

   Each scenario that passes writes a row to the gitignored `tests/.image-preflight-passed.tsv` for
   every digest override whose service it started from that digest and left running or healthy. A
   `[receipts]` line in the run output names each override that got no row, and why; a failed
   scenario withholds only its own rows. Every row also records the commit the test tree was at
   (`source`, with a `-dirty` suffix when the tree had uncommitted or untracked changes) and a run
   id, printed as `[receipts] run id:` at the start and end of the run. Run the preflight from a
   clean checkout of the commit you will accept at: a `-dirty` row never satisfies the accept.
   Rows written by releases up to v0.2.0 carry no per-scenario evidence, and rows written before
   receipt format v2 carry no source; the accept ignores them and prints how many it skipped. Delete
   `tests/.image-preflight-passed.tsv` once after updating and re-run the preflight before accepting
   a digest.

5. For `compose-only` services, validate compose and review the upstream changelog if the service is
   security-sensitive.
6. For `manual` services, start the relevant profile locally and verify the UI/configurator path by
   hand.
7. If any preflight fails, leave `docs/operations/image-digests.lock` unchanged for that service and
   fix the integration before accepting its digest. This does not block accepting other services that
   did pass.
8. Acceptance is **selective by default**: accept only the services whose preflight passed and leave the
   rest pending until they are fixed, manually verified, or deliberately deferred.

   ```bash
   python3 scripts/image_drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-services <svc1,svc2,...>
   ```

   `--accept-services` preserves every other row and its timestamp, and refuses if the snapshot adds or
   removes a service (full re-baseline needs `--accept-current` instead). Reach for `--accept-current`
   only when every drifted service's preflight passed and you want to accept the whole snapshot in one
   step:

   ```bash
   python3 scripts/image_drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current
   ```

   **Accept is receipt-gated.** `--accept-services` / `--accept-current` require a matching receipt
   for the exact `image@digest` and manifest scenario before writing a drifted scenario-backed row.
   A `scenario:X+Y` token needs a receipt from each scenario. The receipt must come from the commit
   the accept runs against: by default `git rev-parse HEAD` of the lock's repository, or the value
   of `--receipt-source <sha>`. A receipt from another commit, from a `-dirty` tree, or with an
   `unknown` source is refused, and the message says which. `--receipt-run-id <id>[,<id>...]`
   narrows the gate to receipts from those runs (the ids `tests/run.sh` printed). The architecture
   must match the accepting host. A skipped assertion withholds all receipts for that scenario.
   Empty or duplicate scenario requirements are invalid. The receipt
   records that the scenario passed and that the service ran from that digest; it does not prove
   the scenario checks that service's behaviour. Tiers with no scenario oracle (`compose-only` /
   `manual`) warn instead of block; `--no-verify-preflight` bypasses the gate. The tiers are not
   equal confidence (see [Manifest](#manifest)), so weigh the tier, not just pass/fail.

9. Regenerate the README Stable-baseline badge from the accepted lock:

   ```bash
   python3 scripts/image_drift.py --write-readme-badges README.md
   ```

10. Inspect the lock-file diff. Only rows for changed images should get new digests and timestamps,
    unless this is the first validation restamp.
11. Commit the lock-file update with any required code/docs fixes. Stable-channel users receive the
    new tested digests after updating the repo and running `./scripts/update.sh`. Latest-channel users
    may already be running the moved upstream digest.

For the first validation pass, keep the tested digests and the accepted digests identical. To
accept a new remote snapshot, run the relevant scenarios with candidate overrides for each changed
`image@digest`, then accept that frozen snapshot using step 8. Testing the bootstrap lock does not
validate different digests in a current remote snapshot. If only restamping the bootstrap baseline,
run the relevant scenarios with candidate overrides for the lock's exact `image@digest` references,
then restamp the existing lock without replacing its digests:

```bash
python3 scripts/image_drift.py --current-file docs/operations/image-digests.lock --write-current docs/operations/image-digests.lock --restamp-all
```

## Manifest

Columns parsed by the unit test use strict tokens; **do not put `|` inside any cell.**
**Pin policy** ∈ `latest` · `major:N` · `exact-patch` · `variant:<tag>`.
**Preflight** ∈ `scenario:<name>` · `scenario:<name>+<name>` (one receipt per scenario) · `unit:tests/unit/<file>.sh` · `compose-only` · `manual`.
**API stability** and **Touchpoint** are human prose (not machine-checked).

These four preflight tokens are not equal confidence. Roughly highest to lowest: a `scenario:`
normally starts the service and runs its own assertions, which can be limited to health or can
skip; a `unit:` check is a narrower, non-DinD assertion; `compose-only` only proves the tag
resolves and parses; `manual` has no automated oracle. Weigh a row's tier, not just whether it
"passed", before accepting it —
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
| autoheal | latest | n/a | scenario:autoheal | docker-compose.yml AUTOHEAL_CONTAINER_LABEL=all + DOCKER_SOCK (socket-proxy) + tests/scenarios/autoheal.sh — proves Autoheal detects an unhealthy fixture container and restarts it through the socket-proxy (fresh-install only proves the container starts/runs, not that it acts) |
| bazarr | latest | stable | scenario:bazarr+upgrade-path | scripts/services/bazarr/main.sh + tests/assertions/bazarr.sh (subtitles profile); upgrade-path preserves subtitle history, a user language profile, settings, keys and subtitle files before reconfiguration |
| beszel | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/beszel/main.sh + tests/assertions/beszel.sh |
| beszel-agent | variant:alpine | stable | scenario:fresh-install+install-e2e | configured indirectly via beszel; tests/assertions/beszel.sh checks the agent runs and that its container stats reach the hub through the socket-proxy; docker-compose.yml beszel-agent DOCKER_HOST/DOCKER_IMAGE_CHECK — a bump that calls a new Docker endpoint shows up as a 403 in the socket-proxy log |
| ddns-updater | latest | stable | scenario:ddns-verify | run tests/scenarios/ddns-verify.sh on every bump — it pins the blackhole force-verify contract (RESOLVER_ADDRESS=127.0.0.1:1 -> // update anyway -> real push -> 500 maps to reject) the whole verify rests on; tests/scenarios/ddns-seed.sh still covers seed + startup; qdm12/ddns-updater#780 (?force=true) is the exit ramp if a digest breaks the fall-through; scripts/services/ddns-updater/main.sh |
| fail2ban | latest | stable | scenario:fail2ban-drift | config/fail2ban/ + tests/assertions/fail2ban.sh |
| flaresolverr | latest | n/a | scenario:fresh-install+install-e2e | healthcheck only (image pulls, container starts, /health passes); no deterministic Cloudflare-solve oracle, see "FlareSolverr — confidence boundary" above |
| homepage | latest | stable | scenario:fresh-install+install-e2e | scripts/services/homepage/main.sh + tests/assertions/homepage.sh |
| jackett | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/jackett/main.sh + tests/assertions/jackett.sh |
| jellyfin | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/jellyfin/main.sh + tests/assertions/jellyfin.sh + fail2ban filter (assert_fail2ban_configured) |
| seerr | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/seerr/main.sh + tests/assertions/seerr.sh + fail2ban filter (assert_fail2ban_configured) |
| npm | major:2 | major-gated | scenario:remote-gcp | tests/gcp-vm/run-candidate.sh npm — accepted-to-candidate proxy and certificate migration, staging renewal and public HTTPS; [remote runbook](remote-image-preflight.md). npm-heal remains a separate recovery scenario. |
| portainer | latest | stable | scenario:fresh-install+install-e2e+portainer-upgrade | scripts/services/portainer/main.sh + tests/assertions/portainer.sh |
| qbittorrent | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/qbittorrent/main.sh + tests/assertions/qbittorrent.sh |
| radarr | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/radarr/main.sh + tests/assertions/radarr.sh |
| socket-proxy | major:1 | major-gated | scenario:fresh-install+install-e2e | docker-compose.yml socket-proxy command (per-method -allowGET/-allowPOST regexes, -listenip=127.0.0.1, -allowfrom, host network) + tests/unit/socket-proxy.sh + tests/assertions/socket-proxy.sh (allowed/denied path matrix incl. attach/ws, loopback-only listeners, no route from the mediastack bridge or the host address) + tests/assertions/beszel.sh (stats through the proxy); also run `scenario:autoheal` (restart through the proxy). Upstream's `1` tag holds until a breaking deployment change, but a bump can still change how paths are matched, so re-read the image README |
| sonarr | latest | stable | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/sonarr/main.sh + tests/assertions/sonarr.sh |
| unpackerr | latest | stable | scenario:unpackerr | docker-compose.yml unpackerr environment (UN_SONARR_0_*/UN_RADARR_0_*) + tests/scenarios/unpackerr.sh — proves generated-key/authenticated completed-Radarr-queue → configured torrent-path archive extraction; does not prove a live qBittorrent transfer or Arr import |
| uptime-kuma | major:2 | major-gated | scenario:fresh-install+install-e2e+upgrade-path | scripts/services/uptime-kuma/main.sh + tests/assertions/uptime-kuma.sh |
| wireguard | major:15 | unstable | scenario:wireguard+wireguard-upgrade | scripts/services/wireguard/main.sh + tests/unit/wireguard-service.sh + wireguard scenarios |
<!-- upgrades-manifest:end -->
