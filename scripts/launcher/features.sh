#!/usr/bin/env bash
# Owns: Feature/settings menu routing and day-2 feature toggles.
# Sources: launcher globals, .env, scripts/lib/ui.sh, storage.sh, recovery.sh, and service helpers.

_feature_state() { [[ "${1:-false}" == "true" ]] && echo "ON" || echo "OFF"; }

submenu_features() {
    while true; do
        clear
        local _remote
        case "${REMOTE_WEB_STATE:-}" in
            ready) _remote="ready (${DOMAIN:-configured})" ;;
            skipped) _remote="LAN only (skipped)" ;;
            *) _remote="LAN only" ;;
        esac
        ui_box "MediaStack - Features & Settings" "$(ui_kv 'Remote access' "$_remote")"
        echo ""
        local options=()

        local _qp_name _dl _ul
        _qp_name=$(CONFIG_FILE="$SCRIPT_DIR/config.yml" cfg_field "quality_profile.name" 2>/dev/null)
        _dl="${QBT_DL_LIMIT:-0}"
        _ul="${QBT_UL_LIMIT:-0}"
        [[ "$_dl" == "0" ]] && _dl="unlimited" || _dl="${_dl} MB/s"
        [[ "$_ul" == "0" ]] && _ul="unlimited" || _ul="${_ul} MB/s"

        if recovery_menu_remote_available; then
            options+=("Add remote access (HTTPS, domain, WireGuard)")
        fi
        options+=("Subtitles (Bazarr): $(_feature_state "${BAZARR_ENABLED:-false}")")
        options+=("File sharing (SMB): $(_feature_state "${SMB_ENABLED:-false}")")
        options+=("Search indexers: $(_feature_state "${PUBLIC_INDEXERS_ENABLED:-false}")")
        options+=("Firewall (UFW): $(_feature_state "${UFW_ENABLED:-true}")")
        options+=("System hardening: $(_feature_state "${HARDENING_ENABLED:-true}")")
        if storage_is_nas; then
            options+=("NAS storage watchdog: $(_feature_state "${STORAGE_WATCHDOG:-true}")")
        fi
        options+=("Change quality profile: ${_qp_name:-unknown}")
        options+=("Adjust bandwidth: DL ${_dl} / UL ${_ul}")
        # Only when remote access is fully set up (ready) AND via DDNS: a static-IP
        # remote has no provider to change, and when remote is unset the "Add remote
        # access" row above is the entry point instead.
        if ! recovery_menu_remote_available && _ddns_configured; then
            options+=("Update DDNS provider / credentials: ${DDNS_PROVIDER:-}")
        fi
        options+=("Back")

        echo ""
        local choice
        choice=$(ui_choose "Manage features & settings:" "${options[@]}")

        case "$choice" in
            "Add remote access"*) action_remote ;;
            "Subtitles (Bazarr):"*) action_toggle_bazarr ;;
            "File sharing (SMB):"*) action_toggle_smb ;;
            "Search indexers:"*) action_toggle_indexers ;;
            "Firewall (UFW):"*) action_toggle_ufw ;;
            "System hardening:"*) action_toggle_hardening ;;
            "NAS storage watchdog:"*) action_toggle_watchdog ;;
            "Change quality profile"*) action_change_quality ;;
            "Adjust bandwidth"*) action_adjust_bandwidth ;;
            "Update DDNS provider"*) action_change_ddns ;;
            *) return 0 ;;
        esac
    done
}

action_toggle_bazarr() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        pause_for_menu
        return 0
    fi
    local rc=0
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Turn OFF subtitles (Bazarr)? Your subtitle settings are kept." no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var BAZARR_ENABLED false
        _reload_env
        ui_log info "Stopping Bazarr (its ./config/bazarr settings are preserved)..."
        # Literal --profile subtitles: the flag is required for compose to see
        # the service, and _build_profile_args no longer yields it post-flip.
        # rm -sf stops + removes only the container; the bind-mount survives.
        docker compose --profile subtitles rm -sf bazarr 2>&1 || rc=$?
        _show_action_result "$rc" "Disable subtitles (Bazarr)"
    else
        ui_confirm "Turn ON subtitles (Bazarr) for automatic subtitle downloads?" yes || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var BAZARR_ENABLED true
        _reload_env
        ui_log info "Enabling Bazarr..."
        _regenerate_override
        local profiles=()
        _build_profile_args profiles
        docker compose "${profiles[@]}" up -d bazarr 2>&1 || rc=$?
        if ((rc == 0)); then
            "$SCRIPT_DIR/scripts/configure.sh" --only bazarr || rc=$?
        fi
        _show_action_result "$rc" "Enable subtitles (Bazarr)"
    fi
    pause_for_menu
}

action_toggle_smb() {
    echo ""
    local rc=0
    if [[ "${SMB_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Turn OFF the host file share (SMB)? Your files are NOT deleted." no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var SMB_ENABLED false
        _reload_env
        ui_log info "Removing the MediaStack SMB share (uses sudo; your files are untouched)..."
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/scripts/setup/hardening.sh"
        setup_samba || rc=$?
        _show_action_result "$rc" "Disable file sharing (SMB)"
    else
        ui_log info "Share your media over the network so other devices can browse it."
        local scope_choice
        scope_choice=$(ui_choose "What should the SMB share expose?" \
            "Media only (recommended)" \
            "Full system (everything on this box)" \
            "Cancel")
        local scope=""
        case "$scope_choice" in
            "Media only"*) scope="data" ;;
            "Full system"*) scope="system" ;;
            *)
                ui_log info "No change."
                pause_for_menu
                return 0
                ;;
        esac
        _set_env_var SMB_ENABLED true
        _set_env_var SMB_SHARE_SCOPE "$scope"
        _reload_env
        ui_log info "Configuring the SMB share (uses sudo)..."
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/scripts/setup/hardening.sh"
        setup_samba || rc=$?
        _show_action_result "$rc" "Enable file sharing (SMB)"
    fi
    pause_for_menu
}

action_toggle_watchdog() {
    echo ""
    local rc=0
    if [[ "${STORAGE_WATCHDOG:-true}" == "true" ]]; then
        ui_confirm "Turn OFF the NAS storage watchdog? Data services will no longer be protected if the NAS drops." no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var STORAGE_WATCHDOG false
        _reload_env
        ui_log info "Stopping the NAS storage watchdog (uses sudo)..."
        storage_pause_watchdog_for_install || rc=$?
        _show_action_result "$rc" "Disable NAS storage watchdog"
    else
        ui_confirm "Turn ON the NAS storage watchdog? Recommended - it protects data services if the NAS disconnects." yes || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var STORAGE_WATCHDOG true
        _reload_env
        ui_log info "Installing the NAS storage watchdog (uses sudo)..."
        storage_install_watchdog || rc=$?
        _show_action_result "$rc" "Enable NAS storage watchdog"
    fi
    pause_for_menu
}

action_toggle_ufw() {
    echo ""
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    local rc=0
    if [[ "${UFW_ENABLED:-true}" == "true" ]]; then
        ui_confirm "Turn OFF the UFW firewall? Rules you added yourself are kept." no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var UFW_ENABLED false
        _reload_env
        ui_log info "Removing MediaStack firewall rules (uses sudo)..."
        if _uninstall_ufw; then
            # Reset the ownership latches so a later re-enable reconfigures
            # cleanly — setup_ufw early-returns if UFW_DEFAULTS_APPLIED is still
            # true with non-'deny allow' defaults after we restored the baseline.
            _ms_state_set UFW_DEFAULTS_APPLIED false
            _ms_state_set UFW_ENABLED_BY_MEDIASTACK false
            _ms_state_set UFW_RULE_COUNT 0
            if sudo ufw status 2>/dev/null | grep -q "Status: active"; then
                ui_log info "MediaStack's firewall rules were removed."
                ui_log warn "UFW itself is left ENABLED because it carries rules/defaults you"
                ui_log warn "added yourself (or it was already running before MediaStack)."
                ui_log warn "Run 'sudo ufw disable' if you want the firewall fully off."
            fi
        else
            rc=1
        fi
        _show_action_result "$rc" "Disable UFW firewall"
    else
        if ! _docker_reachable; then
            ui_log warn "Docker isn't reachable - start the stack first (the firewall restricts Docker's published ports)."
            pause_for_menu
            return 0
        fi
        if ! validate_install_state; then
            ui_log warn "No valid install ledger found - run a full install/repair before enabling the firewall."
            pause_for_menu
            return 0
        fi
        ui_confirm "Turn ON the UFW firewall (default-deny inbound; LAN, SSH and web stay open)?" yes || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var UFW_ENABLED true
        _reload_env
        ui_log info "Configuring the UFW firewall (uses sudo)..."
        setup_ufw || rc=$?
        # Reopen the configurable service ports only when remote access is set up
        # (a real domain); LAN-only installs never opened them.
        if ((rc == 0)) && [[ "${DOMAIN:-example.com}" != "example.com" ]]; then
            setup_ufw_service_ports || rc=$?
        fi
        _show_action_result "$rc" "Enable UFW firewall"
    fi
    pause_for_menu
}

action_toggle_hardening() {
    echo ""
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    local rc=0
    if [[ "${HARDENING_ENABLED:-true}" == "true" ]]; then
        ui_confirm "Turn OFF system hardening (auto security updates + kernel sysctl)?" no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var HARDENING_ENABLED false
        _reload_env
        ui_log info "Reverting kernel hardening and the auto-update policy (uses sudo)..."
        _uninstall_sysctl || rc=$?
        _uninstall_apt || rc=$?
        _show_action_result "$rc" "Disable system hardening"
    else
        if ! validate_install_state; then
            ui_log warn "No valid install ledger found - run a full install/repair before enabling hardening."
            pause_for_menu
            return 0
        fi
        ui_confirm "Turn ON system hardening (automatic security updates + kernel network hardening)?" yes || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var HARDENING_ENABLED true
        _reload_env
        ui_log info "Applying system hardening (uses sudo)..."
        setup_unattended_upgrades || rc=$?
        setup_sysctl_hardening || rc=$?
        _show_action_result "$rc" "Enable system hardening"
    fi
    pause_for_menu
}

action_toggle_indexers() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        pause_for_menu
        return 0
    fi
    local rc=0
    local wiz="$SCRIPT_DIR/scripts/setup/wizard_apply.py"
    if [[ "${PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Stop configuring public indexers? Existing ones stay in Jackett." no || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var PUBLIC_INDEXERS_ENABLED false
        _reload_env
        python3 "$wiz" --indexers-only false --config "$SCRIPT_DIR/config.yml" || rc=$?
        ui_log info "Indexers already added stay configured in Jackett / Sonarr / Radarr -"
        ui_log info "remove them from the Jackett web UI if you no longer want them."
        _show_action_result "$rc" "Disable public indexers"
    else
        ui_log info "This sets your indexer list to the bundled example preset"
        ui_log info "(any indexers you added yourself will be overwritten)."
        ui_confirm "Add the example public search indexers so Sonarr/Radarr can find releases?" yes || {
            ui_log info "No change."
            pause_for_menu
            return 0
        }
        _set_env_var PUBLIC_INDEXERS_ENABLED true
        _reload_env
        ui_log info "Adding public indexers to your settings..."
        python3 "$wiz" --indexers-only true --config "$SCRIPT_DIR/config.yml" || rc=$?
        if ((rc == 0)); then
            ui_log info "Wiring indexers into Jackett, Sonarr and Radarr..."
            "$SCRIPT_DIR/scripts/configure.sh" --only jackett,sonarr,radarr || rc=$?
        fi
        _show_action_result "$rc" "Enable public indexers"
    fi
    pause_for_menu
}

action_remote() { _run_setup_return 0 "Add remote access" --remote; }

action_configure() {
    echo ""
    if ! ui_confirm "Re-run auto-configuration now?" no; then
        ui_log info "Cancelled."
        pause_for_menu
        return 0
    fi
    # Precondition: configure.sh polls each core service for 90s via
    # wait_for_service (lib/http.sh:47). If even one core service is missing,
    # the user waits 90s+ per missing service before configure.sh bails. Check
    # all 10 core services configure.sh requires (configure.sh:105-112). The
    # bazarr/npm/wireguard checks inside configure.sh are already gated by
    # container presence, so we don't enforce those here.
    local core_services=(qbittorrent jackett sonarr radarr jellyfin seerr portainer homepage uptime-kuma beszel)
    local running missing=()
    running=$(docker compose ps --filter status=running --format '{{.Name}}' 2>/dev/null || true)
    local svc
    for svc in "${core_services[@]}"; do
        if ! grep -qx "$svc" <<<"$running"; then
            missing+=("$svc")
        fi
    done
    if ((${#missing[@]} > 0)); then
        ui_log warn "Stack is not fully running - configure.sh would wait 90s per missing service."
        ui_log info "Not running: ${missing[*]}"
        ui_log info "Start the stack first:  Manage stack -> Start all services"
        pause_for_menu
        return 0
    fi
    ui_log info "This adds services newly enabled in your settings. Already-configured services are detected and skipped, not changed."
    ui_log info "To change a running service's settings, use that service's own web UI."
    local rc=0
    "$SCRIPT_DIR/scripts/configure.sh" || rc=$?
    local _issues_file="$SCRIPT_DIR/.configure_issues"
    if [[ -s "$_issues_file" ]]; then
        echo ""
        ui_log warn "Re-run configuration completed with warnings — see summary above."
        rm -f "$_issues_file"
    else
        _show_action_result "$rc" "Re-run configuration"
    fi
    pause_for_menu
}
