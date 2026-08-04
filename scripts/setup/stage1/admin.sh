# Owns: Stage 1 administrator identity collection and review.
# Sources: wizard UI helpers, validators, and `_WIZ_*`/`_WIZ_PREV_*` wizard state.

_stage1_collect_admin() {
    # Collect username, email, then password, and finish with a persistent review
    # of all three so the user sees them together and accepts them at once or
    # starts the section over. Without the review the entered values scroll away
    # (the gum backend clears each input widget after submit), so the earlier
    # answers appear to "disappear".
    #
    # NEVER auto-generate the shared admin credential — it is the one
    # password for every service, so the user must set it (no default; a bare
    # Enter is rejected). Validated against the strictest service floor
    # (validate_admin_password: >=12 chars, >=2 char types, no single quote).
    # Shown as typed (user preference) and printed in the final summary anyway.
    # In UI_DEMO/--demo the ui_* helpers return their demo defaults, so nothing
    # blocks (the DEMO=1 non-interactive installer uses _demo_stage1_noninteractive
    # and never calls this function).
    local choice email_default
    while true; do
        ui_section 1 10 "Admin identity"

        # Echo each captured value as a persistent line right after entry so the
        # details accumulate on screen as you go. The gum backend clears its input
        # widget after submit, so without these confirmation lines the earlier
        # answers vanish; these stay and double as the final review above the
        # accept prompt.
        _WIZ_ADMIN_USER=$(ui_input_validated \
            "Admin username" \
            "${_WIZ_ADMIN_USER:-${_WIZ_PREV_USER:-admin}}" \
            validate_admin_user)
        ui_kv "Username" "$_WIZ_ADMIN_USER"

        email_default="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-}}"
        if [[ -z "$email_default" || "${email_default,,}" =~ @(example\.com|example\.net|example\.org)$ ]]; then
            email_default=""
        fi
        _WIZ_ADMIN_EMAIL=$(ui_input_validated \
            "Admin email (for SSL certs and service login)" \
            "$email_default" \
            validate_admin_email)
        ui_kv "Email" "$_WIZ_ADMIN_EMAIL"

        ui_log info "Password rules: 12+ characters, mix at least 2 of lowercase / UPPERCASE / digits / symbols, no single quotes."
        _WIZ_ADMIN_PW=$(ui_input_validated \
            "Admin password" \
            "" \
            validate_admin_password \
            "DemoAdminPassword123")
        ui_kv "Password" "$_WIZ_ADMIN_PW"

        echo ""
        choice=$(ui_choose "Use these admin details?" "Use these details" "Re-enter")
        [[ "$choice" == "Use these details" ]] && break
    done
}
