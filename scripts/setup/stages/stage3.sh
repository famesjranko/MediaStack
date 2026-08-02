# =============================================================================
# MediaStack Setup -- Hardware Transcoding controller
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

if ! type ui_log >/dev/null 2>&1; then
    ui_log() { :; }
fi

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

_stage3_marker_path() {
    printf '%s/.nvidia-finalize-pending' "$SCRIPT_DIR"
}

stage3_current_boot_id() {
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        cat /proc/sys/kernel/random/boot_id
    else
        printf 'unknown\n'
    fi
}

stage3_marker_exists() {
    [[ -f "$(_stage3_marker_path)" ]]
}

stage3_write_nvidia_marker() {
    # Records the driver-management mode + install source so post-reboot
    # finalization runs the right resume path and applies the patch only for
    # unlock. install_source is "apt" (Standard) or "run" (Unlock .run cache).
    local driver_mode="${1:-unlock}"
    local install_source="${2:-run}"
    local expected_driver_version="${3:-}"
    local marker tmp
    marker="$(_stage3_marker_path)"
    tmp="${marker}.tmp"
    MARKER_PATH="$tmp" MARKER_BOOT_ID="$(stage3_current_boot_id)" \
    MARKER_DRIVER_MODE="$driver_mode" MARKER_INSTALL_SOURCE="$install_source" \
    MARKER_EXPECTED_DRIVER_VERSION="$expected_driver_version" python3 - <<'PY'
import datetime
import json
import os
import pathlib

path = pathlib.Path(os.environ["MARKER_PATH"])
payload = {
    "schema": 3,
    "gpu_type": "nvidia",
    "nvidia_driver_mode": os.environ.get("MARKER_DRIVER_MODE", "unlock"),
    "install_source": os.environ.get("MARKER_INSTALL_SOURCE", "run"),
    "encoder": "nvenc",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "created_boot_id": os.environ.get("MARKER_BOOT_ID", "unknown"),
    "pending": [
        "driver_verify",
        "docker_runtime_verify",
        "encoder_config",
        "test_transcode",
        "summary",
    ],
}
expected = os.environ.get("MARKER_EXPECTED_DRIVER_VERSION", "")
if expected:
    payload["expected_driver_version"] = expected
path.write_text(json.dumps(payload, indent=2) + "\n")
PY
    chmod 600 "$tmp"
    mv "$tmp" "$marker"
}

stage3_remove_nvidia_marker() {
    rm -f "$(_stage3_marker_path)"
}

# Discard a prepared-but-not-finalized NVIDIA driver setup (one that is waiting
# for a reboot) so the user can pick a different driver mode instead of being
# locked into finishing the pending install. Clears the finalize marker and any
# cached .run, and removes the installed .run driver (if present) so a fresh
# Standard/Unlock choice starts from a clean slate. The GPU hardware is still
# detected afterwards, so run_stage3 re-offers the mode menu.
_stage3_discard_pending_setup() {
    ui_log info "Discarding the prepared NVIDIA driver setup..."
    stage3_remove_nvidia_marker
    rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || true
    if command -v nvidia-uninstall >/dev/null 2>&1; then
        ui_spin "Removing the prepared NVIDIA .run driver..." sudo nvidia-uninstall -s || true
        # Clear bash's cached nvidia-smi path so re-detection sees it is gone.
        hash -r
    fi
    NEEDS_REBOOT=false
}

stage3_marker_boot_id() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("created_boot_id", ""))
except Exception:
    print("")
PY
}

# Echo the driver-management mode recorded in the finalize marker (standard|
# unlock|existing). Empty if the marker is absent/unreadable (older schema 1
# markers had no mode field — finalization treats that as "unlock").
stage3_marker_driver_mode() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("nvidia_driver_mode", ""))
except Exception:
    print("")
PY
}

stage3_marker_expected_driver_version() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("expected_driver_version", ""))
except Exception:
    print("")
PY
}

stage3_marker_install_source() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("install_source", ""))
except Exception:
    print("")
PY
}

stage3_marker_ready_to_finalize() {
    stage3_marker_exists || return 1

    local marker_boot current_boot
    marker_boot="$(stage3_marker_boot_id)"
    current_boot="$(stage3_current_boot_id)"
    [[ -n "$marker_boot" && -n "$current_boot" ]] || return 1
    [[ "$marker_boot" != "$current_boot" ]]
}

stage3_pending_nvidia_reboot_same_boot() {
    stage3_marker_exists || return 1
    ! stage3_marker_ready_to_finalize
}

stage3_reboot_prompt_needed() {
    [[ "${NEEDS_REBOOT:-false}" == "true" ]] && stage3_marker_exists
}

stage3_prompt_pending_nvidia_reboot() {
    stage3_pending_nvidia_reboot_same_boot || return 0
    NEEDS_REBOOT=true
    stage3_prompt_nvidia_reboot
}

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
    _env_write_kv "$env_path" "${_kv[@]}" >/dev/null

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

stage3_transcode_log_uses_gpu() {
    local encoder="$1"
    local log_path="$2"
    [[ -f "$log_path" ]] || return 1

    case "$encoder" in
        qsv | vaapi | nvenc) ;;
        *) return 1 ;;
    esac

    local log_lower
    log_lower=$(tr '[:upper:]' '[:lower:]' <"$log_path")
    # Negative evidence: HW init failure or actual software-encoder ffmpeg use.
    # `\[libx26[45] @` matches ffmpeg's runtime tag like `[libx264 @ 0x55a...]`,
    # which only appears when the software encoder is actually invoked. Plain
    # `libx264|libx265` would also match Jellyfin's available-encoders startup
    # log (`Available encoders: [..., "libx264", "libx265", ...]`) and produce
    # a false fallback verdict on a fresh install where no transcode has run.
    if grep -Eq 'no device available|device creation failed|failed to initialise|failed to initialize|hardware device setup failed|\[libx26[45] @' <<<"$log_lower"; then
        return 1
    fi

    case "$encoder" in
        qsv) grep -Eq -- '->[^\n]*(h264_qsv|hevc_qsv|av1_qsv|vp9_qsv)' <<<"$log_lower" ;;
        vaapi) grep -Eq -- '->[^\n]*(h264_vaapi|hevc_vaapi|av1_vaapi|vp9_vaapi)' <<<"$log_lower" ;;
        nvenc) grep -Eq -- '->[^\n]*(h264_nvenc|hevc_nvenc|av1_nvenc)' <<<"$log_lower" ;;
    esac
}

stage3_capture_jellyfin_transcode_log() {
    local source_ref="$1"
    local output_log="$2"

    if [[ -f "$source_ref" ]]; then
        cp "$source_ref" "$output_log"
        return 0
    fi

    if command -v docker >/dev/null 2>&1; then
        local logs_args=(compose logs --no-color)
        if [[ -n "${STAGE3_TRANSCODE_SINCE:-}" ]]; then
            logs_args+=(--since "$STAGE3_TRANSCODE_SINCE")
        fi
        logs_args+=(jellyfin)
        docker "${logs_args[@]}" 2>/dev/null | grep -Ei 'ffmpeg|transcod|qsv|vaapi|nvenc|cuda' >"$output_log" || true
        [[ -s "$output_log" ]] && return 0
    fi

    return 1
}

stage3_resolve_render_device() {
    local vendor="${1:-}"
    if type gpu_persisted_render_device >/dev/null 2>&1; then
        gpu_persisted_render_device "$vendor" && return 0
    elif stage3_persisted_render_device "$vendor"; then
        return 0
    fi

    if type gpu_render_device_for_vendor >/dev/null 2>&1; then
        gpu_render_device_for_vendor "$vendor" && return 0
    fi

    local vendor_id=""
    case "$vendor" in
        intel) vendor_id="0x8086" ;;
        amd) vendor_id="0x1002" ;;
    esac

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

    if [[ -n "$found" ]]; then
        if [[ -n "$vendor_id" && "$saw_vendor_file" == "true" ]]; then
            return 1
        fi
        printf '%s\n' "$found"
    else
        printf '%s\n' "/dev/dri/renderD128"
    fi
}

stage3_render_device_exists() {
    [[ -e "${1:-}" ]]
}

stage3_render_device_vendor_matches() {
    local render_device="${1:-}"
    local vendor="${2:-}"
    local vendor_id=""
    case "$vendor" in
        intel) vendor_id="0x8086" ;;
        amd) vendor_id="0x1002" ;;
    esac

    [[ -n "$vendor_id" ]] || return 0

    local node sys_vendor
    node="${render_device##*/}"
    sys_vendor="/sys/class/drm/${node}/device/vendor"
    [[ -r "$sys_vendor" ]] || return 0
    grep -qi "^${vendor_id}$" "$sys_vendor"
}

stage3_persisted_render_device() {
    local vendor="${1:-}"
    local render_device="${STAGE_3_GPU_RENDER_DEVICE:-}"
    [[ "$render_device" =~ ^/dev/dri/renderD[0-9]+$ ]] || return 1
    stage3_render_device_exists "$render_device" || return 1
    stage3_render_device_vendor_matches "$render_device" "$vendor" || return 1
    printf '%s\n' "$render_device"
}

stage3_run_encoder_smoke_test() {
    local vendor="$1"
    local encoder="$2"
    local smoke_log="$3"
    local codec="${4:-h264}"

    command -v docker >/dev/null 2>&1 || return 1

    local ffmpeg_path="/usr/lib/jellyfin-ffmpeg/ffmpeg"
    local cmd=(
        exec jellyfin "$ffmpeg_path"
        -hide_banner
        -f lavfi
        -i testsrc2=size=640x360:rate=30
        -t 1
    )

    local encoder_name
    case "$encoder:$codec" in
        nvenc:h264) encoder_name="h264_nvenc" ;;
        nvenc:hevc) encoder_name="hevc_nvenc" ;;
        nvenc:av1) encoder_name="av1_nvenc" ;;
        qsv:h264) encoder_name="h264_qsv" ;;
        qsv:hevc) encoder_name="hevc_qsv" ;;
        qsv:av1) encoder_name="av1_qsv" ;;
        vaapi:h264) encoder_name="h264_vaapi" ;;
        vaapi:hevc) encoder_name="hevc_vaapi" ;;
        vaapi:av1) encoder_name="av1_vaapi" ;;
        *) return 1 ;;
    esac

    local render_device=""
    case "$encoder" in
        nvenc)
            cmd+=(-c:v "$encoder_name")
            ;;
        vaapi)
            render_device="$(stage3_resolve_render_device "$vendor")" || return 1
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            cmd+=(
                -vaapi_device "$render_device"
                -vf "format=nv12,hwupload"
                -c:v "$encoder_name"
            )
            ;;
        qsv)
            render_device="$(stage3_resolve_render_device "$vendor")" || return 1
            export STAGE_3_GPU_RENDER_DEVICE="$render_device"
            cmd+=(
                -init_hw_device "qsv=hw:${render_device}"
                -filter_hw_device hw
                -vf "format=nv12,hwupload=extra_hw_frames=64"
                -c:v "$encoder_name"
            )
            ;;
        *)
            return 1
            ;;
    esac

    cmd+=(-f null -)

    if docker "${cmd[@]}" >"$smoke_log" 2>&1 \
        && grep -Eqi -- "->[^\n]*${encoder_name}" "$smoke_log" \
        && stage3_transcode_log_uses_gpu "$encoder" "$smoke_log"; then
        return 0
    fi

    return 1
}

stage3_vainfo_to_capabilities() {
    local vainfo_log="$1"
    [[ -f "$vainfo_log" ]] || return 1

    python3 - "$vainfo_log" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
profiles = set()
hevc10 = False
vp910 = False
for raw in text.splitlines():
    if "VAEntrypointVLD" not in raw:
        continue
    if "VAProfileH264" in raw:
        profiles.add("h264")
    if "VAProfileMPEG2" in raw:
        profiles.add("mpeg2video")
    if "VAProfileVC1" in raw:
        profiles.add("vc1")
    if "VAProfileVP8" in raw:
        profiles.add("vp8")
    if "VAProfileHEVCMain10" in raw:
        profiles.add("hevc")
        hevc10 = True
    elif "VAProfileHEVCMain" in raw:
        profiles.add("hevc")
    if "VAProfileVP9Profile2" in raw:
        profiles.add("vp9")
        vp910 = True
    elif "VAProfileVP9Profile" in raw:
        profiles.add("vp9")
    if "VAProfileAV1Profile" in raw:
        profiles.add("av1")

order = ["h264", "hevc", "mpeg2video", "vc1", "vp8", "vp9", "av1"]
print(",".join(codec for codec in order if codec in profiles))
print("true" if hevc10 else "false")
print("true" if vp910 else "false")
PY
}

stage3_capture_vainfo() {
    local output_log="$1"
    command -v docker >/dev/null 2>&1 || return 1
    local render_device
    render_device="$(stage3_resolve_render_device "${STAGE_3_GPU_VENDOR:-${GPU_TYPE:-}}")" || return 1
    export STAGE_3_GPU_RENDER_DEVICE="$render_device"

    docker exec jellyfin /usr/lib/jellyfin-ffmpeg/vainfo --display drm --device "$render_device" >"$output_log" 2>&1 \
        || docker exec jellyfin vainfo --display drm --device "$render_device" >"$output_log" 2>&1
}

stage3_run_nvidia_decode_smoke_test() {
    local codec="$1"
    local smoke_log="$2"
    command -v docker >/dev/null 2>&1 || return 1

    local source_encoder decoder ext extra_source_opts=""
    case "$codec" in
        h264)
            source_encoder="libx264"
            decoder="h264_cuvid"
            ext="mkv"
            ;;
        hevc)
            source_encoder="libx265"
            decoder="hevc_cuvid"
            ext="mkv"
            extra_source_opts="-pix_fmt yuv420p"
            ;;
        hevc10)
            source_encoder="libx265"
            decoder="hevc_cuvid"
            ext="mkv"
            extra_source_opts="-pix_fmt yuv420p10le -profile:v main10"
            ;;
        vp9)
            source_encoder="libvpx-vp9"
            decoder="vp9_cuvid"
            ext="webm"
            ;;
        vp910)
            source_encoder="libvpx-vp9"
            decoder="vp9_cuvid"
            ext="webm"
            extra_source_opts="-pix_fmt yuv420p10le -profile:v 2"
            ;;
        av1)
            source_encoder="libsvtav1"
            decoder="av1_cuvid"
            ext="mkv"
            extra_source_opts="-preset 13"
            ;;
        *)
            return 1
            ;;
    esac

    local path="/tmp/mediastack-${codec}-decode-probe.${ext}"
    docker exec jellyfin sh -c "
set -eu
ffmpeg=/usr/lib/jellyfin-ffmpeg/ffmpeg
rm -f '$path'
trap \"rm -f '$path'\" EXIT
\$ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=size=320x180:rate=1 -t 1 -c:v '$source_encoder' $extra_source_opts '$path'
\$ffmpeg -hide_banner -hwaccel cuda -c:v '$decoder' -i '$path' -f null -
" >"$smoke_log" 2>&1
}

stage3_probe_capabilities() {
    local vendor="$1"
    local encoder="$2"
    local tmp_log capability_lines
    local hw_decoding_codecs="h264"
    local decode_hevc_10bit="false"
    local decode_vp9_10bit="false"
    local allow_hevc_encoding="false"
    local allow_av1_encoding="false"

    tmp_log=$(mktemp)
    if stage3_run_encoder_smoke_test "$vendor" "$encoder" "$tmp_log" "hevc"; then
        allow_hevc_encoding="true"
    fi
    rm -f "$tmp_log"

    tmp_log=$(mktemp)
    if stage3_run_encoder_smoke_test "$vendor" "$encoder" "$tmp_log" "av1"; then
        allow_av1_encoding="true"
    fi
    rm -f "$tmp_log"

    case "$encoder" in
        qsv | vaapi)
            export STAGE_3_GPU_RENDER_DEVICE
            STAGE_3_GPU_RENDER_DEVICE="$(stage3_resolve_render_device "$vendor")" || return 1
            tmp_log=$(mktemp)
            if stage3_capture_vainfo "$tmp_log"; then
                capability_lines=$(stage3_vainfo_to_capabilities "$tmp_log" 2>/dev/null || true)
                hw_decoding_codecs=$(printf '%s\n' "$capability_lines" | sed -n '1p')
                decode_hevc_10bit=$(printf '%s\n' "$capability_lines" | sed -n '2p')
                decode_vp9_10bit=$(printf '%s\n' "$capability_lines" | sed -n '3p')
                hw_decoding_codecs="${hw_decoding_codecs:-h264}"
                decode_hevc_10bit="${decode_hevc_10bit:-false}"
                decode_vp9_10bit="${decode_vp9_10bit:-false}"
            fi
            rm -f "$tmp_log"
            ;;
        nvenc)
            local codec codec_available codecs=(h264)
            for codec in hevc vp9 av1; do
                codec_available=false
                tmp_log=$(mktemp)
                if stage3_run_nvidia_decode_smoke_test "$codec" "$tmp_log"; then
                    codec_available=true
                fi
                rm -f "$tmp_log"

                case "$codec" in
                    hevc)
                        tmp_log=$(mktemp)
                        if stage3_run_nvidia_decode_smoke_test "hevc10" "$tmp_log"; then
                            decode_hevc_10bit="true"
                            codec_available=true
                        fi
                        rm -f "$tmp_log"
                        ;;
                    vp9)
                        tmp_log=$(mktemp)
                        if stage3_run_nvidia_decode_smoke_test "vp910" "$tmp_log"; then
                            decode_vp9_10bit="true"
                            codec_available=true
                        fi
                        rm -f "$tmp_log"
                        ;;
                esac

                if [[ "$codec_available" == "true" ]]; then
                    codecs+=("$codec")
                fi
            done
            hw_decoding_codecs=$(
                IFS=,
                printf '%s' "${codecs[*]}"
            )
            ;;
    esac

    export STAGE_3_GPU_HW_DECODING_CODECS="$hw_decoding_codecs"
    export STAGE_3_GPU_DECODE_HEVC_10BIT="$decode_hevc_10bit"
    export STAGE_3_GPU_DECODE_VP9_10BIT="$decode_vp9_10bit"
    export STAGE_3_GPU_ALLOW_HEVC_ENCODING="$allow_hevc_encoding"
    export STAGE_3_GPU_ALLOW_AV1_ENCODING="$allow_av1_encoding"
}

stage3_verify_transcode_evidence() {
    local vendor="$1"
    local encoder="$2"
    local log_source="${STAGE3_TRANSCODE_LOG_FIXTURE:-}"
    local log_file

    if [[ -z "$log_source" ]]; then
        log_source="${STAGE3_SAMPLE_TRANSCODE_LOG:-}"
    fi

    # Fixture path: scan once and decide. Used by unit tests with a
    # pre-populated log file — no race possible.
    if [[ -n "$log_source" && -f "$log_source" ]]; then
        log_file=$(mktemp)
        stage3_capture_jellyfin_transcode_log "$log_source" "$log_file" || {
            rm -f "$log_file"
            ui_log warn "No sample media or transcode log evidence available for ${vendor} ${encoder}."
            return 1
        }
        if stage3_transcode_log_uses_gpu "$encoder" "$log_file"; then
            rm -f "$log_file"
            return 0
        fi
        rm -f "$log_file"
        return 1
    fi

    # Live path: the smoke test (an active NVENC transcode via `docker exec
    # jellyfin ffmpeg`) is the strongest proof, but a one-shot run races the
    # container: _stage3_apply_runtime_override (and a config-driven recreate
    # from configure.sh changing .env) has just restarted Jellyfin, so an
    # immediate `docker exec` hits a not-yet-ready container and fails even
    # though NVENC is correctly wired. Retry the smoke test on the poll budget
    # so it succeeds the moment the container is up. Fall back each iteration to
    # scanning startup logs for the encoder-enumeration lines (`Available
    # encoders: [...]`, `Available hwaccel types: [...]`), which emit ~20-25s
    # into startup — later than a single early capture would catch.
    local i=0 max=30
    while :; do
        log_file=$(mktemp)
        if stage3_run_encoder_smoke_test "$vendor" "$encoder" "$log_file"; then
            rm -f "$log_file"
            return 0
        fi
        if stage3_capture_jellyfin_transcode_log "$log_source" "$log_file" \
            && stage3_transcode_log_uses_gpu "$encoder" "$log_file"; then
            rm -f "$log_file"
            return 0
        fi
        rm -f "$log_file"
        ((i >= max)) && break
        sleep 2
        ((i += 2))
    done
    ui_log warn "Automatic test transcode and Jellyfin log evidence were unavailable for ${vendor} ${encoder}."
    return 1
}

_stage3_apply_runtime_override() {
    local gpu_type="${1:-none}"

    if type detect_host_memory >/dev/null 2>&1 && [[ -z "${HOST_MEMORY_MB:-}" ]]; then
        detect_host_memory
    fi

    if type generate_override >/dev/null 2>&1; then
        generate_override "$gpu_type"
    fi

    if command -v docker >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR" && docker compose up -d jellyfin >/dev/null 2>&1) || return 1
        # Wait for the recreated container to accept `docker exec` before
        # returning. Callers probe/transcode immediately (stage3_probe_capabilities
        # runs codec smoke tests; stage3_verify_transcode_evidence runs the NVENC
        # smoke test) — against a container still restarting, every codec exec
        # fails and NVENC gets silently downgraded to h264-only (or the transcode
        # reads as "no GPU"). Bounded; on timeout proceed anyway and let the
        # probes/verify degrade gracefully rather than block finalize forever.
        local _elapsed=0 _max="${STAGE3_CONTAINER_READY_TIMEOUT:-30}"
        [[ "$_max" =~ ^[0-9]+$ ]] || _max=30
        while ! docker exec jellyfin true >/dev/null 2>&1; do
            ((_elapsed >= _max)) && break
            sleep 2
            ((_elapsed += 2))
        done
        return 0
    fi

    return 0
}

_stage3_offer() {
    {
        ui_section "Hardware transcoding"
        ui_box "Hardware transcoding is optional" \
            "Detected GPU: $(gpu_brand_label "${GPU_TYPE:-none}")" \
            "Jellyfin can use supported GPUs for video conversion." \
            "Intel and AMD finish now. NVIDIA may finish after reboot."
    } >&2
    UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Configure hardware transcoding now?" \
        "Configure hardware transcoding" \
        "Skip for now" \
        "Tell me more"
}

_stage3_tell_me_more() {
    # No section header here — the loop re-enters _stage3_offer immediately after,
    # which prints the "Hardware transcoding" header; printing it here too would
    # double it up.
    ui_log info "Intel and AMD GPUs can be configured now without reboot."
    ui_log info "NVIDIA may need one reboot before MediaStack can finish NVENC setup."
    ui_log info "MediaStack only enables a hardware encoder after verification evidence is available."
    ui_log skip "Skipping keeps Jellyfin on software transcoding."
}

_stage3_choose_gpu_vendor() {
    declare -p GPU_CANDIDATES >/dev/null 2>&1 || return 0
    ((${#GPU_CANDIDATES[@]} > 1)) || return 0

    ui_section "Choose GPU"
    local options=() vendors=() vendor default_index=1 choice
    for vendor in "${GPU_CANDIDATES[@]}"; do
        vendors+=("$vendor")
        case "$vendor" in
            nvidia) options+=("NVIDIA — NVENC") ;;
            amd) options+=("AMD — VAAPI") ;;
            intel) options+=("Intel — Quick Sync") ;;
        esac
        [[ "$vendor" == "${GPU_TYPE:-}" ]] && default_index="${#options[@]}"
    done

    choice=$(UI_CHOOSE_DEFAULT_INDEX="$default_index" ui_choose "Which GPU should Jellyfin use?" "${options[@]}")
    case "$choice" in
        "NVIDIA — NVENC") GPU_TYPE=nvidia ;;
        "AMD — VAAPI") GPU_TYPE=amd ;;
        "Intel — Quick Sync") GPU_TYPE=intel ;;
        *) GPU_TYPE="${vendors[$((default_index - 1))]}" ;;
    esac
}

_stage3_configure_jellyfin() {
    (cd "$SCRIPT_DIR" && ./scripts/configure.sh --only jellyfin)
}

_stage3_verify_jellyfin_encoding() {
    local encoder="$1"
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1

    STAGE3_EXPECTED_ENCODER="$encoder" \
        STAGE3_HW_DECODING_CODECS="${STAGE_3_GPU_HW_DECODING_CODECS:-h264}" \
        STAGE3_DECODE_HEVC_10BIT="${STAGE_3_GPU_DECODE_HEVC_10BIT:-false}" \
        STAGE3_DECODE_VP9_10BIT="${STAGE_3_GPU_DECODE_VP9_10BIT:-false}" \
        STAGE3_ALLOW_HEVC_ENCODING="${STAGE_3_GPU_ALLOW_HEVC_ENCODING:-false}" \
        STAGE3_ALLOW_AV1_ENCODING="${STAGE_3_GPU_ALLOW_AV1_ENCODING:-false}" \
        STAGE3_RENDER_DEVICE="${STAGE_3_GPU_RENDER_DEVICE:-/dev/dri/renderD128}" \
        STAGE3_CURRENT_CONFIG="$current" \
        python3 - <<'PY'
import json
import os
import sys

def as_bool(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")

c = json.loads(os.environ["STAGE3_CURRENT_CONFIG"])
encoder = os.environ["STAGE3_EXPECTED_ENCODER"]
expected = {
    "HardwareAccelerationType": encoder,
    "EnableHardwareEncoding": True,
    "HardwareDecodingCodecs": [
        item.strip()
        for item in os.environ.get("STAGE3_HW_DECODING_CODECS", "h264").split(",")
        if item.strip()
    ] or ["h264"],
    "EnableDecodingColorDepth10Hevc": as_bool(os.environ.get("STAGE3_DECODE_HEVC_10BIT", "false")),
    "EnableDecodingColorDepth10Vp9": as_bool(os.environ.get("STAGE3_DECODE_VP9_10BIT", "false")),
    "AllowHevcEncoding": as_bool(os.environ.get("STAGE3_ALLOW_HEVC_ENCODING", "false")),
    "AllowAv1Encoding": as_bool(os.environ.get("STAGE3_ALLOW_AV1_ENCODING", "false")),
}
if encoder == "qsv":
    expected["QsvDevice"] = os.environ.get("STAGE3_RENDER_DEVICE", "")
elif encoder == "vaapi":
    expected["VaapiDevice"] = os.environ.get("STAGE3_RENDER_DEVICE", "")

for key, value in expected.items():
    if c.get(key) != value:
        print(f"{key}: expected {value!r}, got {c.get(key)!r}", file=sys.stderr)
        sys.exit(1)
PY
}

_stage3_wait_for_jellyfin_encoding() {
    local encoder="$1"
    local max_wait="${STAGE3_ENCODING_VERIFY_TIMEOUT:-60}"
    local interval="${STAGE3_ENCODING_VERIFY_INTERVAL:-2}"
    local elapsed=0

    [[ "$max_wait" =~ ^[0-9]+$ ]] || max_wait=60
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -gt 0 ]] || interval=2

    while true; do
        if _stage3_verify_jellyfin_encoding "$encoder"; then
            return 0
        fi
        if ((elapsed >= max_wait)); then
            return 1
        fi
        sleep "$interval" || true
        elapsed=$((elapsed + interval))
    done
}

_stage3_jellyfin_api_key() {
    if [[ -n "${JELLYFIN_API_KEY:-}" ]]; then
        printf '%s\n' "$JELLYFIN_API_KEY"
        return 0
    fi

    python3 - "$SCRIPT_DIR/.env" <<'PY' 2>/dev/null
import pathlib
import shlex
import sys

for raw in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not raw or raw.startswith("#") or "=" not in raw:
        continue
    key, value = raw.split("=", 1)
    if key != "JELLYFIN_API_KEY":
        continue
    try:
        parsed = shlex.split(value, posix=True)
        print(parsed[0] if parsed else "")
    except ValueError:
        print(value)
    break
PY
}

_stage3_disable_jellyfin_hardware() {
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current body
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1
    body=$(echo "$current" | python3 -c '
import json
import sys
c = json.load(sys.stdin)
c["HardwareAccelerationType"] = "none"
c["EnableHardwareEncoding"] = False
print(json.dumps(c))
')
    curl -sf -X POST "$jf_url/System/Configuration/encoding" \
        -H "Authorization: $auth" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1
}

_stage3_encoder_disabled() {
    local jf_token
    jf_token="$(_stage3_jellyfin_api_key)"
    [[ -n "$jf_token" ]] || return 1

    local jf_url="http://localhost:8096"
    local auth="MediaBrowser Client=\"MediaStack\", Device=\"Setup\", DeviceId=\"mediastack-setup\", Version=\"1.0\", Token=\"$jf_token\""
    local current
    current=$(curl -sf "$jf_url/System/Configuration/encoding" -H "Authorization: $auth" 2>/dev/null) || return 1
    # Fallback is safe only when Jellyfin reports full software mode.
    STAGE3_CURRENT_CONFIG="$current" \
        python3 - <<'PY'
import json
import os
import sys

try:
    c = json.loads(os.environ["STAGE3_CURRENT_CONFIG"])
except Exception:
    sys.exit(1)

if c.get("HardwareAccelerationType") == "none" and c.get("EnableHardwareEncoding") is False:
    sys.exit(0)

sys.exit(1)
PY
}

_stage3_fallback() {
    local vendor="${1:-}"
    local encoder="${2:-}"
    stage3_remove_nvidia_marker
    GPU_TYPE="none"
    stage3_set_gpu_env "none" "fallback" "$vendor" "$encoder" || true
    _stage3_configure_jellyfin >/dev/null 2>&1 || true
    if ! _stage3_disable_jellyfin_hardware; then
        ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
    elif ! _stage3_encoder_disabled "$encoder"; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi
    _stage3_apply_runtime_override "none"
    ui_log warn "Hardware transcoding could not be verified. Jellyfin will use software transcoding. Fix the driver/runtime issue, then choose Manage hardware transcoding (GPU) from the menu."
    _stage3_print_final_summary
}

_stage3_skip_to_software_mode() {
    local prior_gpu="${1:-none}"
    local warn_if_disable_fails=false

    stage3_remove_nvidia_marker

    case "$prior_gpu" in
        intel | amd | nvidia) warn_if_disable_fails=true ;;
    esac

    if ! _stage3_disable_jellyfin_hardware; then
        if [[ "$warn_if_disable_fails" == "true" ]]; then
            ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
        fi
    elif ! _stage3_encoder_disabled; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi

    _stage3_apply_runtime_override "none" || true
}

_stage3_nvidia_finalize_failure() {
    stage3_set_gpu_env "none" "fallback" "nvidia" "nvenc" || true
    _stage3_configure_jellyfin >/dev/null 2>&1 || true
    if ! _stage3_disable_jellyfin_hardware; then
        ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
    elif ! _stage3_encoder_disabled "nvenc"; then
        ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
    fi
    _stage3_apply_runtime_override "none"
    stage3_remove_nvidia_marker
    ui_log warn "NVIDIA finalization did not complete. MediaStack is falling back to software transcoding; check journalctl -u mediastack-setup --no-pager, fix the driver/runtime issue, then choose Manage hardware transcoding (GPU) from the menu."
    _stage3_print_final_summary
}

_stage3_configure_and_verify() {
    local vendor="$1"
    local encoder="$2"
    local success_copy="$3"
    local fallback_mode="${4:-fallback}"
    # Optional NVIDIA driver-management mode persisted on success (empty for
    # Intel/AMD, which leaves any existing NVIDIA_DRIVER_MODE untouched).
    local driver_mode="${5:-}"
    local proof_since attempt=1 max_attempts=3

    while ((attempt <= max_attempts)); do
        stage3_set_gpu_env "$vendor" "pending" "$vendor" "$encoder"
        proof_since=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        if _stage3_apply_runtime_override "$vendor" \
            && stage3_probe_capabilities "$vendor" "$encoder" \
            && stage3_set_gpu_env "$vendor" "pending" "$vendor" "$encoder" \
            && _stage3_configure_jellyfin \
            && _stage3_wait_for_jellyfin_encoding "$encoder" \
            && STAGE3_TRANSCODE_SINCE="$proof_since" stage3_verify_transcode_evidence "$vendor" "$encoder"; then
            stage3_set_gpu_env "$vendor" "complete" "$vendor" "$encoder" "$driver_mode"
            type clear_setup_result_banner >/dev/null 2>&1 && clear_setup_result_banner
            ui_log ok "$success_copy"
            _stage3_print_final_summary
            return 0
        fi

        if ((attempt >= max_attempts)) || [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
            if [[ "$fallback_mode" == "try-next" ]]; then
                ui_log warn "${vendor} ${encoder} did not verify; trying the next hardware transcoding method."
                # 2 means the caller may try another hardware encoder; 1 means a terminal fallback/skip already ran.
                return 2
            fi
            _stage3_fallback "$vendor" "$encoder"
            return 1
        fi

        ui_log warn "Hardware transcoding verification failed (attempt ${attempt}/${max_attempts})."
        local action
        action=$(ui_choose "Hardware transcoding did not verify. What should setup do?" \
            "Retry verification" \
            "Use software transcoding" \
            "Skip for now")
        case "$action" in
            "Retry"*)
                attempt=$((attempt + 1))
                continue
                ;;
            "Skip"*)
                GPU_TYPE="none"
                stage3_remove_nvidia_marker
                stage3_set_gpu_env "none" "skipped" "" "" || true
                if ! _stage3_disable_jellyfin_hardware; then
                    ui_log warn "Could not disable Jellyfin hardware transcoding through the API. Check Jellyfin settings before relying on software fallback."
                elif ! _stage3_encoder_disabled "$encoder"; then
                    ui_log warn "Jellyfin hardware transcoding disable could not be verified. Check Jellyfin settings before relying on software fallback."
                fi
                ui_log skip "$(stage3_skip_summary_copy)"
                _stage3_apply_runtime_override "none" || true
                _stage3_print_final_summary
                return 1
                ;;
            *)
                _stage3_fallback "$vendor" "$encoder"
                return 1
                ;;
        esac
    done

    _stage3_fallback "$vendor" "$encoder"
    return 1
}

_stage3_configure_intel() {
    local qsv_rc

    if _stage3_configure_and_verify "intel" "qsv" "Intel Quick Sync configured and verified." "try-next"; then
        return 0
    else
        qsv_rc=$?
    fi

    if [[ "$qsv_rc" == "2" ]]; then
        ui_log info "Trying Intel VAAPI fallback for older Intel graphics hardware..."
        _stage3_configure_and_verify "intel" "vaapi" "Intel VAAPI transcoding configured and verified." || true
    fi

    return 0
}

stage3_prompt_nvidia_reboot() {
    stage3_reboot_prompt_needed || return 0

    ui_section "Reboot"
    ui_box "Reboot needed to finish NVIDIA transcoding" \
        "MediaStack has prepared the NVIDIA driver setup." \
        "After reboot, setup will resume automatically." \
        "It will verify nvidia-smi, restart Docker, write Jellyfin NVENC settings, run a test transcode, and print the final summary."

    local reboot_action
    reboot_action=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "Reboot now?" "Reboot now" "Reboot manually later")
    case "$reboot_action" in
        "Reboot now")
            # The menu above is the single reboot gate: the user chose
            # "Reboot now", so arm the resume hooks and reboot — no redundant
            # second confirm. Resume is scheduled/bannered/announced BEFORE the
            # reboot, so even an interrupted or manual boot finalizes GPU setup.
            schedule_post_reboot
            install_post_reboot_banner
            print_reboot_notice
            # Interactive users get the 10s grace window to READ the reboot notice
            # (and a real chance to Ctrl-C) before the box goes down. On a non-
            # interactive run there is nobody to read it and "Ctrl-C to cancel" is a
            # no-op, so skip the countdown and reboot straight away.
            if [[ -t 0 ]]; then
                local _s
                for _s in 10 9 8 7 6 5 4 3 2 1; do
                    printf '\r  Rebooting in %2ds...  (Ctrl-C to cancel)' "$_s"
                    sleep 1
                done
                printf '\r\033[K'
            fi
            sudo reboot
            ;;
        "Reboot manually later")
            schedule_post_reboot
            install_post_reboot_banner
            print_reboot_notice
            printf '%s\n' "Reboot manually when ready. MediaStack will resume GPU finalization automatically on the next boot."
            ;;
    esac
}

# Post-reboot the nvidia kernel module can take a few seconds to settle before
# nvidia-smi responds (large VRAM, first boot after a fresh install). The resume
# service starts After=docker.service, which is not ordered against the nvidia
# module load, so give the driver a bounded window to come up. Without this a
# not-yet-settled module reads as a driver failure and false-falls-back to
# software even though the driver is fine. Returns 0 as soon as nvidia-smi works.
_stage3_wait_for_nvidia_smi() {
    local max="${STAGE3_NVIDIA_SMI_TIMEOUT:-20}" elapsed=0
    [[ "$max" =~ ^[0-9]+$ ]] || max=20
    while :; do
        if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
            return 0
        fi
        ((elapsed >= max)) && return 1
        sleep 2
        ((elapsed += 2))
    done
}

stage3_finalize_nvidia() {
    local proof_since
    ui_log info "Resuming hardware transcoding: NVIDIA finalization"

    # Let the driver settle before any nvidia-smi-based decision below. Skip when
    # a .run install is already pending — that path (re)installs the driver
    # itself, so waiting for a not-yet-installed driver would just burn the budget.
    if [[ ! -f "$SCRIPT_DIR/.nvidia-tmp/pending" ]]; then
        _stage3_wait_for_nvidia_smi || true
    fi

    # Driver mode comes from the marker (survives .env regeneration). A marker
    # that EXISTS but has no mode field is a schema-1 marker from the old patch
    # flow, so it is unlock by definition — do NOT fall back to .env there, since
    # a regenerated NVIDIA_DRIVER_MODE=standard would wrongly skip the patch. Only
    # when there is no marker at all do we consult .env.
    local _mode _install_source
    if _mode="$(stage3_marker_driver_mode 2>/dev/null)"; then
        [[ -n "$_mode" ]] || _mode="unlock"
    else
        _mode="${NVIDIA_DRIVER_MODE:-unlock}"
    fi
    _install_source=$(stage3_marker_install_source 2>/dev/null || true)

    # Unlock can resume from either a cached .run installer or a Standard→Unlock
    # conversion reboot where the Debian driver was purged before any .run cache
    # existed. Standard/Existing installed (or kept) the driver before reboot and
    # just need verification below. Ignore and clear any stale .run cache for
    # non-Unlock modes so a leftover Unlock cache can never drag a Standard
    # finalize back onto the .run path.
    if [[ "$_mode" == "unlock" && "$_install_source" != "run-update" ]]; then
        if [[ -f "$SCRIPT_DIR/.nvidia-tmp/pending" ]] || ! { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; }; then
            GPU_TYPE="nvidia"
            if ! install_nvidia_drivers; then
                _stage3_nvidia_finalize_failure
                return 0
            fi
        fi
    elif [[ -e "$SCRIPT_DIR/.nvidia-tmp/pending" ]]; then
        ui_log info "Ignoring stale .run driver cache (driver mode is ${_mode})."
        sudo rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || true
    fi

    ui_log info "Verifying NVIDIA driver..."
    if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi -L >/dev/null 2>&1; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    local _expected_version _loaded_version
    _expected_version=$(stage3_marker_expected_driver_version 2>/dev/null || true)
    if [[ -n "$_expected_version" ]]; then
        _loaded_version=$(nvidia_driver_version 2>/dev/null || true)
        if [[ "$_loaded_version" != "$_expected_version" ]]; then
            ui_log warn "Loaded NVIDIA driver version does not match the prepared update."
            _stage3_nvidia_finalize_failure
            return 0
        fi
    fi

    ui_log info "Restarting Docker so NVIDIA runtime is available..."
    sudo systemctl restart docker 2>/dev/null || sudo service docker restart 2>/dev/null || true

    GPU_TYPE="nvidia"
    if [[ "$_mode" == "unlock" ]]; then
        # The Unlock patch only removes the NVENC concurrent-session limit; the
        # driver + NVENC library are already installed and verified above. If the
        # patch fails, hardware NVENC still works (just capped at the stock ~3
        # sessions) — so DON'T drop all the way to CPU software. Keep NVENC, record
        # that the patch isn't applied (marker read by the login banner), and leave
        # the driver in unlock mode so "Manage hardware transcoding -> Reapply
        # Unlock patch" can retry it. Only a driver-level failure (below) falls
        # back to software.
        # apply_nvidia_patch manages the .nvidia-nvenc-unpatched marker itself.
        if ! apply_nvidia_patch; then
            ui_log warn "NVENC Unlock patch did not apply - continuing with hardware NVENC at the stock session limit (~3 simultaneous transcodes). Retry via Manage hardware transcoding -> Reapply Unlock patch."
        fi
    fi
    verify_gpu_usable || true
    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    ui_log info "Writing Jellyfin encoder: nvenc"
    stage3_set_gpu_env "nvidia" "pending" "nvidia" "nvenc"
    proof_since=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if ! _stage3_apply_runtime_override "nvidia"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi
    if ! stage3_probe_capabilities "nvidia" "nvenc"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi
    stage3_set_gpu_env "nvidia" "pending" "nvidia" "nvenc"
    if ! _stage3_configure_jellyfin || ! _stage3_wait_for_jellyfin_encoding "nvenc"; then
        _stage3_nvidia_finalize_failure
        return 0
    fi

    ui_log info "Restarting Jellyfin..."
    (cd "$SCRIPT_DIR" && docker compose up -d jellyfin >/dev/null 2>&1) || true

    # The driver is verified usable (nvidia-smi + docker runtime + verify_gpu_usable
    # above) and Jellyfin is already configured AND confirmed on NVENC. The test
    # transcode is PROOF, not a gate: on a slower boot the smoke test can race the
    # Jellyfin restart, or the encoder-enumeration log lines can emit late, and it
    # comes back inconclusive even though NVENC is correctly wired through. A
    # failure here must NOT drop a working GPU to CPU software (same principle as
    # the Unlock patch above). Keep NVENC, tell the user verification was
    # inconclusive, and let them confirm by playing something.
    ui_log info "Running test transcode..."
    if STAGE3_TRANSCODE_SINCE="$proof_since" stage3_verify_transcode_evidence "nvidia" "nvenc"; then
        ui_log ok "NVIDIA NVENC configured and verified."
    else
        ui_log warn "NVIDIA NVENC is configured and enabled, but the automatic test transcode was inconclusive (this can happen when the smoke test races the Jellyfin restart). Play a video that needs transcoding to confirm, or re-check via Manage hardware transcoding (GPU)."
    fi

    stage3_set_gpu_env "nvidia" "complete" "nvidia" "nvenc" "$_mode"
    stage3_remove_nvidia_marker
    ui_log ok "Post-reboot GPU finalization complete."
    _stage3_print_final_summary
    return 0
}

_stage3_nvidia_mode_more_copy() {
    ui_log info "Standard driver: Debian's packaged NVIDIA driver. It updates with the system (apt) and keeps NVIDIA's official NVENC session limit - typically 3-5 simultaneous transcodes, which is plenty for a home server where most playback is direct-play."
    ui_log info "Unlock NVENC limit: a patch-managed driver that removes the session limit, for households doing many simultaneous transcodes. It modifies NVIDIA driver binaries and must be re-applied from Manage hardware transcoding after every driver update."
    ui_log warn "Unlock modifies NVIDIA driver binaries and may conflict with NVIDIA's terms, warranties, support expectations, or local law."
}

_stage3_confirm_unlock() {
    ui_box "Unlock NVENC limit (advanced)" \
        "Installs a patch-managed NVIDIA driver and modifies its binaries." \
        "Removes the NVENC session limit, but must be re-applied after every" \
        "driver update (Manage hardware transcoding can reapply it)." \
        "May conflict with NVIDIA's terms, warranties, support, or local law."
    ui_confirm "Install the patch-managed driver and apply nvidia-patch?" "no"
}

# Ask Standard vs Unlock. Echoes "standard" or "unlock" to stdout; every menu and
# explanatory line goes to stderr so command substitution captures only the answer.
# Standard is listed first, so it is the default in non-interactive / UI_DEMO runs
# — the patch path is never selected by default.
_stage3_choose_nvidia_mode() {
    local choice
    while true; do
        {
            ui_box "NVIDIA driver setup" \
                "Standard is right for almost every home server - pick it unless you know" \
                "you need more than ~5 people transcoding at the same time." \
                "Standard driver: Debian-managed, official NVENC limits (recommended)" \
                "Unlock NVENC limit: patch-managed, removes the limit (advanced)"
        } >&2
        choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "How should MediaStack set up the NVIDIA driver?" \
            "Standard driver (recommended)" \
            "Unlock NVENC limit (advanced)" \
            "Tell me more")
        case "$choice" in
            *"Standard driver"*)
                printf 'standard'
                return 0
                ;;
            *"Unlock NVENC limit"*)
                if _stage3_confirm_unlock >&2; then
                    printf 'unlock'
                    return 0
                fi
                { ui_log skip "Leaving the patch unapplied; choose Standard for the distro-managed driver."; } >&2
                ;;
            *"Tell me more"*)
                { _stage3_nvidia_mode_more_copy; } >&2
                ;;
            *)
                printf standard
                return 0
                ;;
        esac
    done
}

_stage3_nvidia_manual_guidance() {
    ui_box "NVIDIA driver managed outside MediaStack" \
        "MediaStack will not remove, repair, replace, or patch this driver automatically." \
        "To switch to Standard, remove the current driver using its original uninstall" \
        "method, then open Manage hardware transcoding (GPU) and choose Standard." \
        "To switch to Unlock, remove it first, then choose Unlock NVENC on the same route."
}

_stage3_choose_nvidia_action() {
    local source="$1" health="$2" choice
    # To stderr: this function's stdout is its return value (captured by the
    # caller), so the header must not land on stdout.
    { ui_section "NVIDIA driver"; } >&2
    while true; do
        case "$source:$health" in
            none:*)
                _stage3_choose_nvidia_mode
                return
                ;;
            debian:healthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "How should MediaStack use the NVIDIA driver?" \
                    "Use installed driver $(nvidia_driver_version 2>/dev/null || echo '(version unknown)') (recommended)" \
                    "Replace with Unlock NVENC (advanced)" \
                    "Tell me more")
                case "$choice" in
                    "Use installed"*)
                        printf use
                        return
                        ;;
                    "Replace with Unlock"*)
                        if _stage3_confirm_unlock >&2; then
                            printf unlock
                            return
                        fi
                        { ui_log skip "Unlock replacement cancelled; the installed Debian driver was not changed."; } >&2
                        ;;
                    "Tell me more"*) { _stage3_nvidia_mode_more_copy; } >&2 ;;
                    *)
                        printf use
                        return
                        ;;
                esac
                ;;
            debian:unhealthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "The Debian NVIDIA driver is not healthy. What should MediaStack do?" \
                    "Repair/reinstall Debian driver (recommended)" \
                    "Replace with Unlock NVENC (advanced)" \
                    "Use software transcoding" \
                    "Tell me more")
                case "$choice" in
                    "Repair/reinstall"*)
                        printf repair
                        return
                        ;;
                    "Replace with Unlock"*)
                        if _stage3_confirm_unlock >&2; then
                            printf unlock
                            return
                        fi
                        { ui_log skip "Unlock replacement cancelled; the Debian driver was not changed."; } >&2
                        ;;
                    "Use software"*)
                        printf software
                        return
                        ;;
                    "Tell me more"*) { _stage3_nvidia_mode_more_copy; } >&2 ;;
                    *)
                        printf repair
                        return
                        ;;
                esac
                ;;
            foreign:healthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "NVIDIA driver managed outside MediaStack. What should MediaStack do?" \
                    "Use existing driver with user-managed updates" \
                    "Reinstall (remove existing, choose driver mode)" \
                    "Use software transcoding")
                case "$choice" in
                    "Use existing"*)
                        printf use-existing
                        return
                        ;;
                    "Reinstall"*)
                        printf reinstall
                        return
                        ;;
                    "Use software"*)
                        printf software
                        return
                        ;;
                    *)
                        printf use-existing
                        return
                        ;;
                esac
                ;;
            foreign:unhealthy)
                choice=$(UI_CHOOSE_DEFAULT_INDEX=1 ui_choose "NVIDIA driver managed outside MediaStack is not healthy. What should MediaStack do?" \
                    "Reinstall (remove existing, choose driver mode)" \
                    "Use software transcoding")
                case "$choice" in
                    "Reinstall"*)
                        printf reinstall
                        return
                        ;;
                    *)
                        printf software
                        return
                        ;;
                esac
                ;;
            *)
                printf software
                return
                ;;
        esac
    done
}

_stage3_nvidia_use_driver() {
    local mode="$1" message="$2"
    if ! _install_nvidia_container_toolkit; then
        _stage3_fallback "nvidia" "nvenc"
        return 0
    fi
    GPU_TYPE=nvidia
    verify_gpu_usable || true
    if [[ "$GPU_TYPE" == nvidia ]]; then
        _stage3_configure_and_verify "nvidia" "nvenc" "$message" "" "$mode" || true
    else
        _stage3_fallback "nvidia" "nvenc"
    fi
}

# Queue a reboot to finish NVIDIA setup, recording mode + install source in the
# marker so finalization resumes the right path (and patches only for unlock).
_stage3_nvidia_queue_reboot() {
    local mode="$1" source="$2" expected_version="${3:-}"
    stage3_write_nvidia_marker "$mode" "$source" "$expected_version"
    stage3_set_gpu_env "none" "pending" "nvidia" "nvenc" "$mode" || true
    ui_log warn "NVIDIA driver setup is ready for reboot. MediaStack will finish NVENC configuration after the reboot."
    ui_log info "Post-reboot GPU finalization queued: encoder=nvenc, test transcode, final summary."
    _stage3_print_final_summary
    if [[ "${STAGE3_DEFER_REBOOT_PROMPT:-false}" != "true" ]]; then
        stage3_prompt_nvidia_reboot
    fi
}

# Drive NVIDIA setup: pick the driver-management mode, then install via the
# Debian package (Standard, no patch) or the patch-managed .run (Unlock).
_stage3_run_nvidia() {
    local source health action
    # Optional forced source (used after a reinstall uninstalls the foreign
    # driver: nvidia-smi lingers on disk until reboot, so re-detection would
    # still report 'foreign' and loop the menu). Treat it as a clean install.
    source="${1:-$(nvidia_driver_source)}"
    if [[ -n "${1:-}" ]]; then health=unhealthy; elif nvidia_driver_healthy; then health=healthy; else health=unhealthy; fi
    action=$(_stage3_choose_nvidia_action "$source" "$health")

    case "$action" in
        software)
            _stage3_fallback "nvidia" "nvenc"
            return 0
            ;;
        reinstall)
            if ! command -v nvidia-uninstall &>/dev/null; then
                log_error "nvidia-uninstall not found — cannot remove the existing driver"
                log_info "Remove it manually (sudo nvidia-uninstall), then open Manage hardware transcoding (GPU) from the menu"
                _stage3_fallback "nvidia" "nvenc"
                return 0
            fi
            if ! ui_spin "Removing existing NVIDIA driver..." sudo nvidia-uninstall -s; then
                log_error "Failed to remove existing NVIDIA driver"
                log_info "Try manually: sudo nvidia-uninstall"
                _stage3_fallback "nvidia" "nvenc"
                return 0
            fi
            # nvidia-uninstall removes /usr/bin/nvidia-smi, but bash caches the
            # path from the earlier detection lookup — clear it so re-detection
            # (and install_nvidia_drivers' own check) don't see a phantom driver.
            hash -r
            log_ok "Existing NVIDIA driver removed"
            _stage3_run_nvidia none
            return $?
            ;;
        use)
            _stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified."
            return 0
            ;;
        use-existing)
            _stage3_nvidia_use_driver existing "NVIDIA NVENC configured and verified (you manage driver updates)."
            return 0
            ;;
        repair)
            if ! install_nvidia_drivers_apt repair; then
                _stage3_fallback "nvidia" "nvenc"
                return 0
            fi
            GPU_TYPE=nvidia
            if nvidia_driver_healthy; then
                _stage3_nvidia_use_driver standard "NVIDIA NVENC configured and verified after driver repair."
            else
                NEEDS_REBOOT=true
                _stage3_nvidia_queue_reboot standard apt
            fi
            return 0
            ;;
    esac

    if [[ "$action" == "standard" ]]; then
        local rc=0
        install_nvidia_drivers_apt || rc=$?
        if [[ "$rc" -ne 0 || "${GPU_TYPE:-none}" == "none" ]]; then
            _stage3_fallback "nvidia" "nvenc"
            return 0
        fi
        if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
            _stage3_nvidia_queue_reboot "standard" "apt"
            return 0
        fi
        verify_gpu_usable || true
        if [[ "${GPU_TYPE:-none}" == "nvidia" ]]; then
            _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified." "" "standard" || true
        else
            _stage3_fallback "nvidia" "nvenc"
        fi
        return 0
    fi

    # Unlock (advanced): the patch-managed .run flow. A Debian-managed Standard
    # install is converted automatically by purging the exact installed driver
    # packages while preserving/repairing the NVIDIA container toolkit.
    if [[ "$source" == "debian" ]]; then
        if ! prepare_nvidia_debian_to_unlock; then
            _stage3_fallback "nvidia" "nvenc"
            return 0
        fi
        if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
            _stage3_nvidia_queue_reboot "unlock" "run"
            return 0
        fi
    fi
    if ! install_nvidia_drivers; then
        _stage3_fallback "nvidia" "nvenc"
        return 0
    fi
    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        _stage3_fallback "nvidia" "nvenc"
        return 0
    fi
    if [[ "${NEEDS_REBOOT:-false}" == "true" ]]; then
        _stage3_nvidia_queue_reboot "unlock" "run"
        return 0
    fi
    # Patch failure keeps hardware NVENC (stock ~3-session limit), matching the
    # finalize path — only a driver-level failure falls back to software. The
    # marker is managed inside apply_nvidia_patch.
    if ! apply_nvidia_patch; then
        ui_log warn "NVENC Unlock patch did not apply - continuing with hardware NVENC at the stock session limit (~3 simultaneous transcodes). Retry via Manage hardware transcoding -> Reapply Unlock patch."
    fi
    verify_gpu_usable || true
    if [[ "${GPU_TYPE:-none}" == "nvidia" ]]; then
        _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified." "" "unlock" || true
    else
        _stage3_fallback "nvidia" "nvenc"
    fi
    return 0
}

run_stage3() {
    if [[ "${DEMO:-0}" == "1" ]]; then
        return 0
    fi

    if [[ "${GPU_TYPE:-none}" == "none" ]]; then
        local prior_gpu="${JELLYFIN_GPU:-none}"
        ui_log skip "Hardware transcoding skipped (no supported GPU detected)."
        stage3_set_gpu_env "none" "skipped" "" "" || true
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
                GPU_TYPE="none"
                stage3_set_gpu_env "none" "skipped" "" "" || true
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
                _stage3_fallback "intel" "qsv"
                return 0
            fi
            verify_gpu_usable || true
            if [[ "${GPU_TYPE:-none}" == "intel" ]]; then
                _stage3_configure_intel
            else
                _stage3_fallback "intel" "qsv"
            fi
            ;;
        amd)
            if ! install_amd_drivers; then
                GPU_TYPE="none"
                _stage3_fallback "amd" "vaapi"
                return 0
            fi
            verify_gpu_usable || true
            if [[ "${GPU_TYPE:-none}" == "amd" ]]; then
                _stage3_configure_and_verify "amd" "vaapi" "AMD VAAPI transcoding configured and verified." || true
            else
                _stage3_fallback "amd" "vaapi"
            fi
            ;;
        nvidia)
            _stage3_run_nvidia
            ;;
    esac
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
