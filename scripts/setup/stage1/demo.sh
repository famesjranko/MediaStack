# Owns: Stage 1 non-interactive DEMO=1 collection and install handoff.
# Sources: env state, wizard application, and Stage 1 install helpers.

_demo_stage1_noninteractive() {
    _WIZ_TZ="${_WIZ_PREV_TZ:-${_ENV_TZ:-Etc/UTC}}"
    _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
    _WIZ_STORAGE_MODE="${_WIZ_PREV_STORAGE_MODE:-local}"
    _WIZ_STORAGE_APP_WIRING="${_WIZ_PREV_STORAGE_APP_WIRING:-managed}"
    _WIZ_STORAGE_PROTOCOL="${_WIZ_PREV_STORAGE_PROTOCOL:-}"
    _WIZ_STORAGE_MOUNTPOINT="${_WIZ_PREV_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}"
    _WIZ_STORAGE_NFS_HOST="${_WIZ_PREV_STORAGE_NFS_HOST:-}"
    _WIZ_STORAGE_NFS_EXPORT="${_WIZ_PREV_STORAGE_NFS_EXPORT:-}"
    _WIZ_STORAGE_NFS_OPTS="${_WIZ_PREV_STORAGE_NFS_OPTS:-}"
    _WIZ_STORAGE_SENTINEL="${_WIZ_PREV_STORAGE_SENTINEL:-${_WIZ_STORAGE_MOUNTPOINT}/.mediastack-storage-ready}"
    _WIZ_ADMIN_USER="${_WIZ_PREV_USER:-admin}"
    _WIZ_ADMIN_EMAIL="${_WIZ_PREV_EMAIL:-admin@mediastack.local}"
    _WIZ_DOMAIN=""
    _WIZ_TORRENT_PORT="${_WIZ_PREV_TORRENT_PORT:-6881}"
    _WIZ_IMAGE_CHANNEL="${_WIZ_PREV_IMAGE_CHANNEL:-stable}"
    _WIZ_DL_LIMIT="${_WIZ_PREV_DL:-0}"
    _WIZ_UL_LIMIT="${_WIZ_PREV_UL:-0}"
    _WIZ_PUBLIC_INDEXERS_ENABLED="${_WIZ_PREV_PUBLIC_INDEXERS:-false}"
    _WIZ_BAZARR_ENABLED="${_WIZ_PREV_BAZARR:-false}"
    _WIZ_SMB_ENABLED="${_WIZ_PREV_SMB:-false}"
    _WIZ_SMB_SHARE_SCOPE="${_WIZ_PREV_SMB_SHARE_SCOPE:-data}"
    _WIZ_UFW_ENABLED="${_WIZ_PREV_UFW:-true}"
    _WIZ_HARDENING_ENABLED="${_WIZ_PREV_HARDENING:-true}"
    _WIZ_WG_HOST=""
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR=""
    _WIZ_WG_SERVER_LAN_IP=""
    _WIZ_WG_INIT_ALLOWED_IPS=""
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD=""
    _WIZ_DDNS_PROVIDER=""
    _WIZ_DDNS_FIELDS=()
    _WIZ_DDNS_PREFLIGHT_OK=""
    _WIZ_DDNS_INVALIDATED=""

    local password_source="generated"
    # Pre-seed the prompt default ONLY if the existing password meets the
    # 12-char floor that the validator now enforces (matches Portainer's
    # requirement). Older installs with 8-11 char passwords get a fresh
    # generated default — user can still type the old one if they want
    # but the validator will reject it.
    if [[ -n "${_WIZ_PREV_PW:-}" && "${_WIZ_PREV_PW}" != "changeme" && ${#_WIZ_PREV_PW} -ge 12 ]]; then
        _WIZ_ADMIN_PW="$_WIZ_PREV_PW"
        password_source="preseeded"
    else
        if ! _WIZ_ADMIN_PW=$(openssl rand -base64 16 2>/dev/null); then
            log_error "DEMO: openssl rand failed; cannot generate admin password"
            exit 1
        fi
    fi

    if [[ "$_WIZ_ADMIN_USER" == *\'* ]]; then
        log_error "DEMO: admin username cannot contain a single quote (')"
        exit 1
    fi
    if [[ "$_WIZ_ADMIN_PW" == *\'* ]]; then
        log_error "DEMO: admin password cannot contain a single quote (')"
        exit 1
    fi

    log_info "DEMO: data=${_WIZ_DATA_DIR} torrent=${_WIZ_TORRENT_PORT} pw_source=${password_source}"

    _wizard_apply_settings \
        "${_WIZ_QUALITY_RESOLUTION:-1080p}" \
        "${_WIZ_QUALITY_SIZE:-balanced}" \
        "${_WIZ_SUBTITLE_LANGS:-english}" \
        "0" \
        "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}"
    _stage1_install
}
