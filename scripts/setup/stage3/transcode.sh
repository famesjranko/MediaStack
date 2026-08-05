# Owns: stage3_* — Transcode evidence capture/parsing: render-device resolution, vainfo/nvidia-smi probes, capability parsing, and verification.
# Sources: scripts/lib/render-device.sh helpers (sourced by stages/stage3.sh); python3 for vainfo parsing.

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
        if gpu_render_device_for_vendor "$vendor"; then
            return 0
        fi
    fi

    local resolve_rc=0
    if _render_device_for_vendor "$vendor"; then
        return 0
    else
        resolve_rc=$?
    fi
    if ((resolve_rc == 1)); then
        printf '%s\n' "/dev/dri/renderD128"
        return 0
    fi
    return 1
}

stage3_render_device_exists() {
    _render_device_exists "$@"
}

stage3_render_device_vendor_matches() {
    _render_device_vendor_matches "$@"
}

stage3_persisted_render_device() {
    _render_device_persisted "${1:-}" stage3_render_device_exists stage3_render_device_vendor_matches
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
