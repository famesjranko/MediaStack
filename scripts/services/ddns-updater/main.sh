# =============================================================================
# 9. DDNS Updater — check status, log guidance
# =============================================================================
# Actual DDNS config seeding happens in setup.sh (before containers start).
# This function reports status so configure.sh output is consistent.

configure_ddns_updater() {
    if ! service_container_running ddns-updater; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}[+] Checking DDNS Updater...${NC}"

    local config_file="$SCRIPT_DIR/config/ddns-updater/config.json"
    if [[ -f "$config_file" ]]; then
        log_ok "DDNS config present. View status at http://<ip>:8000; change the provider or credentials via ./mediastack -> Features -> Update DDNS provider / credentials (docs/operations/day-2.md)."
    else
        log_warn "DDNS updater running but no config.json - set up remote access via ./mediastack -> Features -> Add remote access (docs/operations/day-2.md)."
    fi
}
