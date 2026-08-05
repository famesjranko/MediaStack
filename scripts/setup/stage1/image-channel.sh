# Owns: stage1_* — Stage 1 install-time image-channel choice.
# Sources: wizard UI and Stage 1 wizard state.

_stage1_collect_image_channel() {
    ui_section 7 10 "Image channel (install-time)"

    ui_log info "This picks which image versions MediaStack installs with - an"
    ui_log info "install-time choice, not an auto-updater. Nothing updates on its own."
    ui_log info "Either way, after install you can check for and apply updates any"
    ui_log info "time by re-running ./mediastack -> Manage updates."

    local current_channel default_index channel_choice
    current_channel="${_WIZ_IMAGE_CHANNEL:-${_WIZ_PREV_IMAGE_CHANNEL:-stable}}"
    current_channel="${current_channel,,}"
    case "$current_channel" in
        latest) default_index=2 ;;
        *)
            default_index=1
            current_channel="stable"
            ;;
    esac

    channel_choice=$(UI_CHOOSE_DEFAULT_INDEX=$default_index ui_choose "Which image versions should MediaStack install?" \
        "Stable - the versions this MediaStack release was tested against (recommended)." \
        "Latest - newest upstream tags, straight from the registries. YOLO (advanced).")
    case "$channel_choice" in
        Latest*) _WIZ_IMAGE_CHANNEL="latest" ;;
        *) _WIZ_IMAGE_CHANNEL="stable" ;;
    esac
    ui_kv "Image channel" "$_WIZ_IMAGE_CHANNEL"
}
