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
    ui_kv "System hardening" "$([[ "${_WIZ_HARDENING_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)"
}
