# Owns: Stage 3 static wizard copy: offer/tell-me-more/skip-summary/retry choice text and the guarded final-summary call.
# Sources: print_final_summary (stack.sh, when defined).

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

stage3_skip_summary_copy() {
    printf 'Hardware transcoding skipped. Jellyfin will use software transcoding. Choose Manage hardware transcoding (GPU) from the menu to try again.'
}

stage3_verify_retry_choices() {
    printf '%s\n' "Retry verification" "Use software transcoding" "Skip for now"
}
