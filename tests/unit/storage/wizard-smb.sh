# Owns: Stage 1 wizard NAS export-path prompt defaults and the SMB
# collection section (_stage1_collect_nas_settings, _stage1_collect_smb).
# Sourced by tests/unit/storage.sh; inherits its preamble.

ui_log() {
    printf '%s %s\n' "${1:-}" "${*:2}" >>"$NAS_EXPORT_INFO_LOG"
}
# The export-path explanation moved from a ui_log line into the intro ui_box.
ui_box() { printf '%s\n' "$@" >>"$NAS_EXPORT_INFO_LOG"; }
ui_input_validated() {
    case "${1:-}" in
        "Local mountpoint for NAS storage") printf '%s\n' "$TMP_DIR/nas-export-default" ;;
        "NAS host/IP (e.g. 192.168.1.50 or nas.local)") printf '%s\n' "192.0.2.10" ;;
        "NFS export path (the remote path your NAS exports, e.g. /exports/mediastack)")
            printf '%s:%s\n' "$NAS_EXPORT_DEFAULT_LABEL" "${2:-}" >>"$NAS_EXPORT_DEFAULT_LOG"
            printf '%s\n' "/exports/entered"
            ;;
        "NFS mount options") printf '%s\n' "${2:-vers=4.2}" ;;
        "NAS sentinel file") printf '%s\n' "${2:-$TMP_DIR/nas-export-default/.mediastack-storage-ready}" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
NAS_EXPORT_INFO_LOG="$TMP_DIR/nas-export-info.log"
NAS_EXPORT_DEFAULT_LOG="$TMP_DIR/nas-export-defaults.log"
NAS_EXPORT_DEFAULT_LABEL="first"
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT _WIZ_PREV_STORAGE_NFS_EXPORT
_WIZ_DATA_DIR=""
_stage1_collect_nas_settings
assert_eq "first:" "$(sed -n '1p' "$NAS_EXPORT_DEFAULT_LOG")" "wizard NAS export prompt: first run has blank default"
assert_contains "$(cat "$NAS_EXPORT_INFO_LOG")" "the shared folder on the NAS (its NFS export path)" "wizard NAS export prompt: explains export path"

NAS_EXPORT_DEFAULT_LABEL="previous"
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT
_WIZ_PREV_STORAGE_NFS_EXPORT="/exports/previous"
_WIZ_DATA_DIR=""
_stage1_collect_nas_settings
assert_eq "previous:/exports/previous" "$(sed -n '2p' "$NAS_EXPORT_DEFAULT_LOG")" "wizard NAS export prompt: previous export is reused as default"
unset -f ui_log ui_input_validated
unset NAS_EXPORT_INFO_LOG NAS_EXPORT_DEFAULT_LOG NAS_EXPORT_DEFAULT_LABEL
unset _WIZ_STORAGE_MOUNTPOINT _WIZ_STORAGE_NFS_EXPORT _WIZ_PREV_STORAGE_MOUNTPOINT _WIZ_PREV_STORAGE_NFS_EXPORT

ui_section() { :; }
ui_log() { :; }
ui_input_validated() {
    case "${1:-}" in
        "Data directory") printf '%s\n' "$TMP_DIR/smb-data" ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
# SMB collection is its own Stage-1 section (_stage1_collect_smb) since the
# d96bcc1 split — Bazarr/subtitles moved out, so match the SMB enable prompt by
# text rather than by call order.
ui_confirm() {
    case "${1:-}" in
        "Enable SMB"*) return 0 ;; # enable SMB
        *) return 1 ;;
    esac
}
ui_choose() {
    case "${1:-}" in
        "SMB needs TCP port 445"*) printf '%s\n' "Retry port check" ;;
        "Choose SMB share scope:"*) printf '%s\n' "Full system (/) - advanced admin access to the whole server." ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}
validate_smb_port() {
    SMB_PORT_CHECKS=$((SMB_PORT_CHECKS + 1))
    [[ "$SMB_PORT_CHECKS" -ge 2 ]]
}
SMB_PORT_CHECKS=0
_WIZ_DATA_DIR=""
_WIZ_STORAGE_MODE=""
_WIZ_SMB_ENABLED=""
_WIZ_SMB_SHARE_SCOPE=""
_stage1_collect_smb >/dev/null 2>&1
assert_eq "2" "$SMB_PORT_CHECKS" "wizard SMB conflict: retry port check reruns validator"
assert_eq "true" "$_WIZ_SMB_ENABLED" "wizard SMB conflict: successful retry enables SMB"
assert_eq "system" "$_WIZ_SMB_SHARE_SCOPE" "wizard SMB conflict: successful retry continues to scope choice"
unset -f ui_section ui_log ui_input_validated ui_confirm ui_choose validate_smb_port
unset SMB_PORT_CHECKS
