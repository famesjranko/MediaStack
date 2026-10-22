# Owns: stage3_* — Stage 3 static wizard copy: offer/tell-me-more/skip-summary/retry choice text and the guarded final-summary call.
# Sources: print_final_summary (stack.sh, when defined); scripts/lib/gpu-fallback.sh for reason text.
# shellcheck source=/dev/null
declare -F gpu_fallback_reason_text >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/gpu-fallback.sh"

_stage3_print_final_summary() {
    if [[ "${STAGE3_SUPPRESS_FINAL_SUMMARY:-false}" == "true" ]]; then
        return 0
    fi
    if type print_final_summary >/dev/null 2>&1; then
        print_final_summary
    fi
}

stage3_offer_choices() {
    printf '%s\n' "Configure hardware transcoding" "Skip for now" "Tell me more"
}

stage3_tell_me_more_copy() {
    cat <<'COPY'
Intel and AMD GPUs can be configured now without reboot. NVIDIA may need one reboot before MediaStack can finish NVENC setup. Hardware transcoding is optional; skipping keeps Jellyfin on software transcoding and your media server stays usable.
COPY
}

# The closing line after a software fallback: setup did finish, on software
# transcoding, and says why. $1 is the fallback reason code.
stage3_fallback_copy() {
    local reason="${1:-}" text remedy
    text=$(gpu_fallback_reason_text "$reason") || text="hardware transcoding could not be verified"
    remedy=$(gpu_fallback_remedy "$reason")
    printf 'Hardware transcoding finished with software transcoding (%s). Jellyfin will use software transcoding.%s' \
        "$text" "${remedy:+ Next: ${remedy}.}"
}

stage3_skip_summary_copy() {
    printf 'Hardware transcoding skipped. Jellyfin will use software transcoding. Choose Manage hardware transcoding (GPU) from the menu to try again.'
}

stage3_verify_retry_choices() {
    printf '%s\n' "Retry verification" "Use software transcoding" "Skip for now"
}
