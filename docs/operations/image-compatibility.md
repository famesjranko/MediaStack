# Image compatibility evidence

The Stable channel uses accepted digests. A healthy container alone is insufficient
evidence for an update. The manifest in [upgrades.md](upgrades.md#manifest) lists
the required scenarios. A combined token requires every named scenario.

| Service | Fresh configuration and behavior | Existing-install evidence | Additional boundary |
|---|---|---|---|
| Jellyfin | User authentication, libraries, network and encoding settings, fail2ban log format | `upgrade-path`: user IDs, library IDs/paths and API credentials; reconfiguration preserves user changes. `install-e2e`: menu Update and Revert keep users, libraries and keys | Real media playback, watch history and GPU execution need separate proofs |
| Sonarr, Radarr | Profiles, root folders, download clients, deterministic Torznab registration/search, seed policy, Jellyfin connection | `upgrade-path`: stored IDs, profiles, indexers and download clients survive; deliberate profile change remains. `install-e2e`: the same state survives menu Update and Revert | Series/movie history and actual imports need separate proofs |
| Jackett | Generated credentials and nonempty Torznab capabilities through the local tracker | `upgrade-path`: Arr search still works through the existing indexer after update. `install-e2e`: after each menu Update and Revert, Jackett serves the fixture indexer's Torznab categories through its stored API key, and the Arr indexer entries do not change | Public trackers and Cloudflare availability remain external |
| qBittorrent | Login, paths/categories and authenticated Arr connection | `upgrade-path`: preferences/categories and credentials; the launcher's Update and Revert functions with a stopped-config restore point. `install-e2e`: the same moves through the menu | Download history, torrent resume data and interrupted restores need separate proofs |
| Seerr | Jellyfin login, permissions, quotas, stored Arr settings and live connection tests | `upgrade-path`: existing Arr settings and API key; reconfiguration and connection checks. `install-e2e`: Arr settings survive menu Update and Revert | Existing request history needs a separate migration fixture |
| Homepage | Generated dashboard and service widgets; `install-e2e` also through the real installer | Configuration is generated from the same source after updates | Browser rendering and widget interactions have narrower coverage |
| Beszel, beszel-agent | Hub login, agent registration, Docker stats through socket-proxy; `install-e2e` also through the real installer | No dedicated stored-history migration fixture | Hub upgrades require operator review |
| Portainer | Admin login, local endpoint and API key; `install-e2e` also through the real installer | No dedicated database migration fixture | Operator review required for existing-install compatibility |
| Uptime Kuma | Admin login, required monitors and idempotent re-run; `install-e2e` also through the real installer | No dedicated database migration fixture | Operator review required for stored monitoring history |
| NPM | Admin auth, proxy/certificate writes, live HTTPS and security headers; `npm-heal` tests recovery | No dedicated proxy/database migration fixture | Real WAN DNS and public ACME are separate |
| DDNS updater | `ddns-seed` configuration/startup and `ddns-verify` provider/error behavior | Existing rendered provider configuration is reused in the focused fixtures | Real provider accounts and WAN address changes are separate |
| fail2ban | Static filter fixtures plus live Jellyfin/Seerr auth failures in `fresh-install` | Jails/rules recreated and checked in DinD | Host networking remains an operator-run proof |
| socket-proxy | Allow/deny API matrix and agent statistics; `autoheal` proves restart permissions; `install-e2e` also through the real installer | Stateless container replacement | Host network exposure checked separately on real installs |
| autoheal | Unhealthy fixture restart through socket-proxy | Stateless container replacement | Intentional stops remain covered by product unit tests |
| Unpackerr | Authenticated queue fixture through real extraction | Stateless worker replacement | A real transfer and Arr import remain separate |
| Bazarr | Dedicated configurator and API assertions | No existing subtitle database migration fixture | Operator review required |
| WireGuard | Dedicated peer and network policy scenario | No existing-peer migration fixture | Real client traffic and remote access remain separate |
| FlareSolverr | Startup and health only, also under the real installer in `install-e2e` | No deterministic challenge-solve oracle | Health evidence does not authorize automatic acceptance |

`upgrade-path` first installs the accepted lock, then applies the proposed lock
through the real `scripts/update.sh`. It checks saved user state before and after
reconfiguration. It deliberately overwrites a profile once and requires its own
comparison to detect that overwrite. It also calls the launcher's qBittorrent
Update and Revert functions directly, without the menu.

The scenario reports fresh configuration checks and migration checks separately.
Both installations use the current MediaStack configurators. This tests image
changes, not configurator changes from an older MediaStack release.

## API contracts and other touchpoints

`tests/contracts/*.yml` lists every HTTP API call that MediaStack makes to a
service. The hosted preflight requires proof that each call still works on the
candidate digest. See
[the contract gate](hosted-image-preflight.md#contract-gate).

MediaStack also touches images in ways that are not HTTP calls. These
touchpoints have no contract entries. This table gives the evidence for each:

| Touchpoint | Evidence |
|---|---|
| Files that an image writes and MediaStack reads, for example `config.xml` API keys | Indirect: each configurator reads the key from the file, then authenticates with it. An authenticated 2xx response on the candidate proves the read. |
| Files that MediaStack writes for an image | The Homepage assertions, `ddns-verify` and the fail2ban assertions. The service must load the file and behave as configured. |
| Environment, ports and healthchecks | The compose render check, the receipts' health rule (the candidate container must end running or healthy), and the `install-e2e` check of health on the exact digest. |
| fail2ban log formats | Live Jellyfin and Seerr authentication failures in `fresh-install`. fail2ban must ban the source address. |
| Data paths and UID/GID | The persistence assertions in `upgrade-path` and `install-e2e`. Saved state must survive Update and Revert. |
| Uptime Kuma (socket.io API) | Held for operator review. Only its scenario assertions run. |

## Real installer and day-2 menu: `install-e2e`

`install-e2e` runs the installer and the launcher that a user runs. It does not
stub Docker, Compose, image pulls or configurators.

1. A non-root user with sudo runs `DEMO=1 ./setup.sh --full` on the Debian 12
   DinD host. `DEMO=1` takes the Stage 1 answers from a prepared `.env`. The
   installer installs the base packages, checks Docker, writes `.env` and
   `config.yml`, generates the Stable override, then pulls, starts, health-checks
   and configures the stack.
2. Each default-profile and autoheal-profile service must be healthy and run the
   image of its Stable lock row. Its install digest must be in
   `config/state/image-install.tsv`, which Revert uses. The proxy, remote and
   subtitles services must not start.
3. The scenario saves user state through the service APIs, with a deliberate
   change to a Sonarr profile and an extra Jellyfin user. It then runs the
   installer again and chooses **Use existing install**, then **Continue without
   changes**. This branch runs no configurator. No container can be recreated or
   restarted. `.env`, `config.yml`, the override and the install record must not
   change. No pull, start or configuration run is permitted, and the saved state
   must not change.
4. The user then runs `./scripts/configure.sh`, which applies `config.yml` to
   every service on the installed images. It must warn that the changed Sonarr
   profile differs from `config.yml` and leave the change in place. It must keep
   the Uptime Kuma monitors and create none. The saved state must not change. The
   run must exit 0 with no error and no warning in its summary.
5. `./mediastack` runs under a pseudo-terminal and opens **Manage updates (status,
   per-service updates)**. The table must show **Update available** for each
   data-owning service that has a different candidate, and **Up to date** for the
   others. For each service with a candidate, the scenario uses **Update a
   service**, then **Revert a service to its installed image**, then **Update a
   service** again. After each move, the service must be healthy on the expected
   digest. No other container can be recreated, and the saved state must not
   change. Jackett must serve the Torznab categories of the fixture indexer.
6. The `fresh-install` service checks then run on the final stack, with LAN-state
   checks in place of the HTTPS checks. The Jellyfin encoding and `config.yml`
   drift checks of `fresh-install` also run.

These `fresh-install` checks do not run in `install-e2e`:

- NPM, fail2ban and rate-limit checks. A LAN-only install does not start NPM or
  fail2ban.
- The port check. It needs NPM to answer on ports 80 and 443.
- The install-digest check. `fresh-install` runs the digest recorder itself.
  `install-e2e` checks instead that the installer recorded the digest of each
  service.
- The Uptime Kuma re-run check. It runs `configure.sh` as root. `install-e2e`
  makes the same check on the user's `configure.sh` run in step 4.

Candidate digests come from `MS_TEST_IMAGE_OVERRIDES`. The installer's override
pulls them for every service except Jellyfin, Sonarr, Radarr, Jackett, qBittorrent
and Seerr. These six install on their accepted digest and get their candidate from
**Update a service**, because an existing install moves forward that way. An older
image can fail on a database that a newer image has migrated, so the scenario never
uses Update to move back. Revert restores the restore point that Update took.
The scenario ends with each service on its candidate, so its receipts describe the
candidate.

The menu offers Update only when the target digest differs from the running
digest. A data-owning service without a different candidate therefore stays on
its accepted image, and the scenario checks only its **Up to date** status. A run
with no candidate for any of the six (for example, the local battery) does no menu
move at all. The manifest names `install-e2e` for all six data-owning services.
A hosted preflight tests a drifted service, so that service always has a
different candidate. Its menu Update and Revert are therefore required evidence
for acceptance.

Out of scope for `install-e2e`:

- GPU drivers and hardware transcoding. DinD has no GPU, and `DEMO=1` skips
  that stage.
- NAS storage. The install uses local storage.
- Remote access. A `DEMO=1` install is LAN-only, so NPM, fail2ban, the DDNS
  updater and WireGuard do not start. Bazarr and the SMB share are off.
- Host hardening. DinD has no systemd host, so UFW, kernel hardening, automatic
  updates and the admin-port filter are off.
- **Update all**, and migration from an older MediaStack release.

GPU drivers, NAS mounts, host hardening, WAN routing and third-party accounts stay
in the separately invoked host and lab tests. A finite test suite cannot guarantee
that every upstream regression will be detected. Missing migration or behavior
coverage is a reason to hold an image for review.
