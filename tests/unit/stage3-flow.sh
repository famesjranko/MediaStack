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
# gpu_brand_label (used by _stage3_offer for the "Detected GPU" box brand casing)
# now lives in gpu.sh, but sourcing all of gpu.sh here would clobber the
# gpu_render_device_* helpers that the render-device tests below deliberately drive
# without gpu.sh loaded. Provide just the brand-label helper for the offer test.
[[ -f "$REPO_ROOT/scripts/setup/stack.sh" ]] && source "$REPO_ROOT/scripts/setup/stack.sh"
if ! type gpu_brand_label >/dev/null 2>&1; then
    gpu_brand_label() {
        case "${1:-}" in
            nvidia) printf 'NVIDIA' ;;
            amd) printf 'AMD' ;;
            intel) printf 'Intel' ;;
            none | "") printf 'none' ;;
            *) printf '%s' "$1" ;;
        esac
    }
fi

set +e
set +u

if ! type stage3_offer_choices >/dev/null 2>&1; then
    stage3_offer_choices() { printf '__not_implemented__'; }
fi

GPU_CANDIDATES=(nvidia amd intel)
GPU_TYPE=amd
# ui_section (section-header rendering) lives in scripts/lib/ui.sh, which this
# unit test does not source. Stub it globally as a silent no-op so the real
# stage3 menu functions under test don't spew "ui_section: command not found".
ui_section() { :; }

GPU_MENU_CAPTURE=$(mktemp)
ui_choose() {
    shift
    printf '%s\n%s' "${UI_CHOOSE_DEFAULT_INDEX:-}" "$*" >"$GPU_MENU_CAPTURE"
    printf '%s\n' "Intel — Quick Sync"
}
_stage3_choose_gpu_vendor
assert_eq "intel" "$GPU_TYPE" "multi-GPU menu routes to the selected vendor"
assert_eq "2" "$(head -1 "$GPU_MENU_CAPTURE")" "configured available vendor is the multi-GPU default"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "NVIDIA — NVENC" "multi-GPU menu includes detected NVIDIA"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "AMD — VAAPI" "multi-GPU menu includes detected AMD"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "Intel — Quick Sync" "multi-GPU menu includes detected Intel"
unset -f ui_choose
rm -f "$GPU_MENU_CAPTURE"
unset GPU_CANDIDATES GPU_TYPE GPU_MENU_CAPTURE
if ! type stage3_tell_me_more_copy >/dev/null 2>&1; then
    stage3_tell_me_more_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_skip_summary_copy >/dev/null 2>&1; then
    stage3_skip_summary_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_set_gpu_env >/dev/null 2>&1; then
    stage3_set_gpu_env() {
        printf '__not_implemented__'
        return 1
    }
fi

offer_choices="$(stage3_offer_choices)"
if [[ "$offer_choices" == "__not_implemented__" ]]; then
    skip "offer choices pending Stage 3 controller"
else
    assert_contains "$offer_choices" "Configure hardware transcoding" "offer includes Configure hardware transcoding"
    assert_contains "$offer_choices" "Skip for now" "offer includes Skip for now"
    assert_contains "$offer_choices" "Tell me more" "offer includes Tell me more"
fi

if type _stage3_offer >/dev/null 2>&1; then
    offer_stderr="$(mktemp)"
    GPU_TYPE=nvidia
    ui_section() { printf 'SECTION:%s\n' "$*"; }
    ui_box() { printf 'BOX:%s\n' "$*"; }
    ui_choose() { printf '%s\n' "Configure hardware transcoding"; }
    offer_answer="$(_stage3_offer 2>"$offer_stderr")"
    assert_eq "Configure hardware transcoding" "$offer_answer" "offer stdout contains only selected answer"
    assert_contains "$(cat "$offer_stderr")" "Detected GPU: NVIDIA" "offer explains detected GPU outside captured answer"
    rm -f "$offer_stderr"
    unset -f ui_box ui_choose
    ui_section() { :; } # restore the global no-op (this block overrode it above)
    unset GPU_TYPE offer_answer offer_stderr
fi

if type stage3_verify_retry_choices >/dev/null 2>&1; then
    retry_choices="$(stage3_verify_retry_choices)"
    assert_contains "$retry_choices" "Retry verification" "verification failure offers retry"
    assert_contains "$retry_choices" "Use software transcoding" "verification failure offers software fallback"
    assert_contains "$retry_choices" "Skip for now" "verification failure offers skip"
else
    skip "verification retry choices pending Stage 3 controller"
fi

tell_more="$(stage3_tell_me_more_copy)"
if [[ "$tell_more" == "__not_implemented__" ]]; then
    skip "tell-me-more copy pending Stage 3 controller"
else
    assert_contains "$tell_more" "Intel" "tell-me-more covers Intel"
    assert_contains "$tell_more" "AMD" "tell-me-more covers AMD"
    assert_contains "$tell_more" "NVIDIA" "tell-me-more covers NVIDIA"
    assert_contains "$tell_more" "reboot" "tell-me-more explains NVIDIA reboot"
fi

skip_copy="$(stage3_skip_summary_copy)"
if [[ "$skip_copy" == "__not_implemented__" ]]; then
    skip "skip copy pending Stage 3 controller"
else
    if [[ "$skip_copy" == *"Manage hardware transcoding"* ]]; then
        assert_contains "$skip_copy" "Hardware transcoding skipped. Jellyfin will use software transcoding. Choose Manage hardware transcoding (GPU) from the menu to try again." "skip copy names transcoding recovery route"
    else
        skip "skip copy names hardware transcoding recovery route pending recovery hook"
    fi
fi

stage3_path="$REPO_ROOT/scripts/setup/stages/stage3.sh"
if [[ -f "$stage3_path" ]]; then
    stage3_source="$(cat "$stage3_path")"
    assert_contains "$stage3_source" "run_stage3()" "run_stage3 controller exists"
    assert_contains "$stage3_source" "Hardware transcoding skipped (no supported GPU detected)." "no-GPU skip copy"
    assert_contains "$stage3_source" "install_intel_drivers" "Intel branch calls existing installer"
    assert_contains "$stage3_source" "install_amd_drivers" "AMD branch calls existing installer"
    assert_contains "$stage3_source" "install_nvidia_drivers" "NVIDIA branch calls existing installer"
    assert_contains "$stage3_source" "stage3_set_gpu_env" "Stage 3 owns Jellyfin GPU env writes"
    assert_contains "$stage3_source" "qsv" "Intel encoder is qsv"
    assert_contains "$stage3_source" "vaapi" "AMD encoder is vaapi"
    assert_contains "$stage3_source" ".nvidia-finalize-pending" "NVIDIA pre-reboot writes finalize marker"
    assert_contains "$stage3_source" "stage3_verify_transcode_evidence" "vendor branches call transcode evidence helper"
    assert_contains "$stage3_source" 'stage3_set_gpu_env "none"' "failed proof falls back to software"
    assert_contains "$stage3_source" "print_final_summary" "Stage 3 terminal paths print final summary"
else
    skip "Stage 3 controller source checks pending implementation"
fi

setup_source="$(sed -n '1,760p' "$REPO_ROOT/setup.sh")"
stage1_source="$(cat "$REPO_ROOT/scripts/setup/stages/stage1.sh")"
assert_contains "$setup_source" "stash_gpu_type" "setup stashes detected GPU type"
assert_contains "$stage1_source" 'generate_override "none"' "Stage 1 starts baseline stack without GPU runtime override"
if [[ -f "$stage3_path" && "$setup_source" == *"install_nvidia_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_intel_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_amd_drivers"*"run_wizard"* ]]; then
    fail "setup.sh does not run old GPU install path before Stage 3"
elif [[ -f "$stage3_path" ]]; then
    pass "setup.sh does not run old GPU install path before Stage 3"
else
    skip "setup legacy GPU path check pending Stage 3 controller"
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
    unset SONARR_API_KEY RADARR_API_KEY JELLYFIN_API_KEY BAZARR_API_KEY SEERR_API_KEY
    unset PORTAINER_API_KEY BESZEL_AGENT_KEY STAGE_1_COMPLETE NPM_LE_SERVER
    unset JELLYFIN_GPU STAGE_3_GPU_STATE STAGE_3_GPU_VENDOR STAGE_3_GPU_ENCODER
    unset STAGE_3_GPU_HW_DECODING_CODECS STAGE_3_GPU_DECODE_HEVC_10BIT STAGE_3_GPU_DECODE_VP9_10BIT
    unset STAGE_3_GPU_ALLOW_HEVC_ENCODING STAGE_3_GPU_ALLOW_AV1_ENCODING STAGE_3_GPU_RENDER_DEVICE
}

for detected_gpu in nvidia intel amd; do
    seed_write_env_vars "$detected_gpu-unverified"
    GPU_TYPE="$detected_gpu"
    write_env >/dev/null
    assert_eq "none" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "detected $detected_gpu is not published before Stage 3 completion"
done

seed_write_env_vars "preserve-complete"
cat >"$SCRIPT_DIR/.env" <<'ENV'
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
assert_eq "intel" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "completed Stage 3 preserves Jellyfin GPU"
assert_eq "complete" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_STATE)" "Stage 3 state is preserved"
assert_eq "qsv" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_ENCODER)" "Stage 3 encoder is preserved"
assert_eq "h264,hevc,vp9" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_HW_DECODING_CODECS)" "completed Stage 3 preserves hardware decode codec capabilities"
assert_eq "true" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_ALLOW_HEVC_ENCODING)" "completed Stage 3 preserves HEVC encode capability"
assert_eq "/dev/dri/renderD129" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_RENDER_DEVICE)" "completed Stage 3 preserves render device"

seed_write_env_vars "discard-pending"
cat >"$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_GPU=nvidia
STAGE_3_GPU_STATE=pending
STAGE_3_GPU_VENDOR=nvidia
STAGE_3_GPU_ENCODER=nvenc
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
ENV
GPU_TYPE="nvidia"
write_env >/dev/null
assert_eq "none" "$(env_val_from "$SCRIPT_DIR/.env" JELLYFIN_GPU)" "pending NVIDIA does not publish NVENC before finalize"
assert_eq "" "$(env_val_from "$SCRIPT_DIR/.env" STAGE_3_GPU_HW_DECODING_CODECS)" "pending Stage 3 does not preserve codec capabilities"

SCRIPT_DIR="$TMP_ROOT/fallback-api-key"
mkdir -p "$SCRIPT_DIR"
cat >"$SCRIPT_DIR/.env" <<'ENV'
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

assert_eq "from-env-file" "$(_stage3_jellyfin_api_key)" "fallback API key reader strips .env quotes"
if _stage3_disable_jellyfin_hardware && [[ "$curl_auth_header" == *"from-env-file"* ]] && [[ "$curl_posted_body" == *'"HardwareAccelerationType": "none"'* ]]; then
    pass "fallback disable reads Jellyfin API key from .env"
else
    fail "fallback disable reads Jellyfin API key from .env" "auth='$curl_auth_header' body='$curl_posted_body'"
fi
unset -f curl

software_verify_response='{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'
curl() {
    printf '%s\n' "$software_verify_response"
}
if _stage3_encoder_disabled qsv; then
    pass "fallback verification accepts full Jellyfin software mode"
else
    fail "fallback verification accepts full Jellyfin software mode"
fi
software_verify_response='{"HardwareAccelerationType":"vaapi","EnableHardwareEncoding":true}'
if _stage3_encoder_disabled qsv; then
    fail "fallback verification rejects sibling hardware backend"
else
    pass "fallback verification rejects sibling hardware backend"
fi
software_verify_response='{"HardwareAccelerationType":"none","EnableHardwareEncoding":true}'
if _stage3_encoder_disabled qsv; then
    fail "fallback verification rejects half-disabled hardware encoding"
else
    pass "fallback verification rejects half-disabled hardware encoding"
fi
unset -f curl
unset software_verify_response

SCRIPT_DIR="$TMP_ROOT/runtime-override"
mkdir -p "$SCRIPT_DIR"
runtime_override_gpu=""
runtime_override_order=()
unset HOST_MEMORY_MB
detect_host_memory() {
    runtime_override_order+=(detect_host_memory)
    HOST_MEMORY_MB=4096
}
generate_override() {
    runtime_override_order+=(generate_override)
    runtime_override_gpu="$1"
}
docker() { return 42; }
if _stage3_apply_runtime_override "nvidia"; then
    fail "failed Jellyfin recreate blocks GPU completion"
else
    assert_eq "detect_host_memory generate_override" "${runtime_override_order[*]}" "runtime override initializes host memory before generation"
    assert_eq "nvidia" "$runtime_override_gpu" "runtime override writes requested GPU before recreate"
    pass "failed Jellyfin recreate blocks GPU completion"
fi
unset -f detect_host_memory generate_override docker
unset HOST_MEMORY_MB

gpu_render_device_for_vendor() {
    printf '%s\n' "/dev/dri/renderD128"
}
stage3_render_device_exists() {
    case "$1" in
        /dev/dri/renderD128 | /dev/dri/renderD129 | /dev/dri/renderD131) return 0 ;;
        *) return 1 ;;
    esac
}
stage3_render_device_vendor_matches() {
    [[ "$1" != "/dev/dri/renderD131" ]]
}
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD129
assert_eq "/dev/dri/renderD129" "$(stage3_resolve_render_device intel)" "persisted render device wins over vendor auto-detection"
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD130
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "stale persisted render device is ignored"
STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD131
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "vendor-mismatched persisted render device is ignored"
STAGE_3_GPU_RENDER_DEVICE=../../renderD129
assert_eq "/dev/dri/renderD128" "$(stage3_resolve_render_device intel)" "unsafe persisted render device is ignored"
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
assert_eq "/dev/dri/renderD129" "$(stage3_resolve_render_device intel)" "production source order uses shared persisted render device helper"
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
_stage3_apply_runtime_override() {
    runtime_calls=$((runtime_calls + 1))
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
    verify_attempts=$((verify_attempts + 1))
    [[ "$verify_attempts" -ge 2 ]]
}
print_final_summary() { summary_calls=$((summary_calls + 1)); }
if _stage3_configure_and_verify "intel" "qsv" "Intel Quick Sync configured and verified."; then
    pass "verification retry can recover before fallback"
else
    fail "verification retry can recover before fallback"
fi
assert_eq "2" "$verify_attempts" "retry path reruns transcode evidence"
assert_eq "2" "$runtime_calls" "retry path reapplies runtime override"
assert_eq "2" "$probe_calls" "retry path reruns capability probes"
assert_eq "2" "$configure_calls" "retry path reruns Jellyfin configure"
assert_contains "${gpu_env_calls[*]}" "intel:complete:intel:qsv" "successful retry marks GPU complete"
assert_eq "1" "$summary_calls" "successful retry prints final summary once"
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
_stage3_apply_runtime_override() {
    runtime_calls+=("$1")
    return 0
}
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
_stage3_disable_jellyfin_hardware() {
    disable_calls=$((disable_calls + 1))
    return 0
}
_stage3_encoder_disabled() {
    encoder_disabled_arg="$1"
    return 0
}
print_final_summary() { :; }
if _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified."; then
    fail "skip after verification failure does not mark GPU complete"
else
    pass "skip after verification failure does not mark GPU complete"
fi
assert_eq "1" "$disable_calls" "skip after failed verification disables Jellyfin hardware acceleration"
assert_eq "nvenc" "$encoder_disabled_arg" "skip verifies Jellyfin software mode after disable"
assert_contains "${gpu_env_calls[*]}" "none:skipped::" "skip records software transcoding state"
assert_contains "${runtime_calls[*]}" "none" "skip removes GPU runtime override"
if stage3_marker_exists; then
    fail "skip after failed verification clears stale NVIDIA marker"
else
    pass "skip after failed verification clears stale NVIDIA marker"
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
    stage3_set_gpu_env() {
        gpu_env_calls+=("$1:$2:$3:$4")
        JELLYFIN_GPU="$1"
        return 0
    }
    _stage3_disable_jellyfin_hardware() {
        disable_calls=$((disable_calls + 1))
        return 0
    }
    _stage3_encoder_disabled() {
        software_verify_calls=$((software_verify_calls + 1))
        return 0
    }
    _stage3_apply_runtime_override() {
        runtime_calls+=("$1")
        return 0
    }
    print_final_summary() { summary_calls=$((summary_calls + 1)); }

    if [[ "$top_level_skip_path" == "no supported GPU" ]]; then
        GPU_TYPE=none
    fi

    run_stage3
    assert_contains "${gpu_env_calls[*]}" "none:skipped::" "top-level $top_level_skip_path records skipped state"
    assert_eq "1" "$disable_calls" "top-level $top_level_skip_path disables Jellyfin hardware"
    assert_eq "1" "$software_verify_calls" "top-level $top_level_skip_path verifies Jellyfin software mode"
    assert_contains "${runtime_calls[*]}" "none" "top-level $top_level_skip_path removes GPU runtime override"
    assert_eq "1" "$summary_calls" "top-level $top_level_skip_path prints final summary once"
    if stage3_marker_exists; then
        fail "top-level $top_level_skip_path clears stale NVIDIA marker"
    else
        pass "top-level $top_level_skip_path clears stale NVIDIA marker"
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
    verify_gpu_usable() {
        verify_calls=$((verify_calls + 1))
        return 0
    }
    _stage3_fallback() {
        fallback_args+=("$1:$2")
        GPU_TYPE=none
        return 0
    }
    _stage3_configure_intel() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    _stage3_configure_and_verify() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    stage3_write_nvidia_marker() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    stage3_prompt_nvidia_reboot() {
        configure_calls=$((configure_calls + 1))
        return 0
    }

    run_stage3

    case "$failed_vendor" in
        intel) expected_fallback="intel:qsv" ;;
        amd) expected_fallback="amd:vaapi" ;;
        nvidia) expected_fallback="nvidia:nvenc" ;;
    esac
    assert_contains "${fallback_args[*]}" "$expected_fallback" "$failed_vendor installer failure falls back to software"
    assert_eq "none" "$GPU_TYPE" "$failed_vendor installer failure downgrades GPU type"
    assert_eq "0" "$verify_calls" "$failed_vendor installer failure skips GPU verification"
    assert_eq "0" "$configure_calls" "$failed_vendor installer failure skips hardware configure/reboot path"

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
_stage3_choose_nvidia_action() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() {
    prepare_calls=$((prepare_calls + 1))
    return 0
}
install_nvidia_drivers() {
    install_calls=$((install_calls + 1))
    return 0
}
apply_nvidia_patch() { return 0; }
verify_gpu_usable() { return 0; }
_stage3_configure_and_verify() {
    configured_mode="${5:-}"
    return 0
}
_stage3_fallback() { fail "Standard→Unlock conversion should not fall back when prepare/install succeed"; }
run_stage3
assert_eq "1" "$prepare_calls" "Standard→Unlock conversion prepares Debian driver removal"
assert_eq "1" "$install_calls" "Standard→Unlock conversion runs patch-managed installer after prepare"
assert_eq "unlock" "$configured_mode" "Standard→Unlock conversion records Unlock mode"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_action nvidia_driver_source \
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
_stage3_choose_nvidia_action() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() {
    prepare_calls=$((prepare_calls + 1))
    NEEDS_REBOOT=true
    return 0
}
install_nvidia_drivers() {
    install_calls=$((install_calls + 1))
    return 0
}
stage3_set_gpu_env() { return 0; }
stage3_write_nvidia_marker() {
    marker_args="$1:$2"
    return 0
}
stage3_prompt_nvidia_reboot() { return 0; }
_stage3_fallback() { fail "Standard→Unlock conversion reboot path should not fall back"; }
run_stage3
assert_eq "1" "$prepare_calls" "Standard→Unlock conversion can queue reboot after prepare"
assert_eq "0" "$install_calls" "Standard→Unlock reboot path defers patch-managed install"
assert_eq "unlock:run" "$marker_args" "Standard→Unlock reboot path writes Unlock run marker"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_action nvidia_driver_source \
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
install_nvidia_drivers() {
    NEEDS_REBOOT=true
    return 0
}
stage3_set_gpu_env() {
    gpu_env_calls+=("$1:$2:$3:$4")
    return 0
}
stage3_prompt_nvidia_reboot() { prompt_calls=$((prompt_calls + 1)); }
print_final_summary() { summary_calls=$((summary_calls + 1)); }
run_hardware_transcoding_addon
assert_eq "0" "$prompt_calls" "wizard hardware add-on defers NVIDIA reboot prompt"
assert_eq "0" "$summary_calls" "wizard hardware add-on suppresses interim final summary"
assert_contains "${gpu_env_calls[*]}" "none:pending:nvidia:nvenc" "deferred NVIDIA path records pending transcoding state"
stage3_prompt_pending_nvidia_reboot
assert_eq "1" "$prompt_calls" "final reboot gate prompts for deferred NVIDIA reboot"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source install_nvidia_drivers stage3_set_gpu_env stage3_prompt_nvidia_reboot print_final_summary
unset GPU_TYPE NEEDS_REBOOT prompt_calls summary_calls gpu_env_calls

prev_script_dir="${SCRIPT_DIR:-}"
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-install-fail"
mkdir -p "$SCRIPT_DIR/.nvidia-tmp"
touch "$SCRIPT_DIR/.nvidia-tmp/pending"
finalize_failure_calls=0
ui_log() { :; }
install_nvidia_drivers() { return 1; }
_stage3_nvidia_finalize_failure() {
    finalize_failure_calls=$((finalize_failure_calls + 1))
    GPU_TYPE=none
    return 0
}
stage3_finalize_nvidia
assert_eq "1" "$finalize_failure_calls" "NVIDIA finalize installer failure uses finalization failure path"
assert_eq "none" "$GPU_TYPE" "NVIDIA finalize installer failure downgrades GPU type"
unset -f ui_log install_nvidia_drivers _stage3_nvidia_finalize_failure
SCRIPT_DIR="$prev_script_dir"
unset finalize_failure_calls GPU_TYPE prev_script_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

# Post-reboot NVIDIA finalize: driver verifies + patch applies but the final
# test-transcode proof comes back inconclusive. A verified driver must NOT drop
# to CPU software just because proof-gathering raced the Jellyfin restart.
prev_script_dir="${SCRIPT_DIR:-}"
SCRIPT_DIR="$TMP_ROOT/nvidia-finalize-proof-inconclusive"
mkdir -p "$SCRIPT_DIR"
finalize_failure_calls=0
gpu_env_calls=()
NVIDIA_DRIVER_MODE=unlock
ui_log() { :; }
nvidia-smi() { return 0; }
sudo() { return 0; }
docker() { return 0; }
stage3_marker_driver_mode() { printf 'unlock'; }
stage3_marker_install_source() { printf ''; }
stage3_marker_expected_driver_version() { printf ''; }
apply_nvidia_patch() { return 0; }
verify_gpu_usable() {
    GPU_TYPE=nvidia
    return 0
}
_stage3_apply_runtime_override() { return 0; }
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_wait_for_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
stage3_set_gpu_env() {
    gpu_env_calls+=("$1:$2:$3:$4")
    return 0
}
stage3_remove_nvidia_marker() { :; }
_stage3_print_final_summary() { :; }
_stage3_nvidia_finalize_failure() {
    finalize_failure_calls=$((finalize_failure_calls + 1))
    return 0
}
stage3_finalize_nvidia
assert_eq "0" "$finalize_failure_calls" "inconclusive test transcode does not fall back to software"
assert_contains "${gpu_env_calls[*]}" "nvidia:complete:nvidia:nvenc" "inconclusive test transcode still records NVENC complete"
unset -f ui_log nvidia-smi sudo docker stage3_marker_driver_mode stage3_marker_install_source stage3_marker_expected_driver_version apply_nvidia_patch verify_gpu_usable _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_wait_for_jellyfin_encoding stage3_verify_transcode_evidence stage3_set_gpu_env stage3_remove_nvidia_marker _stage3_print_final_summary _stage3_nvidia_finalize_failure
SCRIPT_DIR="$prev_script_dir"
unset finalize_failure_calls gpu_env_calls NVIDIA_DRIVER_MODE GPU_TYPE prev_script_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

# Post-reboot driver-settle wait: the nvidia module can lag a few seconds behind
# the resume service, so a not-yet-ready driver must be retried (bounded) rather
# than read as a failure.
smi_attempts=0
sleep() { :; }
nvidia-smi() {
    smi_attempts=$((smi_attempts + 1))
    ((smi_attempts >= 3)) && return 0
    return 1
}
STAGE3_NVIDIA_SMI_TIMEOUT=20
if _stage3_wait_for_nvidia_smi; then
    pass "driver-settle wait returns success once nvidia-smi comes up"
else
    fail "driver-settle wait returns success once nvidia-smi comes up"
fi
assert_eq "3" "$smi_attempts" "driver-settle wait retries nvidia-smi until it responds"
nvidia-smi() { return 1; }
STAGE3_NVIDIA_SMI_TIMEOUT=4
if _stage3_wait_for_nvidia_smi; then
    fail "driver-settle wait gives up when nvidia-smi never responds"
else
    pass "driver-settle wait gives up when nvidia-smi never responds"
fi
unset -f sleep nvidia-smi
unset smi_attempts STAGE3_NVIDIA_SMI_TIMEOUT

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

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/stage3-encoding-verify"
mkdir -p "$SCRIPT_DIR"
cat >"$SCRIPT_DIR/.env" <<'ENV'
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
    pass "Stage 3 verifies Jellyfin encoding API state before completion"
else
    fail "Stage 3 verifies Jellyfin encoding API state before completion"
fi
curl() {
    printf '%s\n' '{"HardwareAccelerationType":"none","EnableHardwareEncoding":false}'
}
if _stage3_verify_jellyfin_encoding qsv 2>/dev/null; then
    fail "Stage 3 rejects unconfigured Jellyfin encoding before completion"
else
    pass "Stage 3 rejects unconfigured Jellyfin encoding before completion"
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
    pass "Stage 3 waits for Jellyfin encoding API after recreate"
else
    fail "Stage 3 waits for Jellyfin encoding API after recreate"
fi
assert_eq "2" "$verify_attempts" "Stage 3 retries encoding verification once ready"
assert_eq "1" "$sleep_calls" "Stage 3 retry wait sleeps between attempts"
verify_attempts=0
sleep_calls=0
_stage3_verify_jellyfin_encoding() {
    verify_attempts=$((verify_attempts + 1))
    return 1
}
STAGE3_ENCODING_VERIFY_TIMEOUT=1
STAGE3_ENCODING_VERIFY_INTERVAL=1
if _stage3_wait_for_jellyfin_encoding qsv; then
    fail "Stage 3 encoding wait fails after timeout"
else
    pass "Stage 3 encoding wait fails after timeout"
fi
assert_eq "2" "$verify_attempts" "Stage 3 timeout performs bounded verification attempts"
unset -f _stage3_verify_jellyfin_encoding sleep
unset verify_attempts sleep_calls STAGE3_ENCODING_VERIFY_TIMEOUT STAGE3_ENCODING_VERIFY_INTERVAL

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
nvidia_update_dir=$(mktemp -d)
SCRIPT_DIR="$nvidia_update_dir"
stage3_write_nvidia_marker unlock run-update 550.90
command() {
    [[ "${1:-}:${2:-}" == "-v:nvidia-smi" ]] && return 0
    builtin command "$@"
}
nvidia-smi() { return 0; }
nvidia_driver_version() { printf '535.100'; }
install_nvidia_drivers() { UPDATE_FINALIZE_INSTALLS=$((UPDATE_FINALIZE_INSTALLS + 1)); }
apply_nvidia_patch() { UPDATE_FINALIZE_PATCHES=$((UPDATE_FINALIZE_PATCHES + 1)); }
_stage3_nvidia_finalize_failure() { UPDATE_FINALIZE_FAILURES=$((UPDATE_FINALIZE_FAILURES + 1)); }
ui_log() { :; }
UPDATE_FINALIZE_INSTALLS=0
UPDATE_FINALIZE_PATCHES=0
UPDATE_FINALIZE_FAILURES=0
stage3_finalize_nvidia
assert_eq "0" "$UPDATE_FINALIZE_INSTALLS" "update finalization never reinstalls the driver"
assert_eq "0" "$UPDATE_FINALIZE_PATCHES" "version mismatch never patches the loaded driver"
assert_eq "1" "$UPDATE_FINALIZE_FAILURES" "version mismatch uses finalization failure path"
nvidia_driver_version() { printf '550.90'; }
apply_nvidia_patch() {
    UPDATE_FINALIZE_PATCHES=$((UPDATE_FINALIZE_PATCHES + 1))
    return 1
}
stage3_finalize_nvidia
assert_eq "1" "$UPDATE_FINALIZE_PATCHES" "matching update attempts the Unlock patch once"
assert_eq "2" "$UPDATE_FINALIZE_FAILURES" "failed Unlock patch uses finalization failure path"
unset -f command nvidia-smi nvidia_driver_version install_nvidia_drivers apply_nvidia_patch \
    _stage3_nvidia_finalize_failure ui_log
unset UPDATE_FINALIZE_INSTALLS UPDATE_FINALIZE_PATCHES UPDATE_FINALIZE_FAILURES
rm -rf "$nvidia_update_dir"
unset nvidia_update_dir
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
nvidia_driver_version() { printf '550.90'; }
ui_box() { :; }
ui_log() { :; }

NVIDIA_MENU_FILE=$(mktemp)
ui_choose() {
    printf '%s' "$*" >"$NVIDIA_MENU_FILE"
    printf '%s\n' "Use installed driver 550.90 (recommended)"
}
assert_eq "use" "$(_stage3_choose_nvidia_action debian healthy)" \
    "healthy Debian driver defaults to reuse"
assert_contains "$(cat "$NVIDIA_MENU_FILE")" "Replace with Unlock NVENC" \
    "healthy Debian menu offers Unlock replacement"

ui_choose() {
    printf '%s' "$*" >"$NVIDIA_MENU_FILE"
    printf '%s\n' "Repair/reinstall Debian driver (recommended)"
}
assert_eq "repair" "$(_stage3_choose_nvidia_action debian unhealthy)" \
    "unhealthy Debian driver defaults to one repair"
assert_contains "$(cat "$NVIDIA_MENU_FILE")" "Use software transcoding" \
    "unhealthy Debian menu offers software fallback"

ui_choose() {
    printf '%s' "$*" >"$NVIDIA_MENU_FILE"
    printf '%s\n' "Use existing driver with user-managed updates"
}
assert_eq "use-existing" "$(_stage3_choose_nvidia_action foreign healthy)" \
    "healthy externally managed driver can be used without mutation"
assert_contains "$(cat "$NVIDIA_MENU_FILE")" "Reinstall (remove existing" \
    "externally managed driver menu offers reinstall (remove + choose driver mode)"

ui_choose() {
    printf '%s' "$*" >"$NVIDIA_MENU_FILE"
    printf '%s\n' "Use software transcoding"
}
assert_eq "software" "$(_stage3_choose_nvidia_action foreign unhealthy)" \
    "unhealthy externally managed driver defaults to software"
case "$(cat "$NVIDIA_MENU_FILE")" in
    *foreign* | *"Use existing"*) fail "unhealthy external-driver menu avoids internal terminology and unsafe reuse" ;;
    *) pass "unhealthy external-driver menu avoids internal terminology and unsafe reuse" ;;
esac
unset -f nvidia_driver_version ui_box ui_log ui_choose
rm -f "$NVIDIA_MENU_FILE"
unset NVIDIA_MENU_FILE

scenario_end "$CURRENT_SCENARIO"
summary
