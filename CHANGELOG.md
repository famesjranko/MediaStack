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

- Initial public release: guided single-box installer for the full media stack
  (Jellyfin, Sonarr, Radarr, Jackett, qBittorrent, Seerr, and 13 supporting
  services) on Debian, driven entirely by `./mediastack`.
- Day-2 management from the same menu: status, updates on a Stable
  (digest-pinned, MediaStack-tested) or Latest image channel, feature
  add/remove, storage, DDNS, fail2ban, diagnostics, uninstall.
- Hardening on by default: UFW Docker rules, fail2ban jails, admin ports
  restricted to private sources, WireGuard remote access tiers.
- `./mediastack --version` reports the installed release and commit.
