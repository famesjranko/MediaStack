# Owns: the destroy-preview text and the typed-DESTROY teardown sequence
# (wipe/full-wipe/uninstall) for an existing MediaStack install.
# Sources: $SCRIPT_DIR and scripts/lib/common.sh, loaded by the caller
# (scripts/setup/checks.sh, sourced from setup.sh). Calls
# storage_pause_watchdog_for_install (scripts/setup/storage.sh) and
# record_launcher_outcome (scripts/setup/checks.sh).

_print_destroy_preview() {
    # nuke_existing_install helper. DELETE/PRESERVE text reflects the actual destroy commands
    # (down -v + rm .env + rm .nvidia-finalize-pending, no git clean):
    # compose declares NO named volumes and config/ is a host bind mount, so
    # BOTH data/ and config/ survive 'down -v' and are listed under PRESERVE.
    # Optional _mode param: "wipe" (default), "full-wipe", or "uninstall".
    local _mode="${1:-wipe}"
    cat <<'PREVIEW'

This will DELETE:
  * Docker containers (compose --profile '*' down -v --remove-orphans)
  * .env (your secrets file - passwords, API keys, domain) and internal setup markers
PREVIEW
    if [[ "$_mode" == "uninstall" ]]; then
        # Only list what the user actually opted into — the firewall and
        # hardening are optional toggles, so a disabled feature isn't "deleted".
        if [[ "${UFW_ENABLED:-true}" != "false" ]]; then
            printf '  * MediaStack-owned UFW rules and Docker firewall chain\n'
        fi
        if [[ "${HARDENING_ENABLED:-true}" != "false" ]]; then
            printf '  * MediaStack kernel sysctl hardening (unchanged values restored)\n'
            printf '  * MediaStack unattended-upgrades drop-ins\n'
        fi
        printf '  * MediaStack systemd units and watchdog helper files\n'
    fi
    if [[ "$_mode" == "full-wipe" || "$_mode" == "uninstall" ]]; then
        cat <<'PREVIEW'
  * config/ - all service settings & databases (Jellyfin watch history,
    Sonarr/Radarr/Bazarr DBs, qBittorrent, Jackett, NPM certs, WireGuard
    device pairings) - requires sudo for Docker-owned files
PREVIEW
    fi
    cat <<'PREVIEW'

This will PRESERVE:
  * data/ - your media library (bind mount, never touched by 'down -v')
PREVIEW
    if [[ "$_mode" == "wipe" ]]; then
        cat <<'PREVIEW'
  * config/ - all service settings & databases (Jellyfin watch history,
    Sonarr/Radarr/Bazarr DBs, qBittorrent, Jackett, NPM certs, WireGuard
    device pairings) - bind mount, survives 'down -v'
  * Pre-seeded configs (fail2ban filters, jackett ServerConfig, etc.)
PREVIEW
    else
        cat <<'PREVIEW'
  * config/examples/ - reference YAML files (not Docker-owned, not wiped)
PREVIEW
    fi
    echo ""
    case "$_mode" in
        wipe) printf 'Reinstalling keeps your old settings. To start truly clean, clear ./config\nyourself first - this wipe deliberately does not.\n\n' ;;
        full-wipe) printf 'This is a complete reset. All service databases, settings, and credentials\nwill be lost. Use this to recover from a broken install.\n\n' ;;
        uninstall) printf 'data/ (your media) is preserved. config/ settings, databases, and credentials\nare removed so a later reinstall starts clean. The MediaStack directory remains.\n\n' ;;
    esac
}

# Remove all Docker-runtime state in config/ but skip config/examples/ (static
# reference YAML read by wizard_apply.py before create_config_dirs runs — Docker
# never writes there, so there is nothing to wipe). Shared by full-wipe and the
# --uninstall path so a later reinstall starts from a clean slate instead of
# inheriting stale service credentials (Jellyfin/Seerr/Uptime-Kuma embed their
# admin password in config/, which would then reject a freshly generated .env).
wipe_config_runtime() {
    [[ -d "$SCRIPT_DIR/config" ]] || return 0
    sudo find "$SCRIPT_DIR/config" -mindepth 1 -maxdepth 1 \
        -not -name 'examples' -exec rm -rf {} +
    log_ok "config/ wiped (examples/ preserved)."
}

nuke_existing_install() {
    # Typed-DESTROY confirmation + destroy command sequence.
    # Satisfies the documented rebuild path: down -v + rm .env.
    # data/ bind mount is NEVER touched.
    # Optional _mode: "wipe" (default, continues to fresh setup), "full-wipe"
    # (also wipes config/ via sudo, preserving config/examples/ — the live
    # pre-seeds are re-seeded from those templates on the next install), or
    # "uninstall".
    local _mode="${1:-wipe}"

    _print_destroy_preview "$_mode"

    local _input
    _input=$(ui_input "Type DESTROY to confirm (anything else aborts)" "")

    # CR strip — defensive against pasted input from Windows clients.
    # No whitespace trim — one typo aborts.
    local cleaned="${_input//$'\r'/}"

    if [[ "$cleaned" != "DESTROY" ]]; then
        log_info "Aborted. No changes made."
        record_launcher_outcome aborted
        exit 0
    fi

    if [[ -f "$SCRIPT_DIR/.env" ]]; then
        set -a
        source "$SCRIPT_DIR/.env"
        set +a
    fi
    local _watchdog_was_enabled=false _watchdog_was_active=false
    if [[ "$_mode" == "uninstall" ]]; then
        sudo systemctl is-enabled mediastack-storage-watchdog.service >/dev/null 2>&1 \
            && _watchdog_was_enabled=true
        sudo systemctl is-active mediastack-storage-watchdog.service >/dev/null 2>&1 \
            && _watchdog_was_active=true
    fi
    storage_pause_watchdog_for_install || return 1

    # Destroy command sequence — the documented rebuild path, verbatim.
    # No git clean (deliberate — would risk deleting user-valued files
    # in config/jellyfin/data, etc.).
    #
    # The pre-flight prompt_sudo_cache pre-cached creds specifically so
    # this destroy could use sudo when the user's docker group membership
    # isn't loaded yet (the canonical `--full` first-run case). Capture rc
    # and emit a warn before `rm -f .env` so the user knows if the destroy was
    # incomplete (user-observability — no more silent `|| true`).
    local _down_rc=0
    docker compose --profile "*" down -v --remove-orphans || _down_rc=$?
    if ((_down_rc != 0)); then
        log_warn "Pre-flight: destroy did not complete cleanly (docker compose exit ${_down_rc}). Inspect: docker ps -a; docker volume ls"
        if [[ "$_mode" == "uninstall" ]]; then
            [[ "$_watchdog_was_enabled" == "false" ]] \
                || sudo systemctl enable mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            [[ "$_watchdog_was_active" == "false" ]] \
                || sudo systemctl start mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            return "$_down_rc"
        fi
    fi
    if [[ "$_mode" == "uninstall" ]]; then
        local _remaining
        _remaining=$(docker compose --profile "*" ps --all -q 2>/dev/null) || {
            log_warn "Could not verify that MediaStack containers stopped; host cleanup was not started."
            [[ "$_watchdog_was_enabled" == "false" ]] \
                || sudo systemctl enable mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            [[ "$_watchdog_was_active" == "false" ]] \
                || sudo systemctl start mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            return 1
        }
        if [[ -n "$_remaining" ]]; then
            log_warn "MediaStack containers remain after teardown; host cleanup was not started."
            [[ "$_watchdog_was_enabled" == "false" ]] \
                || sudo systemctl enable mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            [[ "$_watchdog_was_active" == "false" ]] \
                || sudo systemctl start mediastack-storage-watchdog.service >/dev/null 2>&1 || true
            return 1
        fi
    else
        rm -f "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.nvidia-finalize-pending"
        # Wipe cleared .env from disk but sourced vars live on in bash memory.
        # record_pre_install_state() guards against STAGE_1_COMPLETE=1 without a
        # ledger (legitimate protection on real hosts); clear it here so the
        # fresh-install path that follows treats this as a new host.
        unset STAGE_1_COMPLETE STAGE_3_GPU_STATE
        if [[ "$_mode" == "full-wipe" ]]; then
            wipe_config_runtime
        fi
    fi

    if [[ "$_mode" == "wipe" || "$_mode" == "full-wipe" ]]; then
        log_ok "Existing install removed. Continuing with fresh setup."
    else
        log_ok "Existing install removed."
    fi
}
