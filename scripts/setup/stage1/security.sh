# Owns: stage1_* — Stage 1 firewall and system-hardening choices.
# Sources: wizard UI and Stage 1 wizard state.

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

    _stage1_collect_admin_filter

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
    ui_kv "Admin-port filter" "$([[ "${_WIZ_ADMIN_PORT_FILTER:-true}" != "false" ]] && echo enabled || echo disabled)"
    ui_kv "System hardening" "$([[ "${_WIZ_HARDENING_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)"
}

# The admin-port filter works without UFW, so it is a separate choice. Ask only
# where the answer matters: when the firewall is declined, or when an earlier
# run opted out (so the user can opt back in). Otherwise keep it on and ask
# nothing. Non-interactive runs take the default (yes) without blocking.
# Only the exact value false is an opt-out, matching admin_filter_opted_out.
_stage1_collect_admin_filter() {
    local prev="${_WIZ_ADMIN_PORT_FILTER:-${ADMIN_PORT_FILTER:-true}}"
    if [[ "$_WIZ_UFW_ENABLED" == "true" && "$prev" != "false" ]]; then
        _WIZ_ADMIN_PORT_FILTER="true"
        return 0
    fi
    local default="yes"
    [[ "$prev" != "false" ]] || default="no"
    ui_log info "The admin-port filter keeps your admin web UIs reachable only from your"
    ui_log info "LAN, this machine and Tailscale. It does not need the firewall and cannot"
    ui_log info "lock you out of SSH. Recommended."
    ui_log warn "If you turn it off, ports 81, 51821, 8000, 3001, 9000, the *arr and download"
    ui_log warn "UIs and 7359/udp become reachable from any source your router forwards."
    if ui_confirm "Keep the admin-port filter?" "$default"; then
        _WIZ_ADMIN_PORT_FILTER="true"
    else
        _WIZ_ADMIN_PORT_FILTER="false"
    fi
}
