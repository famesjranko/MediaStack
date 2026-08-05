# Owns: Stage 1 baseline installation, health proof, marker, and LAN integration.
# Sources: env generation, storage, hardening, stack, configure.sh, `SCRIPT_DIR`/`_ENV_HOST_ADDRESS`, color globals, and Stage 1 state.

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
    if [[ -n "$data_free_gb" ]] && ((data_free_gb < 200)); then
        scaled_min_free=$((data_free_gb / 10))
        ((scaled_min_free < 2)) && scaled_min_free=2
        ((scaled_min_free > 20)) && scaled_min_free=20
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

    # Record the digest each service was installed running, so day-2 "Revert to
    # installed image" has a channel-independent target. Overwrites
    # on every install run to re-baseline a rebuild; best-effort and never fatal.
    python3 "$SCRIPT_DIR/scripts/image_drift.py" \
        --compose "$SCRIPT_DIR/docker-compose.yml" \
        --record-install "$SCRIPT_DIR/config/state/image-install.tsv" || true

    echo ""
    log_info "Running auto-configuration..."
    "$SCRIPT_DIR/scripts/configure.sh"

    # detect_env() falls back to "localhost" when 'hostname -I' returns
    # nothing. Probing http://localhost:8096/health proves the container
    # responds on the loopback but does NOT prove LAN-side clients can reach
    # it — which is the whole point of the Jellyfin LAN reachability check.
    # Warn loudly so the user knows the green tick covers loopback only.
    if [[ "${_ENV_HOST_ADDRESS}" == "localhost" ]]; then
        log_warn "LAN IP not detected (hostname -I returned nothing). Probe will use localhost; LAN access from phones/TVs may not work until you assign a routable IP."
    fi

    # Stronger probe than /health to gate STAGE_1_COMPLETE flip.
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
        done <"$_issues_file"
        rm -f "$_issues_file"
        echo "    Re-run MediaStack setup to retry (already-configured services are skipped)."
        echo ""
    fi
}
