#!/usr/bin/env bash
# tests/unit/stage3-flow.sh
#
# Contract tests for the Stage 3 GPU flow.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-flow"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/setup/stages/stage3.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

if ! type stage3_offer_choices >/dev/null 2>&1; then
    stage3_offer_choices() { printf '__not_implemented__'; }
fi
if ! type stage3_tell_me_more_copy >/dev/null 2>&1; then
    stage3_tell_me_more_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_skip_summary_copy >/dev/null 2>&1; then
    stage3_skip_summary_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_set_gpu_env >/dev/null 2>&1; then
    stage3_set_gpu_env() { printf '__not_implemented__'; return 1; }
fi

offer_choices="$(stage3_offer_choices)"
if [[ "$offer_choices" == "__not_implemented__" ]]; then
    skip "S3-01: offer choices pending Stage 3 controller"
else
    assert_contains "$offer_choices" "Configure hardware transcoding" "S3-01: offer includes Configure hardware transcoding"
    assert_contains "$offer_choices" "Skip for now" "S3-01: offer includes Skip for now"
    assert_contains "$offer_choices" "Tell me more" "S3-01: offer includes Tell me more"
fi

if type _stage3_offer >/dev/null 2>&1; then
    offer_stderr="$(mktemp)"
    GPU_TYPE=nvidia
    ui_section() { printf 'SECTION:%s\n' "$*"; }
    ui_box() { printf 'BOX:%s\n' "$*"; }
    ui_choose() { printf '%s\n' "Configure hardware transcoding"; }
    offer_answer="$(_stage3_offer 2>"$offer_stderr")"
    assert_eq "Configure hardware transcoding" "$offer_answer" "S3-01: offer stdout contains only selected answer"
    assert_contains "$(cat "$offer_stderr")" "Detected GPU: nvidia" "S3-01: offer explains detected GPU outside captured answer"
    rm -f "$offer_stderr"
    unset -f ui_section ui_box ui_choose
    unset GPU_TYPE offer_answer offer_stderr
fi

if type stage3_verify_retry_choices >/dev/null 2>&1; then
    retry_choices="$(stage3_verify_retry_choices)"
    assert_contains "$retry_choices" "Retry verification" "S3-08: verification failure offers retry"
    assert_contains "$retry_choices" "Use software transcoding" "S3-08: verification failure offers software fallback"
    assert_contains "$retry_choices" "Skip for now" "S3-08: verification failure offers skip"
else
    skip "S3-08: verification retry choices pending Stage 3 controller"
fi

tell_more="$(stage3_tell_me_more_copy)"
if [[ "$tell_more" == "__not_implemented__" ]]; then
    skip "S3-01: tell-me-more copy pending Stage 3 controller"
else
    assert_contains "$tell_more" "Intel" "S3-01: tell-me-more covers Intel"
    assert_contains "$tell_more" "AMD" "S3-01: tell-me-more covers AMD"
    assert_contains "$tell_more" "NVIDIA" "S3-01: tell-me-more covers NVIDIA"
    assert_contains "$tell_more" "reboot" "S3-01: tell-me-more explains NVIDIA reboot"
fi

skip_copy="$(stage3_skip_summary_copy)"
if [[ "$skip_copy" == "__not_implemented__" ]]; then
    skip "S3-09: skip copy pending Stage 3 controller"
else
    if [[ "$skip_copy" == *"./setup.sh --transcoding"* ]]; then
        assert_contains "$skip_copy" "Hardware transcoding skipped. Jellyfin will use software transcoding. Run ./setup.sh --transcoding to try again." "REC-03: skip copy names transcoding recovery command"
    else
        skip "REC-03: skip copy names ./setup.sh --transcoding pending recovery hook"
    fi
fi

stage3_path="$REPO_ROOT/scripts/setup/stages/stage3.sh"
if [[ -f "$stage3_path" ]]; then
    stage3_source="$(cat "$stage3_path")"
    assert_contains "$stage3_source" "run_stage3()" "S3-01: run_stage3 controller exists"
    assert_contains "$stage3_source" "Hardware transcoding skipped (no supported GPU detected)." "S3-01: no-GPU skip copy"
    assert_contains "$stage3_source" "install_intel_drivers" "S3-05: Intel branch calls existing installer"
    assert_contains "$stage3_source" "install_amd_drivers" "S3-06: AMD branch calls existing installer"
    assert_contains "$stage3_source" "install_nvidia_drivers" "S3-02: NVIDIA branch calls existing installer"
    assert_contains "$stage3_source" "stage3_set_gpu_env" "S3-07: Stage 3 owns Jellyfin GPU env writes"
    assert_contains "$stage3_source" "qsv" "S3-07: Intel encoder is qsv"
    assert_contains "$stage3_source" "vaapi" "S3-07: AMD encoder is vaapi"
    assert_contains "$stage3_source" ".nvidia-finalize-pending" "S3-07: NVIDIA pre-reboot writes finalize marker"
    assert_contains "$stage3_source" "stage3_verify_transcode_evidence" "S3-08: vendor branches call transcode evidence helper"
    assert_contains "$stage3_source" 'stage3_set_gpu_env "none"' "S3-08: failed proof falls back to software"
    assert_contains "$stage3_source" "print_final_summary" "FIN-01: Stage 3 terminal paths print final summary"
else
    skip "S3-01/S3-08: Stage 3 controller source checks pending implementation"
fi

setup_source="$(sed -n '1,760p' "$REPO_ROOT/setup.sh")"
stage1_source="$(cat "$REPO_ROOT/scripts/setup/stages/stage1.sh")"
assert_contains "$setup_source" "stash_gpu_type" "PRE-07: setup stashes detected GPU type"
assert_contains "$stage1_source" 'generate_override "none"' "S3-07: Stage 1 starts baseline stack without GPU runtime override"
if [[ -f "$stage3_path" && "$setup_source" == *"install_nvidia_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_intel_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_amd_drivers"*"run_wizard"* ]]; then
    fail "S3-01: setup.sh does not run old GPU install path before Stage 3"
elif [[ -f "$stage3_path" ]]; then
    pass "S3-01: setup.sh does not run old GPU install path before Stage 3"
else
    skip "S3-01: setup legacy GPU path check pending Stage 3 controller"
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }

source "$REPO_ROOT/scripts/setup/env_gen.sh"

env_val_from() {
    local env_path="$1"
    local key="$2"
    python3 - "$env_path" "$key" <<'PY'
import pathlib
import sys

env_path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
for line in env_path.read_text().splitlines():
    if line.startswith(key + "="):
        value = line.split("=", 1)[1]
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        print(value, end="")
        break
PY
}

seed_write_env_vars() {
    SCRIPT_DIR="$TMP_ROOT/env-$1"
    mkdir -p "$SCRIPT_DIR/config/ddns-updater"
    _ENV_TZ="Etc/UTC"
    _ENV_PUID="$(id -u)"
    _ENV_PGID="$(id -g)"
    _ENV_HOST_ADDRESS="192.168.1.10"
    _WIZ_TZ="Etc/UTC"
    _WIZ_DATA_DIR="/data"
    _WIZ_ADMIN_USER="admin"
    _WIZ_ADMIN_PW="GeneratedPassword123"
    _WIZ_ADMIN_EMAIL="owner@gpu.test"
    _WIZ_DOMAIN=""
    _WIZ_WG_HOST="example.com"
    _WIZ_WG_PORT="51820"
    _WIZ_WG_DNS="1.1.1.1"
    _WIZ_WG_ACCESS_TIER="full-lan"
    _WIZ_WG_LAN_CIDR="192.168.1.0/24"
    _WIZ_WG_SERVER_LAN_IP="192.168.1.10"
    _WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
    _WIZ_WG_PER_CLIENT_FIREWALL="true"
    _WIZ_WG_INIT_PASSWORD=""
    _WIZ_TORRENT_PORT="6881"
    _WIZ_DL_LIMIT="0"
    _WIZ_UL_LIMIT="0"
    _WIZ_BAZARR_ENABLED="false"
    _WIZ_SMB_ENABLED="false"
    unset SONARR_API_KEY RADARR_API_KEY JELLYFIN_API_KEY BAZARR_API_KEY JELLYSEERR_API_KEY
    unset PORTAINER_API_KEY BESZEL_AGENT_KEY STAGE_1_COMPLETE NPM_LE_SERVER
    unset JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_VENDOR STAGE_3_GPU_ENCODER
    unset STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_DECODE_HEVC_10BIT STAGE_3_GPU_DECODE_VP9_10BIT
    unset STAGE_3_GPU_ALLOW_HEVC_ENCODING STAGE_3_GPU_ALLOW_AV1_ENCODING STAGE_3_GPU_RENDER_DEVICE
}

for detected_gpu in nvidia intel amd; do
    seed_write_env_vars "$detected_gpu-unverified"
    GPU_TYPE="$detected_gpu"
    write_env >/dev/null
    assert_eq "none" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "S3-07: detected $detected_gpu is not published before Stage 3 completion"
done

seed_write_env_vars "preserve-complete"
cat > "$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_GPU=intel
STAGE_3_GPU_STATE=complete
STAGE_3_GPU_VENDOR=intel
STAGE_3_GPU_ENCODER=qsv
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc,vp9
STAGE_3_GPU_DECODE_HEVC_10BIT=true
STAGE_3_GPU_DECODE_VP9_10BIT=true
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
ENV
GPU_TYPE="intel"
write_env >/dev/null
assert_eq "intel" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "S3-07: completed Stage 3 preserves Jellyfin GPU"
assert_eq "complete" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_STATE)" "S3-07: Stage 3 state is preserved"
assert_eq "qsv" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_ENCODER)" "S3-07: Stage 3 encoder is preserved"
assert_eq "h264,hevc,vp9" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_HW_DECODING_CODECS)" "S3-07: completed Stage 3 preserves hardware decode codec capabilities"
assert_eq "true" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_ALLOW_HEVC_ENCODING)" "S3-07: completed Stage 3 preserves HEVC encode capability"
assert_eq "/dev/dri/renderD129" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_RENDER_DEVICE)" "S3-07: completed Stage 3 preserves render device"

seed_write_env_vars "discard-pending"
cat > "$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_GPU=nvidia
STAGE_3_GPU_STATE=pending
STAGE_3_GPU_VENDOR=nvidia
STAGE_3_GPU_ENCODER=nvenc
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
ENV
GPU_TYPE="nvidia"
write_env >/dev/null
assert_eq "none" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "S3-07: pending NVIDIA does not publish NVENC before finalize"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_HW_DECODING_CODECS)" "S3-07: pending Stage 3 does not preserve codec capabilities"

SCRIPT_DIR="$TMP_ROOT/fallback-api-key"
mkdir -p "$SCRIPT_DIR"
cat > "$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_API_KEY='from-env-file'
ENV
curl_auth_header=""
curl_posted_body=""
curl() {
    local next_is_header=false
    local is_post=false
    local next_is_data=false
    for arg in "$@"; do
        if [[ "$next_is_header" == "true" ]]; then
            if [[ "$arg" == Authorization:* ]]; then
                curl_auth_header="$arg"
            fi
            next_is_header=false
            continue
        fi
        if [[ "$next_is_data" == "true" ]]; then
            curl_posted_body="$arg"
            next_is_data=false
            continue
        fi
        case "$arg" in
            -H) next_is_header=true ;;
            -X) is_post=true ;;
            -d) next_is_data=true ;;
        esac
    done
    if [[ "$is_post" == "true" ]]; then
        return 0
    fi
    printf '%s\n' '{"HardwareAccelerationType":"qsv","EnableHardwareEncoding":true}'
}

assert_eq "from-env-file" "$(_stage3_jellyfin_api_key)" "S3-08: fallback API key reader strips .env quotes"
if _stage3_disable_jellyfin_hardware && [[ "$curl_auth_header" == *"from-env-file"* ]] && [[ "$curl_posted_body" == *'"HardwareAccelerationType": "none"'* ]]; then
    pass "S3-08: fallback disable reads Jellyfin API key from .env"
else
    fail "S3-08: fallback disable reads Jellyfin API key from .env" "auth='$curl_auth_header' body='$curl_posted_body'"
fi
unset -f curl

software_verify_response='{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'
curl() {
    printf '%s\n' "$software_verify_response"
}
if _stage3_encoder_disabled qsv; then
    pass "S3-08: fallback verification accepts full Jellyfin software mode"
else
    fail "S3-08: fallback verification accepts full Jellyfin software mode"
fi
software_verify_response='{"HardwareAccelerationType":"vaapi","EnableHardwareEncoding":true}'
if _stage3_encoder_disabled qsv; then
    fail "S3-08: fallback verification rejects sibling hardware backend"
else
    pass "S3-08: fallback verification rejects sibling hardware backend"
fi
software_verify_response='{"HardwareAccelerationType":"none","EnableHardwareEncoding":true}'
if _stage3_encoder_disabled qsv; then
    fail "S3-08: fallback verification rejects half-disabled hardware encoding"
else
    pass "S3-08: fallback verification rejects half-disabled hardware encoding"
fi
unset -f curl
unset software_verify_response

SCRIPT_DIR="$TMP_ROOT/runtime-override"
mkdir -p "$SCRIPT_DIR"
runtime_override_gpu=""
runtime_override_order=()
unset HOST_MEMORY_MB
detect_host_memory() { runtime_override_order+=(detect_host_memory); HOST_MEMORY_MB=4096; }
generate_override() { runtime_override_order+=(generate_override); runtime_override_gpu="$1"; }
docker() { return 42; }
if _stage3_apply_runtime_override "nvidia"; then
    fail "S3-08: failed Jellyfin recreate blocks GPU completion"
else
    assert_eq "detect_host_memory generate_override" "${runtime_override_order[*]}" "S3-08: runtime override initializes host memory before generation"
    assert_eq "nvidia" "$runtime_override_gpu" "S3-08: runtime override writes requested GPU before recreate"
    pass "S3-08: failed Jellyfin recreate blocks GPU completion"
fi
unset -f detect_host_memory generate_override docker
unset HOST_MEMORY_MB

gpu_render_device_for_vendor() {
    printf '%s\n' "/dev/dri/renderD128"
}
stage3_render_device_exists() {
    case "$1" in
        /dev/dri/renderD128|/dev/dri/renderD129|/dev/dri/renderD131) return 0 ;;
        *) return 1 ;;
    esac
}
stage3_render_device_vendor_matches() {
    [[ "$1" != "/dev/dri/renderD131" ]]
}
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
assert_eq "/dev/dri/renderD129" "$(stage3_resolve_render_device intel)" "S3-08: persisted render device wins over vendor auto-detection"
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD130
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "S3-08: stale persisted render device is ignored"
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD131
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "S3-08: vendor-mismatched persisted render device is ignored"
STAGE_3_GPU_RENDER_DEVICE=../../renderD129
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "S3-08: unsafe persisted render device is ignored"
unset -f gpu_render_device_for_vendor
unset -f stage3_render_device_exists stage3_render_device_vendor_matches
unset STAGE_3_GPU_RENDER_DEVICE

source "$REPO_ROOT/scripts/setup/gpu.sh"
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
gpu_render_device_for_vendor() {
    printf '%s\n' "/dev/dri/renderD128"
}
gpu_render_device_exists() {
    [[ "$1" == "/dev/dri/renderD129" ]]
}
gpu_render_device_vendor_matches() {
    return 0
}
stage3_render_device_exists() {
    return 1
}
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
assert_eq "/dev/dri/renderD129" "$(stage3_resolve_render_device intel)" "S3-08: production source order uses shared persisted render device helper"
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
unset -f gpu_persisted_render_device gpu_render_device_for_vendor gpu_render_device_exists gpu_render_device_vendor_matches
unset STAGE_3_GPU_RENDER_DEVICE

SCRIPT_DIR="$TMP_ROOT/transcode-retry"
mkdir -p "$SCRIPT_DIR"
gpu_env_calls=()
verify_attempts=0
runtime_calls=0
configure_calls=0
probe_calls=0
summary_calls=0
ui_choose() { printf '%s\n' "Retry verification"; }
ui_log() { :; }
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); }
_stage3_apply_runtime_override() { runtime_calls=$((runtime_calls + 1)); return 0; }
stage3_probe_capabilities() { probe_calls=$((probe_calls + 1)); return 0; }
_stage3_configure_jellyfin() { configure_calls=$((configure_calls + 1)); return 0; }
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() {
    verify_attempts=$((verify_attempts + 1))
    [[ "$verify_attempts" -ge 2 ]]
}
print_final_summary() { summary_calls=$((summary_calls + 1)); }
if _stage3_configure_and_verify "intel" "qsv" "Intel Quick Sync configured and verified."; then
    pass "S3-08: verification retry can recover before fallback"
else
    fail "S3-08: verification retry can recover before fallback"
fi
assert_eq "2" "$verify_attempts" "S3-08: retry path reruns transcode evidence"
assert_eq "2" "$runtime_calls" "S3-08: retry path reapplies runtime override"
assert_eq "2" "$probe_calls" "S3-08: retry path reruns capability probes"
assert_eq "2" "$configure_calls" "S3-08: retry path reruns Jellyfin configure"
assert_contains "${gpu_env_calls[*]}" "intel:complete:intel:qsv" "S3-08: successful retry marks GPU complete"
assert_eq "1" "$summary_calls" "S3-08: successful retry prints final summary once"
unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence print_final_summary
unset gpu_env_calls verify_attempts runtime_calls probe_calls configure_calls summary_calls

gpu_env_calls=()
runtime_calls=()
disable_calls=0
encoder_disabled_arg=""
SCRIPT_DIR="$TMP_ROOT/skip-after-failed-proof"
mkdir -p "$SCRIPT_DIR"
stage3_write_nvidia_marker >/dev/null 2>&1
ui_choose() { printf '%s\n' "Skip for now"; }
ui_log() { :; }
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); }
_stage3_apply_runtime_override() { runtime_calls+=("$1"); return 0; }
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
_stage3_disable_jellyfin_hardware() { disable_calls=$((disable_calls + 1)); return 0; }
_stage3_encoder_disabled() { encoder_disabled_arg="$1"; return 0; }
print_final_summary() { :; }
if _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified."; then
    fail "S3-08: skip after verification failure does not mark GPU complete"
else
    pass "S3-08: skip after verification failure does not mark GPU complete"
fi
assert_eq "1" "$disable_calls" "S3-08: skip after failed verification disables Jellyfin hardware acceleration"
assert_eq "nvenc" "$encoder_disabled_arg" "S3-08: skip verifies Jellyfin software mode after disable"
assert_contains "${gpu_env_calls[*]}" "none:skipped::" "S3-08: skip records software transcoding state"
assert_contains "${runtime_calls[*]}" "none" "S3-08: skip removes GPU runtime override"
if stage3_marker_exists; then
    fail "S3-08: skip after failed verification clears stale NVIDIA marker"
else
    pass "S3-08: skip after failed verification clears stale NVIDIA marker"
fi
unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence _stage3_disable_jellyfin_hardware _stage3_encoder_disabled print_final_summary
unset -f stage3_probe_capabilities
unset gpu_env_calls runtime_calls disable_calls encoder_disabled_arg

for top_level_skip_path in "no supported GPU" "initial Skip for now"; do
    gpu_env_calls=()
    runtime_calls=()
    disable_calls=0
    software_verify_calls=0
    summary_calls=0
    SCRIPT_DIR="$TMP_ROOT/top-level-${top_level_skip_path// /-}"
    mkdir -p "$SCRIPT_DIR"
    stage3_write_nvidia_marker >/dev/null 2>&1
    GPU_TYPE=intel
    JELLYFIN_GPU=intel
    ui_log() { :; }
    ui_banner() { :; }
    _stage3_offer() { printf '%s\n' "Skip for now"; }
    stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); JELLYFIN_GPU="$1"; return 0; }
    _stage3_disable_jellyfin_hardware() { disable_calls=$((disable_calls + 1)); return 0; }
    _stage3_encoder_disabled() { software_verify_calls=$((software_verify_calls + 1)); return 0; }
    _stage3_apply_runtime_override() { runtime_calls+=("$1"); return 0; }
    print_final_summary() { summary_calls=$((summary_calls + 1)); }

    if [[ "$top_level_skip_path" == "no supported GPU" ]]; then
        GPU_TYPE=none
    fi

    run_stage3
    assert_contains "${gpu_env_calls[*]}" "none:skipped::" "S3-08: top-level $top_level_skip_path records skipped state"
    assert_eq "1" "$disable_calls" "S3-08: top-level $top_level_skip_path disables Jellyfin hardware"
    assert_eq "1" "$software_verify_calls" "S3-08: top-level $top_level_skip_path verifies Jellyfin software mode"
    assert_contains "${runtime_calls[*]}" "none" "S3-08: top-level $top_level_skip_path removes GPU runtime override"
    assert_eq "1" "$summary_calls" "S3-08: top-level $top_level_skip_path prints final summary once"
    if stage3_marker_exists; then
        fail "S3-08: top-level $top_level_skip_path clears stale NVIDIA marker"
    else
        pass "S3-08: top-level $top_level_skip_path clears stale NVIDIA marker"
    fi

    unset -f ui_log ui_banner _stage3_offer stage3_set_gpu_env _stage3_disable_jellyfin_hardware _stage3_encoder_disabled _stage3_apply_runtime_override print_final_summary
    unset gpu_env_calls runtime_calls disable_calls software_verify_calls summary_calls GPU_TYPE JELLYFIN_GPU
done

for failed_vendor in intel amd nvidia; do
    fallback_args=()
    verify_calls=0
    configure_calls=0
    GPU_TYPE="$failed_vendor"
    NEEDS_REBOOT=false
    ui_log() { :; }
    ui_banner() { :; }
    _stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
    # NVIDIA now asks a driver-management mode first; force Unlock so the mocked
    # install_nvidia_drivers below is the installer under test. nvidia_driver_source
    # is mocked to "none" so the real Standard→Unlock purge path is never reached.
    _stage3_choose_nvidia_mode() { printf 'unlock'; }
    nvidia_driver_source() { printf 'none'; }
    install_intel_drivers() { [[ "$failed_vendor" != "intel" ]]; }
    install_amd_drivers() { [[ "$failed_vendor" != "amd" ]]; }
    install_nvidia_drivers() { [[ "$failed_vendor" != "nvidia" ]]; }
    verify_gpu_usable() { verify_calls=$((verify_calls + 1)); return 0; }
    _stage3_fallback() { fallback_args+=("$1:$2"); GPU_TYPE=none; return 0; }
    _stage3_configure_intel() { configure_calls=$((configure_calls + 1)); return 0; }
    _stage3_configure_and_verify() { configure_calls=$((configure_calls + 1)); return 0; }
    stage3_write_nvidia_marker() { configure_calls=$((configure_calls + 1)); return 0; }
    stage3_prompt_nvidia_reboot() { configure_calls=$((configure_calls + 1)); return 0; }

    run_stage3

    case "$failed_vendor" in
        intel) expected_fallback="intel:qsv" ;;
        amd) expected_fallback="amd:vaapi" ;;
        nvidia) expected_fallback="nvidia:nvenc" ;;
    esac
    assert_contains "${fallback_args[*]}" "$expected_fallback" "S3-08: $failed_vendor installer failure falls back to software"
    assert_eq "none" "$GPU_TYPE" "S3-08: $failed_vendor installer failure downgrades GPU type"
    assert_eq "0" "$verify_calls" "S3-08: $failed_vendor installer failure skips GPU verification"
    assert_eq "0" "$configure_calls" "S3-08: $failed_vendor installer failure skips hardware configure/reboot path"

    unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source install_intel_drivers install_amd_drivers install_nvidia_drivers verify_gpu_usable _stage3_fallback _stage3_configure_intel _stage3_configure_and_verify stage3_write_nvidia_marker stage3_prompt_nvidia_reboot
    unset fallback_args verify_calls configure_calls GPU_TYPE NEEDS_REBOOT expected_fallback
done

GPU_TYPE=nvidia
NEEDS_REBOOT=false
prepare_calls=0
install_calls=0
configured_mode=""
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_mode() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() { prepare_calls=$((prepare_calls + 1)); return 0; }
install_nvidia_drivers() { install_calls=$((install_calls + 1)); return 0; }
apply_nvidia_patch() { return 0; }
verify_gpu_usable() { return 0; }
_stage3_configure_and_verify() { configured_mode="${5:-}"; return 0; }
_stage3_fallback() { fail "S3-08: Standard→Unlock conversion should not fall back when prepare/install succeed"; }
run_stage3
assert_eq "1" "$prepare_calls" "S3-08: Standard→Unlock conversion prepares Debian driver removal"
assert_eq "1" "$install_calls" "S3-08: Standard→Unlock conversion runs patch-managed installer after prepare"
assert_eq "unlock" "$configured_mode" "S3-08: Standard→Unlock conversion records Unlock mode"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source \
    prepare_nvidia_debian_to_unlock install_nvidia_drivers apply_nvidia_patch verify_gpu_usable \
    _stage3_configure_and_verify _stage3_fallback
unset GPU_TYPE NEEDS_REBOOT prepare_calls install_calls configured_mode

GPU_TYPE=nvidia
NEEDS_REBOOT=false
prepare_calls=0
install_calls=0
marker_args=""
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_mode() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() { prepare_calls=$((prepare_calls + 1)); NEEDS_REBOOT=true; return 0; }
install_nvidia_drivers() { install_calls=$((install_calls + 1)); return 0; }
stage3_set_gpu_env() { return 0; }
stage3_write_nvidia_marker() { marker_args="$1:$2"; return 0; }
stage3_prompt_nvidia_reboot() { return 0; }
_stage3_fallback() { fail "S3-08: Standard→Unlock conversion reboot path should not fall back"; }
run_stage3
assert_eq "1" "$prepare_calls" "S3-08: Standard→Unlock conversion can queue reboot after prepare"
assert_eq "0" "$install_calls" "S3-08: Standard→Unlock reboot path defers patch-managed install"
assert_eq "unlock:run" "$marker_args" "S3-08: Standard→Unlock reboot path writes Unlock run marker"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source \
    prepare_nvidia_debian_to_unlock install_nvidia_drivers stage3_set_gpu_env \
    stage3_write_nvidia_marker stage3_prompt_nvidia_reboot _stage3_fallback
unset GPU_TYPE NEEDS_REBOOT prepare_calls install_calls marker_args

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/deferred-nvidia-reboot"
mkdir -p "$SCRIPT_DIR"
GPU_TYPE=nvidia
NEEDS_REBOOT=false
prompt_calls=0
summary_calls=0
gpu_env_calls=()
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_mode() { printf 'unlock'; }
nvidia_driver_source() { printf 'none'; }
install_nvidia_drivers() { NEEDS_REBOOT=true; return 0; }
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); return 0; }
stage3_prompt_nvidia_reboot() { prompt_calls=$((prompt_calls + 1)); }
print_final_summary() { summary_calls=$((summary_calls + 1)); }
run_hardware_transcoding_addon
assert_eq "0" "$prompt_calls" "S3-01: wizard hardware add-on defers NVIDIA reboot prompt"
assert_eq "0" "$summary_calls" "S3-01: wizard hardware add-on suppresses interim final summary"
assert_contains "${gpu_env_calls[*]}" "none:pending:nvidia:nvenc" "S3-01: deferred NVIDIA path records pending transcoding state"
stage3_prompt_pending_nvidia_reboot
assert_eq "1" "$prompt_calls" "FIN-02: final reboot gate prompts for deferred NVIDIA reboot"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source install_nvidia_drivers stage3_set_gpu_env stage3_prompt_nvidia_reboot print_final_summary
unset GPU_TYPE NEEDS_REBOOT prompt_calls summary_calls gpu_env_calls

prev_script_dir="${SCRIPT_DIR:-}"
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-install-fail"
mkdir -p "$SCRIPT_DIR/.nvidia-tmp"
touch "$SCRIPT_DIR/.nvidia-tmp/pending"
finalize_failure_calls=0
ui_log() { :; }
install_nvidia_drivers() { return 1; }
_stage3_nvidia_finalize_failure() { finalize_failure_calls=$((finalize_failure_calls + 1)); GPU_TYPE=none; return 0; }
stage3_finalize_nvidia
assert_eq "1" "$finalize_failure_calls" "S3-08: NVIDIA finalize installer failure uses finalization failure path"
assert_eq "none" "$GPU_TYPE" "S3-08: NVIDIA finalize installer failure downgrades GPU type"
unset -f ui_log install_nvidia_drivers _stage3_nvidia_finalize_failure
SCRIPT_DIR="$prev_script_dir"
unset finalize_failure_calls GPU_TYPE prev_script_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

for terminal_choice in "Skip for now" "Use software transcoding"; do
    gpu_env_calls=()
    fallback_args=()
    qsv_attempts=0
    vaapi_attempts=0
    GPU_TYPE=intel
    ui_choose() { printf '%s\n' "$terminal_choice"; }
    ui_log() { :; }
    stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); return 0; }
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
    _stage3_fallback() { fallback_args+=("$1:$2"); GPU_TYPE=none; return 0; }
    print_final_summary() { :; }

    _stage3_configure_intel
    assert_eq "1" "$qsv_attempts" "S3-08: Intel QSV failure prompts before terminal choice: $terminal_choice"
    assert_eq "0" "$vaapi_attempts" "S3-08: Intel terminal choice does not try VAAPI: $terminal_choice"
    if [[ "$terminal_choice" == "Skip for now" ]]; then
        assert_contains "${gpu_env_calls[*]}" "none:skipped::" "S3-08: Intel QSV skip records skipped state"
        assert_eq "" "${fallback_args[*]}" "S3-08: Intel QSV skip does not run software fallback"
    else
        assert_contains "${fallback_args[*]}" "intel:qsv" "S3-08: Intel QSV software choice runs software fallback"
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
        if (( qsv_attempts < 2 )); then
            printf '%s\n' "Retry verification"
        else
            printf '%s\n' "$terminal_choice"
        fi
    }
    ui_log() { :; }
    stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); return 0; }
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
    _stage3_fallback() { fallback_args+=("$1:$2"); GPU_TYPE=none; return 0; }
    print_final_summary() { :; }

    _stage3_configure_intel
    assert_eq "2" "$qsv_attempts" "S3-08: Intel QSV retry reaches terminal choice: $terminal_choice"
    assert_eq "0" "$vaapi_attempts" "S3-08: Intel retry then terminal choice does not try VAAPI: $terminal_choice"
    if [[ "$terminal_choice" == "Skip for now" ]]; then
        assert_contains "${gpu_env_calls[*]}" "none:skipped::" "S3-08: Intel QSV retry then skip records skipped state"
        assert_eq "" "${fallback_args[*]}" "S3-08: Intel QSV retry then skip does not run software fallback"
    else
        assert_contains "${fallback_args[*]}" "intel:qsv" "S3-08: Intel QSV retry then software choice runs software fallback"
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
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); STAGE_3_GPU_ENCODER="$4"; }
_stage3_apply_runtime_override() { runtime_count=$((runtime_count + 1)); return 0; }
stage3_probe_capabilities() { probe_calls=$((probe_calls + 1)); return 0; }
_stage3_configure_jellyfin() { configure_calls=$((configure_calls + 1)); return 0; }
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() {
    verify_calls+=("$1:$2")
    [[ "$2" == "vaapi" ]]
}
print_final_summary() { summary_calls=$((summary_calls + 1)); }
_stage3_configure_intel
assert_contains "${verify_calls[*]}" "intel:qsv" "S3-08: Intel hardware flow tries QSV first"
assert_contains "${verify_calls[*]}" "intel:vaapi" "S3-08: Intel hardware flow tries VAAPI after QSV fails"
assert_contains "${gpu_env_calls[*]}" "intel:complete:intel:vaapi" "S3-08: Intel VAAPI fallback can mark hardware transcoding complete"
assert_eq "4" "$runtime_count" "S3-08: Intel fallback applies runtime for three QSV attempts plus VAAPI"
assert_eq "4" "$probe_calls" "S3-08: Intel fallback probes capabilities for each hardware attempt"
assert_eq "4" "$configure_calls" "S3-08: Intel fallback configures Jellyfin for each hardware attempt"
assert_eq "1" "$summary_calls" "S3-08: Intel VAAPI fallback prints final summary once"
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
assert_contains "$api_fetch_post_body" '"HardwareAccelerationType": "vaapi"' "S3-08: Intel VAAPI fallback can switch Jellyfin from QSV to VAAPI during pending verification"
assert_contains "$api_fetch_post_body" '"VaapiDevice": "/dev/dri/renderD129"' "S3-08: Intel VAAPI fallback writes selected VAAPI render device"
assert_contains "$api_fetch_post_body" '"HardwareDecodingCodecs": ["h264", "hevc", "vp9"]' "S3-08: Jellyfin encoding applies probed decode codec list"
assert_contains "$api_fetch_post_body" '"AllowHevcEncoding": true' "S3-08: Jellyfin encoding enables probed HEVC encoding"
assert_contains "$api_fetch_post_body" '"AllowAv1Encoding": false' "S3-08: Jellyfin encoding disables unproven AV1 encoding"
assert_contains "$api_fetch_post_body" '"EnableDecodingColorDepth10Hevc": true' "S3-08: Jellyfin encoding applies HEVC 10-bit decode capability"
assert_contains "$api_fetch_post_body" '"EnableDecodingColorDepth10Vp9": true' "S3-08: Jellyfin encoding applies VP9 10-bit decode capability"
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
JELLYFIN_GPU=intel
STAGE_3_GPU_STATE=complete
STAGE_3_GPU_ENCODER=qsv
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
STAGE_3_GPU_DECODE_HEVC_10BIT=true
STAGE_3_GPU_DECODE_VP9_10BIT=false
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
configure_jellyfin_encoding "http://localhost:8096" "test-token"
assert_eq "" "$api_fetch_post_body" "S3-08: completed Stage 3 does not overwrite manual Jellyfin codec drift"
assert_contains "$drift_warn" "Leaving manual Jellyfin settings unchanged" "S3-08: completed hardware proof warns instead of reconciling codec drift"
unset -f api_fetch log_warn
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
assert_contains "$api_fetch_post_body" '"QsvDevice": "/dev/dri/renderD129"' "S3-08: Intel QSV writes selected QSV render device"
unset -f api_fetch
unset api_fetch_post_body JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_ENCODER STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_RENDER_DEVICE

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/stage3-encoding-verify"
mkdir -p "$SCRIPT_DIR"
cat > "$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_API_KEY=verify-token
ENV
JELLYFIN_API_KEY=verify-token
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
STAGE_3_GPU_DECODE_HEVC_10BIT=true
STAGE_3_GPU_DECODE_VP9_10BIT=false
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
curl() {
    printf '%s\n' '{"HardwareAccelerationType":"qsv","EnableHardwareEncoding":true,"HardwareDecodingCodecs":["h264","hevc"],"EnableDecodingColorDepth10Hevc":true,"EnableDecodingColorDepth10Vp9":false,"AllowHevcEncoding":true,"AllowAv1Encoding":false,"QsvDevice":"/dev/dri/renderD129"}'
}
if _stage3_verify_jellyfin_encoding qsv 2>/dev/null; then
    pass "S3-08: Stage 3 verifies Jellyfin encoding API state before completion"
else
    fail "S3-08: Stage 3 verifies Jellyfin encoding API state before completion"
fi
curl() {
    printf '%s\n' '{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'
}
if _stage3_verify_jellyfin_encoding qsv 2>/dev/null; then
    fail "S3-08: Stage 3 rejects unconfigured Jellyfin encoding before completion"
else
    pass "S3-08: Stage 3 rejects unconfigured Jellyfin encoding before completion"
fi
unset -f curl
unset JELLYFIN_API_KEY STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_DECODE_HEVC_10BIT STAGE_3_GPU_DECODE_VP9_10BIT
unset STAGE_3_GPU_ALLOW_HEVC_ENCODING STAGE_3_GPU_ALLOW_AV1_ENCODING STAGE_3_GPU_RENDER_DEVICE

verify_attempts=0
sleep_calls=0
_stage3_verify_jellyfin_encoding() {
    verify_attempts=$((verify_attempts + 1))
    [[ "$verify_attempts" -ge 2 ]]
}
sleep() { sleep_calls=$((sleep_calls + 1)); }
STAGE3_ENCODING_VERIFY_TIMEOUT=4
STAGE3_ENCODING_VERIFY_INTERVAL=1
if _stage3_wait_for_jellyfin_encoding qsv; then
    pass "S3-08: Stage 3 waits for Jellyfin encoding API after recreate"
else
    fail "S3-08: Stage 3 waits for Jellyfin encoding API after recreate"
fi
assert_eq "2" "$verify_attempts" "S3-08: Stage 3 retries encoding verification once ready"
assert_eq "1" "$sleep_calls" "S3-08: Stage 3 retry wait sleeps between attempts"
verify_attempts=0
sleep_calls=0
_stage3_verify_jellyfin_encoding() {
    verify_attempts=$((verify_attempts + 1))
    return 1
}
STAGE3_ENCODING_VERIFY_TIMEOUT=1
STAGE3_ENCODING_VERIFY_INTERVAL=1
if _stage3_wait_for_jellyfin_encoding qsv; then
    fail "S3-08: Stage 3 encoding wait fails after timeout"
else
    pass "S3-08: Stage 3 encoding wait fails after timeout"
fi
assert_eq "2" "$verify_attempts" "S3-08: Stage 3 timeout performs bounded verification attempts"
unset -f _stage3_verify_jellyfin_encoding sleep
unset verify_attempts sleep_calls STAGE3_ENCODING_VERIFY_TIMEOUT STAGE3_ENCODING_VERIFY_INTERVAL

scenario_end "$CURRENT_SCENARIO"
summary
