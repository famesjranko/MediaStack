# Owns: stage3_* — GPU .env state writers: stage3_set_gpu_env and stage3_set_state.
# Sources: Only bash builtins; writes $SCRIPT_DIR/.env.

stage3_set_gpu_env() {
    local gpu="$1"
    local state="${2:-}"
    local vendor="${3:-}"
    local encoder="${4:-}"
    # Optional NVIDIA driver-management mode (standard|unlock|existing). When
    # empty the existing .env value is preserved (not clobbered) — most callers
    # don't touch it; only the NVIDIA install flows pass it explicitly.
    local driver_mode="${5:-}"
    local env_path="$SCRIPT_DIR/.env"

    case "$gpu" in
        none | intel | amd | nvidia) ;;
        *) return 1 ;;
    esac
    case "$state" in
        "" | complete | skipped | fallback | pending) ;;
        *) return 1 ;;
    esac

    [[ -f "$env_path" ]] || return 1

    # GPU-state map. When gpu=none every capability field is blanked; otherwise
    # each falls back to the current env value (booleans default false). The
    # render device is empty for none and nvidia (nvidia exposes the GPU via the
    # runtime, not a /dev/dri node).
    local -a _kv=(
        JELLYFIN_GPU "$gpu"
        STAGE_3_GPU_STATE "$state"
        STAGE_3_GPU_VENDOR "$vendor"
        STAGE_3_GPU_ENCODER "$encoder"
    )
    if [[ "$gpu" == "none" ]]; then
        _kv+=(
            STAGE_3_GPU_HW_DECODING_CODECS ""
            STAGE_3_GPU_DECODE_HEVC_10BIT ""
            STAGE_3_GPU_DECODE_VP9_10BIT ""
            STAGE_3_GPU_ALLOW_HEVC_ENCODING ""
            STAGE_3_GPU_ALLOW_AV1_ENCODING ""
            STAGE_3_GPU_RENDER_DEVICE ""
        )
    else
        _kv+=(
            STAGE_3_GPU_HW_DECODING_CODECS "${STAGE_3_GPU_HW_DECODING_CODECS:-}"
            STAGE_3_GPU_DECODE_HEVC_10BIT "${STAGE_3_GPU_DECODE_HEVC_10BIT:-false}"
            STAGE_3_GPU_DECODE_VP9_10BIT "${STAGE_3_GPU_DECODE_VP9_10BIT:-false}"
            STAGE_3_GPU_ALLOW_HEVC_ENCODING "${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-false}"
            STAGE_3_GPU_ALLOW_AV1_ENCODING "${STAGE_3_GPU_ALLOW_AV1_ENCODING:-false}"
        )
        if [[ "$gpu" == "nvidia" ]]; then
            _kv+=(STAGE_3_GPU_RENDER_DEVICE "")
        else
            _kv+=(STAGE_3_GPU_RENDER_DEVICE "${STAGE_3_GPU_RENDER_DEVICE:-}")
        fi
    fi
    # Only rewrite NVIDIA_DRIVER_MODE when a mode was passed; otherwise leave the
    # existing line untouched so unrelated callers don't clobber it.
    if [[ -n "$driver_mode" ]]; then
        _kv+=(NVIDIA_DRIVER_MODE "$driver_mode")
    fi
    # One blessed .env writer (common.sh) — atomic, mode-preserving, quoted.
    local writer_status
    if ! writer_status=$(_env_write_kv "$env_path" "${_kv[@]}"); then
        _env_write_kv_warn JELLYFIN_GPU "$writer_status"
        return 1
    fi

    export JELLYFIN_GPU="$gpu"
    export STAGE_3_GPU_STATE="$state"
    export STAGE_3_GPU_VENDOR="$vendor"
    export STAGE_3_GPU_ENCODER="$encoder"
    if [[ "$gpu" == "none" ]]; then
        export STAGE_3_GPU_HW_DECODING_CODECS=""
        export STAGE_3_GPU_DECODE_HEVC_10BIT=""
        export STAGE_3_GPU_DECODE_VP9_10BIT=""
        export STAGE_3_GPU_ALLOW_HEVC_ENCODING=""
        export STAGE_3_GPU_ALLOW_AV1_ENCODING=""
        export STAGE_3_GPU_RENDER_DEVICE=""
    elif [[ "$gpu" == "nvidia" ]]; then
        export STAGE_3_GPU_RENDER_DEVICE=""
    elif [[ "$gpu" != "nvidia" ]]; then
        export STAGE_3_GPU_RENDER_DEVICE="${STAGE_3_GPU_RENDER_DEVICE:-}"
    fi
    if [[ -n "$driver_mode" ]]; then
        export NVIDIA_DRIVER_MODE="$driver_mode"
    fi
}

stage3_set_state() {
    local state="$1"
    local vendor="${2:-}"
    local encoder="${3:-}"
    stage3_set_gpu_env "none" "$state" "$vendor" "$encoder"
}
