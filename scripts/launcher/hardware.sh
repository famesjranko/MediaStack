#!/usr/bin/env bash
# Owns: Hardware-transcoding status, configuration, and NVIDIA maintenance menus.
# Sources: launcher globals, .env, scripts/lib/ui.sh, recovery.sh, gpu/stage3 helpers, and setup.sh.

# Warn when .env says GPU HW transcoding is complete but Jellyfin is actually
# running in software mode — catches silent runtime regressions (driver update,
# kernel upgrade, GPU hardware failure) after a successful initial setup.
# ponytail: per-session flag so the Jellyfin API call only fires once per launcher run
_warn_gpu_runtime_fallback() {
    [[ -z "${_GPU_WARN_DONE:-}" ]] || return 0
    _GPU_WARN_DONE=1
    [[ "${STAGE_3_GPU_STATE:-}" == "complete" && "${JELLYFIN_GPU:-none}" != "none" ]] || return 0
    [[ -n "${JELLYFIN_API_KEY:-}" ]] || return 0
    docker compose ps --filter status=running --format '{{.Name}}' 2>/dev/null | grep -q 'jellyfin' || return 0
    local resp
    resp=$(curl -sf --max-time 2 http://localhost:8096/System/Configuration/encoding \
        -H "Authorization: MediaBrowser Client=\"MediaStack\", Device=\"Launcher\", DeviceId=\"mediastack-launcher\", Version=\"1.0\", Token=\"${JELLYFIN_API_KEY}\"" \
        2>/dev/null) || return 0
    STAGE3_RESP="$resp" python3 -c '
import json, os, sys
try:
    c = json.loads(os.environ["STAGE3_RESP"])
except Exception:
    sys.exit(0)
sys.exit(1 if c.get("HardwareAccelerationType") == "none" else 0)
' && return 0
    ui_log warn "Hardware transcoding is configured but Jellyfin is using software mode. Select 'Manage hardware transcoding (GPU)' to diagnose."
}

action_transcode() { _run_setup_return 0 "Hardware transcoding" --transcoding; }

action_repatch() {
    _run_setup_return 0 "Reapply NVIDIA Unlock patch" --nvidia-unlock-repatch
}

action_update_nvidia_driver() {
    _run_setup_return 0 "Update NVIDIA Unlock driver" --nvidia-unlock-update
}

_hw_transcoding_info() {
    local gpu="${JELLYFIN_GPU:-none}" mode="${NVIDIA_DRIVER_MODE:-}"
    local state="${STAGE_3_GPU_STATE:-}" lines=()
    case "$gpu" in
        nvidia)
            local name drv
            name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
            drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
            lines+=("$(ui_kv 'GPU' "${name:-NVIDIA}")")
            lines+=("$(ui_kv 'Driver' "${drv:-unknown}${mode:+ (${mode} mode)}")")
            lines+=("$(ui_kv 'Encoder' 'NVENC')")
            if [[ "$mode" == "unlock" ]]; then
                if [[ -f "$SCRIPT_DIR/.nvidia-nvenc-unpatched" ]]; then
                    lines+=("$(ui_kv 'Session limit' 'stock (~3) - patch not applied')")
                else
                    lines+=("$(ui_kv 'Session limit' 'removed (patch applied)')")
                fi
            fi
            ;;
        intel) lines+=("$(ui_kv 'GPU' 'Intel')" "$(ui_kv 'Encoder' 'QSV')") ;;
        amd) lines+=("$(ui_kv 'GPU' 'AMD')" "$(ui_kv 'Encoder' 'VAAPI')") ;;
        *) lines+=("$(ui_kv 'GPU' 'none (software transcoding)')") ;;
    esac
    local state_label
    case "$state" in
        complete) state_label="active" ;;
        pending) state_label="pending reboot to finalize" ;;
        fallback) state_label="software fallback (GPU not active)" ;;
        skipped) state_label="skipped (software)" ;;
        *) state_label="${state:-not configured}" ;;
    esac
    lines+=("$(ui_kv 'State' "$state_label")")
    ui_box "MediaStack - Hardware Transcoding" "${lines[@]}"
}

submenu_manage_hardware() {
    while true; do
        clear
        _hw_transcoding_info

        local options=()
        if stage3_pending_nvidia_reboot_same_boot; then
            options+=("Reboot to finish hardware transcoding")
        fi
        options+=("Configure or change hardware transcoding")
        if [[ "${JELLYFIN_GPU:-none}" == "nvidia" && "${NVIDIA_DRIVER_MODE:-}" == "unlock" ]]; then
            options+=("Update NVIDIA driver + reapply Unlock patch")
            options+=("Reapply Unlock patch only")
        fi
        options+=("Back")

        local choice
        choice=$(ui_choose "Manage hardware transcoding:" "${options[@]}")
        case "$choice" in
            "Reboot to finish hardware transcoding"*) action_transcode ;;
            "Configure or change hardware transcoding"*) action_transcode ;;
            "Update NVIDIA driver"*) action_update_nvidia_driver ;;
            "Reapply Unlock patch"*) action_repatch ;;
            *) return 0 ;;
        esac
    done
}
