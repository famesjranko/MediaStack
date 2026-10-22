# Owns: stage2_* — Stage 2 safe HTTPS-skip persistence path.
# Sources: Stage 2 defaults, env generation, and marker helpers.

_stage2_skip_https() {
    # The seed blanks placeholder addresses so the wizard re-prompts for them. A
    # skip prompts for nothing, so it must write back what .env already holds.
    local kept_email="${_WIZ_ADMIN_EMAIL:-${_WIZ_PREV_EMAIL:-${NPM_ADMIN_EMAIL:-}}}"
    _stage2_seed_wizard_defaults
    _WIZ_ADMIN_EMAIL="$kept_email"
    _WIZ_REMOTE_WEB_STATE="skipped"
    write_env || return 1
    stage2_preserve_stage1_marker
    ui_log skip "$(stage2_skip_summary_copy)"
}
