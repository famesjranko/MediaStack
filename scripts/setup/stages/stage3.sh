# Owns: run_* — Stage 3 hardware-transcoding flow ordering (run_stage3, run_hardware_transcoding_addon).
# Sources: stage3/* concern modules, scripts/lib/render-device.sh, and setup globals.
# =============================================================================
# MediaStack Setup -- Hardware Transcoding controller
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

_STAGE3_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../../lib/render-device.sh
source "$_STAGE3_HELPER_DIR/../lib/render-device.sh"
unset _STAGE3_HELPER_DIR

if ! type ui_log >/dev/null 2>&1; then
    ui_log() { :; }
fi

_STAGE3_CONCERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stage3" && pwd)"
# shellcheck source=../stage3/copy.sh
source "$_STAGE3_CONCERNS_DIR/copy.sh"
# shellcheck source=../stage3/marker.sh
source "$_STAGE3_CONCERNS_DIR/marker.sh"
# shellcheck source=../stage3/state.sh
source "$_STAGE3_CONCERNS_DIR/state.sh"
# shellcheck source=../stage3/transcode.sh
source "$_STAGE3_CONCERNS_DIR/transcode.sh"
# shellcheck source=../stage3/jellyfin.sh
source "$_STAGE3_CONCERNS_DIR/jellyfin.sh"
# shellcheck source=../stage3/nvidia-finalize.sh
source "$_STAGE3_CONCERNS_DIR/nvidia-finalize.sh"
# shellcheck source=../stage3/nvidia-flow.sh
source "$_STAGE3_CONCERNS_DIR/nvidia-flow.sh"
unset _STAGE3_CONCERNS_DIR

run_stage3() {
    if [[ "${DEMO:-0}" == "1" ]]; then
        return 0
    fi

    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        local prior_gpu="${JELLYFIN_GPU:-none}"
        ui_log skip "Hardware transcoding skipped (no supported GPU detected)."
        if ! stage3_set_gpu_env "none" "skipped" "" ""; then
            ui_log warn "Could not persist skipped hardware-transcoding state; software fallback was not applied."
            return 1
        fi
        _stage3_skip_to_software_mode "$prior_gpu"
        _stage3_print_final_summary
        return 0
    fi

    ui_banner "MediaStack - Hardware Transcoding" "Use your GPU for Jellyfin video conversion"

    local action
    while true; do
        # When the caller already made an explicit "configure transcoding" choice
        # (day-2 launcher menu / ./setup.sh --transcoding), the offer prompt is a
        # redundant second gate — skip straight to the real driver selection.
        if [[ "${STAGE3_SKIP_OFFER:-false}" == "true" ]]; then
            break
        fi
        # _stage3_offer prints explanatory UI to stderr and only the selected
        # answer to stdout, so command substitution does not swallow the copy.
        action=$(_stage3_offer)
        case "$action" in
            *"Configure hardware transcoding")
                break
                ;;
            *"Skip for now")
                local prior_gpu="${JELLYFIN_GPU:-none}"
                if ! stage3_set_gpu_env "none" "skipped" "" ""; then
                    ui_log warn "Could not persist skipped hardware-transcoding state; software fallback was not applied."
                    return 1
                fi
                GPU_TYPE="none"
                ui_log skip "$(stage3_skip_summary_copy)"
                _stage3_skip_to_software_mode "$prior_gpu"
                _stage3_print_final_summary
                return 0
                ;;
            *"Tell me more")
                _stage3_tell_me_more
                ;;
        esac
    done

    _stage3_choose_gpu_vendor

    case "${GPU_TYPE:-none}" in
        intel)
            if ! install_intel_drivers; then
                GPU_TYPE="none"
                _stage3_fallback "intel" "qsv" || return $?
                return 0
            fi
            verify_gpu_usable || true
            if [[ "${GPU_TYPE:-none}" == "intel" ]]; then
                _stage3_configure_intel || return $?
            else
                _stage3_fallback "intel" "qsv" || return $?
            fi
            ;;
        amd)
            if ! install_amd_drivers; then
                GPU_TYPE="none"
                _stage3_fallback "amd" "vaapi" || return $?
                return 0
            fi
            verify_gpu_usable || true
            if [[ "${GPU_TYPE:-none}" == "amd" ]]; then
                local amd_rc=0
                _stage3_configure_and_verify "amd" "vaapi" "AMD VAAPI transcoding configured and verified." || amd_rc=$?
                ((amd_rc == 3)) && return 3
            else
                _stage3_fallback "amd" "vaapi" || return $?
            fi
            ;;
        nvidia)
            _stage3_run_nvidia || return $?
            ;;
    esac
    return 0
}

run_hardware_transcoding_addon() {
    local prev_defer="${STAGE3_DEFER_REBOOT_PROMPT+x}"
    local prev_defer_value="${STAGE3_DEFER_REBOOT_PROMPT:-}"
    local prev_summary="${STAGE3_SUPPRESS_FINAL_SUMMARY+x}"
    local prev_summary_value="${STAGE3_SUPPRESS_FINAL_SUMMARY:-}"
    local rc=0

    STAGE3_DEFER_REBOOT_PROMPT=true
    STAGE3_SUPPRESS_FINAL_SUMMARY=true
    run_stage3 || rc=$?

    if [[ -n "$prev_defer" ]]; then
        STAGE3_DEFER_REBOOT_PROMPT="$prev_defer_value"
    else
        unset STAGE3_DEFER_REBOOT_PROMPT
    fi
    if [[ -n "$prev_summary" ]]; then
        STAGE3_SUPPRESS_FINAL_SUMMARY="$prev_summary_value"
    else
        unset STAGE3_SUPPRESS_FINAL_SUMMARY
    fi

    return "$rc"
}
