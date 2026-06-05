# Security Policy

MediaStack is a self-hosted home-server installer. Treat `.env`, DDNS config,
WireGuard peer files, downloaded QR codes, and service API keys as secrets.

## Supported Versions

Only the current `main` branch is supported for security fixes.

## Reporting

Please do not open public issues for exploitable vulnerabilities or leaked
credentials. Use GitHub's private vulnerability reporting if it is enabled for
the repository, or contact the maintainer privately.

Include:

- Affected commit or release
- Reproduction steps
- Impact and exposed services
- Whether the issue requires LAN, VPN, or WAN access

## Public Exposure Boundary

Only Jellyfin and Jellyseerr are intended to be exposed through HTTPS. Admin
ports for NPM, WireGuard, Sonarr, Radarr, Jackett, qBittorrent, Portainer,
DDNS Updater, and monitoring tools should remain LAN/VPN-only.
