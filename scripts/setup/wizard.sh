# =============================================================================
# MediaStack Setup — Interactive wizard
# =============================================================================

source "$SCRIPT_DIR/scripts/lib/network.sh"
source "$SCRIPT_DIR/scripts/lib/validators.sh"
# Shared two-axis quality picker (resolution → size); also sourced by ./mediastack
# for the day-2 "Change quality profile" action so the two surfaces can't drift.
source "$SCRIPT_DIR/scripts/lib/quality_select.sh"

_wizard_load_existing_env() {
    _WIZ_PREV_TZ=""
    _WIZ_PREV_DATA_DIR=""
    _WIZ_PREV_USER=""
    _WIZ_PREV_EMAIL=""
    _WIZ_PREV_PW=""
    _WIZ_PREV_DOMAIN=""
    _WIZ_PREV_DL=""
    _WIZ_PREV_UL=""
    _WIZ_PREV_BAZARR=""
    _WIZ_PREV_SMB=""
    _WIZ_PREV_UFW=""
    _WIZ_PREV_HARDENING=""
    _WIZ_PREV_SMB_SHARE_SCOPE=""
    _WIZ_PREV_TORRENT_PORT=""
    _WIZ_PREV_IMAGE_CHANNEL=""
    _WIZ_PREV_PUBLIC_INDEXERS=""
    _WIZ_PREV_WG_PORT=""
    _WIZ_PREV_STORAGE_MODE=""
    _WIZ_PREV_STORAGE_APP_WIRING=""
    _WIZ_PREV_STORAGE_PROTOCOL=""
    _WIZ_PREV_STORAGE_MOUNTPOINT=""
    _WIZ_PREV_STORAGE_NFS_HOST=""
    _WIZ_PREV_STORAGE_NFS_EXPORT=""
    _WIZ_PREV_STORAGE_NFS_OPTS=""
    _WIZ_PREV_STORAGE_SENTINEL=""
    _WIZ_PREV_STORAGE_WATCHDOG=""

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
        _WIZ_PREV_TZ="${TZ:-}"
        _WIZ_PREV_DATA_DIR="${DATA_DIR:-}"
        _WIZ_PREV_USER="${JELLYFIN_ADMIN_USER:-}"
        _WIZ_PREV_EMAIL="${NPM_ADMIN_EMAIL:-}"
        _WIZ_PREV_PW="${JELLYFIN_ADMIN_PASSWORD:-}"
        _WIZ_PREV_DOMAIN=""
        [[ "${DOMAIN:-example.com}" != "example.com" ]] && _WIZ_PREV_DOMAIN="$DOMAIN"
        _WIZ_PREV_DL="${QBT_DL_LIMIT:-}"
        _WIZ_PREV_UL="${QBT_UL_LIMIT:-}"
        _WIZ_PREV_BAZARR="${BAZARR_ENABLED:-}"
        _WIZ_PREV_SMB="${SMB_ENABLED:-}"
        _WIZ_PREV_UFW="${UFW_ENABLED:-}"
        _WIZ_PREV_HARDENING="${HARDENING_ENABLED:-}"
        _WIZ_PREV_SMB_SHARE_SCOPE="${SMB_SHARE_SCOPE:-}"
        _WIZ_PREV_TORRENT_PORT="${TORRENT_PORT:-}"
        _WIZ_PREV_IMAGE_CHANNEL="${IMAGE_CHANNEL:-}"
        _WIZ_PREV_PUBLIC_INDEXERS="${PUBLIC_INDEXERS_ENABLED:-}"
        _WIZ_PREV_WG_PORT="${WG_PORT:-}"
        _WIZ_PREV_STORAGE_MODE="${STORAGE_MODE:-}"
        _WIZ_PREV_STORAGE_APP_WIRING="${STORAGE_APP_WIRING:-}"
        _WIZ_PREV_STORAGE_PROTOCOL="${STORAGE_PROTOCOL:-}"
        _WIZ_PREV_STORAGE_MOUNTPOINT="${STORAGE_MOUNTPOINT:-}"
        _WIZ_PREV_STORAGE_NFS_HOST="${STORAGE_NFS_HOST:-}"
        _WIZ_PREV_STORAGE_NFS_EXPORT="${STORAGE_NFS_EXPORT:-}"
        _WIZ_PREV_STORAGE_NFS_OPTS="${STORAGE_NFS_OPTS:-}"
        _WIZ_PREV_STORAGE_SENTINEL="${STORAGE_SENTINEL:-}"
        _WIZ_PREV_STORAGE_WATCHDOG="${STORAGE_WATCHDOG:-}"
    fi
}

_wizard_apply_settings() {
    local resolution="$1"
    local size="$2"
    local subtitle_langs="$3"
    local bitrate_limit="$4"
    local public_indexers="${5:-false}"

    write_env
    # wizard_apply.py prints human-readable result lines to stdout (quality
    # profile, subtitle languages, indexer preset). Route them through log_ok so
    # they carry the same ✓ glyph/colour as the rest of the wizard output rather
    # than appearing as naked lines. stderr (errors) is left untouched so real
    # failures still surface on their own path.
    local _apply_out _apply_rc=0 _line
    _apply_out=$(python3 "$SCRIPT_DIR/scripts/setup/wizard_apply.py" \
        --resolution "$resolution" \
        --size "$size" \
        --languages "$subtitle_langs" \
        --bitrate-limit "$bitrate_limit" \
        --public-indexers "$public_indexers" \
        --config "$SCRIPT_DIR/config.yml") || _apply_rc=$?
    while IFS= read -r _line; do
        [[ -n "$_line" ]] && log_ok "$_line"
    done <<<"$_apply_out"
    return "$_apply_rc"
}

_discovery_ip_ok=false
_discovery_speed_ok=false

_wizard_run_discovery() {
    ui_section "Network discovery"
    ui_log info "Probing your network to inform Stage 1 recommendations..."

    _discovery_ip_ok=false
    _discovery_speed_ok=false

    if ui_spin_fg "Detecting public IP..." net_detect_public_ip; then
        _discovery_ip_ok=true
        ui_log ok "Public IP: ${_NET_PUBLIC_IP}"
    else
        ui_log warn "Could not detect public IP (no internet or behind CGNAT)."
    fi

    # The speed test uses curl (always present) with a librespeed-cli fallback,
    # so it is always attempted; net_run_speedtest degrades gracefully on failure.
    if ui_spin_fg "Measuring your connection speed (~15s)..." net_run_speedtest; then
        _discovery_speed_ok=true
        ui_log ok "Download: ${_NET_DL_MBPS} Mbps | Upload: ${_NET_UL_MBPS} Mbps"
    else
        ui_log warn "Speed test unavailable - you can set qBittorrent limits manually."
    fi

    if $_discovery_ip_ok; then
        ui_log info "Checking that ports are available (nothing else listening on them yet)..."
        net_check_port_status 6881 tcp
        net_check_port_status 80 tcp
        net_check_port_status 443 tcp
        net_check_port_status 51820 udp

        # At this stage the stack hasn't started, so "closed" is the GOOD
        # outcome (the port is free for NPM/qBittorrent to bind). "Open"
        # here means another process is already listening — that's a real
        # conflict the user needs to resolve before Stage 1.
        # Real public-reachability check happens in Stage 2 after NPM is up.
        local port status
        for port in 6881 80 443 51820; do
            status="${_NET_PORT_STATUS[$port]:-unknown}"
            case "$status" in
                open) ui_log warn "Port $port: in use by another process - free it before Stage 1 (e.g. 'sudo lsof -i :$port')" ;;
                closed) ui_log ok "Port $port: available" ;;
                udp-unverifiable) ui_log info "Port $port: UDP - availability checked when WireGuard starts" ;;
                *) ui_log info "Port $port: status unknown" ;;
            esac
        done
        ui_log info "Public reachability for ports 80/443 will be checked in Stage 2 once NPM is running."
    else
        ui_log skip "Port availability checks skipped (public IP not detected)."
    fi

    ui_log ok "Discovery complete"
}

source "$SCRIPT_DIR/scripts/setup/stages/stage1.sh"
source "$SCRIPT_DIR/scripts/setup/stages/stage2.sh"
source "$SCRIPT_DIR/scripts/setup/stages/stage3.sh"

run_wizard() {
    seed_root_config # seed live config.yml from template (defined in env_gen.sh)
    # Self-skip only when config.yml, .env, and the Stage 1 completion marker
    # all agree. `_wizard_apply_settings` writes `wizard_completed: true`
    # before Stage 1 starts containers and proves Jellyfin is usable; if setup
    # is interrupted in that window, reruns must resume Stage 1 rather than
    # skipping into setup.sh's markerless late-install fallback.
    if [[ -f "$SCRIPT_DIR/.env" ]] && python3 -c "
import yaml
with open('$SCRIPT_DIR/config.yml') as f:
    c = yaml.safe_load(f)
exit(0 if c.get('wizard_completed') else 1)
" 2>/dev/null; then
        if grep -Eq '^STAGE_1_COMPLETE=1[[:space:]]*$' "$SCRIPT_DIR/.env"; then
            log_skip "Setup wizard already completed (re-run setup to reconfigure)"
            return 0
        fi
        log_warn "Setup wizard marker exists but Stage 1 is not complete; resuming Stage 1."
    fi

    _wizard_load_existing_env

    if [[ "${DEMO:-0}" == "1" ]]; then
        _demo_stage1_noninteractive
        return 0
    fi

    run_stage1

    # Orient the user before the optional stages. On screen the banners read
    # "Stage 1" -> "Hardware Transcoding" (no number) -> "Stage 2", so without
    # this a careful user reads the order as a bug ("did I skip Stage 2?").
    # Interactive only: DEMO returned above, and a non-TTY run stays silent so
    # scripted/CI output is unchanged. "may follow" / "if you have a supported
    # GPU" keeps the copy truthful when the hardware stage self-skips.
    if [[ -t 0 ]]; then
        echo ""
        ui_log info "Core media server is ready. Two optional steps may follow:"
        ui_log info "  1. Hardware transcoding (if you have a supported GPU)"
        ui_log info "  2. Remote access - set up last, on purpose, so it can verify your working stack"
        echo ""
    fi

    run_hardware_transcoding_addon

    local stage2_rc=0
    run_stage2 || stage2_rc=$?
    if ((stage2_rc != 0)); then
        if stage3_pending_nvidia_reboot_same_boot; then
            log_warn "NVIDIA hardware transcoding is prepared and still needs a reboot. Choose Manage hardware transcoding (GPU) from the menu when you are ready to finish it."
        fi
        return "$stage2_rc"
    fi

    if stage3_pending_nvidia_reboot_same_boot; then
        _stage3_print_final_summary
        stage3_prompt_pending_nvidia_reboot
    else
        _stage3_print_final_summary
    fi
}
