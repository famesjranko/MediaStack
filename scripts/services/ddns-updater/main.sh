# =============================================================================
# 9. DDNS Updater — check status, log guidance
# =============================================================================
# Actual DDNS config seeding happens in setup.sh (before containers start).
# This function reports status so configure.sh output is consistent.

configure_ddns_updater() {
    if ! docker ps --filter name=ddns-updater --format '{{.Names}}' 2>/dev/null | grep -q ddns-updater; then
        return 0
    fi

    echo ""
    echo -e "${BOLD}[+] Checking DDNS Updater...${NC}"

    local config_file="$SCRIPT_DIR/config/ddns-updater/config.json"
    if [[ -f "$config_file" ]]; then
        log_ok "DDNS config present (manage at http://<ip>:8000)"
    else
        log_warn "DDNS updater running but no config.json - configure at http://<ip>:8000"
    fi
}
