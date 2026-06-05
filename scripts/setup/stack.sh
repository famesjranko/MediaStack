# =============================================================================
# MediaStack Setup — Data dirs, config dirs, stack lifecycle, access info
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

# Shared docker-compose profile-arg builder (_build_profile_args), also used by
# the ./mediastack launcher so the day-2 menu's stop/start/status always targets
# the same profile set the installer used. Resolved relative to this file so
# every sourcer (setup.sh and the unit/scenario tests) finds it regardless of CWD.
_STACK_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/profiles.sh
source "$_STACK_HELPER_DIR/lib/profiles.sh"
unset _STACK_HELPER_DIR

_stack_env_get() {
    local key="$1"
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    python3 - "$SCRIPT_DIR/.env" "$key" <<'PY'
import pathlib
import shlex
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for raw in env_path.read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    name, value = raw.split("=", 1)
    if name != key:
        continue
    try:
        parsed = shlex.split(value, posix=True)
        print(parsed[0] if parsed else "", end="")
    except ValueError:
        print(value.strip("'\""), end="")
    break
PY
}

_stack_save_env_value() {
    local key="$1" value="$2"
    export "${key}=${value}"
    if [[ -f "$SCRIPT_DIR/.env" ]] && declare -F save_api_key >/dev/null; then
        save_api_key "$key" "$value"
    fi
}

ensure_mediastack_network_config() {
    local requested_prefix="${MEDIASTACK_NETWORK_PREFIX:-}"
    local requested_subnet="${MEDIASTACK_SUBNET:-}"
    local requested_gateway="${MEDIASTACK_GATEWAY:-}"
    local stage1_complete="${STAGE_1_COMPLETE:-}"
    if [[ -z "$requested_prefix" ]]; then
        requested_prefix="$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)"
    fi
    if [[ -z "$requested_subnet" ]]; then
        requested_subnet="$(_stack_env_get MEDIASTACK_SUBNET)"
    fi
    if [[ -z "$requested_gateway" ]]; then
        requested_gateway="$(_stack_env_get MEDIASTACK_GATEWAY)"
    fi
    if [[ -z "$stage1_complete" ]]; then
        stage1_complete="$(_stack_env_get STAGE_1_COMPLETE)"
    fi

    local tmp_dir routes_file addrs_file docker_file mediastack_file
    tmp_dir=$(mktemp -d)
    routes_file="$tmp_dir/routes.txt"
    addrs_file="$tmp_dir/addrs.txt"
    docker_file="$tmp_dir/docker.json"
    mediastack_file="$tmp_dir/mediastack.json"

    if command -v ip >/dev/null 2>&1; then
        ip -o -4 route show >"$routes_file" 2>/dev/null || : >"$routes_file"
        ip -o -4 addr show >"$addrs_file" 2>/dev/null || : >"$addrs_file"
    else
        : >"$routes_file"
        : >"$addrs_file"
    fi

    : >"$docker_file"
    : >"$mediastack_file"
    if command -v docker >/dev/null 2>&1; then
        local docker_network_ids
        docker_network_ids=$(docker network ls -q 2>/dev/null || true)
        if [[ -n "$docker_network_ids" ]]; then
            docker network inspect $docker_network_ids >"$docker_file" 2>/dev/null || : >"$docker_file"
        fi
        docker network inspect mediastack >"$mediastack_file" 2>/dev/null || : >"$mediastack_file"
    fi

    local selector_output selector_rc=0
    selector_output=$(REQUESTED_PREFIX="$requested_prefix" REQUESTED_SUBNET="$requested_subnet" REQUESTED_GATEWAY="$requested_gateway" STAGE1_COMPLETE="$stage1_complete" \
        python3 - "$routes_file" "$addrs_file" "$docker_file" "$mediastack_file" <<'PY'
import ipaddress
import json
import os
import pathlib
import re
import sys

routes_path, addrs_path, docker_path, mediastack_path = map(pathlib.Path, sys.argv[1:5])
requested_prefix = os.environ.get("REQUESTED_PREFIX", "")
requested_subnet = os.environ.get("REQUESTED_SUBNET", "")
requested_gateway = os.environ.get("REQUESTED_GATEWAY", "")
stage1_complete = os.environ.get("STAGE1_COMPLETE", "") == "1"


def valid_prefix(value):
    if not re.fullmatch(r"172\.(1[6-9]|2[0-9]|3[0-1])\.(0|[1-9][0-9]{0,2})", value or ""):
        return False
    try:
        return 0 <= int(value.rsplit(".", 1)[1]) <= 255
    except ValueError:
        return False


def net_for_prefix(prefix):
    return ipaddress.ip_network(f"{prefix}.0/24")


def parse_network(cidr):
    try:
        net = ipaddress.ip_network(cidr, strict=False)
    except ValueError:
        return None
    if net.version == 4 and net.prefixlen != 0:
        return net
    return None


def add_network(items, cidr, source):
    net = parse_network(cidr)
    if net is not None:
        items.append((net, source))


def docker_networks(path):
    text = path.read_text().strip()
    if not text:
        return []
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    if isinstance(data, dict):
        data = [data]
    out = []
    for item in data:
        if not isinstance(item, dict):
            continue
        name = str(item.get("Name") or "")
        network_id = str(item.get("Id") or "")
        options = item.get("Options") or {}
        interfaces = set()
        if name:
            interfaces.add(name)
            interfaces.add(f"br-{name}")
        if network_id:
            interfaces.add(f"br-{network_id[:12]}")
        if isinstance(options, dict):
            bridge_name = options.get("com.docker.network.bridge.name")
            if bridge_name:
                interfaces.add(str(bridge_name))
        for cfg in ((item.get("IPAM") or {}).get("Config") or []):
            subnet = cfg.get("Subnet") if isinstance(cfg, dict) else None
            gateway = cfg.get("Gateway") if isinstance(cfg, dict) else None
            if subnet:
                out.append({
                    "name": name,
                    "subnet": subnet,
                    "gateway": gateway or "",
                    "interfaces": sorted(interfaces),
                })
    return out


existing_mediastack = []
for item in docker_networks(mediastack_path):
    net = parse_network(item["subnet"])
    if net is not None:
        existing_mediastack.append({
            "net": net,
            "gateway": item.get("gateway") or "",
            "interfaces": set(item.get("interfaces") or []),
        })

conflicts = []
for line in routes_path.read_text().splitlines():
    parts = line.split()
    if not parts or parts[0] == "default":
        continue
    token = parts[0]
    if "/" not in token:
        token = f"{token}/32"
    route_net = parse_network(token)
    if route_net is not None and route_net.prefixlen <= 1:
        continue
    add_network(conflicts, token, f"host route: {line}")

for line in addrs_path.read_text().splitlines():
    parts = line.split()
    for idx, part in enumerate(parts):
        if part == "inet" and idx + 1 < len(parts):
            add_network(conflicts, parts[idx + 1], f"host address: {line}")
            break

for item in docker_networks(docker_path):
    name = item["name"]
    if name == "mediastack":
        continue
    add_network(conflicts, item["subnet"], f"Docker network {name}")


def source_interface(source):
    raw = source.split(": ", 1)[1] if ": " in source else source
    route_match = re.search(r"(?:^|\s)dev\s+(\S+)", raw)
    if route_match:
        return route_match.group(1).split("@", 1)[0]
    addr_match = re.match(r"\d+:\s+([^:\s]+)", raw)
    if addr_match:
        return addr_match.group(1).split("@", 1)[0]
    return ""


def is_own_mediastack_source(net, source):
    iface = source_interface(source)
    if not iface:
        return False
    for own in existing_mediastack:
        if net.overlaps(own["net"]) and iface in own["interfaces"]:
            return True
    return False


def conflicts_for(candidate):
    return [
        (net, source)
        for net, source in conflicts
        if candidate.overlaps(net) and not is_own_mediastack_source(net, source)
    ]


def ordered_prefixes():
    seen = set()
    preferred = []
    if valid_prefix(requested_prefix):
        preferred.append(requested_prefix)
    preferred.extend(["172.28.0", "172.29.0", "172.30.0", "172.31.0"])
    for prefix in preferred:
        if prefix not in seen:
            seen.add(prefix)
            yield prefix
    for second in range(16, 32):
        for third in range(0, 256):
            prefix = f"172.{second}.{third}"
            if prefix not in seen:
                seen.add(prefix)
                yield prefix


def prefix_from_net(net):
    parts = str(net.network_address).split(".")
    prefix = ".".join(parts[:3])
    return prefix if valid_prefix(prefix) else ""


def existing_record_for_prefix(prefix):
    candidate = net_for_prefix(prefix)
    for own in existing_mediastack:
        if candidate.subnet_of(own["net"]):
            return own
    return None


def requested_record_for_prefix(prefix):
    if not valid_prefix(prefix):
        return None
    net = parse_network(requested_subnet) if requested_subnet else net_for_prefix(prefix)
    if net is None:
        return None
    if prefix_from_net(net) != prefix:
        return None
    npm_ip = ipaddress.ip_address(f"{prefix}.10")
    if npm_ip not in net:
        return None
    gateway = requested_gateway or f"{prefix}.1"
    try:
        gateway_ip = ipaddress.ip_address(gateway)
    except ValueError:
        gateway = f"{prefix}.1"
        gateway_ip = ipaddress.ip_address(gateway)
    if gateway_ip not in net:
        gateway = f"{prefix}.1"
        gateway_ip = ipaddress.ip_address(gateway)
    if gateway_ip not in net:
        return None
    return {"net": net, "gateway": gateway, "interfaces": set()}


def first_existing_record():
    for own in existing_mediastack:
        prefix = prefix_from_net(own["net"])
        if prefix:
            return prefix, own
    return "", None


def emit_values(prefix, subnet=None, gateway=None):
    print(f"MEDIASTACK_NETWORK_PREFIX={prefix}")
    print(f"MEDIASTACK_SUBNET={subnet or f'{prefix}.0/24'}")
    print(f"MEDIASTACK_GATEWAY={gateway or f'{prefix}.1'}")
    print(f"MEDIASTACK_NPM_IP={prefix}.10")


if stage1_complete:
    locked_prefix, locked_record = first_existing_record()
    if not locked_prefix:
        locked_prefix = requested_prefix if valid_prefix(requested_prefix) else "172.28.0"
        locked_record = existing_record_for_prefix(locked_prefix) or requested_record_for_prefix(locked_prefix)
    locked_net = locked_record["net"] if locked_record else net_for_prefix(locked_prefix)
    locked_conflicts = conflicts_for(locked_net)
    if locked_conflicts:
        print(f"ERROR: MediaStack is already installed with Docker subnet {locked_net}, but that range now overlaps host networking.")
        print("INFO: This is usually caused by a LAN or VPN route using the same private range.")
        print("INFO: Disconnect or narrow the conflicting VPN/LAN route, then rerun setup.")
        print("INFO: MediaStack will not silently migrate an existing install to a different Docker subnet.")
        for net, source in locked_conflicts[:6]:
            print(f"INFO: conflict: {net} ({source})")
        sys.exit(1)
    emit_values(
        locked_prefix,
        str(locked_record["net"]) if locked_record else None,
        locked_record["gateway"] if locked_record else None,
    )
    sys.exit(0)

for prefix in ordered_prefixes():
    existing_record = existing_record_for_prefix(prefix)
    candidate = existing_record["net"] if existing_record else net_for_prefix(prefix)
    if not conflicts_for(candidate):
        emit_values(
            prefix,
            str(existing_record["net"]) if existing_record else None,
            existing_record["gateway"] if existing_record else None,
        )
        sys.exit(0)

print("ERROR: No available MediaStack Docker subnet found inside 172.16.0.0/12.")
print("INFO: A LAN, VPN, or corporate route appears to overlap every conservative Docker candidate.")
print("INFO: Disconnect or narrow the conflicting VPN route, then rerun setup.")
print("INFO: MediaStack intentionally does not auto-pick 10.x or 192.168.x in this mode because qBittorrent and firewall trust rules are scoped to Docker's 172.16.0.0/12 range.")
for net, source in conflicts[:8]:
    print(f"INFO: observed network: {net} ({source})")
sys.exit(1)
PY
    ) || selector_rc=$?
    rm -rf "$tmp_dir"

    if (( selector_rc != 0 )); then
        while IFS= read -r line; do
            case "$line" in
                ERROR:*) log_error "${line#ERROR: }" ;;
                INFO:*)  log_info "${line#INFO: }" ;;
                *)       [[ -n "$line" ]] && log_info "$line" ;;
            esac
        done <<< "$selector_output"
        return 1
    fi

    local prefix="" subnet="" gateway="" npm_ip="" key value
    while IFS='=' read -r key value; do
        case "$key" in
            MEDIASTACK_NETWORK_PREFIX) prefix="$value" ;;
            MEDIASTACK_SUBNET) subnet="$value" ;;
            MEDIASTACK_GATEWAY) gateway="$value" ;;
            MEDIASTACK_NPM_IP) npm_ip="$value" ;;
        esac
    done <<< "$selector_output"

    if [[ -z "$prefix" || -z "$subnet" || -z "$gateway" || -z "$npm_ip" ]]; then
        log_error "Could not determine MediaStack Docker subnet."
        return 1
    fi

    _stack_save_env_value MEDIASTACK_NETWORK_PREFIX "$prefix"
    _stack_save_env_value MEDIASTACK_SUBNET "$subnet"
    _stack_save_env_value MEDIASTACK_GATEWAY "$gateway"
    _stack_save_env_value MEDIASTACK_NPM_IP "$npm_ip"
    log_ok "Docker bridge subnet: ${subnet} (NPM ${npm_ip})"
}

pull_images() {
    cd "$SCRIPT_DIR" || return 1
    local profiles=()
    _build_profile_args profiles
    local image_channel="${IMAGE_CHANNEL:-stable}"
    image_channel="${image_channel,,}"

    # Count active-profile images and how many are already pulled locally.
    # --policy missing below means pulls only fetch what's actually new; this
    # preamble lets us short-circuit when nothing is missing and gives the user
    # an honest line about what's happening (they were previously seeing 20-30
    # min of "Downloading..." for images they already had — silent updates).
    local total=0 present=0
    local image_list
    image_list=$(docker compose "${profiles[@]}" config --images 2>/dev/null || true)
    if [[ -n "$image_list" ]]; then
        total=$(printf '%s\n' "$image_list" | grep -c .)
        present=$(printf '%s\n' "$image_list" \
            | xargs -r -I{} docker image inspect --format=ok {} 2>/dev/null \
            | grep -c ok || true)
    fi

    if (( total > 0 && present == total )); then
        log_ok "All ${total} images already present locally - skipping pull"
        if [[ "$image_channel" == "latest" ]]; then
            log_info "Latest channel selected - run ./scripts/update.sh to refresh upstream tags."
        else
            log_info "Stable channel selected - update MediaStack, then run ./scripts/update.sh to pull newer tested digests."
        fi
        return 0
    elif (( present > 0 && present < total )); then
        log_info "Pulling ${image_channel} channel container images (${present}/${total} already present, fetching $((total - present)) new)..."
    else
        log_info "Pulling ${image_channel} channel container images..."
    fi

    local attempt max_attempts=3
    local backoff=10
    for (( attempt=1; attempt<=max_attempts; attempt++ )); do
        if docker compose "${profiles[@]}" pull --policy missing 2>&1; then
            log_ok "All images pulled successfully"
            return 0
        fi

        if (( attempt < max_attempts )); then
            log_warn "Image pull failed (attempt ${attempt}/${max_attempts}). Retrying in ${backoff}s..."
            sleep "$backoff"
            backoff=$(( backoff * 2 ))
        fi
    done

    log_warn "Some images could not be pulled after ${max_attempts} attempts."
    log_warn "Continuing with cached images (if any). Services with missing images will not start."
    log_info "You can retry manually later: docker compose ${profiles[*]} pull --policy missing"
    if [[ "$image_channel" == "latest" ]]; then
        log_info "Latest channel selected - retry with ./scripts/update.sh when registry access recovers."
    else
        log_info "Stable channel selected - retry after updating MediaStack or restoring registry access."
    fi
    return 0
}

create_data_dirs() {
    local data_dir="${DATA_DIR:-/data}"
    # Default to the operator's actual uid/gid, NOT a hardcoded 1000.
    # On hosts where the operator isn't the first user (so they're uid
    # 1001+), defaulting to 1000 chowns /data to a different account and
    # the operator gets "not writable". env_gen.sh:12 already does this
    # — keep them aligned. Explicit PUID/PGID env vars still win when set.
    local puid="${PUID:-$(id -u)}"
    local pgid="${PGID:-$(id -g)}"

    if [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
        log_skip "Manual storage mode: leaving data directory structure untouched at ${data_dir}"
        return 0
    fi

    log_info "Creating data directory structure at ${data_dir}..."
    local dirs=(
        "${data_dir}/torrents/movies"
        "${data_dir}/torrents/tv"
        "${data_dir}/torrents/incomplete"
        "${data_dir}/media/movies"
        "${data_dir}/media/tv"
    )
    local d created=() sudo_created=()
    for d in "${dirs[@]}"; do
        if [[ ! -d "$d" ]]; then
            if mkdir -p "$d" 2>/dev/null; then
                :
            else
                sudo mkdir -p "$d"
                sudo_created+=("$d")
            fi
            created+=("$d")
        fi
    done

    if [[ "${STORAGE_MODE:-local}" == "nas" ]]; then
        for d in "${sudo_created[@]}"; do
            sudo chown "${puid}:${pgid}" "$d" 2>/dev/null || \
                log_warn "Could not chown NAS directory $d (NFS root-squash may block chown; continuing)"
        done
    else
        sudo chown -R "${puid}:${pgid}" "${data_dir}"
    fi
    log_ok "Data directories created"
}

stop_existing_stack() {
    # Capture-then-test avoids the SIGPIPE+pipefail race: piping into `grep -q`
    # reads false when grep's early exit SIGPIPEs compose under `set -eo pipefail`.
    local ids
    ids=$(docker compose ps -q 2>/dev/null || true)
    if [[ -z "$ids" ]]; then
        return 0
    fi
    log_info "Stopping existing containers (clean slate for config)..."
    # `--profile all` is a literal profile name, not a wildcard — without real
    # profile args, npm/bazarr/wireguard/autoheal survive the down.
    local profiles=()
    _build_profile_args profiles
    docker compose "${profiles[@]}" down 2>/dev/null || true
}

clear_qbittorrent_managed_seed_for_manual_storage() {
    [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]] || return 0

    local qbt_dir="$SCRIPT_DIR/config/qbittorrent/qBittorrent"
    local qbt_conf="$qbt_dir/qBittorrent.conf"
    local qbt_categories="$qbt_dir/categories.json"
    mkdir -p "$qbt_dir"

    local config_file="${CONFIG_FILE:-$SCRIPT_DIR/config.yml}"
    local qbt_save_path qbt_temp_path category_paths managed_paths changed
    qbt_save_path="$(CONFIG_FILE="$config_file" cfg_field "qbittorrent.save_path" 2>/dev/null || echo "/data/torrents")"
    qbt_temp_path="$(CONFIG_FILE="$config_file" cfg_field "qbittorrent.temp_path" 2>/dev/null || echo "/data/torrents/incomplete")"
    category_paths="$(CONFIG_FILE="$config_file" cfg_qbt_categories 2>/dev/null | cut -d: -f2- || true)"
    managed_paths=$(
        {
            printf '%s\n' "$qbt_save_path" "$qbt_temp_path"
            printf '%s\n' "$category_paths"
        } | sort -u
    )

    if ! changed=$(QBT_CONF="$qbt_conf" QBT_CATEGORIES="$qbt_categories" MANAGED_PATHS="$managed_paths" python3 - <<'PY'
import json
import os
from pathlib import Path

managed_paths = {line for line in os.environ.get("MANAGED_PATHS", "").splitlines() if line}
conf_path = Path(os.environ["QBT_CONF"])
cats_path = Path(os.environ["QBT_CATEGORIES"])
changed = False


def is_managed_path(value):
    value = value.strip()
    return value in managed_paths or value == "/data/torrents" or value.startswith("/data/torrents/")


path_keys = {
    "Downloads\\SavePath",
    "Downloads\\TempPath",
    "Session\\SavePath",
    "Session\\TempPath",
    "Session\\DefaultSavePath",
}
temp_enabled_keys = {
    "Downloads\\TempPathEnabled",
    "Session\\TempPathEnabled",
}

if conf_path.exists():
    original = conf_path.read_text()
    out = []
    for raw in original.splitlines():
        if "=" not in raw:
            out.append(raw)
            continue
        key, value = raw.split("=", 1)
        if key in path_keys and is_managed_path(value):
            changed = True
            continue
        if key in temp_enabled_keys and value.strip().lower() == "true":
            out.append(f"{key}=false")
            changed = True
            continue
        out.append(raw)
    new_text = "\n".join(out) + ("\n" if out else "")
    if new_text != original:
        conf_path.write_text(new_text)
        changed = True

if cats_path.exists():
    try:
        cats = json.loads(cats_path.read_text() or "{}")
    except json.JSONDecodeError:
        cats = {}
    if isinstance(cats, dict):
        kept = {}
        for name, meta in cats.items():
            save_path = ""
            if isinstance(meta, dict):
                save_path = str(meta.get("savePath", ""))
            if save_path and is_managed_path(save_path):
                changed = True
                continue
            kept[name] = meta
        if kept != cats:
            cats_path.write_text((json.dumps(kept, indent=2, sort_keys=True) if kept else "{}") + "\n")

if changed:
    print("changed")
PY
); then
        log_warn "Could not inspect qBittorrent seed paths for manual app wiring"
        return 0
    fi
    if [[ "$changed" == "changed" ]]; then
        log_ok "qBittorrent managed seed paths cleared (manual app wiring)"
    fi
    return 0
}

create_config_dirs() {
    log_info "Creating config directories..."
    local services=(jellyfin sonarr radarr jackett qbittorrent jellyseerr unpackerr homepage portainer wireguard ddns-updater bazarr uptime-kuma beszel)
    for svc in "${services[@]}"; do
        mkdir -p "$SCRIPT_DIR/config/${svc}"
    done
    if declare -F repair_ddns_updater_config_permissions >/dev/null; then
        repair_ddns_updater_config_permissions
    else
        # ddns-updater image runs as uid/gid 1000 (not root, no PUID/PGID support).
        # Keep its bind-mounted data directory aligned with the container user.
        sudo chown "${DDNS_UPDATER_UID:-1000}:${DDNS_UPDATER_GID:-1000}" "$SCRIPT_DIR/config/ddns-updater"
        sudo chmod 755 "$SCRIPT_DIR/config/ddns-updater"
    fi
    mkdir -p "$SCRIPT_DIR/config/npm/data"
    mkdir -p "$SCRIPT_DIR/config/npm/letsencrypt"
    mkdir -p "$SCRIPT_DIR/config/jellyfin/cache"
    clear_qbittorrent_managed_seed_for_manual_storage

    # fail2ban configs are shipped with the repo, ensure dirs exist
    mkdir -p "$SCRIPT_DIR/config/fail2ban/jail.d"
    mkdir -p "$SCRIPT_DIR/config/fail2ban/filter.d"

    # Pre-create log-source dirs so fail2ban mounts them before the
    # producing services (NPM/Jellyfin/Jellyseerr) create them on first run.
    # Without this, Docker auto-creates empty root-owned dirs at mount time
    # and fail2ban jails match nothing until each service is exercised.
    #
    # On re-run these dirs may already exist as root-owned (Docker created them).
    # Reclaim ownership so the touch calls below (and configure.sh writes) succeed.
    local log_dirs=(
        "$SCRIPT_DIR/config/npm/data/logs"
        "$SCRIPT_DIR/config/npm/data/nginx/custom"
        "$SCRIPT_DIR/config/jellyfin/log"
        "$SCRIPT_DIR/config/jellyseerr/logs"
    )
    for d in "${log_dirs[@]}"; do
        mkdir -p "$d"
        if [[ "$(stat -c '%u' "$d" 2>/dev/null)" != "$(id -u)" ]]; then
            sudo chown -R "$(id -u):$(id -g)" "$d"
        fi
    done

    # Touch placeholder log files so fail2ban's logpath globs match at boot.
    # Fail2ban refuses to start if any jail's logpath glob matches zero files
    # — an empty dir is not enough. The real services overwrite / supplement
    # these placeholders as they start writing their own logs.
    touch "$SCRIPT_DIR/config/jellyfin/log/log_.log"
    touch "$SCRIPT_DIR/config/npm/data/logs/default-host_.log"
    touch "$SCRIPT_DIR/config/npm/data/logs/proxy-host-___.log"
    touch "$SCRIPT_DIR/config/jellyseerr/logs/overseerr-.log"

    # Seed Homepage configs before first container start. Homepage's image
    # writes its own defaults (GitHub/Reddit/YouTube bookmarks, basic widgets)
    # on first start if these files are missing. Write them only if absent.
    local hp_dir="$SCRIPT_DIR/config/homepage"
    [[ -f "$hp_dir/bookmarks.yaml" ]] || echo '[]' > "$hp_dir/bookmarks.yaml"
    [[ -f "$hp_dir/docker.yaml" ]]    || echo '{}' > "$hp_dir/docker.yaml"
    if [[ ! -f "$hp_dir/widgets.yaml" ]]; then
        cat > "$hp_dir/widgets.yaml" <<'WIDGETS'
- greeting:
    text_size: xl
    text: MediaStack
- datetime:
    text_size: lg
    format:
      dateStyle: long
      timeStyle: short
      hour12: true
- resources:
    cpu: true
    memory: true
    cputemp: true
    network: true
    expanded: true
    refresh: 3000
    disk: /data
WIDGETS
    fi
    if [[ ! -f "$hp_dir/settings.yaml" ]]; then
        cat > "$hp_dir/settings.yaml" <<'SETTINGS'
title: MediaStack
theme: dark
color: slate
headerStyle: clean
background:
  image: https://images.unsplash.com/photo-1502790671504-542ad42d5189?auto=format&fit=crop&w=2560&q=80
  blur: sm
  brightness: 30
  opacity: 30
cardBlur: sm
iconStyle: theme
statusStyle: dot
SETTINGS
    fi

    log_ok "Config directories created"
}

start_stack() {
    log_info "Starting MediaStack..."
    cd "$SCRIPT_DIR" || return 1
    if declare -F storage_guard_before_start >/dev/null; then
        storage_guard_before_start
    fi
    if [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
        export UNPACKERR_TORRENT_PATHS="${UNPACKERR_TORRENT_PATHS-}"
    elif [[ -z "${UNPACKERR_TORRENT_PATHS:-}" ]]; then
        export UNPACKERR_TORRENT_PATHS="/data/torrents"
    fi
    local profiles=()
    _build_profile_args profiles
    # Stop containers from profiles that are no longer selected (re-run safety).
    # docker compose up -d does NOT stop containers from a previously-active
    # profile, so a domain→local switch would leave NPM/fail2ban running.
    if [[ ! " ${profiles[*]} " =~ " --profile proxy " ]]; then
        for svc in npm fail2ban ddns-updater; do
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
                log_info "Stopping leftover $svc (proxy profile no longer active)..."
                docker stop "$svc" >/dev/null 2>&1 && docker rm "$svc" >/dev/null 2>&1 || true
            fi
        done
    fi
    if [[ ! " ${profiles[*]} " =~ " --profile subtitles " ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx bazarr; then
            log_info "Stopping leftover bazarr (subtitles profile no longer active)..."
            docker stop bazarr >/dev/null 2>&1 && docker rm bazarr >/dev/null 2>&1 || true
        fi
    fi
    if [[ ! " ${profiles[*]} " =~ " --profile autoheal " ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx autoheal; then
            log_info "Stopping leftover autoheal (AUTOHEAL_ENABLED=false)..."
            docker stop autoheal >/dev/null 2>&1 && docker rm autoheal >/dev/null 2>&1 || true
        fi
    fi

    ensure_mediastack_network_config
    docker compose "${profiles[@]}" up -d
    log_ok "Containers started"
}

wait_all_healthy() {
    log_info "Waiting for services to become healthy (up to 2 minutes)..."
    local timeout=120
    local elapsed=0
    local interval=5
    local profiles=()
    _build_profile_args profiles
    local expected_services
    if (( $# > 0 )); then
        expected_services=$(printf '%s\n' "$@")
    else
        expected_services=$(docker compose "${profiles[@]}" ps --all --services 2>/dev/null || true)
    fi

    while (( elapsed < timeout )); do
        local status_report failed waiting no_health missing
        status_report=$(docker compose "${profiles[@]}" ps --all --format json 2>/dev/null | \
            EXPECTED_SERVICES="$expected_services" python3 -c "
import json
import os
import sys

expected = set(filter(None, os.environ.get('EXPECTED_SERVICES', '').split()))
records = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    obj = json.loads(line)
    if isinstance(obj, list):
        records.extend(obj)
    else:
        records.append(obj)

seen = set()
failed = []
waiting = []
no_health = []

for svc in records:
    service = str(svc.get('Service') or svc.get('service') or '')
    name = str(svc.get('Name') or svc.get('name') or service or 'unknown')
    label = service or name
    seen.add(service or label)

    state = str(svc.get('State') or svc.get('state') or '').lower()
    health = str(svc.get('Health') or svc.get('health') or '').lower()
    status_text = str(svc.get('Status') or svc.get('status') or '').lower()
    if not health:
        if 'unhealthy' in status_text:
            health = 'unhealthy'
        elif 'healthy' in status_text:
            health = 'healthy'

    if state == 'running':
        if health and health not in ('healthy', 'none', '-'):
            waiting.append(f'{label}({health})')
        elif health in ('', 'none', '-'):
            no_health.append(label)
    elif state in ('exited', 'dead'):
        failed.append(f'{label}({state})')
    elif state:
        waiting.append(f'{label}({state})')
    else:
        waiting.append(f'{label}(unknown)')

missing = sorted(expected - seen)
if not records and not expected:
    waiting.append('compose-status-unavailable')

print('failed\\t' + ' '.join(failed))
print('waiting\\t' + ' '.join(waiting))
print('no_health\\t' + ' '.join(no_health))
print('missing\\t' + ' '.join(missing))
" 2>/dev/null || printf 'failed\tcompose-status-unavailable\nwaiting\t\nno_health\t\nmissing\t\n')

        failed=""
        waiting=""
        no_health=""
        missing=""
        while IFS=$'\t' read -r key value; do
            case "$key" in
                failed) failed="$value" ;;
                waiting) waiting="$value" ;;
                no_health) no_health="$value" ;;
                missing) missing="$value" ;;
            esac
        done <<< "$status_report"

        if [[ -n "$failed" || -n "$missing" ]]; then
            echo ""
            [[ -n "$failed" ]] && log_warn "Some services stopped unexpectedly: ${failed}"
            [[ -n "$missing" ]] && log_warn "Some expected services are missing: ${missing}"
            log_info "Current container state:"
            docker compose "${profiles[@]}" ps || true
            return 1
        fi

        if [[ -z "$waiting" ]]; then
            if [[ -n "$no_health" ]]; then
                log_ok "All services healthy/running (no healthcheck: ${no_health})"
            else
                log_ok "All services healthy!"
            fi
            return 0
        fi

        echo -ne "\r  Waiting... (${elapsed}s) Still starting: ${waiting}    "
        sleep "$interval"
        (( elapsed += interval ))
    done

    echo ""
    log_warn "Some services may still be starting. Check: docker compose ps"
}

# Map REMOTE_WEB_STATE -> a human label. Single source of truth for the Stage 2
# row in print_final_summary AND the recovery re-entry menu's "Current setup"
# block, so the two never drift. Reads $1 (defaults to $REMOTE_WEB_STATE).
remote_state_label() {
    local remote_state="${1-${REMOTE_WEB_STATE:-}}"
    case "$remote_state" in
        ready) printf 'ready' ;;
        skipped) printf 'skipped -- run ./setup.sh --remote to retry' ;;
        failed) printf 'failed -- run ./setup.sh --remote to retry' ;;
        unchecked|"") printf 'not configured' ;;
        *) printf 'not configured' ;;
    esac
}

# Map STAGE_3_GPU_STATE (+ STAGE_3_GPU_VENDOR) -> a human label. Single source of
# truth for the Hardware-transcoding row in print_final_summary AND the recovery
# re-entry menu's "Current setup" block. Reads $1/$2 (default to the env vars).
transcoding_state_label() {
    local gpu_state="${1-${STAGE_3_GPU_STATE:-}}"
    local gpu_vendor="${2-${STAGE_3_GPU_VENDOR:-}}"
    case "$gpu_state" in
        complete)
            case "$gpu_vendor" in
                intel) printf 'complete (intel qsv)' ;;
                amd) printf 'complete (amd vaapi)' ;;
                nvidia) printf 'complete (nvidia nvenc)' ;;
                *) printf 'complete' ;;
            esac
            ;;
        pending)
            if [[ "$gpu_vendor" == "nvidia" ]]; then
                printf 'pending reboot -- NVIDIA finalization queued'
            else
                printf 'not configured'
            fi
            ;;
        skipped) printf 'skipped -- software transcoding' ;;
        fallback) printf 'fallback -- software transcoding' ;;
        *) printf 'not configured' ;;
    esac
}

print_final_summary() {
    if ! type ui_kv >/dev/null 2>&1; then
        ui_kv() { printf '%s: %s' "$1" "$2"; }
    fi

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi

    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    lan_ip="${lan_ip:-${HOST_ADDRESS:-localhost}}"
    # No routable IP detected - the Homepage/Jellyfin LAN rows fall back to loopback,
    # which only works on this box. Flag it so the box below carries a caveat instead
    # of silently presenting local-only links as if a phone/TV could reach them.
    local lan_local_only=false
    [[ "$lan_ip" == "localhost" ]] && lan_local_only=true

    local domain="${DOMAIN:-}"
    local remote_state="${REMOTE_WEB_STATE:-}"
    local admin="${JELLYFIN_ADMIN_USER:-admin}"
    local email="${NPM_ADMIN_EMAIL:-}"
    local wg_init_pw="${WG_INIT_PASSWORD:-}"

    local stage1_label="not configured"
    [[ "${STAGE_1_COMPLETE:-}" == "1" ]] && stage1_label="complete"

    local stage2_label
    stage2_label="$(remote_state_label "$remote_state")"

    local transcoding_label
    transcoding_label="$(transcoding_state_label "${STAGE_3_GPU_STATE:-}" "${STAGE_3_GPU_VENDOR:-}")"

    local homepage="http://${lan_ip}:3000"
    local jellyfin_lan="http://${lan_ip}:8096"
    local remote_ready=false
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready=true
    fi

    local rows=(
        "$(ui_kv 'Stage 1' "$stage1_label")"
        "$(ui_kv 'Stage 2' "$stage2_label")"
        "$(ui_kv 'Hardware transcoding' "$transcoding_label")"
        "$(ui_kv 'Homepage' "$homepage")"
        "$(ui_kv 'Jellyfin LAN' "$jellyfin_lan")"
    )
    if $remote_ready; then
        rows+=("$(ui_kv 'Jellyfin remote' "https://jellyfin.${domain}")")
        rows+=("$(ui_kv 'Jellyseerr remote' "https://jellyseerr.${domain}")")
    fi
    if [[ -n "$wg_init_pw" ]]; then
        rows+=("$(ui_kv 'WireGuard admin' "http://${lan_ip}:51821")")
    fi
    rows+=("$(ui_kv 'Admin user' "$admin")")
    rows+=("$(ui_kv 'Admin email' "$email")")

    if type ui_box >/dev/null 2>&1 && type ui_kv >/dev/null 2>&1; then
        ui_box "MediaStack setup complete" "${rows[@]}"
    else
        printf 'MediaStack setup complete\n'
        printf '%s\n' "${rows[@]}"
    fi

    # Loopback fallback: the Homepage/Jellyfin LAN rows above only work on this box.
    # Spell that out so a headless-server user doesn't read them as phone/TV links.
    if $lan_local_only; then
        echo ""
        echo -e "  ${YELLOW}LAN IP not detected - the localhost links above only work ON this machine.${NC}"
        echo -e "  ${YELLOW}Assign a static LAN IP (or set HOST_ADDRESS in .env), then re-run setup for${NC}"
        echo -e "  ${YELLOW}phone/TV-reachable links.${NC}"
    fi
}

# Echo the stored admin password (the single shared credential reused across every
# service) from .env, or nothing if unset. Single source of truth for the access
# summary's password line and the launcher's day-2 "reveal" so the two never drift,
# and so both always reflect the on-disk value rather than a possibly-stale env var.
_access_admin_pw() {
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    grep -oP "^JELLYFIN_ADMIN_PASSWORD='\\K[^']+" "$SCRIPT_DIR/.env" 2>/dev/null || true
}

# print_access_info [mask]
#   mask — render the admin password as a hidden placeholder instead of the value.
#   The one-time install summary calls this with no arg (shows the value, so the user
#   can save it). The re-openable day-2 launcher view passes `mask`, then offers an
#   explicit opt-in reveal — the shared credential should not be re-printed on screen
#   (or captured to a file) every time someone opens the menu.
print_access_info() {
    local mask_secret=false
    [[ "${1:-}" == "mask" ]] && mask_secret=true
    local lan_ip
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    # Mirror print_final_summary: honour an explicit HOST_ADDRESS from .env before
    # giving up to the loopback fallback, so a headless box with HOST_ADDRESS set
    # still renders routable URLs.
    lan_ip="${lan_ip:-${HOST_ADDRESS:-localhost}}"
    # When detection failed and we fell back to loopback, every ${u}:PORT row below
    # only works ON this machine. Flag it so we can print a caveat the headless-box
    # user won't otherwise connect to the earlier Stage 1 "LAN IP not detected" warning.
    local lan_local_only=false
    [[ "$lan_ip" == "localhost" ]] && lan_local_only=true

    local u="http://${lan_ip}"
    local admin="${JELLYFIN_ADMIN_USER:-admin}"
    local email="${NPM_ADMIN_EMAIL:-admin@example.com}"
    local torrent_port="${TORRENT_PORT:-6881}"
    local wg_port="${WG_PORT:-51820}"

    local admin_pw=""
    local domain=""
    local remote_state=""
    local wg_init_pw=""
    local jellyfin_gpu="${JELLYFIN_GPU:-none}"
    local stage3_state="${STAGE_3_GPU_STATE:-}"
    local public_indexers_enabled="${PUBLIC_INDEXERS_ENABLED:-false}"
    admin_pw=$(_access_admin_pw)
    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        domain=$(grep -oP '^DOMAIN=\K.*' "$SCRIPT_DIR/.env" | tr -d "'" | tr -d '"')
        remote_state=$(grep -oP '^REMOTE_WEB_STATE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        # WireGuard is gated on WG_INIT_PASSWORD alone, independent of DOMAIN (see
        # _build_profile_args' --profile remote) — so this drives the wg-easy admin
        # line below regardless of whether HTTPS/domain remote access was set up.
        wg_init_pw=$(grep -oP "^WG_INIT_PASSWORD='\\K[^']+" "$SCRIPT_DIR/.env" 2>/dev/null || true)
        jellyfin_gpu=$(grep -oP '^JELLYFIN_GPU=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        stage3_state=$(grep -oP '^STAGE_3_GPU_STATE=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
        public_indexers_enabled=$(grep -oP '^PUBLIC_INDEXERS_ENABLED=\K.*' "$SCRIPT_DIR/.env" 2>/dev/null | tr -d "'" | tr -d '"' || true)
    fi
    jellyfin_gpu="${jellyfin_gpu:-none}"
    public_indexers_enabled="${public_indexers_enabled:-false}"
    local has_domain=false
    if [[ -n "$domain" && "$domain" != "example.com" ]]; then
        has_domain=true
    fi
    local remote_ready=false
    if [[ "$remote_state" == "ready" && -n "$domain" && "$domain" != "example.com" ]]; then
        remote_ready=true
    fi

    echo ""
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
    echo -e "${BOLD}  MediaStack is running!${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
    echo ""
    echo -e "  ${BOLD}Admin user:${NC}       ${GREEN}${admin}${NC}"
    if [[ -n "$admin_pw" ]]; then
        if $mask_secret; then
            echo -e "  ${BOLD}Admin password:${NC}   ${YELLOW}(hidden — confirm the reveal prompt to show it)${NC}"
        else
            echo -e "  ${BOLD}Admin password:${NC}   ${GREEN}${admin_pw}${NC}"
        fi
    fi
    echo -e "  ${BOLD}Admin email:${NC}      ${GREEN}${email}${NC}"
    if [[ "${STORAGE_MODE:-local}" == "nas" ]]; then
        if [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
            echo -e "  ${BOLD}Storage:${NC}          ${YELLOW}NAS protected, manual app paths (${STORAGE_NFS_HOST:-unknown}:${STORAGE_NFS_EXPORT:-unknown})${NC}"
        else
            echo -e "  ${BOLD}Storage:${NC}          ${GREEN}NAS (${STORAGE_NFS_HOST:-unknown}:${STORAGE_NFS_EXPORT:-unknown})${NC}"
        fi
    elif [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
        echo -e "  ${BOLD}Storage:${NC}          ${YELLOW}manual - app storage paths were not auto-configured${NC}"
    fi
    echo ""
    # Every service below logs in with the single shared admin password shown (or, in the
    # masked day-2 view, revealable) at the top of this screen. Point each row's LOGIN at it
    # rather than the bare word "password", which a non-technical user can misread as a
    # literal value to type. Mode-aware so the masked view never implies a value is on screen.
    local cred_hint="(admin password above)"
    $mask_secret && cred_hint="(your admin password)"
    if $lan_local_only; then
        echo -e "  ${YELLOW}LAN IP not detected - the http://localhost URLs below only work ON this machine.${NC}"
        echo -e "  ${YELLOW}Assign a static LAN IP (or set HOST_ADDRESS in .env), then re-run setup to get${NC}"
        echo -e "  ${YELLOW}phone/TV-reachable links.${NC}"
        echo ""
    fi
    echo -e "  ${BOLD}SERVICE          URL                     LOGIN${NC}"
    echo -e "  ${CYAN}$(_g_repeat 61 "$_G_H")${NC}"
    echo -e "  Homepage         ${u}:3000     ${GREEN}no login${NC}"
    echo -e "  Jellyfin         ${u}:8096     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Sonarr           ${u}:8989     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Radarr           ${u}:7878     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  qBittorrent      ${u}:8080     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Jackett          ${u}:9117     ${GREEN}${cred_hint/%)/, no username)}${NC}"
    echo -e "  Jellyseerr       ${u}:5055     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Portainer        ${u}:9000     ${GREEN}${admin} / ${cred_hint}${NC}"
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        echo -e "  Bazarr           ${u}:6767     ${GREEN}${admin} / ${cred_hint}${NC}"
    fi
    echo -e "  Uptime Kuma      ${u}:3001     ${GREEN}${admin} / ${cred_hint}${NC}"
    echo -e "  Beszel           ${u}:8090     ${GREEN}${email} / ${cred_hint}${NC}"
    if $has_domain; then
        echo -e "  NPM Admin        ${u}:81       ${GREEN}${email} / ${cred_hint}${NC}"
    fi
    echo ""

    # WireGuard is a LAN-reachable admin service whenever the remote profile is up
    # (gated on WG_INIT_PASSWORD, not on having a domain) — its wg-easy UI is the
    # only place to download VPN client configs / QR codes, so surface it here.
    if [[ -n "$wg_init_pw" ]]; then
        echo -e "  ${BOLD}WireGuard VPN${NC}    ${u}:51821     ${GREEN}admin UI — get VPN client configs / QR here${NC}"
        echo ""
    fi

    if [[ "$stage3_state" == "complete" && "$jellyfin_gpu" != "none" ]]; then
        echo -e "  ${GREEN}GPU: ${jellyfin_gpu} transcoding enabled${NC}"
        echo "  Configure in Jellyfin > Dashboard > Playback > Transcoding"
        echo ""
    fi

    if [[ "${SMB_ENABLED:-false}" == "true" ]]; then
        local smb_share_name="Media"
        local smb_share_path="${DATA_DIR:-/data}"
        if [[ "${SMB_SHARE_SCOPE:-data}" == "system" ]]; then
            smb_share_name="MediaStackSystem"
            smb_share_path="/"
        fi
        echo -e "  ${GREEN}SMB share: \\\\${lan_ip}\\${smb_share_name} -> ${smb_share_path}${NC}"
        echo "  Connect with admin credentials from any device on your network"
        echo ""
    fi

    if [[ "$public_indexers_enabled" != "true" ]]; then
        echo -e "  ${YELLOW}No search indexers configured${NC} - Sonarr/Radarr can't find releases yet."
        echo "  Add them: copy entries from config/examples/public-indexers.yml into"
        echo "  config.yml, then run ./scripts/configure.sh (re-runs are safe - already-"
        echo "  configured services are skipped, never overwritten)."
        echo "  Or enable them anytime from the launcher:"
        echo "    ./mediastack -> Features (subtitles, file sharing, indexers) -> Search indexers"
        echo ""
    fi

    if $has_domain; then
        echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
        echo -e "  ${BOLD}REMOTE ACCESS${NC}"
        echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
        echo ""
        if $remote_ready; then
            echo -e "  ${BOLD}Jellyfin${NC}         https://jellyfin.${domain}"
            echo -e "  ${BOLD}Jellyseerr${NC}       https://jellyseerr.${domain}"
        elif [[ "$remote_state" == "skipped" ]]; then
            echo "  HTTPS skipped. LAN + VPN work. Run ./setup.sh --remote to try again."
        elif [[ "$remote_state" == "failed" ]]; then
            echo "  HTTPS setup failed. LAN + VPN work. Run ./setup.sh --remote after fixing the issue."
        else
            echo "  Remote access: not yet configured -- run ./setup.sh --remote"
        fi
        echo ""
    fi

    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo -e "  ${BOLD}PORT FORWARDING${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo ""
    echo "  Forward these ports to ${lan_ip} in your router:"
    echo ""
    echo "  TCP+UDP $(printf '%-6s' "$torrent_port")-> ${lan_ip}   (qBittorrent peer connections)"
    if $has_domain; then
        echo "  TCP 80        -> ${lan_ip}   (Let's Encrypt + HTTP redirect)"
        echo "  TCP 443       -> ${lan_ip}   (HTTPS - Jellyfin, Jellyseerr)"
        echo "  UDP $(printf '%-6s' "$wg_port")-> ${lan_ip}   (WireGuard VPN)"
    fi
    echo ""

    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo -e "  ${BOLD}GETTING STARTED${NC}"
    echo -e "${CYAN}$(_g_repeat 65 "$_G_H")${NC}"
    echo ""
    echo "  Open Homepage:    ${u}:3000"
    echo ""
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        echo -e "  ${YELLOW}Subtitles: add a provider at ${u}:6767/settings/providers${NC}"
        echo -e "  ${YELLOW}Recommended: OpenSubtitles.com (free account required)${NC}"
        echo ""
    fi
    if ! groups 2>/dev/null | grep -qw docker; then
        echo -e "  ${YELLOW}Log out and back in (or run: newgrp docker) to use docker commands${NC}"
        echo ""
    fi

    if [[ "$remote_ready" != "true" ]]; then
        echo ""
        echo -e "  ${BOLD}You can stop here. Your media server works on the LAN.${NC}"
        echo "  To enable remote access (HTTPS, VPN), run setup.sh again."
        echo ""
    fi
    echo -e "${CYAN}$(_g_repeat 65 "$_G_DH")${NC}"
}
