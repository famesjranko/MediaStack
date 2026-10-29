# Image compatibility evidence

The Stable channel uses accepted digests. A healthy container alone is insufficient
evidence for an update. The manifest in [upgrades.md](upgrades.md#manifest) lists
the required scenarios. A combined token requires every named scenario.

| Service | Fresh configuration and behavior | Existing-install evidence | Additional boundary |
|---|---|---|---|
| Jellyfin | User authentication, libraries, network and encoding settings, fail2ban log format | `upgrade-path`: user IDs and names with their administrator and disabled flags, library IDs, paths and options, system/encoding/network settings, a watched local movie with its user/item IDs, play count and last-played date, and each API key (name and fingerprint). The stored MediaStack key must stay listed and must authenticate. The shared admin password must log in as an administrator. The Stage 1 `/Users` probe and the post-Revert login checks run again on the candidate. Reconfiguration keeps user changes. `install-e2e`: the same saved state survives menu Update and Revert | Real media playback and GPU execution need separate proofs |
| Sonarr, Radarr | Profiles, root folders, download clients, deterministic Torznab registration/search, seed policy, Jellyfin connection | `upgrade-path`: stored IDs, profiles, indexers and download clients survive; deliberate profile change remains. Naming, custom formats, quality definitions and media management are compared before reconfiguration. A series, episode and movie retain their IDs and history events. The Jellyfin connection keeps its ID, host, port, SSL, library-update and notify settings, and its triggers. `install-e2e`: the same state survives menu Update and Revert | Actual grabs and imports need separate proofs; history is seeded offline against the accepted SQLite schema |
| Jackett | Generated credentials and nonempty Torznab capabilities through the local tracker | `upgrade-path`: the stored admin password still logs in, the admin password stays set, and the API key stays the same as the key in `ServerConfig.json`. The configured indexer IDs and the FlareSolverr URL stay the same. Torznab answers with the stored key. Arr search still works through the existing indexer after the update. `install-e2e`: the same saved state survives menu Update and Revert. After each move, Jackett serves the fixture indexer's Torznab categories through its stored API key, and the Arr indexer entries do not change | Public trackers and Cloudflare availability remain external |
| qBittorrent | Login, paths/categories and authenticated Arr connection | `upgrade-path`: categories, and every preference that the configurator writes (paths, ratio and seeding limits, queue, connection and speed limits, listen port, UPnP, preallocation, the auth whitelist and the WebUI user name), and login with the stored credentials; the launcher's Update and Revert functions with a stopped-config restore point. `install-e2e`: the same saved state survives the same moves through the menu. A paused local torrent retains one verified piece, per-file progress, limits, tags and metainfo; torrent and resume files must exist. `upgrade-path` also kills Revert after the real config rename, then retries with real Docker and login and checks that the safety archive was reused | Peer transfers, power loss and daemon failure are outside this fixture; host unit `revert-interrupted` covers more process-interruption boundaries |
| Seerr | Jellyfin login, permissions, quotas, stored Arr settings and live connection tests | `upgrade-path`: user IDs, emails and permissions, the Seerr API key (set, and the same fingerprint), authentication with the stored key, default permissions and quotas, and the stored Arr, Jellyfin and network settings; a declined movie request retains its ID, status, dates, media and requestor; reconfiguration and connection checks. `install-e2e`: the same saved state survives menu Update and Revert | Request creation and public metadata lookup are outside this fixture; the request is seeded offline |
| Homepage | Generated dashboard and service widgets; `install-e2e` also through the real installer | Configuration is generated from the same source after updates | Browser rendering and widget interactions have narrower coverage |
| Beszel, beszel-agent | Hub login, agent registration, Docker stats through socket-proxy; `install-e2e` also through the real installer | `upgrade-path` preserves hub admin and user logins, monitored systems, user preferences, system/container history and the agent key before and after reconfiguration | Hub candidates require all three scenarios; agent stats remain covered by fresh setup |
| Portainer | Admin login, local endpoint and API key; `install-e2e` also through the real installer | `portainer-upgrade`: the real update script preserves user IDs, names and roles, password logins, the stored Homepage token, tag IDs and names, and local endpoint IDs, type, socket URL, group and tags. State is compared before and after reconfiguration. The endpoint must still list the running Portainer container | Stacks, registries, teams, remote endpoints and their credentials remain outside this fixture |
| Uptime Kuma | Admin login, required monitors and idempotent re-run; `install-e2e` also through the real installer | `upgrade-path`: managed monitor IDs and settings, a paused push monitor with real up/down events, minute/hour/day uptime totals, custom retention and status-page membership survive the real update and reconfiguration. Each read logs in with the saved admin password | SQLite within major 2 is covered. External notification delivery, other database engines and major-version migration need separate proofs |
| NPM | Admin auth, proxy/certificate writes, live HTTPS and security headers; `npm-heal` tests recovery; `npm-renewal` tests manual and scheduled certificate deployment | `npm-upgrade`: the real update script preserves admin identity and login, proxy IDs and rules, certificate IDs, certificate and private-key fingerprints before and after reconfiguration. Fresh SNI connections must serve the saved leaves; renewal must deploy new leaves | Local ACME uses Pebble. Real WAN DNS, public ACME and host firewall behavior remain separate operator proofs |
| DDNS updater | `ddns-seed` configuration/startup and `ddns-verify` provider/error behavior | Existing rendered provider configuration is reused in the focused fixtures | Real provider accounts and WAN address changes are separate |
| fail2ban | Static filter fixtures plus live Jellyfin/Seerr auth failures in `fresh-install` | `upgrade-path`: the update script's filter check (`fail2ban-regex`) runs on the candidate; jails/rules recreated and checked in DinD | Host networking remains an operator-run proof |
| socket-proxy | Allow/deny API matrix and agent statistics; `autoheal` proves restart permissions; `install-e2e` also through the real installer | Stateless container replacement | Host network exposure checked separately on real installs |
| autoheal | Unhealthy fixture restart through socket-proxy | Stateless container replacement | Intentional stops remain covered by product unit tests |
| Unpackerr | Authenticated queue fixture through real extraction | Stateless worker replacement | A real transfer and Arr import remain separate |
| Bazarr | Dedicated configurator and API assertions | `upgrade-path`: accepted-to-candidate subtitle history for a local episode and movie, a custom hearing-impaired language profile, settings, API-key fingerprints and external subtitle files; history must remain readable through the candidate API before and after reconfiguration | Records are seeded with the writers stopped. Matching Arr records and local video files keep normal startup sync active. Real provider downloads and media imports need separate proofs |
| WireGuard | Dedicated peer and network policy scenario | `wireguard-upgrade`: accepted-to-candidate `update.sh`, API authentication, enabled and disabled peer IDs, addresses, expiry, routing, firewall settings, DNS, MTU, keepalive, key fingerprints, client exports and loaded kernel configuration; an existing IPv4 client handshakes and exchanges tunnel traffic before and after reconfiguration | Public remote access, LAN forwarding and host firewall rules remain separate |
| FlareSolverr | Startup and health only, also under the real installer in `install-e2e` | No deterministic challenge-solve oracle | Health evidence does not authorize automatic acceptance |

`upgrade-path` first installs the accepted lock, then applies the proposed lock
through the real `scripts/update.sh`. It checks saved user state before and after
reconfiguration. Each check also requires that every stored credential
authenticates on the running image: the Sonarr, Radarr, Jellyfin and Seerr API
keys in `.env`, the Jackett API key in `ServerConfig.json`, the qBittorrent
login, and the Jellyfin login with the shared admin password. The saved state
holds no secret value. A credential is recorded only as a fingerprint or as a
boolean. A check also fails when the Seerr API key, the Jackett admin password,
a Jellyfin library or the Sonarr or Radarr Jellyfin connection is missing,
because a comparison with an empty value proves nothing.

The first check after the update runs before `configure.sh`. Reconfiguration
applies `config.yml` again, for example the Seerr default permissions and quotas,
so a later check cannot show a value that the update lost.

Kuma has a separate application-level snapshot (`tests/fixtures/kuma_state.py`).
The fixture sends three local push events, then pauses that monitor so its
history stays fixed. It compares heartbeat IDs, status, time, message, ping and
duration, plus uptime samples and ping summaries at each chart period. It also
checks saved monitor settings, retention, and both the managed and custom
status pages. Normal service monitors continue polling; their changing history
is excluded. Before the upgrade, clearing the fixture history through Kuma must
make the check fail. The fixture is then seeded again. No SQL writes bypass the
application. Status-page group IDs are excluded because configuration rebuilds
managed groups; monitor IDs and group membership are compared.
The shared product probes also call Kuma's real HTTP readiness fallback, so a
healthy Docker check cannot leave that contract untested on the candidate.

Before the update, the scenario tests its own comparison. It changes a Sonarr
profile, and the comparison must report the change. It then deletes a Seerr user
and a Jellyfin API key, and the comparison must name both. It creates the two
records again and saves the state again before the update. It also calls the
launcher's qBittorrent Update and Revert functions directly, without the menu.

The scenario reports fresh configuration checks and migration checks separately.
Both installations use the current MediaStack configurators. This tests image
changes, not configurator changes from an older MediaStack release.

### Migration fixtures and limits

The accepted images first create their own databases. The fixture stops Sonarr,
Radarr and Seerr, inserts a small linked series/episode/movie/history/request
population into their SQLite schemas, then starts them again. All comparisons
read the real APIs. A candidate never seeds or repairs a missing record. This
keeps public metadata providers and actual grabs outside the migration proof.

Jellyfin scans a one-second clip generated by its bundled FFmpeg, with remote
metadata fetchers disabled for the movie library. The fixture marks it watched
through the API. Watch state is read with the user-scoped bulk item query; the
per-item endpoint can return stale user data after a library mark. qBittorrent
checks two local torrent pieces, one present and
one absent, then restarts to load its resume file. The torrent stays paused,
private and without a tracker. No peer transfer is required.

Every snapshot runs the Arr download-client, indexer and notification
`testall` operations. These use the stored integration settings, including
masked secrets, before reconfiguration can repair them. Separate qBittorrent
and Jackett logins require the shared password. Raw masked values cannot be
compared; authenticated operations prove that the stored integrations work.

The live interrupted-Revert case kills only the launcher process after it
moves the stopped qBittorrent config aside. A fresh launcher process must reuse
the safety archive, restore the installed image, pass real health/login checks,
load the saved torrent state and remove recovery metadata. Host unit
`revert-interrupted` covers additional interruption and rollback boundaries.
Neither test simulates host power loss or a Docker daemon crash.

The fixture covers one small population per service. It does not prove every
history event type, real media playback, a live torrent transfer, an Arr import,
or a migration from an older MediaStack release.

## WireGuard peer migration

`wireguard-upgrade` starts the accepted Stable digest and configures the admin
peer. It adds an enabled peer and a disabled peer with non-default settings.
Before recording the baseline, it changes a peer MTU through the API and requires
the comparison to reject the change. It restores the setting before the upgrade.

The scenario runs the real `scripts/update.sh` with an exact candidate digest.
Only WireGuard is active in this dedicated Docker fixture. It compares saved
state before reconfiguration, then reconfigures and compares again. Each check
uses the stored admin credential. Client exports supply the private-key and
preshared-key fingerprints; raw keys never enter the saved snapshot or logs.
Enabled peers and their preshared keys must also be loaded in the kernel.

The accepted image exports the enabled fixture peer once. A client on a separate
Docker network reuses that private export and the accepted client image. Only
the endpoint address changes to the Docker host gateway; it uses the exported
custom UDP port and allowed routes. The client must authenticate a new tunnel
and receive an ICMP reply from a fixture address on the server. A fresh client
container and interface prevent a previous session from satisfying a later
check. Blocked server UDP and a wrong preshared key must both fail before the
valid client connects. Raw client keys stay inside DinD in private files.

Without a candidate, the scenario forcibly recreates the accepted image and
checks that it reloads the saved state. This earns no candidate receipt. An
explicit candidate equal to the accepted digest is refused. Local acceptance
requires both `wireguard` and `wireguard-upgrade` receipts for the same candidate.
The hosted publisher requires both scenarios and their product API traces.
This fixture does not test IPv6 traffic, public WAN reachability, LAN forwarding,
host firewall rules, older MediaStack configurators, or Revert.

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
| Uptime Kuma (socket.io API) | Real configurator assertions in fresh and installer scenarios. `upgrade-path` compares authenticated Socket.IO reads of monitor settings, heartbeat events and each uptime chart period before and after reconfiguration. |

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
