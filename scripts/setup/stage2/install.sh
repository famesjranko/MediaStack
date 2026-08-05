# Owns: Stage 2 remote-access persistence, stack start, configuration, and LE handoff.
# Sources: Stage 2 defaults, DDNS, LE, stack, fail2ban, and setup helpers.

_stage2_install() {
    log_info "Installing remote access..."

    _stage2_seed_wizard_defaults
    # Commit the WireGuard init password here (install path only) and only when
    # the user opted in — this is what activates the remote WG profile. Doing it
    # here rather than during collection means every skip path leaves it as-is
    # (empty on a fresh setup), so a confirm-time "Skip remote access" can't
    # silently enable WireGuard. Explicitly clear it when WG is declined so an
    # existing install's WG is turned off when the user says no.
    if [[ "${_WIZ_WG_ENABLED:-true}" == "true" ]]; then
        _WIZ_WG_INIT_PASSWORD="${_WIZ_ADMIN_PW}"
    else
        _WIZ_WG_INIT_PASSWORD=""
    fi
    _WIZ_REMOTE_WEB_STATE="unchecked"
    write_env || return 1
    _stage2_preserve_stage1_marker

    _stage2_source_env

    # Apply chosen Jellyfin remote-streaming cap to config.yml so the
    # post-LE-gate `configure.sh --only npm,jellyfin,homepage` run picks
    # it up via configure_jellyfin_streaming. Skip when no value was set
    # (e.g. wizard not run interactively, or user kept the default 0).
    if [[ -n "${_WIZ_JELLYFIN_BITRATE:-}" ]]; then
        sed -i "s/^  remote_bitrate_limit:.*/  remote_bitrate_limit: ${_WIZ_JELLYFIN_BITRATE}    # Mbps per remote viewer (0 = unlimited). Set by Stage 2 wizard./" "$SCRIPT_DIR/config.yml"
        log_info "Jellyfin remote streaming cap: $([[ "$_WIZ_JELLYFIN_BITRATE" == "0" ]] && echo unlimited || echo "${_WIZ_JELLYFIN_BITRATE} Mbps per viewer")"
    fi

    echo ""
    pull_images

    echo ""
    start_stack
    wait_all_healthy

    # fail2ban only runs on remote-access (proxy-profile) installs, which is a
    # Stage 2 decision — hence installed here, not in Stage 1 beside the storage
    # watchdog. Install the log-rotation reload watcher when fail2ban is up; tear
    # it down otherwise (LAN-only re-run). Gated on ground truth, not a wizard var.
    if service_container_running fail2ban; then
        f2b_install_reload_watcher
    else
        f2b_uninstall_reload_watcher || true
    fi

    echo ""
    log_info "Running remote-access auto-configuration..."
    local remote_config_rc=0
    # DDNS verify degraded (docker/image unavailable at collection): creds are
    # saved but nothing was pushed and a fresh install's DNS is not live yet.
    # Don't gamble a Let's Encrypt attempt (rate-limit risk + a scary "failed"):
    # still bring ddns-updater up so it pushes the IP, but leave remote HTTPS at
    # "unchecked" and let day-2 "Add remote access" finish it once DNS resolves.
    local attempt_remote=1 spin_msg="Requesting Let's Encrypt certificates..."
    if _stage2_ddns_unverified; then
        attempt_remote=0
        spin_msg="Configuring DDNS + WireGuard (HTTPS deferred until DNS resolves)..."
    fi
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    elif type ui_spin >/dev/null 2>&1; then
        # configure.sh --only npm runs sudo internally (configure_npm), but it is
        # wrapped in `bash -c` here so ui_spin's direct-`sudo` prime can't reach it —
        # warm the credential cache in the foreground first (see scripts/lib/ui.sh).
        sudo -v 2>/dev/null || true
        ui_spin "$spin_msg" \
            bash -c "cd '$SCRIPT_DIR' && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard" || remote_config_rc=$?
    else
        (cd "$SCRIPT_DIR" && MEDIASTACK_NPM_ATTEMPT_REMOTE=$attempt_remote ./scripts/configure.sh --only npm,ddns-updater,wireguard) || remote_config_rc=$?
    fi
    if ((remote_config_rc != 0)); then
        log_warn "Remote-access auto-configuration returned a warning or error; checking HTTPS postconditions anyway."
    fi

    if _stage2_ddns_unverified; then
        # REMOTE_WEB_STATE stays "unchecked" (set above); no LE gate to run.
        log_info "DDNS is set up for $(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER"). Once jellyfin.${_WIZ_DOMAIN} resolves to this box, choose Features & settings -> Add remote access to enable HTTPS."
        print_access_info
        return 0
    fi

    stage2_le_gate "$_WIZ_DOMAIN"
    local gate_rc=$?

    print_access_info
    return "$gate_rc"
}
