# Changelog

All notable changes to MediaStack will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
under the 0.x policy in [docs/project/release.md](docs/project/release.md).

> **The body of each `## [x.y.z]` section below is the GitHub Release note, used
> verbatim** — read by someone deciding whether to update their install. The bracketed
> headings are the keys the release extractor matches, not links. The rules for
> writing an entry live here:
>
> - One **bullet per operator-visible change** — no sub-bullets, no paragraphs
>   (wrapping at the file's line width is fine): headline, then the consequence an
>   operator acts on, then its `(#issue)` where one exists. Full reasoning stays in
>   the issue or PR.
> - Operator-visible means it changes the wizard flow, the service set, compose or
>   image-channel behaviour, day-2 menu actions, host requirements, or the security
>   posture. Tests, CI, formatting, and repo hygiene are **not** — that record belongs
>   in the PR and in git. An entry nobody can act on is noise.
> - A change behind an option the wizard never offered is off-contract and is not an
>   entry; a change to what a documented choice does always is.
> - A breaking change (a re-run of `./mediastack` behaves differently on an existing
>   install, or a manual migration step is required) goes under `### Breaking Changes`
>   with the migration step inline.

## [Unreleased]

- Report a failed Unpackerr recreate instead of claiming success; the warning names the Compose exit and the service shows WARN in the summary (#100).
- Start a service recreates a stopped service on its staged image and starts its stopped dependencies; a failed recreate is reported and the service stays stopped (#103).
- State why setup asks for the sudo password and warn when the prompt fails, so a later prompt behind the spinner is explained (#95).
- Changing the quality profile no longer claims to start a library search; the prompt describes the in-place profile update (#104).
- Drift notices give a keep route and a reapply route instead of recommending `docker compose down -v`, which keeps service databases; Uninstall MediaStack is the only reset (#105).
- Warn on re-run when a Sonarr or Radarr Jellyfin connection holds a key Jellyfin rejects; Features & settings -> Repair Jellyfin connections replaces it after confirmation (#107).
- Add WireGuard VPN from Features & settings once HTTPS is ready; declining leaves the install unchanged and re-running finishes starting wg-easy if its settings were saved (#98).
- Preserve `MS_DISABLE_RESOURCE_LIMITS` across `.env` rewrites; an invalid value warns and keeps the limits on (#102).
- The NAS storage watchdog no longer restarts a service you stopped from the launcher, at boot or after an outage; a service that depends on one you stopped starts without it (#106).
- Re-running setup after Jackett drops its FlareSolverr URL, for example after a Jackett update, no longer reports every configured indexer as "not available in Jackett"; the configurator signs in again after the repair restart.
- Uptime Kuma monitors and the status page are created even when an earlier `sudo` run left `/tmp/kuma-configure.err` behind; setup no longer skips the step with "returned no output" (#153).

### Breaking Changes

- Reconcile Seerr quota periods; a `config.yml` limit of 0 now clears a quota set in the Seerr UI on the next re-run; before re-running, set `seerr.quotas` in `config.yml` to the limits you want to keep (#101) (#108).
- Require per-scenario evidence for Stable preflight receipts; delete the receipt file from releases up to v0.2.0 once before accepting image updates (#99).

## [0.2.0] - 2026-10-25

- Allow slow DDNS provider responses with a 45-second timeout (#65).
- Report unreadable newer qBittorrent whitelist layouts as drift without writing to them (#66).
- Show the NAS watchdog cause in Health when relevant (#67).
- Stop all removes stopped containers in active profiles (#68).
- Report Samba startup and firewall failures, and keep firewall work pending after a failure (#69).
- Treat normal no-GPU and user-choice transcoding fallbacks as completed (#69).
- Retry incomplete sysctl hardening on a later setup run (#69).
- Fail closed when admin-filter rule ordering is wrong or cannot be verified (#69).
- Warn before qBittorrent Revert restores a whitelist layout that may not work with the target image (#66).
- Complete Revert cleanup when restore displaces container-owned config.
- Recognize NPM's existing-user HTTP 403 during setup reruns and verify saved credentials.
- Wait for authenticated Jellyfin network configuration after a MediaStack-owned restart.
- Refresh the Stable container image baseline after per-service preflights.
- Keep LAN access and retry guidance clear when HTTPS setup is skipped or fails, without claiming VPN access is configured.

## [0.1.0] - 2026-10-23

- Initial public release: guided single-box installer for the full media stack
  (Jellyfin, Sonarr, Radarr, Jackett, qBittorrent, Seerr, and 14 supporting
  services) on Debian 12 or 13, driven entirely by `./mediastack`. Setup
  refuses other hosts, Ubuntu included, and Debian 11 as end of life.
- Day-2 management from the same menu: status, updates on a Stable
  (digest-pinned, MediaStack-tested) or Latest image channel, feature
  add/remove, storage, DDNS, fail2ban, diagnostics, uninstall. Health lists
  every container of the enabled profiles, stopped ones included.
- Hardening on by default: UFW Docker rules, fail2ban jails, admin ports
  restricted to private sources, WireGuard remote access tiers (peers reach host
  services with UFW on). The admin-port filter is its own `ADMIN_PORT_FILTER`
  choice, applied by a systemd unit that Docker requires, so a filter failure
  stops Docker instead of publishing admin ports; the health check and main menu
  warn when it is wanted but not active.
- Docker socket access is filtered: Beszel Agent and Autoheal reach Docker
  through a `socket-proxy` container on the host network that listens on
  127.0.0.1 only and, as a path allowlist, permits container list, stats and
  restart plus version and info. Portainer keeps the socket. Beszel's
  image-update indicator and per-container info and log views are off; use
  Portainer for container details and logs. The Beszel agent talks to its hub
  over a unix socket, so it opens no TCP port.
- New day-2 action, Health & security -> "Apply changes from a MediaStack
  update" (`scripts/update.sh` runs it too): installs the admin-port filter,
  narrows qBittorrent's old auth whitelist, moves Beszel's hub entry to the
  socket, deletes the unused `MediaStack:Beszel-agent` UFW rule, converges the
  WireGuard UFW rule and installs a missing NAS watchdog. Run it once after
  pulling new code onto an existing install.
- NVIDIA GPU install runs apt non-interactively, detects Secure Boot with MOK
  enrolment guidance, and keeps the driver working across kernel upgrades: it
  installs the kernel headers metapackage so DKMS builds the module for each new
  kernel, and a re-run or Repair builds a module a kernel is missing. Jellyfin
  NVENC needs driver 520.56.06 or newer; an older GPU falls back to software
  transcoding with the reason shown in status and health. Hardware decode is
  enabled only for codecs the setup probe proved.
- Image updates save a restore point of the service's config first; Revert
  puts back the old image and that config.
- NAS storage gets a watchdog that repairs a dropped mount;
  `STORAGE_WATCHDOG=false` opts out.
- Turning the Samba share OFF closes its firewall rules and stops Samba when
  MediaStack installed it, unless you have added shares of your own. Once you
  have, MediaStack treats Samba as yours for good, even after SMB is turned back
  on: uninstall keeps the Samba package, the Linux account and the Samba groups.
  Otherwise uninstall removes the Samba account it created when nothing else
  uses it. Uninstall also removes MediaStack's Docker volumes and networks.
- Manage stack -> Stop all also removes the anonymous Docker volume of a
  container that setup recreated (the Beszel agent), so no stray volume is left
  after uninstall. The Manage stack status table lists stopped services too.
- DDNS credential prompts hint at a narrower credential for providers that
  send the secret in the request URL (it can appear in ddns-updater logs).
- qBittorrent keeps WebUI login on for the Docker network; only Sonarr, Radarr
  and Homepage are exempt. A whitelist you set yourself is reported as drift,
  never overwritten.
- `./mediastack --version` reports the installed release and commit.
