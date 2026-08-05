# Owns: stage2_* — Stage 2 remote-access confirmation screen and action selection.
# Sources: Stage 2 DDNS display helpers, WireGuard state, and interactive UI.

_stage2_confirm() {
    ui_section 5 5 "Confirm install"
    # Honest DDNS summary: what was chosen this run, OR — on a day-2 re-run where
    # the user skipped but a previously-configured provider's config.json is
    # preserved (env_gen keeps it rather than leaving a config-less dead remote) —
    # say we're keeping it, not "skipped" (which would be a lie while it still runs).
    local ddns_summary
    if [[ "${_WIZ_USES_DDNS:-false}" == "true" && -n "${_WIZ_DDNS_PROVIDER:-}" ]]; then
        ddns_summary=$(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER")
    elif [[ -n "${DDNS_PROVIDER:-}" ]]; then
        ddns_summary="keeping your existing $(_stage2_ddns_provider_label "$DDNS_PROVIDER") setup"
    else
        ddns_summary="skipped (you manage DNS)"
    fi
    ui_box "Remote Access: Install Plan" \
        "$(ui_kv 'Domain' "$_WIZ_DOMAIN")" \
        "$(ui_kv 'DDNS' "$ddns_summary")" \
        "$(ui_kv 'HTTPS' "jellyfin.${_WIZ_DOMAIN}, seerr.${_WIZ_DOMAIN}")" \
        "$(ui_kv 'WireGuard' "$([[ "${_WIZ_WG_ENABLED:-true}" == "true" ]] && echo "${_WIZ_WG_HOST}:${_WIZ_WG_PORT}" || echo 'disabled')")" \
        "$(ui_kv 'Remote streaming cap' "$([[ "${_WIZ_JELLYFIN_BITRATE:-0}" == "0" ]] && echo 'unlimited' || echo "${_WIZ_JELLYFIN_BITRATE} Mbps/viewer")")" \
        "$(ui_kv 'Access' 'LAN remains available if HTTPS fails')"

    _STAGE2_CONFIRM_ACTION=$(ui_choose "Proceed with remote access installation?" \
        "Install" \
        "Back" \
        "Skip remote access")
}
