#!/usr/bin/env bash
# tests/unit/stage3-intel-fallback.sh
#
# Contract tests for the Intel QSV/VAAPI hardware fallback sequence.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-intel-fallback"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

for terminal_choice in "Skip for now" "Use software transcoding"; do
    gpu_env_calls=()
    fallback_args=()
    qsv_attempts=0
    vaapi_attempts=0
    GPU_TYPE=intel
    ui_choose() { printf '%s\n' "$terminal_choice"; }
    ui_log() { :; }
    stage3_set_gpu_env() {
        gpu_env_calls+=("$1:$2:$3:$4")
        return 0
    }
    _stage3_apply_runtime_override() { return 0; }
    stage3_probe_capabilities() { return 0; }
    _stage3_configure_jellyfin() { return 0; }
    _stage3_verify_jellyfin_encoding() { return 0; }
    stage3_verify_transcode_evidence() {
        [[ "$2" == "qsv" ]] && qsv_attempts=$((qsv_attempts + 1))
        [[ "$2" == "vaapi" ]] && vaapi_attempts=$((vaapi_attempts + 1))
        return 1
    }
    _stage3_disable_jellyfin_hardware() { return 0; }
    _stage3_encoder_disabled() { return 0; }
    _stage3_fallback() {
        fallback_args+=("$1:$2")
        GPU_TYPE=none
        return 0
    }
    print_final_summary() { :; }

    _stage3_configure_intel
    assert_eq "1" "$qsv_attempts" "Intel QSV failure prompts before terminal choice: $terminal_choice"
    assert_eq "0" "$vaapi_attempts" "Intel terminal choice does not try VAAPI: $terminal_choice"
    if [[ "$terminal_choice" == "Skip for now" ]]; then
        assert_contains "${gpu_env_calls[*]}" "none:skipped::" "Intel QSV skip records skipped state"
        assert_eq "" "${fallback_args[*]}" "Intel QSV skip does not run software fallback"
    else
        assert_contains "${fallback_args[*]}" "intel:qsv" "Intel QSV software choice runs software fallback"
    fi

    unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence _stage3_disable_jellyfin_hardware _stage3_encoder_disabled _stage3_fallback print_final_summary
    unset gpu_env_calls fallback_args qsv_attempts vaapi_attempts GPU_TYPE
done

for terminal_choice in "Skip for now" "Use software transcoding"; do
    gpu_env_calls=()
    fallback_args=()
    qsv_attempts=0
    vaapi_attempts=0
    GPU_TYPE=intel
    ui_choose() {
        if ((qsv_attempts < 2)); then
            printf '%s\n' "Retry verification"
        else
            printf '%s\n' "$terminal_choice"
        fi
    }
    ui_log() { :; }
    stage3_set_gpu_env() {
        gpu_env_calls+=("$1:$2:$3:$4")
        return 0
    }
    _stage3_apply_runtime_override() { return 0; }
    stage3_probe_capabilities() { return 0; }
    _stage3_configure_jellyfin() { return 0; }
    _stage3_verify_jellyfin_encoding() { return 0; }
    stage3_verify_transcode_evidence() {
        [[ "$2" == "qsv" ]] && qsv_attempts=$((qsv_attempts + 1))
        [[ "$2" == "vaapi" ]] && vaapi_attempts=$((vaapi_attempts + 1))
        return 1
    }
    _stage3_disable_jellyfin_hardware() { return 0; }
    _stage3_encoder_disabled() { return 0; }
    _stage3_fallback() {
        fallback_args+=("$1:$2")
        GPU_TYPE=none
        return 0
    }
    print_final_summary() { :; }

    _stage3_configure_intel
    assert_eq "2" "$qsv_attempts" "Intel QSV retry reaches terminal choice: $terminal_choice"
    assert_eq "0" "$vaapi_attempts" "Intel retry then terminal choice does not try VAAPI: $terminal_choice"
    if [[ "$terminal_choice" == "Skip for now" ]]; then
        assert_contains "${gpu_env_calls[*]}" "none:skipped::" "Intel QSV retry then skip records skipped state"
        assert_eq "" "${fallback_args[*]}" "Intel QSV retry then skip does not run software fallback"
    else
        assert_contains "${fallback_args[*]}" "intel:qsv" "Intel QSV retry then software choice runs software fallback"
    fi

    unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence _stage3_disable_jellyfin_hardware _stage3_encoder_disabled _stage3_fallback print_final_summary
    unset gpu_env_calls fallback_args qsv_attempts vaapi_attempts GPU_TYPE
done

gpu_env_calls=()
verify_calls=()
runtime_count=0
configure_calls=0
probe_calls=0
summary_calls=0
ui_choose() { printf '%s\n' "Retry verification"; }
ui_log() { :; }
stage3_set_gpu_env() {
    gpu_env_calls+=("$1:$2:$3:$4")
    STAGE_3_GPU_ENCODER="$4"
}
_stage3_apply_runtime_override() {
    runtime_count=$((runtime_count + 1))
    return 0
}
stage3_probe_capabilities() {
    probe_calls=$((probe_calls + 1))
    return 0
}
_stage3_configure_jellyfin() {
    configure_calls=$((configure_calls + 1))
    return 0
}
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() {
    verify_calls+=("$1:$2")
    [[ "$2" == "vaapi" ]]
}
print_final_summary() { summary_calls=$((summary_calls + 1)); }
_stage3_configure_intel
assert_contains "${verify_calls[*]}" "intel:qsv" "Intel hardware flow tries QSV first"
assert_contains "${verify_calls[*]}" "intel:vaapi" "Intel hardware flow tries VAAPI after QSV fails"
assert_contains "${gpu_env_calls[*]}" "intel:complete:intel:vaapi" "Intel VAAPI fallback can mark hardware transcoding complete"
assert_eq "4" "$runtime_count" "Intel fallback applies runtime for three QSV attempts plus VAAPI"
assert_eq "4" "$probe_calls" "Intel fallback probes capabilities for each hardware attempt"
assert_eq "4" "$configure_calls" "Intel fallback configures Jellyfin for each hardware attempt"
assert_eq "1" "$summary_calls" "Intel VAAPI fallback prints final summary once"
unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence print_final_summary
unset gpu_env_calls verify_calls runtime_count probe_calls configure_calls summary_calls

source "$REPO_ROOT/scripts/services/jellyfin/main.sh"
api_fetch_post_body=""
api_fetch() {
    local is_post=false next_is_data=false arg
    for arg in "$@"; do
        if [[ "$next_is_data" == "true" ]]; then
            api_fetch_post_body="$arg"
            next_is_data=false
            continue
        fi
        case "$arg" in
            -X) is_post=true ;;
            -d) next_is_data=true ;;
        esac
    done
    if [[ "$is_post" == "true" ]]; then
        return 0
    fi
    printf '%s\n' '{"HardwareAccelerationType":"qsv","EnableHardwareEncoding":true,"VaapiDevice":"","EnableTonemapping":true,"EnableVppTonemapping":false,"TonemappingAlgorithm":"bt2390"}'
}
JELLYFIN_GPU=intel
STAGE_3_GPU_STATE=pending
STAGE_3_GPU_ENCODER=vaapi
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc,vp9
STAGE_3_GPU_DECODE_HEVC_10BIT=true
STAGE_3_GPU_DECODE_VP9_10BIT=true
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
configure_jellyfin_encoding "http://localhost:8096" "test-token"
assert_contains "$api_fetch_post_body" '"HardwareAccelerationType": "vaapi"' "Intel VAAPI fallback can switch Jellyfin from QSV to VAAPI during pending verification"
assert_contains "$api_fetch_post_body" '"VaapiDevice": "/dev/dri/renderD129"' "Intel VAAPI fallback writes selected VAAPI render device"
assert_contains "$api_fetch_post_body" '"HardwareDecodingCodecs": ["h264", "hevc", "vp9"]' "Jellyfin encoding applies probed decode codec list"
assert_contains "$api_fetch_post_body" '"AllowHevcEncoding": true' "Jellyfin encoding enables probed HEVC encoding"
assert_contains "$api_fetch_post_body" '"AllowAv1Encoding": false' "Jellyfin encoding disables unproven AV1 encoding"
assert_contains "$api_fetch_post_body" '"EnableDecodingColorDepth10Hevc": true' "Jellyfin encoding applies HEVC 10-bit decode capability"
assert_contains "$api_fetch_post_body" '"EnableDecodingColorDepth10Vp9": true' "Jellyfin encoding applies VP9 10-bit decode capability"
unset -f api_fetch
unset api_fetch_post_body JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_ENCODER
unset STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_DECODE_HEVC_10BIT STAGE_3_GPU_DECODE_VP9_10BIT
unset STAGE_3_GPU_ALLOW_HEVC_ENCODING STAGE_3_GPU_ALLOW_AV1_ENCODING STAGE_3_GPU_RENDER_DEVICE

api_fetch_post_body=""
drift_warn=""
api_fetch() {
    local is_post=false next_is_data=false arg
    for arg in "$@"; do
        if [[ "$next_is_data" == "true" ]]; then
            api_fetch_post_body="$arg"
            next_is_data=false
            continue
        fi
        case "$arg" in
            -X) is_post=true ;;
            -d) next_is_data=true ;;
        esac
    done
    if [[ "$is_post" == "true" ]]; then
        return 0
    fi
    printf '%s\n' '{"HardwareAccelerationType":"qsv","EnableHardwareEncoding":true,"HardwareDecodingCodecs":["h264"],"AllowHevcEncoding":false,"AllowAv1Encoding":false,"EnableDecodingColorDepth10Hevc":false,"EnableDecodingColorDepth10Vp9":false,"VaapiDevice":"","EnableTonemapping":true,"EnableVppTonemapping":false,"TonemappingAlgorithm":"bt2390"}'
}
log_warn() { drift_warn="$*"; }
log_drift() { drift_warn="$*"; }
JELLYFIN_GPU=intel
STAGE_3_GPU_STATE=complete
STAGE_3_GPU_ENCODER=qsv
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
STAGE_3_GPU_DECODE_HEVC_10BIT=true
STAGE_3_GPU_DECODE_VP9_10BIT=false
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
configure_jellyfin_encoding "http://localhost:8096" "test-token"
assert_eq "" "$api_fetch_post_body" "completed Stage 3 does not overwrite manual Jellyfin codec drift"
assert_contains "$drift_warn" "Leaving manual Jellyfin settings unchanged" "completed hardware proof warns instead of reconciling codec drift"
unset -f api_fetch log_warn log_drift
unset api_fetch_post_body drift_warn JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_ENCODER
unset STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_DECODE_HEVC_10BIT STAGE_3_GPU_DECODE_VP9_10BIT
unset STAGE_3_GPU_ALLOW_HEVC_ENCODING STAGE_3_GPU_ALLOW_AV1_ENCODING

api_fetch_post_body=""
api_fetch() {
    local is_post=false next_is_data=false arg
    for arg in "$@"; do
        if [[ "$next_is_data" == "true" ]]; then
            api_fetch_post_body="$arg"
            next_is_data=false
            continue
        fi
        case "$arg" in
            -X) is_post=true ;;
            -d) next_is_data=true ;;
        esac
    done
    if [[ "$is_post" == "true" ]]; then
        return 0
    fi
    printf '%s\n' '{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'
}
JELLYFIN_GPU=intel
STAGE_3_GPU_STATE=pending
STAGE_3_GPU_ENCODER=qsv
STAGE_3_GPU_HW_DECODING_CODECS=h264
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
configure_jellyfin_encoding "http://localhost:8096" "test-token"
assert_contains "$api_fetch_post_body" '"QsvDevice": "/dev/dri/renderD129"' "Intel QSV writes selected QSV render device"
unset -f api_fetch
unset api_fetch_post_body JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_ENCODER STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_RENDER_DEVICE

scenario_end "$CURRENT_SCENARIO"
summary
