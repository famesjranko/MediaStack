# Owns: detect_* gpu_* — GPU hardware detection, vendor selection, and render-device helpers.
# Sources: common.sh and lib/render-device.sh, already sourced by gpu.sh.
detect_gpu() {
    GPU_TYPE="none"
    GPU_CANDIDATES=()

    if ! command -v lspci &>/dev/null; then
        log_warn "lspci not found (install pciutils) - cannot detect GPU"
        return
    fi

    local gpu_lines vendor
    gpu_lines=$(lspci 2>/dev/null | grep -Ei '(VGA compatible controller|3D controller|Display controller):' || true)

    for vendor in nvidia amd intel; do
        case "$vendor" in
            nvidia) grep -qi 'nvidia' <<<"$gpu_lines" && GPU_CANDIDATES+=(nvidia) ;;
            amd) grep -qEi 'amd|radeon' <<<"$gpu_lines" && GPU_CANDIDATES+=(amd) ;;
            intel) grep -qi 'intel' <<<"$gpu_lines" && GPU_CANDIDATES+=(intel) ;;
        esac
    done

    if ((${#GPU_CANDIDATES[@]} == 0)); then
        log_info "No dedicated GPU detected - Jellyfin will use software transcoding"
        return
    fi

    GPU_TYPE="${GPU_CANDIDATES[0]}"
    if gpu_candidate_available "${JELLYFIN_GPU:-none}"; then
        GPU_TYPE="$JELLYFIN_GPU"
    fi

    if ((${#GPU_CANDIDATES[@]} == 1)); then
        log_ok "$(gpu_brand_label "$GPU_TYPE") GPU detected"
    else
        log_ok "Supported GPUs detected: ${GPU_CANDIDATES[*]}"
    fi
}

gpu_candidate_available() {
    local wanted="${1:-}" candidate
    for candidate in "${GPU_CANDIDATES[@]:-}"; do
        [[ "$candidate" == "$wanted" ]] && return 0
    done
    return 1
}

gpu_brand_label() {
    case "${1:-}" in
        nvidia) printf 'NVIDIA' ;;
        amd) printf 'AMD' ;;
        intel) printf 'Intel' ;;
        none | "") printf 'none' ;;
        *) printf '%s' "$1" ;;
    esac
}

gpu_render_device_for_vendor() {
    if _render_device_for_vendor "$@"; then
        return 0
    fi
    return 1
}

gpu_render_device_exists() {
    _render_device_exists "$@"
}

gpu_render_device_vendor_matches() {
    _render_device_vendor_matches "$@"
}

gpu_persisted_render_device() {
    _render_device_persisted "${1:-}" gpu_render_device_exists gpu_render_device_vendor_matches
}

# Detect Secure Boot state via mokutil. Secure Boot refuses to load unsigned
# kernel modules, so if enabled we'd install a driver that never loads.
# Echoes one of: enabled, disabled, unavailable.
