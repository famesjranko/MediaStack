# Owns: stage1_* — Stage 1 library-quality preset collection and review.
# Sources: wizard UI, quality selector, and Stage 1 wizard state.

_stage1_collect_quality() {
    while true; do
        _stage1_collect_quality_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these library choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_quality_once() {
    ui_section 5 10 "Library quality"

    # Two orthogonal axes (resolution → size), menus built dynamically from
    # scripts/setup/presets.yml. Shared with the day-2 launcher so the two can't
    # drift. Defaults to 1080p Balanced (the recommended cell). If the menu can't
    # be read, keep any prior selection or fall back to 1080p/balanced rather
    # than aborting the wizard.
    if ! quality_select_pick _WIZ_QUALITY_RESOLUTION _WIZ_QUALITY_SIZE \
        "${_WIZ_QUALITY_RESOLUTION:-1080p}" "${_WIZ_QUALITY_SIZE:-balanced}"; then
        _WIZ_QUALITY_RESOLUTION="${_WIZ_QUALITY_RESOLUTION:-1080p}"
        _WIZ_QUALITY_SIZE="${_WIZ_QUALITY_SIZE:-balanced}"
    fi
    ui_kv "Quality" "${_WIZ_QUALITY_RESOLUTION:-1080p} ${_WIZ_QUALITY_SIZE:-balanced}"
}
