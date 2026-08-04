# Owns: Stage 1 SMB enablement, retry, and share-scope collection.
# Sources: wizard UI, SMB port validator, and Stage 1 wizard state.

# File sharing (SMB): enable + share scope in one section.
_stage1_collect_smb() {
    while true; do
        _stage1_collect_smb_once
        echo ""
        local _confirm
        _confirm=$(ui_choose "Use these file-sharing choices?" "Use these details" "Re-enter")
        [[ "$_confirm" == "Use these details" ]] && break
    done
}

_stage1_collect_smb_once() {
    ui_section 4 10 "File sharing (SMB)"

    local smb_default="no"
    if [[ "${_WIZ_SMB_ENABLED:-${_WIZ_PREV_SMB:-false}}" == "true" ]]; then
        smb_default="yes"
    fi
    while true; do
        if ui_confirm "Enable SMB file share for LAN file access?" "$smb_default"; then
            while true; do
                if validate_smb_port 445; then
                    _WIZ_SMB_ENABLED="true"
                    local smb_scope_choice
                    smb_scope_choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Choose SMB share scope:" \
                        "Media files only (${_WIZ_DATA_DIR}) (recommended)" \
                        "Full system (/) - advanced admin access to the whole server.")
                    case "$smb_scope_choice" in
                        "Full system"*) _WIZ_SMB_SHARE_SCOPE="system" ;;
                        *) _WIZ_SMB_SHARE_SCOPE="data" ;;
                    esac
                    break 2
                fi

                local smb_action
                smb_action=$(ui_choose "SMB needs TCP port 445. What should setup do?" \
                    "Retry port check" \
                    "Disable SMB" \
                    "Quit installer")
                case "$smb_action" in
                    "Retry"*) continue ;;
                    "Quit"*)
                        log_info "Setup aborted - choose Install MediaStack from the menu to try again"
                        exit 0
                        ;;
                    *)
                        _WIZ_SMB_ENABLED="false"
                        _WIZ_SMB_SHARE_SCOPE="${_WIZ_SMB_SHARE_SCOPE:-${_WIZ_PREV_SMB_SHARE_SCOPE:-data}}"
                        break 2
                        ;;
                esac
            done
        else
            _WIZ_SMB_ENABLED="false"
            _WIZ_SMB_SHARE_SCOPE="${_WIZ_SMB_SHARE_SCOPE:-${_WIZ_PREV_SMB_SHARE_SCOPE:-data}}"
            break
        fi
    done
    if [[ "${_WIZ_SMB_ENABLED:-false}" == "true" ]]; then
        ui_kv "File share (SMB)" "on (${_WIZ_SMB_SHARE_SCOPE:-data})"
    else
        ui_kv "File share (SMB)" "off"
    fi
}
