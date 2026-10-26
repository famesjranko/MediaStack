#!/usr/bin/env bash
# Owns: Feature/settings menu routing and day-2 feature toggles.
# Sources: launcher globals, .env, scripts/lib/ui.sh, storage.sh, recovery.sh, and service helpers.

# The admin-port filter is ON unless ADMIN_PORT_FILTER is exactly "false"; the
# rule lives in admin-filter.sh so setup, health and the menu cannot disagree.
# Loaded from this file's own location because the toggles source hardening.sh
# only when they run, after the menu has already rendered.
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/../setup/hardening/admin-filter.sh"

_feature_admin_filter_state() {
    admin_filter_opted_out && echo "OFF" || echo "ON"
}

_feature_state() { [[ "${1:-false}" == "true" ]] && echo "ON" || echo "OFF"; }

# Persist a toggle's KEY VALUE pairs before the action applies them, so a failed
# write stops the action instead of leaving .env behind the live system. Returns
# non-zero once the operator has been shown the failure; callers return early.
_feature_persist_or_report() {
    local label="$1" persist_rc=0
    shift
    _set_env_vars "$@" || persist_rc=$?
    if ((persist_rc != 0)); then
        _show_action_result 1 "$label"
        launcher_pause_for_menu
        return 1
    fi
    _reload_env
}

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
        options+=("Admin-port filter: $(_feature_admin_filter_state)")
        options+=("System hardening: $(_feature_state "${HARDENING_ENABLED:-true}")")
        if storage_is_nas; then
            options+=("NAS storage watchdog: $(_feature_state "${STORAGE_WATCHDOG:-true}")")
        fi
        options+=("Change quality profile: ${_qp_name:-unknown}")
        options+=("Adjust bandwidth: DL ${_dl} / UL ${_ul}")
        options+=("Repair Jellyfin connections (Sonarr, Radarr)")
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
            "Admin-port filter:"*) action_toggle_admin_filter ;;
            "System hardening:"*) action_toggle_hardening ;;
            "NAS storage watchdog:"*) action_toggle_watchdog ;;
            "Change quality profile"*) action_change_quality ;;
            "Adjust bandwidth"*) action_adjust_bandwidth ;;
            "Repair Jellyfin connections"*) action_repair_jellyfin_connections ;;
            "Update DDNS provider"*) action_change_ddns ;;
            *) return 0 ;;
        esac
    done
}

action_toggle_bazarr() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        launcher_pause_for_menu
        return 0
    fi
    local rc=0
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Turn OFF subtitles (Bazarr)? Your subtitle settings are kept." no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable subtitles (Bazarr)" BAZARR_ENABLED false || return 0
        ui_log info "Stopping Bazarr (its ./config/bazarr settings are preserved)..."
        # Literal --profile subtitles: the flag is required for compose to see
        # the service, and profiles_build_args no longer yields it post-flip.
        # rm -sf stops + removes only the container; the bind-mount survives.
        docker compose --profile subtitles rm -sf bazarr 2>&1 || rc=$?
        _show_action_result "$rc" "Disable subtitles (Bazarr)"
    else
        ui_confirm "Turn ON subtitles (Bazarr) for automatic subtitle downloads?" yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable subtitles (Bazarr)" BAZARR_ENABLED true || return 0
        ui_log info "Enabling Bazarr..."
        _regenerate_override
        local profiles=()
        profiles_build_args profiles
        docker compose "${profiles[@]}" up -d bazarr 2>&1 || rc=$?
        if ((rc == 0)); then
            "$SCRIPT_DIR/scripts/configure.sh" --only bazarr || rc=$?
        fi
        _show_action_result "$rc" "Enable subtitles (Bazarr)"
    fi
    launcher_pause_for_menu
}

action_toggle_smb() {
    echo ""
    local rc=0
    if [[ "${SMB_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Turn OFF the host file share (SMB)? Your files are NOT deleted." no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable file sharing (SMB)" \
            SMB_ENABLED false SMB_SHARE_SCOPE data || return 0
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
                launcher_pause_for_menu
                return 0
                ;;
        esac
        _feature_persist_or_report "Enable file sharing (SMB)" \
            SMB_ENABLED true SMB_SHARE_SCOPE "$scope" || return 0
        ui_log info "Configuring the SMB share (uses sudo)..."
        # shellcheck disable=SC1091
        source "$SCRIPT_DIR/scripts/setup/hardening.sh"
        setup_samba || rc=$?
        _show_action_result "$rc" "Enable file sharing (SMB)"
    fi
    launcher_pause_for_menu
}

action_toggle_watchdog() {
    echo ""
    local rc=0
    if [[ "${STORAGE_WATCHDOG:-true}" == "true" ]]; then
        ui_confirm "Turn OFF the NAS storage watchdog? Data services will no longer be protected if the NAS drops." no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable NAS storage watchdog" STORAGE_WATCHDOG false || return 0
        ui_log info "Stopping the NAS storage watchdog (uses sudo)..."
        storage_pause_watchdog_for_install || rc=$?
        _show_action_result "$rc" "Disable NAS storage watchdog"
    else
        ui_confirm "Turn ON the NAS storage watchdog? Recommended - it protects data services if the NAS disconnects." yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable NAS storage watchdog" STORAGE_WATCHDOG true || return 0
        ui_log info "Installing the NAS storage watchdog (uses sudo)..."
        storage_install_watchdog || rc=$?
        _show_action_result "$rc" "Enable NAS storage watchdog"
    fi
    launcher_pause_for_menu
}

action_toggle_ufw() {
    echo ""
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    local rc=0
    if [[ "${UFW_ENABLED:-true}" == "true" ]]; then
        ui_confirm "Turn OFF the UFW firewall? Rules you added yourself are kept." no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable UFW firewall" UFW_ENABLED false || return 0
        ui_log info "Removing MediaStack firewall rules (uses sudo)..."
        # The admin-port filter is not UFW's. Converging it first also moves a
        # legacy after.rules block out before UFW is touched; the UFW teardown
        # itself never touches the chain.
        if ! admin_filter_opted_out; then
            setup_admin_filter || rc=1
        fi
        if ((rc == 0)) && _uninstall_ufw; then
            # Reset the ownership latches so a later re-enable reconfigures
            # cleanly — setup_ufw early-returns if UFW_DEFAULTS_APPLIED is still
            # true with non-'deny allow' defaults after we restored the baseline.
            _ms_state_set UFW_DEFAULTS_APPLIED false
            _ms_state_set UFW_ENABLED_BY_MEDIASTACK false
            _ms_ufw_ledger_truncate 0 "$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || echo 0)"
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
        if ! validate_install_state; then
            ui_log warn "No valid install ledger found - run a full install/repair before enabling the firewall."
            launcher_pause_for_menu
            return 0
        fi
        ui_confirm "Turn ON the UFW firewall (default-deny inbound; LAN, SSH and web stay open)?" yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable UFW firewall" UFW_ENABLED true || return 0
        ui_log info "Configuring the UFW firewall (uses sudo)..."
        # Converge the admin-port filter first (the UFW toggles never touch the
        # chain): a legacy after.rules block must be gone before UFW loads it.
        if ! admin_filter_opted_out; then
            setup_admin_filter || rc=$?
        fi
        ((rc == 0)) && { setup_ufw || rc=$?; }
        # Reopen the configurable service ports only when remote access is set up
        # (a real domain); LAN-only installs never opened them.
        if ((rc == 0)) && [[ "${DOMAIN:-example.com}" != "example.com" ]]; then
            setup_ufw_service_ports || rc=$?
        fi
        # Independent of DOMAIN: WireGuard is gated on WG_INIT_PASSWORD alone.
        ((rc == 0)) && { setup_ufw_wireguard_clients || rc=$?; }
        _show_action_result "$rc" "Enable UFW firewall"
    fi
    launcher_pause_for_menu
}

action_toggle_admin_filter() {
    echo ""
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    local rc=0
    if ! admin_filter_opted_out; then
        ui_log warn "Turning this OFF makes ports 81, 51821, 8000, 3001, 9000, the *arr and"
        ui_log warn "download UIs and 7359/udp reachable from ANY source your router forwards."
        ui_confirm "Turn OFF the admin-port filter?" no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable admin-port filter" ADMIN_PORT_FILTER false || return 0
        ui_log info "Removing the admin-port filter (uses sudo; Docker keeps running)..."
        admin_filter_disable || rc=1
        _show_action_result "$rc" "Disable admin-port filter"
    else
        if ! validate_install_state; then
            ui_log warn "No valid install ledger found - run a full install/repair before enabling the filter."
            launcher_pause_for_menu
            return 0
        fi
        ui_confirm "Turn ON the admin-port filter (admin UIs reachable from the LAN, this machine and Tailscale only)?" yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable admin-port filter" ADMIN_PORT_FILTER true || return 0
        ui_log info "Installing the admin-port filter (uses sudo)..."
        setup_admin_filter || rc=$?
        _show_action_result "$rc" "Enable admin-port filter"
    fi
    launcher_pause_for_menu
}

action_toggle_hardening() {
    echo ""
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/scripts/setup/hardening.sh"
    local rc=0
    if [[ "${HARDENING_ENABLED:-true}" == "true" ]]; then
        ui_confirm "Turn OFF system hardening (auto security updates + kernel sysctl)?" no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable system hardening" HARDENING_ENABLED false || return 0
        ui_log info "Reverting kernel hardening and the auto-update policy (uses sudo)..."
        _uninstall_sysctl || rc=$?
        _uninstall_apt || rc=$?
        _show_action_result "$rc" "Disable system hardening"
    else
        if ! validate_install_state; then
            ui_log warn "No valid install ledger found - run a full install/repair before enabling hardening."
            launcher_pause_for_menu
            return 0
        fi
        ui_confirm "Turn ON system hardening (automatic security updates + kernel network hardening)?" yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable system hardening" HARDENING_ENABLED true || return 0
        ui_log info "Applying system hardening (uses sudo)..."
        setup_unattended_upgrades || rc=$?
        setup_sysctl_hardening || rc=$?
        _show_action_result "$rc" "Enable system hardening"
    fi
    launcher_pause_for_menu
}

action_toggle_indexers() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        launcher_pause_for_menu
        return 0
    fi
    local rc=0
    local wiz="$SCRIPT_DIR/scripts/setup/wizard_apply.py"
    if [[ "${PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]]; then
        ui_confirm "Stop configuring public indexers? Existing ones stay in Jackett." no || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Disable public indexers" PUBLIC_INDEXERS_ENABLED false || return 0
        python3 "$wiz" --indexers-only false --config "$SCRIPT_DIR/config.yml" || rc=$?
        ui_log info "Indexers already added stay configured in Jackett / Sonarr / Radarr -"
        ui_log info "remove them from the Jackett web UI if you no longer want them."
        _show_action_result "$rc" "Disable public indexers"
    else
        ui_log info "This sets your indexer list to the bundled example preset"
        ui_log info "(any indexers you added yourself will be overwritten)."
        ui_confirm "Add the example public search indexers so Sonarr/Radarr can find releases?" yes || {
            ui_log info "No change."
            launcher_pause_for_menu
            return 0
        }
        _feature_persist_or_report "Enable public indexers" PUBLIC_INDEXERS_ENABLED true || return 0
        ui_log info "Adding public indexers to your settings..."
        python3 "$wiz" --indexers-only true --config "$SCRIPT_DIR/config.yml" || rc=$?
        if ((rc == 0)); then
            ui_log info "Wiring indexers into Jackett, Sonarr and Radarr..."
            "$SCRIPT_DIR/scripts/configure.sh" --only jackett,sonarr,radarr || rc=$?
        fi
        _show_action_result "$rc" "Enable public indexers"
    fi
    launcher_pause_for_menu
}

# The script checks Sonarr and Radarr, lists what it would change and asks before
# it changes anything, so the confirmation is shown next to its evidence.
action_repair_jellyfin_connections() {
    echo ""
    if ! _docker_reachable; then
        ui_log warn "Docker isn't reachable - start the stack first."
        launcher_pause_for_menu
        return 0
    fi
    ui_log info "Checks the Jellyfin connection in Sonarr and Radarr. After you confirm,"
    ui_log info "it replaces a stale Jellyfin API key in the connections MediaStack created."
    local rc=0
    "$SCRIPT_DIR/scripts/configure.sh" --repair-jellyfin-connections || rc=$?
    _show_action_result "$rc" "Repair Jellyfin connections"
    launcher_pause_for_menu
}

action_remote() { _run_setup_return 0 "Add remote access" --remote; }
