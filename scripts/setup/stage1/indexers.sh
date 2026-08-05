# Owns: stage1_* — Stage 1 example public-tracker indexer choice and review.
# Sources: wizard UI and Stage 1 wizard state.

# Search indexers: its own section (public trackers are a search feature, not a
# quality or subtitles setting). Enable-only — no config sub-layer.
_stage1_collect_indexers() {
    while true; do
        _stage1_collect_indexers_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use this indexer choice?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_indexers_once() {
    ui_section 6 10 "Search indexers"

    local indexer_default="no"
    if [[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-${_WIZ_PREV_PUBLIC_INDEXERS:-false}}" == "true" ]]; then
        indexer_default="yes"
    fi
    ui_box "Public tracker indexers (optional)" \
        "Adds example public trackers so Sonarr/Radarr can search" \
        "right away. Skip and add your own later from the menu." \
        "" \
        "Laws, site rules, and ISP policies vary - enable only" \
        "for content you are legally allowed to use."
    if ui_confirm "Enable the example public-tracker indexers?" "$indexer_default"; then
        _WIZ_PUBLIC_INDEXERS_ENABLED="true"
    else
        _WIZ_PUBLIC_INDEXERS_ENABLED="false"
        ui_log info "No indexers enabled - add your own later from Features & settings -> Search indexers."
    fi
    ui_kv "Public indexers" "$([[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)"
}
