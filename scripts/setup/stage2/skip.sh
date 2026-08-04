# Owns: Stage 2 safe HTTPS-skip persistence path.
# Sources: Stage 2 defaults, env generation, and marker helpers.

_stage2_skip_https() {
    _stage2_seed_wizard_defaults
    _WIZ_REMOTE_WEB_STATE="skipped"
    write_env || return 1
    _stage2_preserve_stage1_marker
    ui_log skip "$(stage2_skip_summary_copy)"
}
