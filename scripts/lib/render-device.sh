# =============================================================================
# MediaStack Setup — shared render-device helpers
# =============================================================================
# Sourced by setup modules. Function definitions only: callers retain ownership
# of source-time state and the public helper names. `_render_device_for_vendor`
# returns 1 for no render node and 2 for readable, vendor-mismatched metadata;
# setup's public wrapper preserves its historical single failure status, while
# Stage 3 keeps its historical fallback-only-for-no-node behavior.

_render_device_vendor_id() {
    case "${1:-}" in
        intel) printf '0x8086\n' ;;
        amd) printf '0x1002\n' ;;
    esac
}

_render_device_for_vendor() {
    local vendor="${1:-}"
    local vendor_id
    vendor_id="$(_render_device_vendor_id "$vendor")"

    local render node sys_vendor found="" saw_vendor_file=false
    for render in /dev/dri/renderD*; do
        [[ -e "$render" ]] || continue
        node="${render##*/}"
        sys_vendor="/sys/class/drm/${node}/device/vendor"
        if [[ -r "$sys_vendor" ]]; then
            saw_vendor_file=true
            if [[ -n "$vendor_id" ]] && grep -qi "^${vendor_id}$" "$sys_vendor"; then
                printf '%s\n' "$render"
                return 0
            fi
        fi
        [[ -z "$found" ]] && found="$render"
    done

    if [[ -n "$vendor_id" && "$saw_vendor_file" == "true" ]]; then
        return 2
    fi
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

_render_device_exists() {
    [[ -e "${1:-}" ]]
}

_render_device_vendor_matches() {
    local render_device="${1:-}"
    local vendor="${2:-}"
    local vendor_id
    vendor_id="$(_render_device_vendor_id "$vendor")"

    [[ -n "$vendor_id" ]] || return 0

    local node sys_vendor
    node="${render_device##*/}"
    sys_vendor="/sys/class/drm/${node}/device/vendor"
    [[ -r "$sys_vendor" ]] || return 0
    grep -qi "^${vendor_id}$" "$sys_vendor"
}

_render_device_persisted() {
    local vendor="${1:-}"
    local exists_fn="${2:-}"
    local vendor_matches_fn="${3:-}"
    local render_device="${STAGE_3_GPU_RENDER_DEVICE:-}"
    [[ "$render_device" =~ ^/dev/dri/renderD[0-9]+$ ]] || return 1
    "$exists_fn" "$render_device" || return 1
    "$vendor_matches_fn" "$render_device" "$vendor" || return 1
    printf '%s\n' "$render_device"
}
