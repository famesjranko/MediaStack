# =============================================================================
# MediaStack Setup — Environment detection and .env generation
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# detect_env()  — non-interactive auto-detection, sets shell variables.
# write_env()   — writes .env from globals set by detect_env + wizard.

detect_env() {
    _ENV_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
    _ENV_PUID=$(id -u)
    _ENV_PGID=$(id -g)
    _ENV_HOST_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
    _ENV_HOST_ADDRESS="${_ENV_HOST_ADDRESS:-localhost}"
}

_ddns_updater_owner() {
    printf '%s:%s' "${DDNS_UPDATER_UID:-1000}" "${DDNS_UPDATER_GID:-1000}"
}

_ddns_prepare_config_dir() {
    local ddns_dir="$1"
    local owner
    owner="$(_ddns_updater_owner)"
    local current_owner

    if [[ -L "$ddns_dir" ]]; then
        log_warn "Refusing to use symlinked DDNS config directory: $ddns_dir"
        return 1
    fi
    if ! mkdir -p "$ddns_dir" 2>/dev/null; then
        sudo mkdir -p "$ddns_dir" || return 1
    fi
    if [[ -L "$ddns_dir" || ! -d "$ddns_dir" ]]; then
        log_warn "Refusing to use unsafe DDNS config directory: $ddns_dir"
        return 1
    fi
    current_owner=$(stat -c '%u:%g' "$ddns_dir" 2>/dev/null || true)
    if [[ "$current_owner" != "$owner" ]]; then
        if ! chown "$owner" "$ddns_dir" 2>/dev/null; then
            sudo chown "$owner" "$ddns_dir" || return 1
        fi
    fi
    if ! chmod 755 "$ddns_dir" 2>/dev/null; then
        sudo chmod 755 "$ddns_dir" || return 1
    fi
}

_ddns_secure_config_file() {
    local config_file="$1"
    local owner
    owner="$(_ddns_updater_owner)"
    local current_owner

    if [[ -L "$config_file" ]]; then
        log_warn "Refusing to secure symlinked DDNS config path: $config_file"
        return 1
    fi
    current_owner=$(stat -c '%u:%g' "$config_file" 2>/dev/null || true)
    if [[ "$current_owner" != "$owner" ]]; then
        if ! chown "$owner" "$config_file" 2>/dev/null; then
            sudo chown "$owner" "$config_file" || return 1
        fi
    fi
    if ! chmod 600 "$config_file" 2>/dev/null; then
        sudo chmod 600 "$config_file" || return 1
    fi
}

repair_ddns_updater_config_permissions() {
    local ddns_dir="$SCRIPT_DIR/config/ddns-updater"
    local ddns_config="$ddns_dir/config.json"

    _ddns_prepare_config_dir "$ddns_dir" || return 1
    if [[ -e "$ddns_config" || -L "$ddns_config" ]]; then
        _ddns_secure_config_file "$ddns_config" || return 1
    fi
}

_env_quote_preserved_secret() {
    local out_var="$1" label="$2" value="$3"
    if [[ "$value" == *"'"* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        log_warn "Ignoring preserved ${label} with unsupported quote/newline characters."
        printf -v "$out_var" "''"
        return 0
    fi
    printf -v "$out_var" "'%s'" "$value"
}

# Resolve the persisted NVIDIA driver-management mode from prior state. Migrates
# the legacy NVIDIA_PATCH_ENABLED boolean (public shipped it before the mode var)
# to "unlock", validates the value, and echoes standard|unlock|existing or "".
# Fresh installs echo "" — the wizard sets "standard" only once a driver installs.
_nvidia_resolve_driver_mode() {
    local _mode="${1:-}" _legacy_patch="${2:-}"
    if [[ -z "$_mode" && "$_legacy_patch" == "true" ]]; then
        _mode="unlock"
    fi
    case "$_mode" in
        standard|unlock|existing) printf '%s' "$_mode" ;;
        *) printf '' ;;
    esac
}

write_env() {
    local remote_web_state="${_WIZ_REMOTE_WEB_STATE:-}"
    if [[ -z "$remote_web_state" && -n "${_WIZ_DOMAIN:-}" && "${_WIZ_DOMAIN}" != "example.com" ]]; then
        remote_web_state="unchecked"
    fi

    local prev_sonarr="${SONARR_API_KEY:-}"
    local prev_radarr="${RADARR_API_KEY:-}"
    local prev_jellyfin="${JELLYFIN_API_KEY:-}"
    local prev_bazarr="${BAZARR_API_KEY:-}"
    local prev_seerr="${SEERR_API_KEY:-}"
    local prev_portainer="${PORTAINER_API_KEY:-}"
    local prev_beszel="${BESZEL_AGENT_KEY:-}"
    local prev_stage1="${STAGE_1_COMPLETE:-}"
    local prev_npm_le_server="${NPM_LE_SERVER:-}"
    local prev_jellyfin_gpu="${JELLYFIN_GPU:-}"
    local prev_nvidia_driver_mode="${NVIDIA_DRIVER_MODE:-}"
    local prev_nvidia_patch_enabled="${NVIDIA_PATCH_ENABLED:-}"
    local prev_image_channel="${IMAGE_CHANNEL:-}"
    local prev_public_indexers="${PUBLIC_INDEXERS_ENABLED:-}"
    local prev_stage3_state="${STAGE_3_GPU_STATE:-}"
    local prev_stage3_vendor="${STAGE_3_GPU_VENDOR:-}"
    local prev_stage3_encoder="${STAGE_3_GPU_ENCODER:-}"
    local prev_stage3_hw_decoding_codecs="${STAGE_3_GPU_HW_DECODING_CODECS:-}"
    local prev_stage3_decode_hevc_10bit="${STAGE_3_GPU_DECODE_HEVC_10BIT:-}"
    local prev_stage3_decode_vp9_10bit="${STAGE_3_GPU_DECODE_VP9_10BIT:-}"
    local prev_stage3_allow_hevc_encoding="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-}"
    local prev_stage3_allow_av1_encoding="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-}"
    local prev_stage3_render_device="${STAGE_3_GPU_RENDER_DEVICE:-}"
    local prev_storage_expected_source="${STORAGE_EXPECTED_SOURCE:-}"
    local prev_storage_expected_fstype="${STORAGE_EXPECTED_FSTYPE:-}"
    local prev_unpackerr_torrent_paths="${UNPACKERR_TORRENT_PATHS:-}"
    local prev_mediastack_network_prefix="${MEDIASTACK_NETWORK_PREFIX:-}"
    local prev_mediastack_subnet="${MEDIASTACK_SUBNET:-}"
    local prev_mediastack_gateway="${MEDIASTACK_GATEWAY:-}"

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        local existing_env
        existing_env=$(python3 - "$SCRIPT_DIR/.env" <<'PY'
import pathlib
import shlex
import sys

wanted = {
    "SONARR_API_KEY", "RADARR_API_KEY", "JELLYFIN_API_KEY", "BAZARR_API_KEY",
    "SEERR_API_KEY", "PORTAINER_API_KEY", "BESZEL_AGENT_KEY",
    "STAGE_1_COMPLETE", "NPM_LE_SERVER", "JELLYFIN_GPU", "IMAGE_CHANNEL",
    "PUBLIC_INDEXERS_ENABLED", "NVIDIA_DRIVER_MODE", "NVIDIA_PATCH_ENABLED",
    "STAGE_3_GPU_STATE", "STAGE_3_GPU_VENDOR", "STAGE_3_GPU_ENCODER",
    "STAGE_3_GPU_HW_DECODING_CODECS", "STAGE_3_GPU_DECODE_HEVC_10BIT",
    "STAGE_3_GPU_DECODE_VP9_10BIT", "STAGE_3_GPU_ALLOW_HEVC_ENCODING",
    "STAGE_3_GPU_ALLOW_AV1_ENCODING", "STAGE_3_GPU_RENDER_DEVICE",
    "STORAGE_EXPECTED_SOURCE", "STORAGE_EXPECTED_FSTYPE",
        "UNPACKERR_TORRENT_PATHS", "MEDIASTACK_NETWORK_PREFIX",
        "MEDIASTACK_SUBNET", "MEDIASTACK_GATEWAY",
}
for raw in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    if key in wanted:
        try:
            parsed = shlex.split(value, posix=True)
            value = parsed[0] if parsed else ""
        except ValueError:
            pass
        print(f"{key}={shlex.quote(value)}")
PY
)
        eval "$existing_env"
        prev_sonarr="${SONARR_API_KEY:-$prev_sonarr}"
        prev_radarr="${RADARR_API_KEY:-$prev_radarr}"
        prev_jellyfin="${JELLYFIN_API_KEY:-$prev_jellyfin}"
        prev_bazarr="${BAZARR_API_KEY:-$prev_bazarr}"
        prev_seerr="${SEERR_API_KEY:-$prev_seerr}"
        prev_portainer="${PORTAINER_API_KEY:-$prev_portainer}"
        prev_beszel="${BESZEL_AGENT_KEY:-$prev_beszel}"
        prev_stage1="${STAGE_1_COMPLETE:-$prev_stage1}"
        prev_npm_le_server="${NPM_LE_SERVER:-$prev_npm_le_server}"
        prev_jellyfin_gpu="${JELLYFIN_GPU:-$prev_jellyfin_gpu}"
        prev_nvidia_driver_mode="${NVIDIA_DRIVER_MODE:-$prev_nvidia_driver_mode}"
        prev_nvidia_patch_enabled="${NVIDIA_PATCH_ENABLED:-$prev_nvidia_patch_enabled}"
        prev_image_channel="${IMAGE_CHANNEL:-$prev_image_channel}"
        prev_public_indexers="${PUBLIC_INDEXERS_ENABLED:-$prev_public_indexers}"
        prev_stage3_state="${STAGE_3_GPU_STATE:-$prev_stage3_state}"
        prev_stage3_vendor="${STAGE_3_GPU_VENDOR:-$prev_stage3_vendor}"
        prev_stage3_encoder="${STAGE_3_GPU_ENCODER:-$prev_stage3_encoder}"
        prev_stage3_hw_decoding_codecs="${STAGE_3_GPU_HW_DECODING_CODECS:-$prev_stage3_hw_decoding_codecs}"
        prev_stage3_decode_hevc_10bit="${STAGE_3_GPU_DECODE_HEVC_10BIT:-$prev_stage3_decode_hevc_10bit}"
        prev_stage3_decode_vp9_10bit="${STAGE_3_GPU_DECODE_VP9_10BIT:-$prev_stage3_decode_vp9_10bit}"
        prev_stage3_allow_hevc_encoding="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-$prev_stage3_allow_hevc_encoding}"
        prev_stage3_allow_av1_encoding="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-$prev_stage3_allow_av1_encoding}"
        prev_stage3_render_device="${STAGE_3_GPU_RENDER_DEVICE:-$prev_stage3_render_device}"
        prev_storage_expected_source="${STORAGE_EXPECTED_SOURCE:-$prev_storage_expected_source}"
        prev_storage_expected_fstype="${STORAGE_EXPECTED_FSTYPE:-$prev_storage_expected_fstype}"
        prev_unpackerr_torrent_paths="${UNPACKERR_TORRENT_PATHS:-$prev_unpackerr_torrent_paths}"
        prev_mediastack_network_prefix="${MEDIASTACK_NETWORK_PREFIX:-$prev_mediastack_network_prefix}"
        prev_mediastack_subnet="${MEDIASTACK_SUBNET:-$prev_mediastack_subnet}"
        prev_mediastack_gateway="${MEDIASTACK_GATEWAY:-$prev_mediastack_gateway}"
    fi

    local jellyfin_gpu="none"
    case "$prev_jellyfin_gpu" in
        intel|amd|nvidia)
            if [[ "$prev_stage3_state" == "complete" ]]; then
                jellyfin_gpu="$prev_jellyfin_gpu"
            else
                prev_stage3_hw_decoding_codecs=""
                prev_stage3_decode_hevc_10bit=""
                prev_stage3_decode_vp9_10bit=""
                prev_stage3_allow_hevc_encoding=""
                prev_stage3_allow_av1_encoding=""
                prev_stage3_render_device=""
            fi
            ;;
        *)
            prev_stage3_hw_decoding_codecs=""
            prev_stage3_decode_hevc_10bit=""
            prev_stage3_decode_vp9_10bit=""
            prev_stage3_allow_hevc_encoding=""
            prev_stage3_allow_av1_encoding=""
            prev_stage3_render_device=""
            ;;
    esac

    # NVIDIA driver-management mode is the single source of truth (patch-enabled
    # is derived: true iff "unlock"). Legacy NVIDIA_PATCH_ENABLED=true migrates to
    # "unlock"; see _nvidia_resolve_driver_mode.
    local nvidia_driver_mode
    nvidia_driver_mode=$(_nvidia_resolve_driver_mode "$prev_nvidia_driver_mode" "$prev_nvidia_patch_enabled")

    local desired_storage_source=""
    if [[ "${_WIZ_STORAGE_MODE:-local}" == "nas" && -n "${_WIZ_STORAGE_NFS_HOST:-}" && -n "${_WIZ_STORAGE_NFS_EXPORT:-}" ]]; then
        desired_storage_source="${_WIZ_STORAGE_NFS_HOST}:${_WIZ_STORAGE_NFS_EXPORT}"
    fi
    if [[ "${_WIZ_STORAGE_MODE:-local}" != "nas" ]]; then
        prev_storage_expected_source=""
        prev_storage_expected_fstype=""
    elif [[ -n "$prev_storage_expected_source" && "$prev_storage_expected_source" != "$desired_storage_source" ]]; then
        prev_storage_expected_source=""
        prev_storage_expected_fstype=""
    fi

    local storage_mode storage_app_wiring storage_mountpoint storage_sentinel
    storage_mode="${_WIZ_STORAGE_MODE:-local}"
    storage_app_wiring="${_WIZ_STORAGE_APP_WIRING:-managed}"
    storage_mountpoint="${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_DATA_DIR}}"
    storage_sentinel="${_WIZ_STORAGE_SENTINEL:-${_WIZ_DATA_DIR}/.mediastack-storage-ready}"
    if [[ "$storage_app_wiring" == "manual" && "$storage_mode" != "nas" ]]; then
        storage_mountpoint=""
        storage_sentinel=""
    fi
    local unpackerr_torrent_paths="/data/torrents"
    if [[ "$storage_app_wiring" == "manual" ]]; then
        unpackerr_torrent_paths=""
    elif [[ -n "$prev_unpackerr_torrent_paths" ]]; then
        unpackerr_torrent_paths="$prev_unpackerr_torrent_paths"
    fi
    if [[ "$unpackerr_torrent_paths" == *"'"* || "$unpackerr_torrent_paths" == *$'\n'* || "$unpackerr_torrent_paths" == *$'\r'* ]]; then
        log_warn "Ignoring custom UNPACKERR_TORRENT_PATHS with unsupported quote/newline characters."
        if [[ "$storage_app_wiring" == "manual" ]]; then
            unpackerr_torrent_paths=""
        else
            unpackerr_torrent_paths="/data/torrents"
        fi
    fi
    local unpackerr_torrent_paths_env="'${unpackerr_torrent_paths}'"

    local mediastack_network_prefix="${prev_mediastack_network_prefix:-172.28.0}"
    if ! [[ "$mediastack_network_prefix" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\.(0|[1-9][0-9]{0,2})$ ]]; then
        log_warn "Ignoring invalid MEDIASTACK_NETWORK_PREFIX '${mediastack_network_prefix}' - setup will use 172.28.0 unless collision checks choose another subnet."
        mediastack_network_prefix="172.28.0"
    else
        local _ms_third_octet="${mediastack_network_prefix##*.}"
        if (( 10#$_ms_third_octet > 255 )); then
            log_warn "Ignoring invalid MEDIASTACK_NETWORK_PREFIX '${mediastack_network_prefix}' - setup will use 172.28.0 unless collision checks choose another subnet."
            mediastack_network_prefix="172.28.0"
        fi
    fi
    local mediastack_network_values mediastack_subnet mediastack_gateway mediastack_npm_ip
    mediastack_network_values=$(NETWORK_PREFIX="$mediastack_network_prefix" \
        PREV_SUBNET="$prev_mediastack_subnet" \
        PREV_GATEWAY="$prev_mediastack_gateway" \
        python3 - <<'PY'
import ipaddress
import os

prefix = os.environ["NETWORK_PREFIX"]
prev_subnet = os.environ.get("PREV_SUBNET", "")
prev_gateway = os.environ.get("PREV_GATEWAY", "")
default_subnet = f"{prefix}.0/24"
default_gateway = f"{prefix}.1"
npm_ip = f"{prefix}.10"

subnet = default_subnet
gateway = default_gateway
try:
    candidate = ipaddress.ip_network(prev_subnet, strict=True)
    if (
        candidate.version == 4
        and candidate.prefixlen in (16, 24)
        and ".".join(str(candidate.network_address).split(".")[:3]) == prefix
        and ipaddress.ip_address(npm_ip) in candidate
    ):
        subnet = str(candidate)
        try:
            candidate_gateway = ipaddress.ip_address(prev_gateway)
            if candidate_gateway in candidate:
                gateway = str(candidate_gateway)
        except ValueError:
            pass
except ValueError:
    pass

print(f"{subnet}|{gateway}|{npm_ip}")
PY
    )
    IFS='|' read -r mediastack_subnet mediastack_gateway mediastack_npm_ip <<< "$mediastack_network_values"

    local image_channel="${_WIZ_IMAGE_CHANNEL:-${prev_image_channel:-stable}}"
    image_channel="${image_channel,,}"
    case "$image_channel" in
        stable|latest) ;;
        *)
            log_warn "Ignoring invalid IMAGE_CHANNEL '${image_channel}' - using stable."
            image_channel="stable"
            ;;
    esac

    local public_indexers_enabled="${_WIZ_PUBLIC_INDEXERS_ENABLED:-${prev_public_indexers:-false}}"
    [[ "$public_indexers_enabled" == "true" ]] || public_indexers_enabled="false"

    local prev_sonarr_env prev_radarr_env prev_jellyfin_env prev_bazarr_env
    local prev_seerr_env prev_portainer_env prev_beszel_env
    _env_quote_preserved_secret prev_sonarr_env "SONARR_API_KEY" "$prev_sonarr"
    _env_quote_preserved_secret prev_radarr_env "RADARR_API_KEY" "$prev_radarr"
    _env_quote_preserved_secret prev_jellyfin_env "JELLYFIN_API_KEY" "$prev_jellyfin"
    _env_quote_preserved_secret prev_bazarr_env "BAZARR_API_KEY" "$prev_bazarr"
    _env_quote_preserved_secret prev_seerr_env "SEERR_API_KEY" "$prev_seerr"
    _env_quote_preserved_secret prev_portainer_env "PORTAINER_API_KEY" "$prev_portainer"
    _env_quote_preserved_secret prev_beszel_env "BESZEL_AGENT_KEY" "$prev_beszel"

    local ddns_username="" ddns_password=""
    if [[ "${_WIZ_DDNS_PREFLIGHT_OK:-false}" == "true" ]]; then
        ddns_username="${_WIZ_DDNS_USER:-}"
        ddns_password="${_WIZ_DDNS_PW:-}"
    fi
    if [[ -n "${_WIZ_DOMAIN:-}" && "${_WIZ_DOMAIN}" != "example.com" ]]; then
        if ! repair_ddns_updater_config_permissions; then
            log_error "Unsafe DDNS config directory. Refusing to enable proxy/DDNS profile until config/ddns-updater is a real directory."
            return 1
        fi
    fi

    local env_path="$SCRIPT_DIR/.env"
    local env_tmp
    if ! env_tmp=$(mktemp "${env_path}.tmp.XXXXXX"); then
        log_error "Failed to create temporary .env file."
        return 1
    fi
    if ! chmod 600 "$env_tmp"; then
        rm -f "$env_tmp" 2>/dev/null || true
        log_error "Failed to secure temporary .env file."
        return 1
    fi

    if ! cat > "$env_tmp" <<EOF
# Generated by setup.sh on $(date -Iseconds)

# --- Core ---
# Single-quoted: free-form user input. Bash source and Docker Compose .env
# parser both treat single-quoted values as literal, neutralising any
# shell-meaningful characters in the value. Validators reject single quotes
# in user input so no escaping is attempted here.
TZ='${_WIZ_TZ}'
PUID=${_ENV_PUID}
PGID=${_ENV_PGID}
DATA_DIR='${_WIZ_DATA_DIR}'
HOST_ADDRESS='${_ENV_HOST_ADDRESS}'
IMAGE_CHANNEL=${image_channel}
MEDIASTACK_NETWORK_PREFIX=${mediastack_network_prefix}
MEDIASTACK_SUBNET=${mediastack_subnet}
MEDIASTACK_GATEWAY=${mediastack_gateway}
MEDIASTACK_NPM_IP=${mediastack_npm_ip}

# --- Storage ---
STORAGE_MODE=${storage_mode}
STORAGE_APP_WIRING=${storage_app_wiring}
STORAGE_PROTOCOL=${_WIZ_STORAGE_PROTOCOL:-}
STORAGE_MOUNTPOINT='${storage_mountpoint}'
STORAGE_NFS_HOST='${_WIZ_STORAGE_NFS_HOST:-}'
STORAGE_NFS_EXPORT='${_WIZ_STORAGE_NFS_EXPORT:-}'
STORAGE_NFS_OPTS='${_WIZ_STORAGE_NFS_OPTS:-}'
STORAGE_SENTINEL='${storage_sentinel}'
STORAGE_EXPECTED_SOURCE='${prev_storage_expected_source}'
STORAGE_EXPECTED_FSTYPE='${prev_storage_expected_fstype}'

# --- Admin Credentials (shared across all services) ---
JELLYFIN_ADMIN_USER='${_WIZ_ADMIN_USER}'
# Single-quoted: passwords may contain \$ " \ # and other shell- or Compose-
# special characters. Bash source and Docker Compose .env parser both
# treat single-quoted values as literal. A single quote inside the value is
# rejected interactively (see wizard); no escaping is attempted here.
JELLYFIN_ADMIN_PASSWORD='${_WIZ_ADMIN_PW}'
NPM_ADMIN_EMAIL='${_WIZ_ADMIN_EMAIL}'

# --- GPU ---
JELLYFIN_GPU=${jellyfin_gpu}
# Primary NVIDIA driver-management state (standard|unlock|existing); patch-enabled
# is derived (true iff unlock). Migrated from a legacy NVIDIA_PATCH_ENABLED=true.
NVIDIA_DRIVER_MODE=${nvidia_driver_mode}

# --- Remote Access ---
DOMAIN=${_WIZ_DOMAIN:-example.com}
REMOTE_WEB_STATE=${remote_web_state}
NPM_LE_SERVER=${prev_npm_le_server}
# DDNS creds: persisted so wizard re-runs (./setup.sh --remote) pre-fill the
# Dynu prompts via _stage2_seed_wizard_defaults instead of asking again.
# ddns-updater itself reads from config/ddns-updater/config.json, not these
# vars — these exist purely for wizard recall on re-runs. Single-quoted
# because passwords may contain shell-special chars.
DDNS_USERNAME='${ddns_username}'
DDNS_PASSWORD='${ddns_password}'
WG_HOST=${_WIZ_WG_HOST:-example.com}
WG_PORT=${_WIZ_WG_PORT:-51820}
# Single-quoted: plaintext password may contain shell-special chars (\$ " \).
# v15 INIT_PASSWORD is first-start only; persisted here to match MediaStack's
# shared-credential pattern (JELLYFIN_ADMIN_PASSWORD lives here too).
WG_INIT_PASSWORD='${_WIZ_WG_INIT_PASSWORD:-}'
WG_DEFAULT_DNS=${_WIZ_WG_DNS:-1.1.1.1}
WG_ACCESS_TIER=${_WIZ_WG_ACCESS_TIER:-full-lan}
WG_LAN_CIDR='${_WIZ_WG_LAN_CIDR:-}'
WG_SERVER_LAN_IP=${_WIZ_WG_SERVER_LAN_IP:-${_ENV_HOST_ADDRESS}}
# Derived by the Stage-2 wizard from WG_ACCESS_TIER + WG_LAN_CIDR + WG_SERVER_LAN_IP.
# Power users wanting full-tunnel routing set this to '0.0.0.0/0, ::/0' AND
# WG_PER_CLIENT_FIREWALL=false (both required — the per-client firewall would
# otherwise drop the now-routed traffic).
WG_INIT_ALLOWED_IPS='${_WIZ_WG_INIT_ALLOWED_IPS:-192.168.0.0/16}'
WG_PER_CLIENT_FIREWALL=${_WIZ_WG_PER_CLIENT_FIREWALL:-true}

# --- qBittorrent ---
TORRENT_PORT=${_WIZ_TORRENT_PORT:-6881}
QBT_DL_LIMIT=${_WIZ_DL_LIMIT:-0}
QBT_UL_LIMIT=${_WIZ_UL_LIMIT:-0}
UNPACKERR_TORRENT_PATHS=${unpackerr_torrent_paths_env}
PUBLIC_INDEXERS_ENABLED=${public_indexers_enabled}

# --- Bazarr (subtitles) ---
BAZARR_ENABLED=${_WIZ_BAZARR_ENABLED:-false}

# --- SMB file share (LAN only) ---
SMB_ENABLED=${_WIZ_SMB_ENABLED:-false}
SMB_SHARE_SCOPE=${_WIZ_SMB_SHARE_SCOPE:-data}

# --- autoheal sidecar ---
AUTOHEAL_ENABLED=${AUTOHEAL_ENABLED:-true}

# --- API Keys (auto-populated by configure.sh) ---
SONARR_API_KEY=${prev_sonarr_env}
RADARR_API_KEY=${prev_radarr_env}
JELLYFIN_API_KEY=${prev_jellyfin_env}
BAZARR_API_KEY=${prev_bazarr_env}
SEERR_API_KEY=${prev_seerr_env}
PORTAINER_API_KEY=${prev_portainer_env}
# Single-quoted: generated API keys may include shell- or Compose-special
# characters, and beszel-agent keys contain spaces.
BESZEL_AGENT_KEY=${prev_beszel_env}

# --- Stage Markers ---
# Sentinel convention (do NOT change to '0'):
#   STAGE_1_COMPLETE=     -- Stage 1 not yet completed (initial value)
#   STAGE_1_COMPLETE=1    -- Stage 1 completed successfully
# stage1.sh and setup.sh both predicate on '== "1"' with ':-' empty default.
# Set to 1 by setup.sh after Stage 1 install completes successfully.
STAGE_1_COMPLETE=${prev_stage1}
STAGE_3_GPU_STATE=${prev_stage3_state}
STAGE_3_GPU_VENDOR=${prev_stage3_vendor}
STAGE_3_GPU_ENCODER=${prev_stage3_encoder}
STAGE_3_GPU_HW_DECODING_CODECS=${prev_stage3_hw_decoding_codecs}
STAGE_3_GPU_DECODE_HEVC_10BIT=${prev_stage3_decode_hevc_10bit}
STAGE_3_GPU_DECODE_VP9_10BIT=${prev_stage3_decode_vp9_10bit}
STAGE_3_GPU_ALLOW_HEVC_ENCODING=${prev_stage3_allow_hevc_encoding}
STAGE_3_GPU_ALLOW_AV1_ENCODING=${prev_stage3_allow_av1_encoding}
STAGE_3_GPU_RENDER_DEVICE=${prev_stage3_render_device}
EOF
    then
        rm -f "$env_tmp" 2>/dev/null || true
        log_error "Failed to write temporary .env file."
        return 1
    fi

    if ! mv -f "$env_tmp" "$env_path"; then
        rm -f "$env_tmp" 2>/dev/null || true
        log_error "Failed to replace .env atomically."
        return 1
    fi
    log_ok ".env generated (chmod 600)"

    # Seed DDNS config.json before containers start.
    # Always (over)write after the wizard verified Dynu credentials. The
    # previous "skip if file exists" guard left stale-empty config.json in
    # place when an earlier wizard run created the file with empty creds
    # (e.g. wizard was killed mid-flow, or a prior code path skipped
    # credential collection). Verified wizard creds are authoritative.
    if [[ -n "$ddns_username" ]]; then
        local ddns_config="$SCRIPT_DIR/config/ddns-updater/config.json"
        local ddns_dir
        ddns_dir="$(dirname "$ddns_config")"
        local ddns_tmp=""
        local ddns_payload
        ddns_payload=$(DDNS_DOMAIN="$_WIZ_DOMAIN" DDNS_USERNAME="$ddns_username" DDNS_PASSWORD="$ddns_password" \
            python3 -c '
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "username": os.environ["DDNS_USERNAME"],
    "password": os.environ["DDNS_PASSWORD"],
    "ip_version": "ipv4",
}]}, indent=2))
')
        # Keep the temp file outside config/ddns-updater: that directory is
        # deliberately writable by the fixed uid-1000 ddns-updater container.
        local ddns_write_ok=false
        if _ddns_prepare_config_dir "$ddns_dir"; then
            ddns_tmp=$(mktemp "$SCRIPT_DIR/.ddns-updater-config.XXXXXX" 2>/dev/null || true)
            if [[ -n "$ddns_tmp" ]] \
                && printf '%s\n' "$ddns_payload" > "$ddns_tmp" 2>/dev/null \
                && _ddns_secure_config_file "$ddns_tmp"; then
                if mv -f "$ddns_tmp" "$ddns_config" 2>/dev/null \
                    || sudo mv -f "$ddns_tmp" "$ddns_config"; then
                    ddns_tmp=""
                    if _ddns_secure_config_file "$ddns_config"; then
                        ddns_write_ok=true
                    fi
                fi
            fi
        fi
        [[ -n "$ddns_tmp" ]] && rm -f "$ddns_tmp" 2>/dev/null || true
        if $ddns_write_ok; then
            log_ok "DDNS config written ($_WIZ_DOMAIN - wildcard covers subdomains)"
        else
            log_warn "Failed to write DDNS config.json - configure manually at http://${_ENV_HOST_ADDRESS}:8000"
        fi
    fi

    export DATA_DIR="$_WIZ_DATA_DIR"
    export PUID="$_ENV_PUID"
    export PGID="$_ENV_PGID"
    export STORAGE_MODE="$storage_mode"
    export STORAGE_APP_WIRING="$storage_app_wiring"
    export STORAGE_PROTOCOL="${_WIZ_STORAGE_PROTOCOL:-}"
    export STORAGE_MOUNTPOINT="$storage_mountpoint"
    export STORAGE_NFS_HOST="${_WIZ_STORAGE_NFS_HOST:-}"
    export STORAGE_NFS_EXPORT="${_WIZ_STORAGE_NFS_EXPORT:-}"
    export STORAGE_NFS_OPTS="${_WIZ_STORAGE_NFS_OPTS:-}"
    export STORAGE_SENTINEL="$storage_sentinel"
    export UNPACKERR_TORRENT_PATHS="$unpackerr_torrent_paths"
    export IMAGE_CHANNEL="$image_channel"
    export PUBLIC_INDEXERS_ENABLED="$public_indexers_enabled"
    export MEDIASTACK_NETWORK_PREFIX="$mediastack_network_prefix"
    export MEDIASTACK_SUBNET="$mediastack_subnet"
    export MEDIASTACK_GATEWAY="$mediastack_gateway"
    export MEDIASTACK_NPM_IP="$mediastack_npm_ip"
}
