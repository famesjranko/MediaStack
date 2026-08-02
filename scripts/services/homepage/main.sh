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
    if container_running bazarr; then
        has_bazarr=1
    fi
    if container_running wireguard; then
        has_wireguard=1
    fi
    if container_running ddns-updater; then
        has_ddns=1
    fi
    if container_running beszel; then
        has_beszel=1
    fi
    if [[ -n "$domain" && "$domain" != "example.com" ]] && container_running npm; then
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
        SERVICE_PORTS_JSON="$(service_http_ports_json)" \
        SERVICE_URLS_JSON="$(service_internal_urls_json)" \
        python3 -c '
import json, os, yaml

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
service_ports = json.loads(os.environ["SERVICE_PORTS_JSON"])
service_urls = json.loads(os.environ["SERVICE_URLS_JSON"])

use_domain = remote_state == "ready" and domain and domain != "example.com"

def port(service):
    return service_ports[service]

def svc_url(service):
    return service_urls[service]

def href(subdomain, service):
    if use_domain:
        return f"https://{subdomain}.{domain}"
    return f"http://{host}:{port(service)}"

services = []

# Media
media = {"Media": [
    {"Jellyfin": {
        "icon": "jellyfin",
        "description": "Media Server",
        "href": href("jellyfin", "jellyfin"),
        "siteMonitor": svc_url("jellyfin"),
        "widget": {"type": "jellyfin", "url": svc_url("jellyfin"), "key": jf_key},
    }},
    {"Seerr": {
        "icon": "seerr",
        "description": "Media Requests",
        "href": href("seerr", "seerr"),
        "siteMonitor": svc_url("seerr"),
        **({"widget": {"type": "seerr", "url": svc_url("seerr"), "key": seerr_key}} if seerr_key else {}),
    }},
]}
services.append(media)

# Media Management
mgmt = []
mgmt.append({"Sonarr": {
    "icon": "sonarr",
    "description": "TV Shows",
    "href": "http://{}:{}".format(host, port("sonarr")),
    "siteMonitor": svc_url("sonarr"),
    "widget": {"type": "sonarr", "url": svc_url("sonarr"), "key": sonarr_key},
}})
mgmt.append({"Radarr": {
    "icon": "radarr",
    "description": "Movies",
    "href": "http://{}:{}".format(host, port("radarr")),
    "siteMonitor": svc_url("radarr"),
    "widget": {"type": "radarr", "url": svc_url("radarr"), "key": radarr_key},
}})
if has_bazarr:
    mgmt.append({"Bazarr": {
        "icon": "bazarr",
        "description": "Subtitles",
        "href": "http://{}:{}".format(host, port("bazarr")),
        "siteMonitor": svc_url("bazarr"),
    }})
services.append({"Media Management": mgmt})

# Downloads
services.append({"Downloads": [
    {"qBittorrent": {
        "icon": "qbittorrent",
        "description": "Torrent Client",
        "href": "http://{}:{}".format(host, port("qbittorrent")),
        "siteMonitor": svc_url("qbittorrent"),
        "widget": {"type": "qbittorrent", "url": svc_url("qbittorrent")},
    }},
    {"Jackett": {
        "icon": "jackett",
        "description": "Indexer Proxy",
        "href": "http://{}:{}".format(host, port("jackett")),
        "siteMonitor": svc_url("jackett"),
    }},
]})

# Network (only shown when at least one network service is running)
net = []
if has_npm:
    npm_entry = {
        "icon": "nginx-proxy-manager",
        "description": "Reverse Proxy",
        "href": "http://{}:{}".format(host, port("npm")),
        "siteMonitor": svc_url("npm"),
    }
    if npm_email and npm_pw:
        npm_entry["widget"] = {"type": "npm", "url": svc_url("npm"), "username": npm_email, "password": npm_pw}
    net.append({"Nginx Proxy Manager": npm_entry})
if has_wireguard:
    net.append({"WireGuard": {
        "icon": "wireguard",
        "description": "VPN",
        "href": "http://{}:{}".format(host, port("wireguard")),
        "siteMonitor": svc_url("wireguard"),
    }})
if has_ddns:
    net.append({"DDNS Updater": {
        "icon": "ddns-updater",
        "description": "Dynamic DNS",
        "href": "http://{}:{}".format(host, port("ddns-updater")),
        "siteMonitor": svc_url("ddns-updater"),
    }})
if net:
    services.append({"Network": net})

# Admin
admin = []
ptainer_entry = {
    "icon": "portainer",
    "description": "Container Management",
    "href": "http://{}:{}".format(host, port("portainer")),
    "siteMonitor": svc_url("portainer"),
}
if ptainer_key:
    ptainer_entry["widget"] = {"type": "portainer", "url": svc_url("portainer"), "env": 1, "key": ptainer_key}
admin.append({"Portainer": ptainer_entry})
if has_beszel:
    beszel_entry = {
        "icon": "beszel",
        "description": "System Resources",
        "href": "http://{}:{}".format(host, port("beszel")),
        "siteMonitor": svc_url("beszel"),
    }
    if beszel_email and beszel_pw:
        beszel_entry["widget"] = {
            "type": "beszel",
            "url": svc_url("beszel"),
            "username": beszel_email,
            "password": beszel_pw,
            "version": 2,
        }
    admin.append({"Beszel": beszel_entry})
admin.append({"Uptime Kuma": {
    "icon": "uptime-kuma",
    "description": "Service Monitoring",
    "href": "http://{}:{}".format(host, port("uptime-kuma")),
    "siteMonitor": svc_url("uptime-kuma"),
    "widget": {
        "type": "uptimekuma",
        "url": svc_url("uptime-kuma"),
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
            echo "$new_services" >"$services_file"
            log_ok "Homepage services.yaml generated"
        fi
    else
        echo "$new_services" >"$services_file"
        log_ok "Homepage services.yaml generated"
    fi

    # Homepage writes default bookmarks (GitHub, Reddit, YouTube) on first
    # start, overwriting the git-tracked empty file. Reset every run, atomically:
    # write to tmpfile then rename, so a concurrent reader (test, autoheal-
    # induced restart) never observes a transient empty file.
    local bookmarks_file="$SCRIPT_DIR/config/homepage/bookmarks.yaml"
    if [[ ! -f "$bookmarks_file" ]] || ! grep -qx '\[\]' "$bookmarks_file"; then
        local tmp="${bookmarks_file}.tmp.$$"
        echo '[]' >"$tmp" && mv "$tmp" "$bookmarks_file"
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

    # Toggle cputemp based on whether the host exposes a readable thermal sensor.
    # /sys is bind-mounted host-scoped, but VMs (and some bare-metal boards) have
    # no thermal_zone*/temp, which leaves Homepage's temp widget broken ("Max"
    # with no reading). Detect on the host and disable the widget when absent.
    if [[ -f "$widgets_file" ]] && grep -q "cputemp:" "$widgets_file"; then
        local has_temp=false _z
        for _z in /sys/class/thermal/thermal_zone*/temp; do
            [[ -r "$_z" && -n "$(cat "$_z" 2>/dev/null)" ]] && {
                has_temp=true
                break
            }
        done
        if grep -q "cputemp: $has_temp" "$widgets_file"; then
            log_skip "Homepage cputemp already $has_temp"
        else
            sed -i "s/cputemp: .*/cputemp: $has_temp/" "$widgets_file"
            if $has_temp; then
                log_ok "Homepage cputemp enabled"
            else
                log_ok "Homepage cputemp disabled (no host thermal sensor)"
            fi
        fi
    fi

    # NAS storage label: on NAS installs with the storage watchdog running, show
    # the header /data disk readout as its own labeled "NAS" block (NFS-backed
    # storage). Gated like cputemp — local installs, and NAS without the
    # watchdog, keep disk folded into the main resources widget.
    local nas_label=false
    if storage_is_nas && systemctl is-active --quiet mediastack-storage-watchdog.service 2>/dev/null; then
        nas_label=true
    fi
    _homepage_apply_nas_label "$widgets_file" "$nas_label"
}

# Split the header /data disk readout into a labeled "NAS" resources block
# (want=true) or fold it back into the main resources widget (want=false).
# Idempotent; a pure function of the widgets file + want flag (unit-tested in
# tests/unit/homepage-nas-label.sh). /data is the in-container mount path.
_homepage_apply_nas_label() {
    local widgets_file="$1" want="$2" nas_result
    [[ -f "$widgets_file" ]] || return 0
    nas_result=$(WIDGETS_FILE="$widgets_file" NAS_LABEL="$want" python3 -c '
import os, yaml

want_nas = os.environ["NAS_LABEL"] == "true"
path = os.environ["WIDGETS_FILE"]
with open(path) as f:
    widgets = yaml.safe_load(f) or []

DISK, LABEL = "/data", "NAS"
main_res, nas_idx = None, None
for i, item in enumerate(widgets):
    if not isinstance(item, dict) or "resources" not in item:
        continue
    r = item["resources"] or {}
    if r.get("label") == LABEL and "disk" in r:
        nas_idx = i
    elif "cpu" in r or "memory" in r:
        main_res = r

changed = False
if want_nas:
    if main_res is not None and "disk" in main_res:
        del main_res["disk"]; changed = True
    if nas_idx is None:
        widgets.append({"resources": {"label": LABEL, "disk": DISK, "expanded": True}})
        changed = True
else:
    if nas_idx is not None:
        widgets.pop(nas_idx); changed = True
    if main_res is not None and main_res.get("disk") != DISK:
        main_res["disk"] = DISK; changed = True

if not changed:
    print("SKIP")
else:
    with open(path, "w") as f:
        yaml.safe_dump(widgets, f, default_flow_style=False, sort_keys=False)
    print("OK")
') || return 0
    case "$nas_result" in
        SKIP) log_skip "Homepage NAS storage label already correct" ;;
        OK) if [[ "$want" == true ]]; then
            log_ok "Homepage NAS storage label enabled"
        else
            log_ok "Homepage NAS storage label reset (not NAS+watchdog)"
        fi ;;
    esac
}
