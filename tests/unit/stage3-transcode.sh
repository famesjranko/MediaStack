#!/usr/bin/env bash
# tests/unit/stage3-transcode.sh
#
# Contract tests for transcode evidence parsing.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-transcode"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/setup/stages/stage3.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

if ! type stage3_transcode_log_uses_gpu >/dev/null 2>&1; then
    stage3_transcode_log_uses_gpu() { return 1; }
fi
if ! type stage3_capture_jellyfin_transcode_log >/dev/null 2>&1; then
    stage3_capture_jellyfin_transcode_log() { return 1; }
fi
if ! type stage3_run_encoder_smoke_test >/dev/null 2>&1; then
    stage3_run_encoder_smoke_test() { return 1; }
fi
if ! type stage3_verify_transcode_evidence >/dev/null 2>&1; then
    stage3_verify_transcode_evidence() { return 1; }
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

qsv_log="$TMP_ROOT/qsv.log"
vaapi_log="$TMP_ROOT/vaapi.log"
nvenc_log="$TMP_ROOT/nvenc.log"
hevc_nvenc_log="$TMP_ROOT/hevc-nvenc.log"
software_log="$TMP_ROOT/software.log"
startup_log="$TMP_ROOT/startup.log"
vainfo_log="$TMP_ROOT/vainfo.log"
vainfo_encode_only_10bit_log="$TMP_ROOT/vainfo-encode-only-10bit.log"

cat > "$qsv_log" <<'LOG'
Stream mapping:
  h264 (h264_qsv) -> h264 (h264_qsv)
Hardware device qsv initialized.
LOG

cat > "$vaapi_log" <<'LOG'
libva info: VA-API version 1.20
Stream mapping:
  hevc -> h264 (h264_vaapi)
LOG

cat > "$nvenc_log" <<'LOG'
Stream mapping:
  h264 -> h264 (h264_nvenc)
Using hardware decoding with cuda.
LOG

cat > "$hevc_nvenc_log" <<'LOG'
Stream mapping:
  h264 -> hevc (hevc_nvenc)
LOG

cat > "$software_log" <<'LOG'
Stream mapping:
  h264 -> h264 (libx264)
No device available for decoder: device type vaapi needed.
LOG

cat > "$startup_log" <<'LOG'
Available encoders: ["libx264", "h264_qsv", "h264_vaapi", "h264_nvenc"]
Available hwaccel types: cuda vaapi qsv
LOG

cat > "$vainfo_log" <<'LOG'
vainfo: Supported profile and entrypoints
      VAProfileH264Main               : VAEntrypointVLD
      VAProfileHEVCMain               : VAEntrypointVLD
      VAProfileHEVCMain10             : VAEntrypointVLD
      VAProfileMPEG2Main              : VAEntrypointVLD
      VAProfileVC1Advanced            : VAEntrypointVLD
      VAProfileVP9Profile0            : VAEntrypointVLD
      VAProfileVP9Profile2            : VAEntrypointVLD
      VAProfileAV1Profile0            : VAEntrypointVLD
      VAProfileH264Main               : VAEntrypointEncSlice
LOG

cat > "$vainfo_encode_only_10bit_log" <<'LOG'
vainfo: Supported profile and entrypoints
      VAProfileH264Main               : VAEntrypointVLD
      VAProfileHEVCMain               : VAEntrypointVLD
      VAProfileVP9Profile0            : VAEntrypointVLD
      VAProfileHEVCMain10             : VAEntrypointEncSlice
      VAProfileVP9Profile2            : VAEntrypointEncSlice
LOG

if stage3_transcode_log_uses_gpu qsv "$qsv_log"; then
    pass "S3-08: parser accepts QSV evidence"
else
    fail "S3-08: parser accepts QSV evidence"
fi

if stage3_transcode_log_uses_gpu vaapi "$vaapi_log"; then
    pass "S3-08: parser accepts VAAPI evidence"
else
    fail "S3-08: parser accepts VAAPI evidence"
fi

if stage3_transcode_log_uses_gpu nvenc "$nvenc_log"; then
    pass "S3-08: parser accepts NVENC evidence"
else
    fail "S3-08: parser accepts NVENC evidence"
fi

if stage3_transcode_log_uses_gpu vaapi "$software_log"; then
    fail "S3-08: parser rejects software/failure log"
else
    pass "S3-08: parser rejects software/failure log"
fi

if stage3_transcode_log_uses_gpu bogus "$nvenc_log"; then
    fail "S3-08: parser rejects unknown encoder"
else
    pass "S3-08: parser rejects unknown encoder"
fi

if stage3_transcode_log_uses_gpu qsv "$startup_log"; then
    fail "S3-08: parser rejects startup encoder enumeration without transcode mapping"
else
    pass "S3-08: parser rejects startup encoder enumeration without transcode mapping"
fi

capture_out="$TMP_ROOT/captured.log"
if stage3_capture_jellyfin_transcode_log "$nvenc_log" "$capture_out" && cmp -s "$nvenc_log" "$capture_out"; then
    pass "S3-08: capture helper can copy a transcode log fixture"
else
    fail "S3-08: capture helper can copy a transcode log fixture"
fi

smoke_out="$TMP_ROOT/smoke.log"
docker_smoke_args="$TMP_ROOT/docker-smoke-args.txt"
docker() {
    printf '%s\n' "$*" > "$docker_smoke_args"
    if [[ "${1:-}" == "exec" ]]; then
        case "$*" in
            *hevc_nvenc*) cat "$hevc_nvenc_log" ;;
            *) cat "$nvenc_log" ;;
        esac
        return 0
    fi
    return 1
}

if stage3_run_encoder_smoke_test nvidia nvenc "$smoke_out"; then
    pass "S3-08: automatic smoke test proves NVENC without user playback"
else
    fail "S3-08: automatic smoke test proves NVENC without user playback"
fi
assert_contains "$(cat "$docker_smoke_args")" "h264_nvenc" "S3-08: automatic smoke test selects requested encoder"
if stage3_run_encoder_smoke_test nvidia nvenc "$smoke_out" hevc; then
    pass "S3-08: automatic smoke test proves optional HEVC encoder"
else
    fail "S3-08: automatic smoke test proves optional HEVC encoder"
fi
assert_contains "$(cat "$docker_smoke_args")" "hevc_nvenc" "S3-08: automatic smoke test selects optional encoder"
unset -f docker

nvidia_decode_script="$TMP_ROOT/nvidia-decode-script.txt"
docker() {
    if [[ "${1:-}" == "exec" && "${2:-}" == "jellyfin" && "${3:-}" == "sh" && "${4:-}" == "-c" ]]; then
        printf '%s\n' "$5" > "$nvidia_decode_script"
        return 0
    fi
    return 1
}
if stage3_run_nvidia_decode_smoke_test hevc10 "$smoke_out"; then
    pass "S3-08: NVIDIA decode probe exercises HEVC Main 10 sample"
else
    fail "S3-08: NVIDIA decode probe exercises HEVC Main 10 sample"
fi
assert_contains "$(cat "$nvidia_decode_script")" "-pix_fmt yuv420p10le" "S3-08: HEVC 10-bit probe generates 10-bit source"
assert_contains "$(cat "$nvidia_decode_script")" "-profile:v main10" "S3-08: HEVC 10-bit probe requests Main 10 profile"
assert_contains "$(cat "$nvidia_decode_script")" "hevc_cuvid" "S3-08: HEVC 10-bit probe decodes with NVIDIA CUVID"
if stage3_run_nvidia_decode_smoke_test vp910 "$smoke_out"; then
    pass "S3-08: NVIDIA decode probe exercises VP9 Profile 2 sample"
else
    fail "S3-08: NVIDIA decode probe exercises VP9 Profile 2 sample"
fi
assert_contains "$(cat "$nvidia_decode_script")" "-pix_fmt yuv420p10le" "S3-08: VP9 10-bit probe generates 10-bit source"
assert_contains "$(cat "$nvidia_decode_script")" "-profile:v 2" "S3-08: VP9 10-bit probe requests Profile 2"
assert_contains "$(cat "$nvidia_decode_script")" "vp9_cuvid" "S3-08: VP9 10-bit probe decodes with NVIDIA CUVID"
unset -f docker

STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
stage3_render_device_exists() {
    [[ "$1" == "/dev/dri/renderD129" ]]
}
stage3_render_device_vendor_matches() {
    return 0
}
docker() {
    printf '%s\n' "$*" > "$docker_smoke_args"
    if [[ "${1:-}" == "exec" ]]; then
        cat "$qsv_log"
        return 0
    fi
    return 1
}
if stage3_run_encoder_smoke_test intel qsv "$smoke_out"; then
    pass "S3-08: automatic smoke test uses selected QSV render device"
else
    fail "S3-08: automatic smoke test uses selected QSV render device"
fi
assert_contains "$(cat "$docker_smoke_args")" "qsv=hw:/dev/dri/renderD129" "S3-08: QSV smoke test uses selected render device"
docker() {
    printf '%s\n' "$*" > "$docker_smoke_args"
    if [[ "${1:-}" == "exec" ]]; then
        cat "$vaapi_log"
        return 0
    fi
    return 1
}
if stage3_run_encoder_smoke_test amd vaapi "$smoke_out"; then
    pass "S3-08: automatic smoke test uses selected VAAPI render device"
else
    fail "S3-08: automatic smoke test uses selected VAAPI render device"
fi
assert_contains "$(cat "$docker_smoke_args")" "-vaapi_device /dev/dri/renderD129" "S3-08: VAAPI smoke test uses selected render device"
unset -f docker
unset -f stage3_render_device_exists stage3_render_device_vendor_matches
unset STAGE_3_GPU_RENDER_DEVICE

capability_lines="$(stage3_vainfo_to_capabilities "$vainfo_log")"
assert_eq "h264,hevc,mpeg2video,vc1,vp9,av1" "$(printf '%s\n' "$capability_lines" | sed -n '1p')" "S3-08: vainfo parser maps hardware decode codecs"
assert_eq "true" "$(printf '%s\n' "$capability_lines" | sed -n '2p')" "S3-08: vainfo parser detects HEVC 10-bit decode"
assert_eq "true" "$(printf '%s\n' "$capability_lines" | sed -n '3p')" "S3-08: vainfo parser detects VP9 10-bit decode"
capability_lines="$(stage3_vainfo_to_capabilities "$vainfo_encode_only_10bit_log")"
assert_eq "h264,hevc,vp9" "$(printf '%s\n' "$capability_lines" | sed -n '1p')" "S3-08: vainfo parser keeps 8-bit decode codecs when 10-bit profiles are encode-only"
assert_eq "false" "$(printf '%s\n' "$capability_lines" | sed -n '2p')" "S3-08: vainfo parser rejects HEVC 10-bit without VLD decode"
assert_eq "false" "$(printf '%s\n' "$capability_lines" | sed -n '3p')" "S3-08: vainfo parser rejects VP9 10-bit without VLD decode"

stage3_run_encoder_smoke_test() {
    case "$4" in
        hevc) return 0 ;;
        av1) return 1 ;;
        *) return 0 ;;
    esac
}
stage3_capture_vainfo() {
    cp "$vainfo_log" "$1"
}
stage3_probe_capabilities intel qsv
assert_eq "true" "$STAGE_3_GPU_ALLOW_HEVC_ENCODING" "S3-08: capability probe enables HEVC only when smoke encode passes"
assert_eq "false" "$STAGE_3_GPU_ALLOW_AV1_ENCODING" "S3-08: capability probe disables AV1 when smoke encode fails"
assert_eq "h264,hevc,mpeg2video,vc1,vp9,av1" "$STAGE_3_GPU_HW_DECODING_CODECS" "S3-08: capability probe stores VAAPI/QSV decode codecs"
assert_eq "true" "$STAGE_3_GPU_DECODE_HEVC_10BIT" "S3-08: capability probe stores HEVC 10-bit decode"
assert_eq "true" "$STAGE_3_GPU_DECODE_VP9_10BIT" "S3-08: capability probe stores VP9 10-bit decode"
unset -f stage3_run_encoder_smoke_test stage3_capture_vainfo
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

nvidia_decode_calls=()
stage3_run_encoder_smoke_test() {
    case "${4:-h264}" in
        hevc) return 0 ;;
        av1) return 1 ;;
        *) return 0 ;;
    esac
}
stage3_run_nvidia_decode_smoke_test() {
    nvidia_decode_calls+=("$1")
    case "$1" in
        hevc|hevc10|vp910) return 0 ;;
        *) return 1 ;;
    esac
}
stage3_probe_capabilities nvidia nvenc
assert_eq "h264,hevc,vp9" "$STAGE_3_GPU_HW_DECODING_CODECS" "S3-08: NVIDIA capability probe stores 10-bit-capable decode codecs"
assert_eq "true" "$STAGE_3_GPU_DECODE_HEVC_10BIT" "S3-08: NVIDIA capability probe stores HEVC 10-bit decode"
assert_eq "true" "$STAGE_3_GPU_DECODE_VP9_10BIT" "S3-08: NVIDIA capability probe stores VP9 10-bit decode"
assert_eq "hevc hevc10 vp9 vp910 av1" "${nvidia_decode_calls[*]}" "S3-08: NVIDIA capability probe checks 8-bit and 10-bit decode fixtures"
unset -f stage3_run_encoder_smoke_test stage3_run_nvidia_decode_smoke_test
unset nvidia_decode_calls
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

stage3_run_encoder_smoke_test() {
    return 1
}
stage3_run_nvidia_decode_smoke_test() {
    case "$1" in
        hevc|vp9) return 0 ;;
        *) return 1 ;;
    esac
}
stage3_probe_capabilities nvidia nvenc
assert_eq "h264,hevc,vp9" "$STAGE_3_GPU_HW_DECODING_CODECS" "S3-08: NVIDIA capability probe keeps 8-bit decode codecs without 10-bit support"
assert_eq "false" "$STAGE_3_GPU_DECODE_HEVC_10BIT" "S3-08: NVIDIA capability probe leaves HEVC 10-bit disabled when probe fails"
assert_eq "false" "$STAGE_3_GPU_DECODE_VP9_10BIT" "S3-08: NVIDIA capability probe leaves VP9 10-bit disabled when probe fails"
unset -f stage3_run_encoder_smoke_test stage3_run_nvidia_decode_smoke_test
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

smoke_calls=()
stage3_run_encoder_smoke_test() {
    smoke_calls+=("$1:$2:${4:-h264}")
    cat "$nvenc_log" > "$3"
    return 0
}
stage3_capture_jellyfin_transcode_log() {
    return 1
}
if stage3_verify_transcode_evidence nvidia nvenc; then
    pass "S3-08: verification helper runs automatic smoke test before log polling"
else
    fail "S3-08: verification helper runs automatic smoke test before log polling"
fi
assert_eq "nvidia:nvenc:h264" "${smoke_calls[*]}" "S3-08: automatic smoke test receives vendor, encoder, and required codec"
unset -f stage3_run_encoder_smoke_test stage3_capture_jellyfin_transcode_log
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

STAGE3_TRANSCODE_LOG_FIXTURE="$qsv_log"
export STAGE3_TRANSCODE_LOG_FIXTURE
if stage3_verify_transcode_evidence intel qsv; then
    pass "S3-08: verification helper can prove Intel QSV when log evidence exists"
else
    fail "S3-08: verification helper can prove Intel QSV when log evidence exists"
fi

unset STAGE3_TRANSCODE_LOG_FIXTURE
docker_args_file="$TMP_ROOT/docker-args.txt"
docker() {
    if [[ "${1:-}" == "compose" && "${2:-}" == "logs" ]]; then
        printf '%s\n' "$*" > "$docker_args_file"
        cat "$qsv_log"
        return 0
    fi
    return 1
}

if STAGE3_TRANSCODE_SINCE="2026-05-01T00:00:00Z" stage3_verify_transcode_evidence intel qsv; then
    pass "S3-08: verification helper consults Jellyfin logs when no fixture is set"
else
    fail "S3-08: verification helper consults Jellyfin logs when no fixture is set"
fi
docker_log_args="$(cat "$docker_args_file" 2>/dev/null)"
assert_contains "$docker_log_args" "--since 2026-05-01T00:00:00Z" "S3-08: Docker log evidence is bounded to the current proof attempt"

unset -f docker
stage3_run_encoder_smoke_test() {
    return 1
}
stage3_capture_jellyfin_transcode_log() {
    return 1
}
sleep() {
    :
}
if stage3_verify_transcode_evidence intel qsv; then
    fail "S3-08: verification helper falls back when sample/log/evidence is unavailable"
else
    pass "S3-08: verification helper falls back when sample/log/evidence is unavailable"
fi
unset -f stage3_run_encoder_smoke_test stage3_capture_jellyfin_transcode_log sleep

scenario_end "$CURRENT_SCENARIO"
summary
