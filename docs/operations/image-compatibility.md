# Image compatibility evidence

The Stable channel uses accepted digests. A healthy container alone is insufficient
evidence for an update. The manifest in [upgrades.md](upgrades.md#manifest) lists
the required scenarios. A combined token requires every named scenario.

| Service | Fresh configuration and behavior | Existing-install evidence | Additional boundary |
|---|---|---|---|
| Jellyfin | User authentication, libraries, network and encoding settings, fail2ban log format | `upgrade-path`: user IDs, library IDs/paths and API credentials; reconfiguration preserves user changes | Real media playback, watch history and GPU execution need separate proofs |
| Sonarr, Radarr | Profiles, root folders, download clients, deterministic Torznab registration/search, seed policy, Jellyfin connection | `upgrade-path`: stored IDs, profiles, indexers and download clients survive; deliberate profile change remains | Series/movie history and actual imports need separate proofs |
| Jackett | Generated credentials and nonempty Torznab capabilities through the local tracker | `upgrade-path`: Arr search still works through the existing indexer after update | Public trackers and Cloudflare availability remain external |
| qBittorrent | Login, paths/categories and authenticated Arr connection | `upgrade-path`: preferences/categories and credentials; real launcher Update and Revert with stopped-config restore point | Download history, torrent resume data and interrupted restores need separate proofs |
| Seerr | Jellyfin login, permissions, quotas, stored Arr settings and live connection tests | `upgrade-path`: existing Arr settings and API key; reconfiguration and connection checks | Existing request history needs a separate migration fixture |
| Homepage | Generated dashboard and service widgets | Configuration is generated from the same source after updates | Browser rendering and widget interactions have narrower coverage |
| Beszel, beszel-agent | Hub login, agent registration, Docker stats through socket-proxy | No dedicated stored-history migration fixture | Hub upgrades require operator review |
| Portainer | Admin login, local endpoint and API key | No dedicated database migration fixture | Operator review required for existing-install compatibility |
| Uptime Kuma | Admin login, required monitors and idempotent re-run | No dedicated database migration fixture | Operator review required for stored monitoring history |
| NPM | Admin auth, proxy/certificate writes, live HTTPS and security headers; `npm-heal` tests recovery | No dedicated proxy/database migration fixture | Real WAN DNS and public ACME are separate |
| DDNS updater | `ddns-seed` configuration/startup and `ddns-verify` provider/error behavior | Existing rendered provider configuration is reused in the focused fixtures | Real provider accounts and WAN address changes are separate |
| fail2ban | Static filter fixtures plus live Jellyfin/Seerr auth failures in `fresh-install` | Jails/rules recreated and checked in DinD | Host networking remains an operator-run proof |
| socket-proxy | Allow/deny API matrix and agent statistics; `autoheal` proves restart permissions | Stateless container replacement | Host network exposure checked separately on real installs |
| autoheal | Unhealthy fixture restart through socket-proxy | Stateless container replacement | Intentional stops remain covered by product unit tests |
| Unpackerr | Authenticated queue fixture through real extraction | Stateless worker replacement | A real transfer and Arr import remain separate |
| Bazarr | Dedicated configurator and API assertions | No existing subtitle database migration fixture | Operator review required |
| WireGuard | Dedicated peer and network policy scenario | No existing-peer migration fixture | Real client traffic and remote access remain separate |
| FlareSolverr | Startup and health only | No deterministic challenge-solve oracle | Health evidence does not authorize automatic acceptance |

`upgrade-path` first installs the accepted lock, then applies the proposed lock
through the real `scripts/update.sh`. It checks saved user state before and after
reconfiguration. It deliberately overwrites a profile once and requires its own
comparison to detect that overwrite. It also calls the launcher's real qBittorrent
Update and Revert functions. Menu input and presentation are covered separately by
the image-free wizard tests.

The scenario reports fresh configuration checks and migration checks separately.
It does not execute the complete `setup.sh --full` host installation. GPU drivers,
NAS mounts, host hardening, WAN routing and third-party accounts stay in the
separately invoked host/lab tests. A finite test suite cannot guarantee that every
upstream regression will be detected. Missing migration or behavior coverage is a
reason to hold an image for review.
