# Owns: Data/config directory creation, seeding from templates, and stop/qBittorrent-seed-path cleanup for setup.sh.
# Sources: scripts/setup/stack.sh state ($SCRIPT_DIR, $DATA_DIR) plus scripts/lib/common.sh.

create_data_dirs() {
    local data_dir="${DATA_DIR:-/data}"
    # Default to the operator's actual uid/gid, NOT a hardcoded 1000.
    # On hosts where the operator isn't the first user (so they're uid
    # 1001+), defaulting to 1000 chowns /data to a different account and
    # the operator gets "not writable". env-gen.sh:12 already does this
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
            sudo chown "${puid}:${pgid}" "$d" 2>/dev/null \
                || log_warn "Could not chown NAS directory $d (NFS root-squash may block chown; continuing)"
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
    profiles_build_args profiles
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

    if ! changed=$(
        QBT_CONF="$qbt_conf" QBT_CATEGORIES="$qbt_categories" MANAGED_PATHS="$managed_paths" python3 - <<'PY'
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

# Seed live service configs from the tracked templates under
# config/examples/defaults/. Copies each template to its live path only if the
# live file is absent (never clobbers a user's config). The live copies are
# gitignored and get wiped on uninstall; the templates survive (config/examples/
# is the only path the wipe preserves), so a wipe -> reinstall re-seeds cleanly.
# Kept log-free and dependency-free (find/cp/mkdir + $SCRIPT_DIR only) so it is
# safe to call from bare contexts such as the test harness's
# create_config_dirs_in_dind (which runs under set -e without common.sh).
seed_config_from_templates() {
    local tpl_root="$SCRIPT_DIR/config/examples/defaults"
    [[ -d "$tpl_root" ]] || return 0
    local f dest
    while IFS= read -r -d '' f; do
        dest="$SCRIPT_DIR/config/${f#"$tpl_root/"}"
        [[ -f "$dest" ]] || {
            mkdir -p "$(dirname "$dest")"
            cp "$f" "$dest"
        }
    done < <(find "$tpl_root" -type f -print0)
}

create_config_dirs() {
    log_info "Creating config directories..."
    local services=(jellyfin sonarr radarr jackett qbittorrent seerr unpackerr homepage portainer wireguard ddns-updater bazarr uptime-kuma beszel)
    for svc in "${services[@]}"; do
        mkdir -p "$SCRIPT_DIR/config/${svc}"
    done
    # Re-create the live pre-seed files (fail2ban jails/filters/action, homepage
    # YAML, jackett ServerConfig, qbittorrent conf/categories) from their tracked
    # templates. Must run before clear_qbittorrent_managed_seed_for_manual_storage
    # (edits the seeded qbt files) and before start_stack/configure.sh.
    seed_config_from_templates
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

    # Pre-create log-source dirs so fail2ban mounts them before the
    # producing services (NPM/Jellyfin/Seerr) create them on first run.
    # Without this, Docker auto-creates empty root-owned dirs at mount time
    # and fail2ban jails match nothing until each service is exercised.
    #
    # On re-run these dirs may already exist as root-owned (Docker created them).
    # Reclaim ownership so the touch calls below (and configure.sh writes) succeed.
    local log_dirs=(
        "$SCRIPT_DIR/config/npm/data/logs"
        "$SCRIPT_DIR/config/npm/data/nginx/custom"
        "$SCRIPT_DIR/config/jellyfin/log"
        "$SCRIPT_DIR/config/seerr/logs"
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
    touch "$SCRIPT_DIR/config/seerr/logs/seerr-.log"
    # The official Seerr image writes /app/config as uid/gid 1000.
    sudo chown -R 1000:1000 "$SCRIPT_DIR/config/seerr"

    # Homepage YAML (bookmarks/docker/widgets/settings) is seeded from the
    # templates by seed_config_from_templates above — including the dashboard
    # layout: block, which the old inline heredoc omitted.

    log_ok "Config directories created"
}
