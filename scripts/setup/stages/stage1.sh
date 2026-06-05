# =============================================================================
# MediaStack Setup — Stage 1 controller (Core LAN)
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

_stage1_mbps_to_mbs() {
    # Pass numeric inputs through the environment so python3 parses them with
    # float() rather than executing them as Python source. This keeps
    # speedtest-fed values (which travel through speedtest-cli's JSON output
    # and a Python parser) from ever reaching the eval surface, even if a
    # future speedtest-cli version returns a non-numeric token. Same shape
    # as stage2_ip_in_cloudflare_v4 in network.sh.
    MBPS="$1" RATIO="$2" python3 -c '
import os
mbps = float(os.environ["MBPS"])
ratio = float(os.environ["RATIO"])
value = (mbps * ratio) / 8
text = f"{value:.1f}"
print(text.rstrip("0").rstrip("."))
'
}

# Read a qBittorrent MB/s speed limit, re-prompting until valid. Delegates to the
# shared ui_input_validated + validate_mb_per_sec so the install prompt and the
# day-2 "Adjust bandwidth limits" launcher action use one input path (same
# grammar, same "MB/s" copy — no drift). The default must be numeric (callers
# pass a suggested/previous value or 0) so a non-TTY EOF returns it without
# looping.
_stage1_read_limit() {
    ui_input_validated "$1" "$2" validate_mb_per_sec
}

run_stage1() {
    # Sentinel convention: STAGE_1_COMPLETE is unset OR empty when Stage 1
    # has not yet completed; literal "1" means complete. env_gen.sh writes
    # the empty value (see 'STAGE_1_COMPLETE=${prev_stage1}' where
    # prev_stage1 defaults to ""), and setup.sh uses '${STAGE_1_COMPLETE:-}'
    # to match. Do NOT change this to ':-0' — the sentinel is empty, not 0,
    # and a non-empty default would change predicate semantics if env_gen
    # ever wrote an explicit "0".
    if [[ "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        log_skip "Stage 1 already complete - rerun setup to add remote access or hardware transcoding when needed"
        log_skip "To rebuild from scratch: docker compose down -v && ./setup.sh --full"
        # Mark the install path as complete so setup.sh::main() does not fall
        # through to stop_existing_stack / pull_images / configure.sh on a
        # benign re-run. Honors the graceful re-run invariant —
        # without this flag, every './setup.sh' after Stage 1 was complete
        # would tear down the running stack and re-pull images.
        WIZARD_RAN_INSTALL=true
        return 0
    fi

    ui_banner "MediaStack - Stage 1: Core LAN" "Working media server in 5-7 minutes"

    _wizard_run_discovery
    _stage1_show_system

    while true; do
        _stage1_collect_admin
        _stage1_collect_storage
        _stage1_collect_quality
        _stage1_collect_image_channel
        _stage1_collect_qbit

        local action
        _stage1_confirm
        action="${_STAGE1_CONFIRM_ACTION:-Back}"
        case "$action" in
            Install) break ;;
            Back) continue ;;
            Abort)
                _stage1_cleanup_preflight_nas_mount
                log_info "Setup aborted - re-run setup.sh to try again"
                exit 0
                ;;
        esac
    done

    _stage1_install
}

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
    _WIZ_WG_HOST=""
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR=""
    _WIZ_WG_SERVER_LAN_IP=""
    _WIZ_WG_INIT_ALLOWED_IPS=""
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD=""
    _WIZ_DDNS_USER=""
    _WIZ_DDNS_PW=""

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
        "${_WIZ_QUALITY_PRESET:-balanced}" \
        "${_WIZ_SUBTITLE_LANGS:-english}" \
        "0" \
        "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}"
    _stage1_install
}

_stage1_show_system() {
    local hostname_value os_value docker_value ram_value root_free data_path data_free
    hostname_value=$(hostname)
    os_value=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || echo "unknown")
    docker_value=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    ram_value=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2}')
    root_free=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}')
    data_path=$(_resolve_data_partition)
    data_free=$(df -BG "$data_path" 2>/dev/null | awk 'NR==2 {print $4}')

    ui_box "Detected your system" \
        "$(ui_kv 'Hostname' "$hostname_value")" \
        "$(ui_kv 'LAN IP' "${_ENV_HOST_ADDRESS:-unknown}")" \
        "$(ui_kv 'Public IP' "${_NET_PUBLIC_IP:-not detected - fine for LAN-only}")" \
        "$(ui_kv 'OS' "$os_value")" \
        "$(ui_kv 'Docker version' "${docker_value:-unknown}")" \
        "$(ui_kv 'RAM total' "${ram_value:-unknown}")" \
        "$(ui_kv 'GPU' "${GPU_TYPE:-none}")" \
        "$(ui_kv 'Timezone' "${_ENV_TZ:-Etc/UTC}")" \
        "$(ui_kv 'Disk free' "/=${root_free:-unknown} | ${data_path}=${data_free:-unknown}")"

    local tz_default action
    tz_default="${_WIZ_TZ:-${_WIZ_PREV_TZ:-${_ENV_TZ:-Etc/UTC}}}"
    action=$(ui_choose "Continue with these detected values?" \
        "Continue" \
        "Override timezone" \
        "Abort")

    case "$action" in
        "Override timezone")
            _WIZ_TZ=$(ui_input_validated "Timezone" "$tz_default" validate_timezone)
            ;;
        "Abort")
            log_info "Setup aborted - re-run setup.sh to try again"
            exit 0
            ;;
        *)
            _WIZ_TZ="$tz_default"
            ;;
    esac
}

_stage1_collect_admin() {
    ui_section 1 6 "Admin identity"

    local email_default password_default
    _WIZ_ADMIN_USER=$(ui_input_validated \
        "Admin username" \
        "${_WIZ_ADMIN_USER:-${_WIZ_PREV_USER:-admin}}" \
        validate_admin_user)

    email_default="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-}}"
    if [[ -z "$email_default" || "${email_default,,}" =~ @(example\.com|example\.net|example\.org)$ ]]; then
        email_default=""
    fi
    _WIZ_ADMIN_EMAIL=$(ui_input_validated \
        "Admin email (for SSL certs and service login)" \
        "$email_default" \
        validate_admin_email)

    password_default="${_WIZ_ADMIN_PW:-${_WIZ_PREV_PW:-}}"
    if [[ -z "$password_default" || "$password_default" == "changeme" || "$password_default" == *\'* || ${#password_default} -lt 12 ]]; then
        # WR-08: NEVER fall back to a hard-coded literal. The previous code
        # silently shipped 'GeneratedPassword123' as the default for every
        # service if openssl rand failed (rare on --full but possible on
        # Debian-minimal hosts where openssl was never installed). validators
        # would happily accept it. Result: universal default credential for
        # Jellyfin, Sonarr, Radarr, qBittorrent, NPM, Portainer, wg-easy,
        # Beszel — any LAN attacker owns the entire stack.
        # Match the _demo_stage1_noninteractive path, which already hard-fails
        # in this branch with a clear remediation.
        if ! password_default=$(openssl rand -base64 16 2>/dev/null); then
            log_error "openssl rand failed and no admin password is set."
            log_error "Install openssl: sudo apt-get install -y openssl"
            exit 1
        fi
    fi
    # Masked input: the admin password is the single shared credential for the whole
    # stack — never echo keystrokes (or the generated default) into terminal scrollback.
    _WIZ_ADMIN_PW=$(ui_password_validated \
        "Admin password" \
        "$password_default" \
        validate_admin_password)
}

_stage1_collect_storage() {
    ui_section 2 6 "Storage + optional services"

    local storage_choice local_default
    local_default="${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}"
    if [[ "${_WIZ_STORAGE_MODE:-local}" != "local" ]]; then
        local_default="${_WIZ_PREV_DATA_DIR:-/data}"
    fi
    storage_choice=$(ui_choose "Where should MediaStack store media and downloads?" \
        "Local disk (${local_default}) - Recommended for most users." \
        "Network/NAS storage (NFS) - MediaStack manages mount checks and service protection." \
        "Advanced manual storage - install apps but skip app-level storage wiring." \
        "Quit installer")

    case "$storage_choice" in
        "Network/NAS"*)
            _WIZ_STORAGE_MODE="nas"
            _WIZ_STORAGE_APP_WIRING="managed"
            _WIZ_STORAGE_PROTOCOL="nfs"
            _stage1_collect_nas_settings
            _stage1_preflight_nas_choice
            ;;
        "Advanced manual"*)
            _stage1_collect_manual_storage
            ;;
        "Quit"*)
            log_info "Setup aborted - re-run setup.sh to try again"
            exit 0
            ;;
        *)
            _stage1_cleanup_preflight_nas_mount
            _WIZ_STORAGE_MODE="local"
            _WIZ_STORAGE_APP_WIRING="managed"
            _WIZ_STORAGE_PROTOCOL=""
            _WIZ_DATA_DIR=$(ui_input_validated \
                "Data directory" \
                "$local_default" \
                validate_data_dir)
            _stage1_reset_local_storage_fields
            ;;
    esac

    local bazarr_default="no"
    if [[ "${_WIZ_BAZARR_ENABLED:-${_WIZ_PREV_BAZARR:-false}}" == "true" ]]; then
        bazarr_default="yes"
    fi
    # Surface RAM constraint BEFORE the prompt so the warning informs the
    # decision rather than appearing after the user has already said yes.
    local free_ram_gb
    free_ram_gb=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null)
    if [[ -n "$free_ram_gb" && "$free_ram_gb" -lt 4 ]]; then
        ui_log warn "Only ${free_ram_gb}GB RAM free - Bazarr may struggle (it expects ~4GB)."
    fi
    if ui_confirm "Enable automatic subtitle downloads with Bazarr?" "$bazarr_default"; then
        _WIZ_BAZARR_ENABLED="true"
    else
        _WIZ_BAZARR_ENABLED="false"
    fi

    local smb_default="no"
    if [[ "${_WIZ_SMB_ENABLED:-${_WIZ_PREV_SMB:-false}}" == "true" ]]; then
        smb_default="yes"
    fi
    while true; do
        if ui_confirm "Enable SMB file share for LAN file access?" "$smb_default"; then
            while true; do
                if validate_smb_port 445; then
                    _WIZ_SMB_ENABLED="true"
                    local smb_scope_choice
                    smb_scope_choice=$(ui_choose "Choose SMB share scope:" \
                        "Media files only (${_WIZ_DATA_DIR}) - Recommended for most users." \
                        "Full system (/): advanced admin access to the whole server.")
                    case "$smb_scope_choice" in
                        "Full system"*) _WIZ_SMB_SHARE_SCOPE="system" ;;
                        *)               _WIZ_SMB_SHARE_SCOPE="data" ;;
                    esac
                    break 2
                fi

                local smb_action
                smb_action=$(ui_choose "SMB needs TCP port 445. What should setup do?" \
                    "Retry port check" \
                    "Disable SMB" \
                    "Quit installer")
                case "$smb_action" in
                    "Retry"*) continue ;;
                    "Quit"*) log_info "Setup aborted - re-run setup.sh to try again"; exit 0 ;;
                    *)
                        _WIZ_SMB_ENABLED="false"
                        _WIZ_SMB_SHARE_SCOPE="${_WIZ_SMB_SHARE_SCOPE:-${_WIZ_PREV_SMB_SHARE_SCOPE:-data}}"
                        break 2
                        ;;
                esac
            done
        else
            _WIZ_SMB_ENABLED="false"
            _WIZ_SMB_SHARE_SCOPE="${_WIZ_SMB_SHARE_SCOPE:-${_WIZ_PREV_SMB_SHARE_SCOPE:-data}}"
            break
        fi
    done
}

_stage1_collect_nas_settings() {
    local previous_mountpoint="${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-}}"
    _WIZ_DATA_DIR=$(ui_input_validated \
        "Local mountpoint for NAS storage" \
        "${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}}}" \
        validate_nas_mountpoint)
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    _WIZ_STORAGE_NFS_HOST=$(ui_input_validated \
        "NAS host/IP" \
        "${_WIZ_STORAGE_NFS_HOST:-${_WIZ_PREV_STORAGE_NFS_HOST:-}}" \
        validate_nfs_host)
    ui_log info "Enter the remote path exported by your NAS, for example /exports/mediastack. This is the NAS export path, not the local mountpoint."
    _WIZ_STORAGE_NFS_EXPORT=$(ui_input_validated \
        "NFS export path" \
        "${_WIZ_STORAGE_NFS_EXPORT:-${_WIZ_PREV_STORAGE_NFS_EXPORT:-}}" \
        validate_nfs_export)
    _WIZ_STORAGE_NFS_OPTS=$(ui_input_validated \
        "NFS mount options" \
        "${_WIZ_STORAGE_NFS_OPTS:-${_WIZ_PREV_STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}}" \
        validate_nfs_options)
    local sentinel_default="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
    if [[ -n "${_WIZ_STORAGE_SENTINEL:-}" && "$previous_mountpoint" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_STORAGE_SENTINEL"
    elif [[ -n "${_WIZ_PREV_STORAGE_SENTINEL:-}" && "${_WIZ_PREV_STORAGE_MOUNTPOINT:-}" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_PREV_STORAGE_SENTINEL"
    fi
    while true; do
        _WIZ_STORAGE_SENTINEL=$(ui_input_validated \
            "NAS sentinel file" \
            "$sentinel_default" \
            validate_storage_sentinel)
        if storage_path_is_under_mountpoint "$_WIZ_STORAGE_SENTINEL" "$_WIZ_STORAGE_MOUNTPOINT"; then
            break
        fi
        ui_log warn "NAS sentinel must be inside the selected NAS mountpoint (${_WIZ_STORAGE_MOUNTPOINT})."
        sentinel_default="${_WIZ_STORAGE_MOUNTPOINT}/.mediastack-storage-ready"
    done
}

_stage1_reset_local_storage_fields() {
    _WIZ_STORAGE_MODE="local"
    _WIZ_STORAGE_APP_WIRING="managed"
    _WIZ_STORAGE_PROTOCOL=""
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    _WIZ_STORAGE_NFS_HOST=""
    _WIZ_STORAGE_NFS_EXPORT=""
    _WIZ_STORAGE_NFS_OPTS=""
    _WIZ_STORAGE_SENTINEL="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
}

_stage1_reset_manual_storage_fields() {
    _WIZ_STORAGE_APP_WIRING="manual"
    _WIZ_STORAGE_MODE="local"
    _WIZ_STORAGE_PROTOCOL=""
    _WIZ_STORAGE_MOUNTPOINT=""
    _WIZ_STORAGE_NFS_HOST=""
    _WIZ_STORAGE_NFS_EXPORT=""
    _WIZ_STORAGE_NFS_OPTS=""
    _WIZ_STORAGE_SENTINEL=""
}

_stage1_collect_manual_storage() {
    _WIZ_STORAGE_APP_WIRING="manual"
    ui_log warn "Advanced manual storage skips Jellyfin libraries, Sonarr/Radarr root folders, qBittorrent paths/categories, Jellyseerr links, and Unpackerr path wiring."

    if ui_confirm "Still enable NAS mount guard/watchdog for this manual storage?" "no"; then
        ui_log info "MediaStack will verify the NAS mount/sentinel and protect data services, but app storage paths stay manual."
        _WIZ_STORAGE_MODE="nas"
        _WIZ_STORAGE_PROTOCOL="nfs"
        if [[ -z "${_WIZ_STORAGE_NFS_HOST:-}" || -z "${_WIZ_STORAGE_NFS_EXPORT:-}" ]]; then
            _stage1_collect_nas_settings
        fi
        _stage1_preflight_nas_choice
        _WIZ_STORAGE_APP_WIRING="manual"
    else
        _stage1_cleanup_preflight_nas_mount
        _WIZ_DATA_DIR=$(ui_input_validated \
            "Container data mount root" \
            "${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}" \
            validate_data_dir)
        _stage1_reset_manual_storage_fields
    fi
}

_stage1_cleanup_preflight_nas_mount() {
    if [[ "${_WIZ_STORAGE_PREFLIGHT_MOUNTED_BY_SETUP:-false}" != "true" ]]; then
        return 0
    fi
    if [[ -n "${_WIZ_STORAGE_MOUNTPOINT:-}" ]] && findmnt -rn -M "$_WIZ_STORAGE_MOUNTPOINT" >/dev/null 2>&1; then
        sudo umount "$_WIZ_STORAGE_MOUNTPOINT" 2>/dev/null || sudo umount -l "$_WIZ_STORAGE_MOUNTPOINT" 2>/dev/null || true
    fi
    _WIZ_STORAGE_PREFLIGHT_MOUNTED_BY_SETUP=false
}

_stage1_preflight_nas_choice() {
    local prev_data="${DATA_DIR:-}"
    local prev_mode="${STORAGE_MODE:-}"
    local prev_host="${STORAGE_NFS_HOST:-}"
    local prev_export="${STORAGE_NFS_EXPORT:-}"
    local prev_opts="${STORAGE_NFS_OPTS:-}"
    local prev_sentinel="${STORAGE_SENTINEL:-}"
    local prev_mountpoint="${STORAGE_MOUNTPOINT:-}"
    local prev_expected_source="${STORAGE_EXPECTED_SOURCE:-}"
    local prev_expected_fstype="${STORAGE_EXPECTED_FSTYPE:-}"

    local was_mounted=false
    local had_mismatched_mount=false

    while true; do
        export DATA_DIR="$_WIZ_DATA_DIR"
        export STORAGE_MODE="nas"
        export STORAGE_NFS_HOST="$_WIZ_STORAGE_NFS_HOST"
        export STORAGE_NFS_EXPORT="$_WIZ_STORAGE_NFS_EXPORT"
        export STORAGE_NFS_OPTS="$_WIZ_STORAGE_NFS_OPTS"
        export STORAGE_SENTINEL="$_WIZ_STORAGE_SENTINEL"
        export STORAGE_MOUNTPOINT="${_WIZ_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}"
        export STORAGE_EXPECTED_SOURCE=""
        export STORAGE_EXPECTED_FSTYPE=""
        was_mounted=false
        had_mismatched_mount=false
        if findmnt -rn -M "$STORAGE_MOUNTPOINT" >/dev/null 2>&1; then
            was_mounted=true
            if ! storage_mount_matches; then
                had_mismatched_mount=true
            fi
        fi

        if ! storage_ensure_nfs_common; then
            ui_log warn "Could not install nfs-common, which is required for managed NAS storage."
            local fallback
            fallback=$(ui_choose "NAS support could not be installed. What should setup do?" \
                "Retry installing NAS support" \
                "Use local storage instead" \
                "Advanced manual storage" \
                "Quit installer")
            case "$fallback" in
                "Retry"*) continue ;;
                "Advanced manual"*) _stage1_collect_manual_storage ;;
                "Quit"*) log_info "Setup aborted - re-run setup.sh to try again"; exit 0 ;;
                *) _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"; _stage1_reset_local_storage_fields ;;
            esac
            DATA_DIR="$prev_data"; STORAGE_MODE="$prev_mode"; STORAGE_NFS_HOST="$prev_host"; STORAGE_NFS_EXPORT="$prev_export"; STORAGE_NFS_OPTS="$prev_opts"; STORAGE_SENTINEL="$prev_sentinel"; STORAGE_MOUNTPOINT="$prev_mountpoint"; STORAGE_EXPECTED_SOURCE="$prev_expected_source"; STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
            return 0
        fi
        if ! storage_mount_nfs; then
            ui_log warn "Could not mount NAS storage now."
            local fallback
            fallback=$(ui_choose "NAS mount failed. What should setup do?" \
                "Edit NAS settings and retry" \
                "Retry with the same settings" \
                "Use local storage instead" \
                "Advanced manual storage" \
                "Quit installer")
            case "$fallback" in
                "Edit"*) _stage1_collect_nas_settings; continue ;;
                "Retry"*) continue ;;
                "Advanced manual"*)
                    _stage1_collect_manual_storage
                    ;;
                "Quit"*) log_info "Setup aborted - re-run setup.sh to try again"; exit 0 ;;
                *)
                    _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
                    _stage1_reset_local_storage_fields
                    ;;
            esac
            DATA_DIR="$prev_data"; STORAGE_MODE="$prev_mode"; STORAGE_NFS_HOST="$prev_host"; STORAGE_NFS_EXPORT="$prev_export"; STORAGE_NFS_OPTS="$prev_opts"; STORAGE_SENTINEL="$prev_sentinel"; STORAGE_MOUNTPOINT="$prev_mountpoint"; STORAGE_EXPECTED_SOURCE="$prev_expected_source"; STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
            return 0
        fi
        break
    done

    if { ! $was_mounted || $had_mismatched_mount; } && storage_mount_matches; then
        _WIZ_STORAGE_PREFLIGHT_MOUNTED_BY_SETUP=true
    fi

    local classification
    classification=$(storage_classify_data_root "${_WIZ_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}")
    case "$classification" in
        empty)
            ui_log ok "NAS share is empty and ready for MediaStack."
            ;;
        mediastack)
            ui_log ok "NAS share already has a MediaStack-style media/torrents layout."
            ;;
        conflict:*)
            ui_log warn "NAS share has a blocking conflict at ${classification#conflict:}."
            if [[ "${_WIZ_STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
                ui_log warn "Manual app wiring selected: MediaStack will protect this NAS but will not create app paths or managed media/torrents directories."
            else
                _stage1_resolve_nonstandard_nas_root "conflict"
            fi
            ;;
        nonempty)
            ui_log warn "NAS share is non-empty and does not look like a MediaStack data root."
            if [[ "${_WIZ_STORAGE_APP_WIRING:-managed}" == "manual" ]]; then
                ui_log warn "Manual app wiring selected: MediaStack will protect this NAS but will not create app paths or managed media/torrents directories."
            else
                _stage1_resolve_nonstandard_nas_root "nonempty"
            fi
            ;;
    esac

    DATA_DIR="$prev_data"; STORAGE_MODE="$prev_mode"; STORAGE_NFS_HOST="$prev_host"; STORAGE_NFS_EXPORT="$prev_export"; STORAGE_NFS_OPTS="$prev_opts"; STORAGE_SENTINEL="$prev_sentinel"; STORAGE_MOUNTPOINT="$prev_mountpoint"; STORAGE_EXPECTED_SOURCE="$prev_expected_source"; STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
}

_stage1_resolve_nonstandard_nas_root() {
    local reason="$1"
    local choice
    choice=$(ui_choose "How should MediaStack handle this NAS share?" \
        "Use a new mediastack/ subfolder on this NAS - Recommended." \
        "Use local storage instead" \
        "Advanced manual storage" \
        "Quit installer")
    case "$choice" in
        "Use a new"*)
            _WIZ_DATA_DIR="${_WIZ_STORAGE_MOUNTPOINT:-$_WIZ_DATA_DIR}/mediastack"
            _WIZ_STORAGE_SENTINEL="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
            ui_log info "MediaStack will use NAS subfolder: $_WIZ_DATA_DIR"
            ;;
        "Advanced manual"*)
            ui_log warn "Manual storage selected after NAS ${reason}."
            _stage1_collect_manual_storage
            ;;
        "Quit"*)
            _stage1_cleanup_preflight_nas_mount
            log_info "Setup aborted - re-run setup.sh to try again"
            exit 0
            ;;
        *)
            _stage1_cleanup_preflight_nas_mount
            _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
            _stage1_reset_local_storage_fields
            ui_log info "Continuing with local storage at $_WIZ_DATA_DIR"
            ;;
    esac
}

_stage1_source_env() {
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
}

_stage1_write_and_source_env() {
    write_env
    _stage1_source_env
}

_stage1_final_nas_preflight() {
    if [[ "${STORAGE_MODE:-local}" != "nas" ]]; then
        return 0
    fi

    while true; do
        if storage_preflight_nas; then
            return 0
        fi

        ui_log warn "NAS storage could not be verified immediately before install."
        local action
        action=$(ui_choose "NAS storage check failed. What should setup do?" \
            "Retry NAS check" \
            "Edit NAS settings and retry" \
            "Use local storage instead" \
            "Advanced manual storage" \
            "Quit installer")
        case "$action" in
            "Retry"*)
                continue
                ;;
            "Edit"*)
                _stage1_collect_nas_settings
                _stage1_preflight_nas_choice
                _stage1_write_and_source_env
                [[ "${STORAGE_MODE:-local}" == "nas" ]] || return 0
                continue
                ;;
            "Advanced manual"*)
                _stage1_collect_manual_storage
                _stage1_write_and_source_env
                [[ "${STORAGE_MODE:-local}" == "nas" ]] || return 0
                continue
                ;;
            "Quit"*)
                log_info "Setup aborted - re-run setup.sh to try again"
                exit 0
                ;;
            *)
                _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"
                _stage1_reset_local_storage_fields
                _stage1_write_and_source_env
                return 0
                ;;
        esac
    done
}

_stage1_collect_quality() {
    ui_section 3 6 "Library quality + subtitles"

    # Three preset tiers from scripts/setup/presets.yml. Keep the visual order
    # from smallest to largest, but default to Balanced as the recommended tier.
    local preset_choice
    preset_choice=$(UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Choose how much storage to spend per movie/show:" \
        "Compact (~2-4 GB/movie) - Smaller files, good quality. Best for limited storage." \
        "Balanced (~4-8 GB/movie) - Recommended for most users." \
        "Quality (~6-15 GB/movie) - Best quality at 1080p. Larger files.")
    case "$preset_choice" in
        Compact*)  _WIZ_QUALITY_PRESET="compact" ;;
        Quality*)  _WIZ_QUALITY_PRESET="quality" ;;
        *)         _WIZ_QUALITY_PRESET="balanced" ;;
    esac

    _WIZ_SUBTITLE_LANGS=$(ui_input_validated \
        "Subtitle languages (comma-separated, e.g. english,spanish,french)" \
        "${_WIZ_SUBTITLE_LANGS:-${SUBTITLE_LANGUAGES:-english}}" \
        validate_subtitle_langs)
    # ui_input_validated echoes the raw input (the validator only returns 0/1),
    # so lowercase the accepted value here: Bazarr's LANG_MAP lookup is
    # case-sensitive over lowercase keys, and the value reaches config.yml
    # verbatim. ${,,} folds casing only (commas/spaces untouched; wizard_apply.py
    # strips per-token whitespace) — not validity, but the DEMO/non-TTY
    # short-circuit returns the literal 'english' default, so nothing invalid
    # can slip through unvalidated.
    _WIZ_SUBTITLE_LANGS="${_WIZ_SUBTITLE_LANGS,,}"

    local indexer_default="no"
    if [[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-${_WIZ_PREV_PUBLIC_INDEXERS:-false}}" == "true" ]]; then
        indexer_default="yes"
    fi
    ui_log info "Skip this and Sonarr/Radarr start with no search sources until you add indexers to config.yml (see config/examples/public-indexers.yml) and re-run ./scripts/configure.sh."
    ui_log warn "Public tracker laws, site rules, and ISP policies vary. Enable this preset only for indexers and content you are legally allowed to use."
    if ui_confirm "Enable the example public-tracker indexer preset?" "$indexer_default"; then
        _WIZ_PUBLIC_INDEXERS_ENABLED="true"
    else
        _WIZ_PUBLIC_INDEXERS_ENABLED="false"
        ui_log info "No indexers enabled. Add them later in config.yml, then run ./scripts/configure.sh."
    fi
}

_stage1_collect_image_channel() {
    ui_section 4 6 "Image updates"

    local current_channel default_index channel_choice
    current_channel="${_WIZ_IMAGE_CHANNEL:-${_WIZ_PREV_IMAGE_CHANNEL:-stable}}"
    current_channel="${current_channel,,}"
    case "$current_channel" in
        latest) default_index=2 ;;
        *)      default_index=1; current_channel="stable" ;;
    esac

    channel_choice=$(UI_CHOOSE_DEFAULT_INDEX=$default_index ui_choose "Choose how MediaStack should update container images:" \
        "Stable - recommended tested image digests from this MediaStack repo." \
        "Latest - advanced upstream image tags, newest available from registries.")
    case "$channel_choice" in
        Latest*) _WIZ_IMAGE_CHANNEL="latest" ;;
        *)       _WIZ_IMAGE_CHANNEL="stable" ;;
    esac
}

_stage1_collect_qbit() {
    ui_section 5 6 "qBittorrent limits + peer port"

    local dl_default ul_default suggested_dl suggested_ul
    suggested_dl="${_WIZ_DL_LIMIT:-${_WIZ_PREV_DL:-0}}"
    suggested_ul="${_WIZ_UL_LIMIT:-${_WIZ_PREV_UL:-0}}"

    if [[ "${_discovery_speed_ok:-false}" == "true" && -n "${_NET_DL_MBPS:-}" && -n "${_NET_UL_MBPS:-}" ]]; then
        suggested_dl=$(_stage1_mbps_to_mbs "$_NET_DL_MBPS" "0.50")
        suggested_ul=$(_stage1_mbps_to_mbs "$_NET_UL_MBPS" "0.25")
        ui_log info "Detected ${_NET_DL_MBPS} Mbps down / ${_NET_UL_MBPS} Mbps up."
        ui_log info "Suggested qBittorrent download limit: ${suggested_dl} MB/s (50% of download)."
        ui_log info "Suggested qBittorrent upload limit: ${suggested_ul} MB/s (25% of upload)."
    fi

    dl_default="${_WIZ_DL_LIMIT:-${_WIZ_PREV_DL:-$suggested_dl}}"
    ul_default="${_WIZ_UL_LIMIT:-${_WIZ_PREV_UL:-$suggested_ul}}"

    _WIZ_DL_LIMIT=$(_stage1_read_limit "qBittorrent download limit MB/s (0 = unlimited)" "${dl_default:-0}")
    _WIZ_UL_LIMIT=$(_stage1_read_limit "qBittorrent upload limit MB/s (0 = unlimited)" "${ul_default:-0}")

    _WIZ_TORRENT_PORT=$(ui_input_validated \
        "qBittorrent peer port" \
        "${_WIZ_TORRENT_PORT:-${_WIZ_PREV_TORRENT_PORT:-6881}}" \
        validate_torrent_port)

    # qBittorrent isn't running yet (we haven't even reached the install
    # plan) — so this is a true local-availability check ("is the port free
    # for qBittorrent to bind?"), not a forwarding check. ss-based bind
    # detection is reliable regardless of hairpin NAT / public IP detection.
    if net_is_port_locally_bound "$_WIZ_TORRENT_PORT"; then
        ui_log warn "Port ${_WIZ_TORRENT_PORT} is already in use by another process - qBittorrent will fail to bind. Pick a different port or free this one."
    else
        ui_log info "Port ${_WIZ_TORRENT_PORT}: available - public reachability will be verified after qBittorrent starts in Stage 1."
    fi
}

_stage1_confirm() {
    ui_section 6 6 "Confirm install plan"

    local -a compose_args=(--env-file "$SCRIPT_DIR/.env.example")
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        compose_args+=(--profile subtitles)
    fi
    if [[ "${AUTOHEAL_ENABLED:-true}" != "false" ]]; then
        compose_args+=(--profile autoheal)
    fi

    local services_raw service_count image_count
    services_raw=$(docker compose "${compose_args[@]}" config --services 2>/dev/null || true)
    if [[ -z "$services_raw" ]]; then
        # WR-07: removed the hardcoded fallback list — it omitted unpackerr
        # and flaresolverr (both default-profile services per docs/project/stack.md), so
        # users hit the fallback would have seen an inaccurate plan, clicked
        # Install, and gotten more services than promised. A non-technical
        # audience needs trustworthy commit screens; better to fail loudly
        # than guess.
        log_error "Cannot enumerate services for install plan. Is docker-compose.yml present and is the Docker daemon reachable?"
        exit 1
    fi
    service_count=$(printf '%s\n' "$services_raw" | awk 'NF {count++} END {print count + 0}')
    image_count=$(docker compose "${compose_args[@]}" config --images 2>/dev/null | awk 'NF {count++} END {print count + 0}')

    ui_box "Stage 1: Install Plan" \
        "$(ui_kv 'Services' "${service_count:-0} core containers")" \
        "$(ui_kv 'Images' "${image_count:-0}")" \
        "$(ui_kv 'Image channel' "${_WIZ_IMAGE_CHANNEL:-stable}")" \
        "$(ui_kv 'Storage' "${_WIZ_STORAGE_MODE:-local} at ${_WIZ_DATA_DIR:-/data} (${_WIZ_STORAGE_APP_WIRING:-managed} app wiring)")" \
        "$(ui_kv 'Indexer preset' "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}")" \
        "$(ui_kv 'Time' '5-7 minutes on first run')" \
        "$(ui_kv 'Access' 'no public access - LAN only')" \
        "$(ui_kv 'Result' 'Working media server on your LAN')"

    _STAGE1_CONFIRM_ACTION=$(ui_choose "Proceed with Stage 1 installation?" \
        "Install" \
        "Back" \
        "Abort")
}

_stage1_install() {
    log_info "Stage 1: installing your media server..."
    # Global read by setup.sh::main() to decide post-install steps, not here.
    # shellcheck disable=SC2034
    WIZARD_RAN_INSTALL=true

    _wizard_apply_settings \
        "${_WIZ_QUALITY_PRESET:-balanced}" \
        "${_WIZ_SUBTITLE_LANGS:-english}" \
        "0" \
        "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}"
    _stage1_source_env

    storage_pause_watchdog_for_install || return 1
    _stage1_final_nas_preflight

    stop_existing_stack
    create_data_dirs
    create_config_dirs
    # Hardware transcoding owns GPU runtime publication after driver/runtime verification.
    # Stage 1 must be able to start the baseline LAN stack before NVIDIA
    # runtime or /dev/dri passthrough exists.
    generate_override "none"

    # Auto-scale min_free_space_gb to the actual data partition before the
    # *arr quality profiles get applied. The shipped default (20GB) was a
    # reasonable floor for typical home NAS sizes (1-10 TB), but on smaller
    # disks (cloud VMs, single-SSD installs) it leaves so little headroom
    # that qBittorrent pauses downloads almost immediately. Formula: 10% of
    # the data partition's free space, clamped to [2, 20]GB.
    local data_free_gb scaled_min_free
    data_free_gb=$(df -BG "${_WIZ_DATA_DIR:-/data}" 2>/dev/null | awk 'NR==2 {gsub(/G/, "", $4); print $4}')
    if [[ -n "$data_free_gb" ]] && (( data_free_gb < 200 )); then
        scaled_min_free=$(( data_free_gb / 10 ))
        (( scaled_min_free < 2 )) && scaled_min_free=2
        (( scaled_min_free > 20 )) && scaled_min_free=20
        if [[ "$scaled_min_free" != "20" ]]; then
            sed -i "s/^min_free_space_gb:.*/min_free_space_gb: ${scaled_min_free}    # auto-scaled by wizard from ${data_free_gb}GB free/" "$SCRIPT_DIR/config.yml"
            log_info "Auto-scaled min_free_space_gb to ${scaled_min_free}GB (10% of ${data_free_gb}GB available - was hardcoded 20GB)."
        fi
    fi

    echo ""
    pull_images

    echo ""
    start_stack
    storage_install_watchdog
    wait_all_healthy

    echo ""
    log_info "Running auto-configuration..."
    "$SCRIPT_DIR/scripts/configure.sh"

    # WR-05: detect_env() falls back to "localhost" when 'hostname -I' returns
    # nothing. Probing http://localhost:8096/health proves the container
    # responds on the loopback but does NOT prove LAN-side clients can reach
    # it — which is the whole point of S1-08 (Jellyfin LAN reachability).
    # Warn loudly so the user knows the green tick covers loopback only.
    if [[ "${_ENV_HOST_ADDRESS}" == "localhost" ]]; then
        log_warn "LAN IP not detected (hostname -I returned nothing). Probe will use localhost; LAN access from phones/TVs may not work until you assign a routable IP."
    fi

    # WR-06: stronger probe than /health to gate STAGE_1_COMPLETE flip.
    # /health returns 200 well before the admin user is created, so a
    # half-broken configure.sh (warnings, not hard failure) could leave the
    # admin user uncreated and we'd still flip the marker — locking the user
    # out of their "complete" install. Re-source .env to pick up
    # JELLYFIN_API_KEY (configure_jellyfin saves it after authenticating
    # against /Users/AuthenticateByName), then probe /Users with that key.
    # This proves Jellyfin is alive AND the admin user exists AND the API
    # key works. Falls back to /health if the API key wasn't saved (rare —
    # would mean configure.sh hard-failed before reaching jellyfin).
    set -a
    source "$SCRIPT_DIR/.env"
    set +a

    local probe_ok=false
    if [[ -n "${JELLYFIN_API_KEY:-}" ]]; then
        if curl --max-time 5 -fsS \
            -H "Authorization: MediaBrowser Token=\"${JELLYFIN_API_KEY}\"" \
            "http://${_ENV_HOST_ADDRESS}:8096/Users" >/dev/null 2>&1; then
            probe_ok=true
            log_ok "Jellyfin admin user authenticated at http://${_ENV_HOST_ADDRESS}:8096"
        else
            log_warn "Jellyfin /Users probe failed despite JELLYFIN_API_KEY being set - configure.sh may have left services half-configured. Check 'docker compose logs jellyfin' and re-run setup.sh."
        fi
    elif curl --max-time 5 -fsS "http://${_ENV_HOST_ADDRESS}:8096/health" >/dev/null 2>&1; then
        # Fallback only — JELLYFIN_API_KEY missing means configure.sh did
        # not reach the jellyfin step, so do not flip the marker.
        log_warn "Jellyfin /health responded but JELLYFIN_API_KEY is empty - admin user was not created. Check 'docker compose logs jellyfin' and re-run setup.sh."
    else
        log_warn "Jellyfin didn't respond at http://${_ENV_HOST_ADDRESS}:8096/health within 5s. Check container logs: docker compose logs jellyfin"
    fi

    if $probe_ok; then
        sed -i 's/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/' "$SCRIPT_DIR/.env"
        log_ok "Stage 1 complete (STAGE_1_COMPLETE=1)"
    else
        log_warn "Stage 1 marker NOT set - re-run setup.sh after fixing"
    fi

    print_access_info
}
