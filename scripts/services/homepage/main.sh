# =============================================================================
# 8. Homepage dashboard — generate services.yaml with API widgets
# =============================================================================
# Homepage reads static YAML from /app/config/. No Docker socket needed.
# Pre-seeded settings.yaml, docker.yaml, widgets.yaml, bookmarks.yaml are
# tracked in git. Only services.yaml is generated (contains API keys).

configure_homepage() {
    echo ""
    echo -e "${BOLD}Configuring Homepage dashboard...${NC}"

    local services_file="$SCRIPT_DIR/config/homepage/services.yaml"
    local host_addr="${HOST_ADDRESS:-}"
    if [[ -z "$host_addr" || "$host_addr" == "localhost" ]]; then
        host_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
        host_addr="${host_addr:-localhost}"
    fi
    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"

    local has_bazarr="" has_wireguard="" has_ddns="" has_beszel="" has_npm=""
    if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx bazarr; then
        has_bazarr=1
    fi
    if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx wireguard; then
        has_wireguard=1
    fi
    if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx ddns-updater; then
        has_ddns=1
    fi
    if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx beszel; then
        has_beszel=1
    fi
    if [[ -n "$domain" && "$domain" != "example.com" ]] && \
       docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx npm; then
        has_npm=1
    fi

    local new_services
    new_services=$(HOST_ADDR="$host_addr" \
        DOMAIN="${domain}" \
        REMOTE_WEB_STATE="${remote_state}" \
        SONARR_KEY="${SONARR_API_KEY:-}" \
        RADARR_KEY="${RADARR_API_KEY:-}" \
        JELLYFIN_KEY="${JELLYFIN_API_KEY:-}" \
        SEERR_KEY="${SEERR_API_KEY:-}" \
        NPM_EMAIL="${NPM_ADMIN_EMAIL:-}" \
        NPM_PW="${JELLYFIN_ADMIN_PASSWORD:-}" \
        PORTAINER_KEY="${PORTAINER_API_KEY:-}" \
        HAS_BAZARR="$has_bazarr" \
        HAS_NPM="$has_npm" \
        HAS_WIREGUARD="$has_wireguard" \
        HAS_DDNS="$has_ddns" \
        HAS_BESZEL="$has_beszel" \
        BESZEL_EMAIL="${NPM_ADMIN_EMAIL:-}" \
        BESZEL_PW="${JELLYFIN_ADMIN_PASSWORD:-}" \
        python3 -c '
import os, yaml

host = os.environ["HOST_ADDR"]
domain = os.environ["DOMAIN"]
remote_state = os.environ["REMOTE_WEB_STATE"]
sonarr_key = os.environ["SONARR_KEY"]
radarr_key = os.environ["RADARR_KEY"]
jf_key = os.environ["JELLYFIN_KEY"]
seerr_key = os.environ["SEERR_KEY"]
npm_email = os.environ["NPM_EMAIL"]
npm_pw = os.environ["NPM_PW"]
ptainer_key = os.environ["PORTAINER_KEY"]
has_bazarr = os.environ["HAS_BAZARR"]
has_npm = os.environ["HAS_NPM"]
has_wireguard = os.environ["HAS_WIREGUARD"]
has_ddns = os.environ["HAS_DDNS"]
has_beszel = os.environ["HAS_BESZEL"]
beszel_email = os.environ["BESZEL_EMAIL"]
beszel_pw = os.environ["BESZEL_PW"]

use_domain = remote_state == "ready" and domain and domain != "example.com"

def href(subdomain, port):
    if use_domain:
        return f"https://{subdomain}.{domain}"
    return f"http://{host}:{port}"

services = []

# Media
media = {"Media": [
    {"Jellyfin": {
        "icon": "jellyfin",
        "description": "Media Server",
        "href": href("jellyfin", 8096),
        "siteMonitor": "http://jellyfin:8096",
        "widget": {"type": "jellyfin", "url": "http://jellyfin:8096", "key": jf_key},
    }},
    {"Seerr": {
        "icon": "seerr",
        "description": "Media Requests",
        "href": href("seerr", 5055),
        "siteMonitor": "http://seerr:5055",
        **({"widget": {"type": "seerr", "url": "http://seerr:5055", "key": seerr_key}} if seerr_key else {}),
    }},
]}
services.append(media)

# Media Management
mgmt = []
mgmt.append({"Sonarr": {
    "icon": "sonarr",
    "description": "TV Shows",
    "href": f"http://{host}:8989",
    "siteMonitor": "http://sonarr:8989",
    "widget": {"type": "sonarr", "url": "http://sonarr:8989", "key": sonarr_key},
}})
mgmt.append({"Radarr": {
    "icon": "radarr",
    "description": "Movies",
    "href": f"http://{host}:7878",
    "siteMonitor": "http://radarr:7878",
    "widget": {"type": "radarr", "url": "http://radarr:7878", "key": radarr_key},
}})
if has_bazarr:
    mgmt.append({"Bazarr": {
        "icon": "bazarr",
        "description": "Subtitles",
        "href": f"http://{host}:6767",
        "siteMonitor": "http://bazarr:6767",
    }})
services.append({"Media Management": mgmt})

# Downloads
services.append({"Downloads": [
    {"qBittorrent": {
        "icon": "qbittorrent",
        "description": "Torrent Client",
        "href": f"http://{host}:8080",
        "siteMonitor": "http://qbittorrent:8080",
        "widget": {"type": "qbittorrent", "url": "http://qbittorrent:8080"},
    }},
    {"Jackett": {
        "icon": "jackett",
        "description": "Indexer Proxy",
        "href": f"http://{host}:9117",
        "siteMonitor": "http://jackett:9117",
    }},
]})

# Network (only shown when at least one network service is running)
net = []
if has_npm:
    npm_entry = {
        "icon": "nginx-proxy-manager",
        "description": "Reverse Proxy",
        "href": f"http://{host}:81",
        "siteMonitor": "http://npm:81",
    }
    if npm_email and npm_pw:
        npm_entry["widget"] = {"type": "npm", "url": "http://npm:81", "username": npm_email, "password": npm_pw}
    net.append({"Nginx Proxy Manager": npm_entry})
if has_wireguard:
    net.append({"WireGuard": {
        "icon": "wireguard",
        "description": "VPN",
        "href": f"http://{host}:51821",
        "siteMonitor": "http://wireguard:51821",
    }})
if has_ddns:
    net.append({"DDNS Updater": {
        "icon": "ddns-updater",
        "description": "Dynamic DNS",
        "href": f"http://{host}:8000",
        "siteMonitor": "http://ddns-updater:8000",
    }})
if net:
    services.append({"Network": net})

# Admin
admin = []
ptainer_entry = {
    "icon": "portainer",
    "description": "Container Management",
    "href": f"http://{host}:9000",
    "siteMonitor": "http://portainer:9000",
}
if ptainer_key:
    ptainer_entry["widget"] = {"type": "portainer", "url": "http://portainer:9000", "env": 1, "key": ptainer_key}
admin.append({"Portainer": ptainer_entry})
if has_beszel:
    beszel_entry = {
        "icon": "beszel",
        "description": "System Resources",
        "href": f"http://{host}:8090",
        "siteMonitor": "http://beszel:8090",
    }
    if beszel_email and beszel_pw:
        beszel_entry["widget"] = {
            "type": "beszel",
            "url": "http://beszel:8090",
            "username": beszel_email,
            "password": beszel_pw,
            "version": 2,
        }
    admin.append({"Beszel": beszel_entry})
admin.append({"Uptime Kuma": {
    "icon": "uptime-kuma",
    "description": "Service Monitoring",
    "href": f"http://{host}:3001",
    "siteMonitor": "http://uptime-kuma:3001",
    "widget": {
        "type": "uptimekuma",
        "url": "http://uptime-kuma:3001",
        "slug": "mediastack",
    },
}})
services.append({"Admin": admin})

print(yaml.safe_dump(services, default_flow_style=False, sort_keys=False))
')

    if [[ -z "$new_services" ]]; then
        log_warn "Failed to generate Homepage services.yaml"
        return 0
    fi

    if [[ -f "$services_file" ]]; then
        local existing
        existing=$(cat "$services_file")
        if [[ "$existing" == "$new_services" ]]; then
            log_skip "Homepage services.yaml already up to date"
        else
            echo "$new_services" > "$services_file"
            log_ok "Homepage services.yaml generated"
        fi
    else
        echo "$new_services" > "$services_file"
        log_ok "Homepage services.yaml generated"
    fi

    # Homepage writes default bookmarks (GitHub, Reddit, YouTube) on first
    # start, overwriting the git-tracked empty file. Reset every run, atomically:
    # write to tmpfile then rename, so a concurrent reader (test, autoheal-
    # induced restart) never observes a transient empty file.
    local bookmarks_file="$SCRIPT_DIR/config/homepage/bookmarks.yaml"
    if [[ ! -f "$bookmarks_file" ]] || ! grep -qx '\[\]' "$bookmarks_file"; then
        local tmp="${bookmarks_file}.tmp.$$"
        echo '[]' > "$tmp" && mv "$tmp" "$bookmarks_file"
        log_ok "Homepage bookmarks.yaml reset (removed defaults)"
    fi

    # Patch settings.yaml layout to match actual service counts per group.
    # Column count = number of services in each group (capped at 4).
    local settings_file="$SCRIPT_DIR/config/homepage/settings.yaml"
    if [[ -f "$settings_file" && -f "$services_file" ]]; then
        local layout_result
        layout_result=$(SETTINGS_FILE="$settings_file" SERVICES_FILE="$services_file" python3 -c '
import os, yaml

with open(os.environ["SERVICES_FILE"]) as f:
    services = yaml.safe_load(f) or []

layout = {}
for group_dict in services:
    for group_name, svc_list in group_dict.items():
        count = len(svc_list)
        layout[group_name] = {"style": "row", "columns": min(count, 4)}

with open(os.environ["SETTINGS_FILE"]) as f:
    settings = yaml.safe_load(f) or {}

if settings.get("layout") == layout:
    print("SKIP")
else:
    settings["layout"] = layout
    with open(os.environ["SETTINGS_FILE"], "w") as f:
        yaml.safe_dump(settings, f, default_flow_style=False, sort_keys=False)
    print("OK")
')
        if [[ "$layout_result" == "SKIP" ]]; then
            log_skip "Homepage settings.yaml layout already up to date"
        else
            log_ok "Homepage settings.yaml layout updated"
        fi
    fi

    # Patch widgets.yaml with the host's default network interface.
    # /proc/net/dev is namespace-scoped (container sees only its own eth0),
    # but /sys is host-scoped, so Homepage can read real stats from
    # /sys/class/net/<iface>/statistics/ when given a specific interface name.
    local widgets_file="$SCRIPT_DIR/config/homepage/widgets.yaml"
    local host_iface
    host_iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -n "$host_iface" ]] && [[ -f "$widgets_file" ]]; then
        if grep -q "network: $host_iface" "$widgets_file"; then
            log_skip "Homepage network widget already set to $host_iface"
        elif grep -q "network:" "$widgets_file"; then
            sed -i "s/network: .*/network: $host_iface/" "$widgets_file"
            log_ok "Homepage network widget: $host_iface"
        else
            sed -i '/resources:/a\    network: '"$host_iface" "$widgets_file"
            log_ok "Homepage network widget: $host_iface"
        fi
    fi
}
