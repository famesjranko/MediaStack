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
    seed_root_config   # ensure live config.yml exists before the wizard mutates it (env_gen.sh)
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

    ui_banner "MediaStack - Core Media Server" "Working media server in 5-7 minutes"

    _wizard_run_discovery
    _stage1_show_system

    while true; do
        _stage1_collect_admin
        _stage1_collect_storage
        _stage1_collect_subtitles
        _stage1_collect_smb
        _stage1_collect_quality
        _stage1_collect_indexers
        _stage1_collect_image_channel
        _stage1_collect_qbit
        _stage1_collect_security

        local action
        _stage1_confirm
        action="${_STAGE1_CONFIRM_ACTION:-Back}"
        case "$action" in
            Install) break ;;
            Back) continue ;;
            Abort)
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
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
        "${_WIZ_QUALITY_RESOLUTION:-1080p}" \
        "${_WIZ_QUALITY_SIZE:-balanced}" \
        "${_WIZ_SUBTITLE_LANGS:-english}" \
        "0" \
        "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}"
    _stage1_install
}

_stage1_show_system() {
    local hostname_value os_value docker_value ram_value root_free data_path data_free gateway_value
    hostname_value=$(hostname)
    # LAN gateway = the router the user logs into for port forwarding. The `via`
    # address of the default route ($3) — reliable on any host with a default
    # route; empty (shown as "unknown") only if there's no route configured.
    # `|| true`: under `set -euo pipefail` a missing/erroring `ip` would make this
    # standalone assignment abort the whole wizard. Empty gateway is fine (shows
    # "unknown").
    gateway_value=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}' || true)
    os_value=$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || echo "unknown")
    docker_value=$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')
    # Report total RAM in GB (one decimal) so it matches the preflight RAM check
    # and the free-RAM warning, which both use GB — never `free -h`'s mixed Gi/Mi.
    ram_value=$(awk '/^MemTotal:/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    root_free=$(df -BG / 2>/dev/null | awk 'NR==2 {print $4}')
    data_path=$(_resolve_data_partition)
    data_free=$(df -BG "$data_path" 2>/dev/null | awk 'NR==2 {print $4}')

    ui_box "Detected your system" \
        "$(ui_kv 'Hostname' "$hostname_value")" \
        "$(ui_kv 'LAN IP' "${_ENV_HOST_ADDRESS:-unknown}")" \
        "$(ui_kv 'Router (gateway)' "${gateway_value:-unknown}")" \
        "$(ui_kv 'Public IP' "${_NET_PUBLIC_IP:-not detected - fine for LAN-only}")" \
        "$(ui_kv 'OS' "$os_value")" \
        "$(ui_kv 'Docker version' "${docker_value:-unknown}")" \
        "$(ui_kv 'RAM total' "${ram_value:-unknown}")" \
        "$(ui_kv 'GPU' "$(gpu_brand_label "${GPU_TYPE:-none}")")" \
        "$(ui_kv 'Timezone' "${_ENV_TZ:-Etc/UTC}")" \
        "$(ui_kv 'Disk free' "/=${root_free:-unknown} | ${data_path}=${data_free:-unknown}")"

    local tz_default action
    tz_default="${_WIZ_TZ:-${_WIZ_PREV_TZ:-${_ENV_TZ:-Etc/UTC}}}"
    action=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Continue with these detected values?" \
        "Continue" \
        "Override timezone" \
        "Abort")

    case "$action" in
        "Override timezone")
            _WIZ_TZ=$(ui_input_validated "Timezone" "$tz_default" validate_timezone)
            ;;
        "Abort")
            log_info "Setup aborted - choose Install MediaStack from the menu to try again"
            exit 0
            ;;
        *)
            _WIZ_TZ="$tz_default"
            ;;
    esac
}

_stage1_collect_admin() {
    # Collect username, email, then password, and finish with a persistent review
    # of all three so the user sees them together and accepts them at once or
    # starts the section over. Without the review the entered values scroll away
    # (the gum backend clears each input widget after submit), so the earlier
    # answers appear to "disappear".
    #
    # WR-08 / #95: NEVER auto-generate the shared admin credential — it is the one
    # password for every service, so the user must set it (no default; a bare
    # Enter is rejected). Validated against the strictest service floor
    # (validate_admin_password: >=12 chars, >=2 char types, no single quote).
    # Shown as typed (user preference) and printed in the final summary anyway.
    # In UI_DEMO/--demo the ui_* helpers return their demo defaults, so nothing
    # blocks (the DEMO=1 non-interactive installer uses _demo_stage1_noninteractive
    # and never calls this function).
    local choice email_default
    while true; do
        ui_section 1 10 "Admin identity"

        # Echo each captured value as a persistent line right after entry so the
        # details accumulate on screen as you go. The gum backend clears its input
        # widget after submit, so without these confirmation lines the earlier
        # answers vanish; these stay and double as the final review above the
        # accept prompt.
        _WIZ_ADMIN_USER=$(ui_input_validated \
            "Admin username" \
            "${_WIZ_ADMIN_USER:-${_WIZ_PREV_USER:-admin}}" \
            validate_admin_user)
        ui_kv "Username" "$_WIZ_ADMIN_USER"

        email_default="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-}}"
        if [[ -z "$email_default" || "${email_default,,}" =~ @(example\.com|example\.net|example\.org)$ ]]; then
            email_default=""
        fi
        _WIZ_ADMIN_EMAIL=$(ui_input_validated \
            "Admin email (for SSL certs and service login)" \
            "$email_default" \
            validate_admin_email)
        ui_kv "Email" "$_WIZ_ADMIN_EMAIL"

        ui_log info "Password rules: 12+ characters, mix at least 2 of lowercase / UPPERCASE / digits / symbols, no single quotes."
        _WIZ_ADMIN_PW=$(ui_input_validated \
            "Admin password" \
            "" \
            validate_admin_password \
            "DemoAdminPassword123")
        ui_kv "Password" "$_WIZ_ADMIN_PW"

        echo ""
        choice=$(ui_choose "Use these admin details?" "Use these details" "Re-enter")
        [[ "$choice" == "Use these details" ]] && break
    done
}

# Thin wrapper: collect storage, then let the user accept or re-enter (mirrors
# _stage1_collect_admin). The per-choice ui_kv echoes live INSIDE _once so they
# pile up interleaved with the prompts (like admin), not as one block here.
# Re-enter re-runs the whole section — the same idempotent re-run the outer
# plan-box Back loop does (storage_mount_nfs early-returns when mounted).
_stage1_collect_storage() {
    while true; do
        _stage1_collect_storage_once
        # Managed NAS confirms its own choices inside the NAS sub-flow, so its
        # "Re-enter" only revisits the NFS options + watchdog (not the whole
        # connection flow). Every other path uses this generic confirm, whose
        # "Re-enter" re-opens the storage menu.
        if [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-}" == "managed" ]]; then
            break
        fi
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these storage choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_storage_once() {
    ui_section 2 10 "Storage"

    # Loop the storage menu so the NAS sub-flow's "Back to storage options" can
    # bring the user straight back here to pick a different backend.
    local storage_choice local_default
    while true; do
        local_default="${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}"
        if [[ "${_WIZ_STORAGE_MODE:-local}" != "local" ]]; then
            local_default="${_WIZ_PREV_DATA_DIR:-/data}"
        fi
        storage_choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Where should MediaStack store media and downloads?" \
            "Local disk (${local_default}) (recommended)" \
            "Network/NAS storage (NFS) - MediaStack manages mount checks and service protection." \
            "Advanced manual storage - install apps but skip app-level storage wiring." \
            "Quit installer")

        case "$storage_choice" in
            "Network/NAS"*)
                _WIZ_STORAGE_MODE="nas"
                _WIZ_STORAGE_APP_WIRING="managed"
                _WIZ_STORAGE_PROTOCOL="nfs"
                # Returns 0 once the NAS is verified + confirmed (or classification
                # rerouted to local/manual); returns 1 for "Back to storage options",
                # which re-shows this menu on the next loop.
                _stage1_collect_nas_managed && break
                ;;
            "Advanced manual"*)
                _stage1_collect_manual_storage
                break
                ;;
            "Quit"*)
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                exit 0
                ;;
            *)
                _WIZ_STORAGE_MODE="local"
                _WIZ_STORAGE_APP_WIRING="managed"
                _WIZ_STORAGE_PROTOCOL=""
                _WIZ_DATA_DIR=$(ui_input_validated \
                    "Data directory" \
                    "$local_default" \
                    validate_data_dir)
                _stage1_reset_local_storage_fields
                break
                ;;
        esac
    done
    # Consolidated storage summary line. The NAS host:export is echoed per-field
    # inside _stage1_collect_nas_settings, so it isn't repeated here. Managed NAS
    # already prints this inside its own confirm loop, so skip it to avoid a dupe.
    if ! [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-}" == "managed" ]]; then
        ui_kv "Storage" "${_WIZ_STORAGE_MODE:-local} at ${_WIZ_DATA_DIR:-/data} (${_WIZ_STORAGE_APP_WIRING:-managed} wiring)"
    fi
}

# Subtitles (Bazarr): enable + language list live together so the toggle and the
# setting it gates form one coherent section (mirrors _stage1_collect_admin).
_stage1_collect_subtitles() {
    while true; do
        _stage1_collect_subtitles_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these subtitle choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_subtitles_once() {
    ui_section 3 10 "Subtitles (Bazarr)"

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
    ui_kv "Subtitles (Bazarr)" "$([[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)"

    # Only ask for subtitle languages when Bazarr is enabled (#100): the value
    # feeds render_bazarr alone, so prompting after the user declined Bazarr asks
    # for something inert and contradicts the choice just made. When Bazarr is
    # off, keep a stored default so a later `./setup.sh` that enables Bazarr still
    # has a sensible language list.
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        _WIZ_SUBTITLE_LANGS=$(ui_input_validated \
            "Subtitle languages (comma-separated, e.g. english,spanish,french)" \
            "${_WIZ_SUBTITLE_LANGS:-${SUBTITLE_LANGUAGES:-english}}" \
            validate_subtitle_langs)
    else
        _WIZ_SUBTITLE_LANGS="${_WIZ_SUBTITLE_LANGS:-${SUBTITLE_LANGUAGES:-english}}"
    fi
    # ui_input_validated echoes the raw input (the validator only returns 0/1),
    # so lowercase the accepted value here: Bazarr's LANG_MAP lookup is
    # case-sensitive over lowercase keys, and the value reaches config.yml
    # verbatim. ${,,} folds casing only (commas/spaces untouched; wizard_apply.py
    # strips per-token whitespace) — not validity, but the DEMO/non-TTY
    # short-circuit returns the literal 'english' default, so nothing invalid
    # can slip through unvalidated.
    _WIZ_SUBTITLE_LANGS="${_WIZ_SUBTITLE_LANGS,,}"
    # Use an if (not `[[ ]] && ui_kv`): this is the function's last statement, so a
    # false trailing test would make the function return 1 and abort the wizard
    # under `set -e` whenever Bazarr is disabled (the default).
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        ui_kv "Subtitle langs" "${_WIZ_SUBTITLE_LANGS:-english}"
    fi
}

# File sharing (SMB): enable + share scope in one section.
_stage1_collect_smb() {
    while true; do
        _stage1_collect_smb_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these file-sharing choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_smb_once() {
    ui_section 4 10 "File sharing (SMB)"

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
                    smb_scope_choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Choose SMB share scope:" \
                        "Media files only (${_WIZ_DATA_DIR}) (recommended)" \
                        "Full system (/) - advanced admin access to the whole server.")
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
                    "Quit"*) log_info "Setup aborted - choose Install MediaStack from the menu to try again"; exit 0 ;;
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
    if [[ "${_WIZ_SMB_ENABLED:-false}" == "true" ]]; then
        ui_kv "File share (SMB)" "on (${_WIZ_SMB_SHARE_SCOPE:-data})"
    else
        ui_kv "File share (SMB)" "off"
    fi
}

_stage1_collect_nas_settings() {
    local previous_mountpoint="${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-}}"

    # Frame the three things NAS setup needs before the first prompt (house style:
    # a ui_box, like the public-indexers panel). Each answer is echoed with ui_kv
    # right after entry (mirrors _stage1_collect_admin) so choices accumulate on
    # screen as a running summary — the gum backend clears each input widget after
    # submit, so without these the answers would vanish before the mount preflight.
    ui_box "Network/NAS storage (NFS)" \
        "MediaStack will connect to your NAS and store your media there." \
        "You'll need three things:" \
        "  - your NAS address (IP or hostname)" \
        "  - the shared folder on the NAS (its NFS export path)" \
        "  - where it should appear on this server (the mountpoint, e.g. /data)"
    echo ""

    _WIZ_DATA_DIR=$(ui_input_validated \
        "Local mountpoint for NAS storage" \
        "${_WIZ_STORAGE_MOUNTPOINT:-${_WIZ_PREV_STORAGE_MOUNTPOINT:-${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}}}" \
        validate_nas_mountpoint)
    _WIZ_STORAGE_MOUNTPOINT="$_WIZ_DATA_DIR"
    ui_kv "NAS mountpoint" "$_WIZ_STORAGE_MOUNTPOINT"
    echo ""

    _WIZ_STORAGE_NFS_HOST=$(ui_input_validated \
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)" \
        "${_WIZ_STORAGE_NFS_HOST:-${_WIZ_PREV_STORAGE_NFS_HOST:-}}" \
        validate_nfs_host)
    ui_kv "NAS host/IP" "$_WIZ_STORAGE_NFS_HOST"
    echo ""

    _WIZ_STORAGE_NFS_EXPORT=$(ui_input_validated \
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)" \
        "${_WIZ_STORAGE_NFS_EXPORT:-${_WIZ_PREV_STORAGE_NFS_EXPORT:-}}" \
        validate_nfs_export)
    ui_kv "NFS export" "$_WIZ_STORAGE_NFS_EXPORT"

    # NFS mount options and the watchdog toggle are collected AFTER the connection
    # is verified and confirmed (_stage1_collect_nas_options). Seed the recommended
    # defaults here so the verification probe has something to mount with.
    _WIZ_STORAGE_NFS_OPTS="${_WIZ_STORAGE_NFS_OPTS:-${_WIZ_PREV_STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}}"

    # The safety marker is the watchdog's internal sentinel; users never name it.
    # Always default it under the mountpoint (silently).
    local sentinel_default="${_WIZ_DATA_DIR}/.mediastack-storage-ready"
    if [[ -n "${_WIZ_STORAGE_SENTINEL:-}" && "$previous_mountpoint" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_STORAGE_SENTINEL"
    elif [[ -n "${_WIZ_PREV_STORAGE_SENTINEL:-}" && "${_WIZ_PREV_STORAGE_MOUNTPOINT:-}" == "$_WIZ_STORAGE_MOUNTPOINT" ]]; then
        sentinel_default="$_WIZ_PREV_STORAGE_SENTINEL"
    fi
    if ! storage_path_is_under_mountpoint "$sentinel_default" "$_WIZ_STORAGE_MOUNTPOINT"; then
        sentinel_default="${_WIZ_STORAGE_MOUNTPOINT}/.mediastack-storage-ready"
    fi
    _WIZ_STORAGE_SENTINEL="$sentinel_default"
}

# Managed-NAS orchestrator: a small state machine so the final review can send
# the user back to any layer. connection -> options -> review. The review box
# lists every choice and its menu confirms or jumps back to a specific layer.
# Returns 0 when confirmed (or classification rerouted to local/manual), 1 when
# the user chooses "Change storage type" (caller re-shows the storage menu).
# Nothing is mounted or configured here; confirming only locks in the _WIZ_*
# choices (the probe is non-destructive; the real mount is deferred to install).
_stage1_collect_nas_managed() {
    local step=connection action
    while true; do
        case "$step" in
            connection)
                _stage1_collect_nas_settings
                echo ""
                _stage1_preflight_nas_choice
                # A probe failure or a non-empty-share reroute may have switched
                # away from managed NAS (to local, or to manual app wiring). If so
                # it's already resolved and there is nothing to review here.
                [[ "${_WIZ_STORAGE_MODE:-}" == "nas" && "${_WIZ_STORAGE_APP_WIRING:-managed}" == "managed" ]] || return 0
                step=options
                ;;
            options)
                echo ""
                _stage1_collect_nas_options
                step=review
                ;;
            review)
                echo ""
                _stage1_nas_review_box
                action=$(ui_choose "Lock in these storage choices?" \
                    "Confirm and continue" \
                    "Change NFS options / watchdog" \
                    "Change NAS address, export or mount point" \
                    "Change storage type" \
                    "Abort installation")
                case "$action" in
                    "Confirm"*)        return 0 ;;
                    "Change NFS"*)     step=options ;;
                    "Change NAS"*)     step=connection ;;
                    "Change storage"*) return 1 ;;
                    "Abort"*)          log_info "Setup aborted - choose Install MediaStack from the menu to try again"; exit 0 ;;
                esac
                ;;
        esac
    done
}

# Consolidated review of the managed-NAS choices, shown before the lock-in menu.
# Reuses the ui_box + ui_kv pattern from _stage1_show_system.
_stage1_nas_review_box() {
    local wd
    [[ "${_WIZ_STORAGE_WATCHDOG:-true}" == "false" ]] && wd="off" || wd="on"
    ui_box "Storage choices to lock in" \
        "$(ui_kv 'Storage' 'Network/NAS (NFS)')" \
        "$(ui_kv 'NAS server' "${_WIZ_STORAGE_NFS_HOST}:${_WIZ_STORAGE_NFS_EXPORT}")" \
        "$(ui_kv 'Mount point' "${_WIZ_DATA_DIR}")" \
        "$(ui_kv 'NFS options' "${_WIZ_STORAGE_NFS_OPTS}")" \
        "$(ui_kv 'Watchdog' "$wd")"
}

# NFS options + watchdog, asked only after the connection is verified and the
# user has confirmed the NAS. The verification probe ran on the recommended
# options, so "yes" needs no re-check; custom options are unproven and re-probed.
_stage1_collect_nas_options() {
    local nfs_opts_default
    nfs_opts_default="${_WIZ_STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}"

    if ui_confirm "Use the recommended NFS mount options?" "yes"; then
        _WIZ_STORAGE_NFS_OPTS="$nfs_opts_default"
    else
        ui_log warn "Custom NFS options are advanced and unsupported - if the mount misbehaves with these, that is on you. The recommended defaults suit almost everyone."
        while true; do
            _WIZ_STORAGE_NFS_OPTS=$(ui_input_validated \
                "NFS mount options" \
                "$nfs_opts_default" \
                validate_nfs_options)
            if _stage1_reprobe_with_current_opts; then
                break
            fi
            local retry
            retry=$(ui_choose "Could not verify the NAS with those options. What now?" \
                "Edit the options" \
                "Use the recommended options instead")
            if [[ "$retry" == "Use the recommended"* ]]; then
                _WIZ_STORAGE_NFS_OPTS="$nfs_opts_default"
                break
            fi
        done
    fi
    ui_kv "NFS options" "$_WIZ_STORAGE_NFS_OPTS"

    echo ""
    local watchdog_default="yes"
    [[ "${_WIZ_STORAGE_WATCHDOG:-${_WIZ_PREV_STORAGE_WATCHDOG:-true}}" == "false" ]] && watchdog_default="no"
    ui_log info "The NAS watchdog stops your media services if the NAS disconnects and restarts them when it returns. Recommended."
    if ui_confirm "Enable the NAS mount watchdog?" "$watchdog_default"; then
        _WIZ_STORAGE_WATCHDOG="true"
    else
        _WIZ_STORAGE_WATCHDOG="false"
        ui_log warn "Watchdog disabled: MediaStack will NOT stop or protect data services if the NAS drops mid-run."
    fi
    [[ "${_WIZ_STORAGE_WATCHDOG:-true}" == "false" ]] && ui_kv "NAS watchdog" "off" || ui_kv "NAS watchdog" "on"
}

# Re-run the non-destructive probe with the user's just-entered custom options,
# then restore the caller's STORAGE_* env. Returns 0 if the probe passes.
_stage1_reprobe_with_current_opts() {
    local prev_host="${STORAGE_NFS_HOST:-}" prev_export="${STORAGE_NFS_EXPORT:-}" prev_opts="${STORAGE_NFS_OPTS:-}"
    export STORAGE_NFS_HOST="$_WIZ_STORAGE_NFS_HOST"
    export STORAGE_NFS_EXPORT="$_WIZ_STORAGE_NFS_EXPORT"
    export STORAGE_NFS_OPTS="$_WIZ_STORAGE_NFS_OPTS"
    local rc=0
    storage_probe_nas || rc=1
    STORAGE_NFS_HOST="$prev_host"; STORAGE_NFS_EXPORT="$prev_export"; STORAGE_NFS_OPTS="$prev_opts"
    return $rc
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
    _WIZ_STORAGE_WATCHDOG="true"
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
    _WIZ_STORAGE_WATCHDOG="true"
}

_stage1_collect_manual_storage() {
    _WIZ_STORAGE_APP_WIRING="manual"
    ui_log warn "Advanced manual storage skips Jellyfin libraries, Sonarr/Radarr root folders, qBittorrent paths/categories, Seerr links, and Unpackerr path wiring."
    ui_log warn "You take responsibility for app-level storage wiring here: MediaStack will not create or manage media/download paths, and fixing any misconfiguration is on you."

    if ui_confirm "Still enable NAS mount guard/watchdog for this manual storage?" "no"; then
        ui_log info "MediaStack will verify the NAS mount/sentinel and protect data services, but app storage paths stay manual."
        _WIZ_STORAGE_MODE="nas"
        _WIZ_STORAGE_PROTOCOL="nfs"
        _WIZ_STORAGE_WATCHDOG="true"
        _WIZ_STORAGE_NFS_OPTS="${_WIZ_STORAGE_NFS_OPTS:-${_WIZ_PREV_STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}}"
        if [[ -z "${_WIZ_STORAGE_NFS_HOST:-}" || -z "${_WIZ_STORAGE_NFS_EXPORT:-}" ]]; then
            _stage1_collect_nas_settings
        fi
        _stage1_preflight_nas_choice
        _WIZ_STORAGE_APP_WIRING="manual"
    else
        _WIZ_DATA_DIR=$(ui_input_validated \
            "Container data mount root" \
            "${_WIZ_DATA_DIR:-${_WIZ_PREV_DATA_DIR:-/data}}" \
            validate_data_dir)
        _stage1_reset_manual_storage_fields
    fi
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
                "Quit"*) log_info "Setup aborted - choose Install MediaStack from the menu to try again"; exit 0 ;;
                *) _WIZ_DATA_DIR="${_WIZ_PREV_DATA_DIR:-/data}"; _stage1_reset_local_storage_fields ;;
            esac
            DATA_DIR="$prev_data"; STORAGE_MODE="$prev_mode"; STORAGE_NFS_HOST="$prev_host"; STORAGE_NFS_EXPORT="$prev_export"; STORAGE_NFS_OPTS="$prev_opts"; STORAGE_SENTINEL="$prev_sentinel"; STORAGE_MOUNTPOINT="$prev_mountpoint"; STORAGE_EXPECTED_SOURCE="$prev_expected_source"; STORAGE_EXPECTED_FSTYPE="$prev_expected_fstype"
            return 0
        fi
        # Verify only — never mount the real mountpoint during the wizard. The
        # probe temp-mounts elsewhere, so a changed export can't collide with a
        # prior mount and we never ask the user to detach anything. The real
        # /data mount happens at install (storage_preflight_nas).
        if ! storage_probe_nas; then
            ui_log warn "Could not verify NAS storage."
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
                "Quit"*) log_info "Setup aborted - choose Install MediaStack from the menu to try again"; exit 0 ;;
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

    local classification="${_STORAGE_PROBE_CLASS:-empty}"
    case "$classification" in
        empty)
            ui_log ok "NAS connection verified - NAS share is empty and ready for MediaStack."
            ;;
        mediastack)
            ui_log ok "NAS connection verified - NAS share already has a MediaStack-style media/torrents layout."
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
        "Use a new mediastack/ subfolder on this NAS (recommended)" \
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
            log_info "Setup aborted - choose Install MediaStack from the menu to try again"
            exit 0
            ;;
        *)
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
                log_info "Setup aborted - choose Install MediaStack from the menu to try again"
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
    while true; do
        _stage1_collect_quality_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these library choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_quality_once() {
    ui_section 5 10 "Library quality"

    # Two orthogonal axes (resolution → size), menus built dynamically from
    # scripts/setup/presets.yml. Shared with the day-2 launcher so the two can't
    # drift. Defaults to 1080p Balanced (the recommended cell). If the menu can't
    # be read, keep any prior selection or fall back to 1080p/balanced rather
    # than aborting the wizard.
    if ! quality_select_pick _WIZ_QUALITY_RESOLUTION _WIZ_QUALITY_SIZE \
        "${_WIZ_QUALITY_RESOLUTION:-1080p}" "${_WIZ_QUALITY_SIZE:-balanced}"; then
        _WIZ_QUALITY_RESOLUTION="${_WIZ_QUALITY_RESOLUTION:-1080p}"
        _WIZ_QUALITY_SIZE="${_WIZ_QUALITY_SIZE:-balanced}"
    fi
    ui_kv "Quality" "${_WIZ_QUALITY_RESOLUTION:-1080p} ${_WIZ_QUALITY_SIZE:-balanced}"
}

# Search indexers: its own section (public trackers are a search feature, not a
# quality or subtitles setting). Enable-only — no config sub-layer.
_stage1_collect_indexers() {
    while true; do
        _stage1_collect_indexers_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use this indexer choice?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_indexers_once() {
    ui_section 6 10 "Search indexers"

    local indexer_default="no"
    if [[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-${_WIZ_PREV_PUBLIC_INDEXERS:-false}}" == "true" ]]; then
        indexer_default="yes"
    fi
    ui_box "Public tracker indexers (optional)" \
        "Adds example public trackers so Sonarr/Radarr can search" \
        "right away. Skip and add your own later from the menu." \
        "" \
        "Laws, site rules, and ISP policies vary - enable only" \
        "for content you are legally allowed to use."
    if ui_confirm "Enable the example public-tracker indexers?" "$indexer_default"; then
        _WIZ_PUBLIC_INDEXERS_ENABLED="true"
    else
        _WIZ_PUBLIC_INDEXERS_ENABLED="false"
        ui_log info "No indexers enabled - add your own later from Features & settings -> Search indexers."
    fi
    ui_kv "Public indexers" "$([[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)"
}

_stage1_collect_image_channel() {
    ui_section 7 10 "Image updates"

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
    ui_kv "Image updates" "$_WIZ_IMAGE_CHANNEL"
}

_stage1_collect_qbit() {
    while true; do
        _stage1_collect_qbit_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these qBittorrent settings?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_qbit_once() {
    ui_section 8 10 "qBittorrent limits + peer port"

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
    local _dl_disp="${_WIZ_DL_LIMIT:-0}" _ul_disp="${_WIZ_UL_LIMIT:-0}"
    [[ "$_dl_disp" == "0" ]] && _dl_disp="unlimited" || _dl_disp="${_dl_disp} MB/s"
    [[ "$_ul_disp" == "0" ]] && _ul_disp="unlimited" || _ul_disp="${_ul_disp} MB/s"
    ui_kv "Download limit" "$_dl_disp"
    ui_kv "Upload limit" "$_ul_disp"

    _WIZ_TORRENT_PORT=$(ui_input_validated \
        "qBittorrent peer port" \
        "${_WIZ_TORRENT_PORT:-${_WIZ_PREV_TORRENT_PORT:-6881}}" \
        validate_torrent_port)
    ui_kv "Peer port" "${_WIZ_TORRENT_PORT:-6881}"

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

_stage1_collect_security() {
    ui_section 9 10 "Security"

    # Both default to yes (recommended). Absent prev value => yes so existing
    # installs keep their firewall/hardening. Session value wins on a Back loop.
    local ufw_default="yes"
    [[ "${_WIZ_UFW_ENABLED:-${_WIZ_PREV_UFW:-true}}" == "true" ]] || ufw_default="no"
    ui_log info "The UFW firewall blocks unexpected inbound connections. Your media"
    ui_log info "web UIs (from the LAN) and SSH stay reachable; only unsolicited"
    ui_log info "traffic to other ports is dropped. Recommended."
    if ui_confirm "Set up the UFW firewall?" "$ufw_default"; then
        _WIZ_UFW_ENABLED="true"
    else
        _WIZ_UFW_ENABLED="false"
    fi

    local hardening_default="yes"
    [[ "${_WIZ_HARDENING_ENABLED:-${_WIZ_PREV_HARDENING:-true}}" == "true" ]] || hardening_default="no"
    ui_log info "System hardening enables automatic security updates and applies"
    ui_log info "conservative kernel network-hardening settings (sysctl). It does"
    ui_log info "not auto-reboot. Recommended."
    if ui_confirm "Apply system hardening (auto security updates + kernel hardening)?" "$hardening_default"; then
        _WIZ_HARDENING_ENABLED="true"
    else
        _WIZ_HARDENING_ENABLED="false"
    fi

    ui_kv "Firewall" "$([[ "${_WIZ_UFW_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)"
    ui_kv "System hardening" "$([[ "${_WIZ_HARDENING_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)"
}

_stage1_confirm() {
    ui_section 10 10 "Confirm install plan"

    # _stage1_preflight_nas_choice exports DATA_DIR/STORAGE_* (so the NAS mount
    # helper sees them) and restores them to their pre-preflight values — which are
    # EMPTY on a fresh install — without dropping the export attribute, so they
    # linger in the environment. docker compose gives the process environment
    # precedence over --env-file, so a leaked empty DATA_DIR turns the compose bind
    # "${DATA_DIR}:/data" into ":/data" ("invalid spec: :/data") and the config
    # below reports zero services -> the misleading "Cannot enumerate services"
    # abort. Drop them here so the install plan reflects .env.example; the real
    # install re-derives them from the _WIZ_* values when it writes and sources .env.
    unset DATA_DIR STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT \
          STORAGE_NFS_OPTS STORAGE_SENTINEL STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE

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

    ui_box "Core Media Server: Install Plan" \
        "$(ui_kv 'Services' "${service_count:-0} core containers")" \
        "$(ui_kv 'Images' "${image_count:-0}")" \
        "$(ui_kv 'Image channel' "${_WIZ_IMAGE_CHANNEL:-stable}")" \
        "$(ui_kv 'Storage' "${_WIZ_STORAGE_MODE:-local} at ${_WIZ_DATA_DIR:-/data} (${_WIZ_STORAGE_APP_WIRING:-managed} app wiring)")" \
        "$(ui_kv 'Indexer preset' "$([[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Firewall' "$([[ "${_WIZ_UFW_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Hardening' "$([[ "${_WIZ_HARDENING_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Time' '5-7 minutes on first run')" \
        "$(ui_kv 'Access' 'no public access - LAN only')" \
        "$(ui_kv 'Result' 'Working media server on your LAN')"

    _STAGE1_CONFIRM_ACTION=$(ui_choose "Proceed with Stage 1 installation?" \
        "Install" \
        "Back" \
        "Abort")
}

_stage1_install() {
    log_info "Installing your core media server..."
    # Global read by setup.sh::main() to decide post-install steps, not here.
    # shellcheck disable=SC2034
    WIZARD_RAN_INSTALL=true

    _wizard_apply_settings \
        "${_WIZ_QUALITY_RESOLUTION:-1080p}" \
        "${_WIZ_QUALITY_SIZE:-balanced}" \
        "${_WIZ_SUBTITLE_LANGS:-english}" \
        "0" \
        "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}"
    _stage1_source_env

    storage_pause_watchdog_for_install || return 1
    _stage1_final_nas_preflight

    # Apply the firewall/hardening the user chose in the wizard BEFORE the stack
    # starts, so published management ports are never exposed unprotected. .env
    # (with UFW_ENABLED/HARDENING_ENABLED) was sourced by _stage1_source_env above.
    setup_hardening

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
            log_warn "Jellyfin /Users probe failed despite JELLYFIN_API_KEY being set - configure.sh may have left services half-configured. View logs from the menu (Manage stack -> Tail logs (live)), then choose Install MediaStack to re-run setup."
        fi
    elif curl --max-time 5 -fsS "http://${_ENV_HOST_ADDRESS}:8096/health" >/dev/null 2>&1; then
        # Fallback only — JELLYFIN_API_KEY missing means configure.sh did
        # not reach the jellyfin step, so do not flip the marker.
        log_warn "Jellyfin /health responded but JELLYFIN_API_KEY is empty - admin user was not created. View logs from the menu (Manage stack -> Tail logs (live)), then choose Install MediaStack to re-run setup."
    else
        log_warn "Jellyfin didn't respond at http://${_ENV_HOST_ADDRESS}:8096/health within 5s. View logs from the menu: Manage stack -> Tail logs (live)"
    fi

    if $probe_ok; then
        sed -i 's/^STAGE_1_COMPLETE=$/STAGE_1_COMPLETE=1/' "$SCRIPT_DIR/.env"
        log_ok "Core media server ready (STAGE_1_COMPLETE=1)"
    else
        log_warn "Stage 1 marker NOT set - choose Install MediaStack from the menu after fixing"
    fi

    # Host-level LAN services belong to Stage 1: the user chose the SMB share in
    # the Stage 1 wizard, so configure it (and the service-port firewall rules)
    # here — before print_access_info advertises the share — instead of tacking
    # it on after the final summary at the very end of setup.
    [[ "${UFW_ENABLED:-true}" == "true" ]] && setup_ufw_service_ports
    setup_samba

    print_access_info

    # Surface configure.sh failures that were buried mid-scroll. configure.sh
    # writes .configure_issues only when at least one service had warnings; we
    # delete it here so stale state never bleeds into a later ./mediastack info.
    local _issues_file="$SCRIPT_DIR/.configure_issues"
    if [[ -s "$_issues_file" ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}  ⚠  Services that need attention:${NC}"
        while IFS='|' read -r _ilabel _; do
            echo -e "    ${YELLOW}$(_ui_status_token warn)${NC}  $_ilabel"
        done < "$_issues_file"
        rm -f "$_issues_file"
        echo    "    Re-run MediaStack setup to retry (already-configured services are skipped)."
        echo ""
    fi
}
