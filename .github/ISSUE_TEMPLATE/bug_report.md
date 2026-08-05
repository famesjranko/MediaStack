---
name: Bug report
about: Something in MediaStack does not work as expected
title: ''
labels: bug
---

## What happened

<!-- What went wrong, in plain terms. -->

## Expected vs actual

- Expected:
- Actual:

## Host

- OS / distro and version:
- Install channel (stable or latest):
- MediaStack version / commit (`git -C <install-dir> rev-parse --short HEAD`):

## Diagnostics

<!-- For setup, networking, or remote-access problems, paste the output of the
     relevant check from `./mediastack` → Diagnostics (System readiness check,
     domain DNS, port forwarding). -->

## Affected services

<!-- Which service(s) are involved (Jellyfin, Sonarr, Radarr, qBittorrent,
     Jackett, NPM, WireGuard, Portainer, ...). -->

## Steps to reproduce

1.
2.
3.

## Logs

<!-- Relevant output. Container logs: `docker logs <service>`. Setup problems:
     the output of `./setup.sh` or the relevant `config/<service>/` log. -->

> ⚠️ **Redact secrets first.** Mask or remove API keys, `.env` values, and
> WireGuard peer details. Security *vulnerabilities* go through the private
> advisory link, not a public issue (see SECURITY.md).
