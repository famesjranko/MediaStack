# Remote access

This guide is for people who want to watch Jellyfin and use Seerr away from home, or connect to their home network with a VPN.

Remote access needs a domain name and port forwarding on your router. You start it from the menu. Run `./mediastack`.

| Access type | What is exposed | Protected by |
|:------------|:----------------|:-------------|
| Internet (HTTPS) | Jellyfin, Seerr | Nginx Proxy Manager (NPM) reverse proxy, Let's Encrypt, fail2ban |
| LAN only | All admin pages | Router ports not forwarded |
| VPN (WireGuard) | Set by the access tier of each peer | WireGuard and the admin password |

## What you need

- A running MediaStack install. See the [install guide](install.md).
- A router where you can forward ports.
- A domain name. The next section shows how to get one for free.
- A fixed LAN address for the server. Use a static IP or a DHCP reservation on your router.

## Get a domain (free DDNS providers, or your own domain)

`jellyfin.<domain>` and `seerr.<domain>` must point to your home IP address. A DDNS provider keeps the name correct when your home IP changes.

The installer asks for a provider. You can choose one of these:

| Choice | Providers |
|:-------|:----------|
| Free hostname | DuckDNS, Dynu, deSEC, dynv6 |
| Your own domain | Cloudflare, Porkbun |

1. Choose a provider when the installer asks.
2. Enter the credentials of that provider.
3. Let MediaStack keep the name pointed at your current IP.

If you own a domain at another company, you can manage the DNS records yourself.

1. Create an A record for `jellyfin.<domain>` that points to your public IP.
2. Create an A record for `seerr.<domain>` that points to your public IP.
3. If you enable WireGuard, also create an A record for `<domain>` that points to your public IP. This is the VPN endpoint.
4. Choose **Yes - static IP, or I keep my own DNS updated (skip DDNS)** when the installer asks.

Keep these records updated if your public IP changes.

## Forward ports

Forward the ports for the features you use to the LAN address of your server. To find that address, run `hostname -I` on the server.

| Port | Protocol | Purpose |
|:-----|:---------|:--------|
| 80 | TCP | Let's Encrypt validation and HTTP to HTTPS redirect |
| 443 | TCP | HTTPS for Jellyfin and Seerr |
| 6881 (default) | TCP and UDP | Incoming qBittorrent peer connections |
| 51820 (default) | UDP | WireGuard VPN, if enabled |

HTTPS needs ports 80 and 443. If you changed the torrent or WireGuard port during setup, forward the selected port instead of its default.

> [!WARNING]
> Keep admin pages private. Do not forward the NPM admin port (81), the wg-easy admin port (51821), or other admin ports.
> Jellyfin and Seerr reach the internet through the reverse proxy on port 443, not through their own ports.

To test the forwards, open **Diagnostics (ports, public IP, DNS, readiness)** and choose **Test port forwarding**. Then choose **Test the required MediaStack ports**.

## Turn on remote access

1. Run `./mediastack`.
2. Choose **Features & settings (quality, bandwidth, subtitles, sharing, indexers)**.
3. Choose **Add remote access (HTTPS, domain, WireGuard)**.
4. Answer the questions: domain, DDNS provider, and WireGuard.

MediaStack then creates the reverse-proxy hosts, asks Let's Encrypt for certificates, and adds security headers. It also sets Seerr to trust the proxy.

If a certificate request fails, MediaStack shows a `[WARN]` message. It does not publish a public proxy host without a usable certificate. LAN access still works. The usual causes are:

- DNS does not point to your home IP yet.
- Port 80 is not forwarded.

Fix the cause. Then choose **Add remote access (HTTPS, domain, WireGuard)** again. For manual certificate management, see the [Nginx Proxy Manager docs](https://nginxproxymanager.com/guide/).

> [!NOTE]
> After a browser receives the [HSTS header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security) over HTTPS, it requires HTTPS for that hostname and its subdomains.

## Check it works

1. Open **Diagnostics (ports, public IP, DNS, readiness)** in `./mediastack`.
2. Choose **Check domain DNS**. This compares your subdomains to your current public IP.
3. On a phone with mobile data (not your home Wi-Fi), open `https://jellyfin.<domain>`.
4. Open `https://seerr.<domain>`.
5. Look for the HTTPS lock in the browser.

When a DDNS provider is set up, the main menu shows a `DDNS:` line. It shows these states:

| Colour | Meaning |
|:-------|:--------|
| Green | The domain resolves to your current public IP. |
| Yellow, `propagating?` | The domain resolves to a different IP. The record is old or not updated yet. |
| `not resolving yet` | The domain has no A record. |

The menu caches your public IP for the session and checks DDNS whenever it redraws. Choose **Refresh status (re-check public IP & DDNS)** to refresh the public IP too.

### Change the DDNS provider or credentials

1. Open **Features & settings (quality, bandwidth, subtitles, sharing, indexers)**.
2. Choose **Update DDNS provider / credentials**.
3. Choose a provider, or choose **Skip for now** to change nothing.
4. Enter the new credentials. MediaStack attempts to verify them with the provider.
5. Confirm the restart of `ddns-updater`.

This entry appears only when remote access is set up with a DDNS provider. For Dynu and deSEC, MediaStack warns that a successful response may not prove the credentials work when the IP has not changed.

If saving the settings or restarting the updater fails, MediaStack attempts to restore the previous settings. It reports a warning if recovery fails. A running updater alone does not prove that it can update DNS.

This action keeps your domain. Use it to enter the credentials again, or to switch between Cloudflare and Porkbun on a domain you own. A switch to or from DuckDNS, Dynu, deSEC, or dynv6 needs a new hostname. MediaStack then offers to start **Add remote access**.

## WireGuard VPN

WireGuard lets your phone or laptop reach your home network while away. Choose WireGuard during remote-access setup. If you declined it, add it later: choose **Features & settings (quality, bandwidth, subtitles, sharing, indexers)** → **Add WireGuard VPN**, or run `./setup.sh --wireguard`. This item shows only when HTTPS is ready and WireGuard is not set up. MediaStack first asks whether to set up WireGuard. If you say yes, it asks for the UDP port and access tier. The Full LAN tier also asks for your home LAN CIDR. Then it asks you to confirm. If you decline or cancel, nothing changes. Your domain, HTTPS setup, and passwords stay as they are. If WireGuard is already set up, the action changes nothing. Running `./setup.sh --remote` repairs the existing setup, keeps the peers in wg-easy, and does not ask for new WireGuard settings.

wg-easy manages the VPN. It starts with your admin login and one first peer. The peer has the name of your admin user and the access tier you chose at install.

### Add peers

Open WireGuard from Homepage, sign in with your admin login, and make one peer for each person. For the how, see the [wg-easy docs](https://wg-easy.github.io/wg-easy/latest/). Keep peer files and QR codes secret.

Forward only the UDP port of WireGuard. The client endpoint is your domain and that UDP port, for example `yourdomain.com:51820`.

### Access tiers

Normal internet traffic does not go through MediaStack. The tier only controls what a peer can reach on your network. At install you choose the tier for your own first peer. Most people keep Full LAN.

- **Full LAN**: every device on your home network. Best for your own admin device.
- **Server**: this server on every port, including SSH. Use it for a co-admin.
- **Containers**: MediaStack app ports only. No host services and no other LAN devices.

Two lower tiers are not installer choices. Use the templates below for the extra peers you add:

- **Streaming**: Jellyfin only. For watch-only people.
- **Streaming + requests**: Jellyfin and Seerr. For people who also request titles.

Neither Streaming tier shows Homepage.

The server enforces the tiers. A peer cannot widen its own access by editing its config. When UFW is on, MediaStack adds one rule, `MediaStack:WireGuard-clients`. It lets the WireGuard container reach this host. The rule does not give peers more access.

### Templates for extra peers

Your first peer already has the tier you chose. Use these templates only for peers you add in the wg-easy page. A new peer has an empty **Firewall Allowed IPs** field, which means no access.

1. Copy one template from the list below.
2. Paste it into the **Firewall Allowed IPs** field of the peer.
3. Replace `<server>` with the LAN IP of the server.
4. Replace `<lan-cidr>` with your LAN range, for example `192.168.1.0/24`.

**Full LAN:**
```text
<lan-cidr>
```
**Server** (this box, all ports incl. SSH):
```text
<server>/32
```
**Containers** (apps only, no host SSH/SMB or wg-easy UI):
```text
<server>:80/tcp,<server>:81/tcp,<server>:443/tcp,<server>:3000/tcp,<server>:3001/tcp,<server>:5055/tcp,<server>:6767/tcp,<server>:7359/udp,<server>:7878/tcp,<server>:8000/tcp,<server>:8080/tcp,<server>:8090/tcp,<server>:8096/tcp,<server>:8191/tcp,<server>:8989/tcp,<server>:9000/tcp,<server>:9117/tcp
```
**Streaming** (Jellyfin only, watch-only):
```text
<server>:8096/tcp
```
**Streaming + requests** (Jellyfin + Seerr):
```text
<server>:8096/tcp,<server>:5055/tcp
```

Set the client-side **Allowed IPs** to match: `<lan-cidr>` for Full LAN, and `<server>/32` for the other tiers. The Firewall field takes an IP or CIDR with an optional `:port/proto`. It does not accept host names.

## Keep admin pages private

MediaStack limits the admin pages to your LAN and VPN range. They are not reachable from the internet, even when your router forwards ports. Three settings help:

- **Firewall (UFW)** blocks inbound traffic by default.
- **Admin-port filter** answers admin pages only to local, private, and Tailscale sources. It is on by default.
- **System hardening** adds automatic security updates and kernel hardening.

To change them, open **Features & settings (quality, bandwidth, subtitles, sharing, indexers)** and choose the setting. Keep the admin-port filter on. If you turn it off, ports 81, 51821, 8000, 3001, 9000, the *arr pages, and the download pages answer any source that your router forwards.

If fail2ban blocks you by mistake, release the address.

1. Run `./mediastack`.
2. Choose **Manage fail2ban (banned IPs, whitelist, stats)**.
3. Choose **Banned IPs**.
4. Choose the address.
5. Choose **Unban (restores all access)**.

Full-tunnel routing sends all internet traffic of a device through your home VPN. It is rare for a media server and bypasses the access tiers. See the "Advanced — full-tunnel routing" note in [configuration-schema.md](../setup/configuration-schema.md).

The security model is in [architecture.md](../design/architecture.md#security-layer).

See also: [Install](install.md) · [Using the menu](using-the-menu.md) · [Troubleshooting](troubleshooting.md)
