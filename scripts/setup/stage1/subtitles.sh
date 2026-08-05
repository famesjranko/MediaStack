# Owns: stage1_* — Stage 1 Bazarr enablement and subtitle-language collection.
# Sources: wizard UI, validator, and Stage 1 wizard state.

_stage1_collect_subtitles() {
    while true; do
        _stage1_collect_subtitles_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these subtitle choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_subtitles_once() {
    ui_section 3 10 "Subtitles (Bazarr)"

    local bazarr_default="no"
    if [[ "${_WIZ_BAZARR_ENABLED:-${_WIZ_PREV_BAZARR:-false}}" == "true" ]]; then
        bazarr_default="yes"
    fi
    # Surface RAM constraint BEFORE the prompt so the warning informs the
    # decision rather than appearing after the user has already said yes.
    local free_ram_gb
    free_ram_gb=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null)
    if [[ -n "$free_ram_gb" && "$free_ram_gb" -lt 4 ]]; then
        ui_log warn "Only ${free_ram_gb}GB RAM free - Bazarr may struggle (it expects ~4GB)."
    fi
    if ui_confirm "Enable automatic subtitle downloads with Bazarr?" "$bazarr_default"; then
        _WIZ_BAZARR_ENABLED="true"
    else
        _WIZ_BAZARR_ENABLED="false"
    fi
    ui_kv "Subtitles (Bazarr)" "$([[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)"

    # Only ask for subtitle languages when Bazarr is enabled: the value
    # feeds render_bazarr alone, so prompting after the user declined Bazarr asks
    # for something inert and contradicts the choice just made. When Bazarr is
    # off, keep a stored default so a later `./setup.sh` that enables Bazarr still
    # has a sensible language list.
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        _WIZ_SUBTITLE_LANGS=$(ui_input_validated \
            "Subtitle languages (comma-separated, e.g. english,spanish,french)" \
            "${_WIZ_SUBTITLE_LANGS:-${SUBTITLE_LANGUAGES:-english}}" \
            validate_subtitle_langs)
    else
        _WIZ_SUBTITLE_LANGS="${_WIZ_SUBTITLE_LANGS:-${SUBTITLE_LANGUAGES:-english}}"
    fi
    # ui_input_validated echoes the raw input (the validator only returns 0/1),
    # so lowercase the accepted value here: Bazarr's LANG_MAP lookup is
    # case-sensitive over lowercase keys, and the value reaches config.yml
    # verbatim. ${,,} folds casing only (commas/spaces untouched; wizard_apply.py
    # strips per-token whitespace) — not validity, but the DEMO/non-TTY
    # short-circuit returns the literal 'english' default, so nothing invalid
    # can slip through unvalidated.
    _WIZ_SUBTITLE_LANGS="${_WIZ_SUBTITLE_LANGS,,}"
    # Use an if (not `[[ ]] && ui_kv`): this is the function's last statement, so a
    # false trailing test would make the function return 1 and abort the wizard
    # under `set -e` whenever Bazarr is disabled (the default).
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        ui_kv "Subtitle langs" "${_WIZ_SUBTITLE_LANGS:-english}"
    fi
}
