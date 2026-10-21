# Owns: the main-menu warning shown while the admin-port filter is wanted but not active.
# Sources: scripts/lib/health.sh (the verdict) and scripts/lib/ui.sh.

# Print one warning line under the banner when ADMIN_PORT_FILTER is on (or
# unset, or any value other than false) and the health verdict says the filter is not working. Nothing prints
# when the user turned the filter off: that is their choice, and the Health
# menu reports it as such. A skipped verdict (no passwordless sudo to read
# iptables) also prints nothing, because the filter cannot be shown broken.
launcher_admin_filter_warning() {
    launcher_is_installed || return 0
    declare -F health_docker_user_restrict >/dev/null 2>&1 || source "$SCRIPT_DIR/scripts/lib/health.sh"
    ! admin_filter_opted_out || return 0
    local verdict
    verdict=$(health_docker_user_restrict) || return 0
    [[ "$verdict" == fail\|* ]] || return 0
    ui_log warn "Admin-port filter NOT active: ${verdict#fail|}"
    ui_log warn "Fix: Health & security > Apply changes from a MediaStack update."
}
