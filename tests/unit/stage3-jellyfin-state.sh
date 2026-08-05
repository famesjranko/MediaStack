#!/usr/bin/env bash
# tests/unit/stage3-jellyfin-state.sh
#
# Contract tests for Stage 3 completed/pending .env state preservation and API-key fallback.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-jellyfin-state"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

log_ok() { :; }
log_warn() { :; }
log_skip() { :; }
log_info() { :; }
log_error() { :; }

source "$REPO_ROOT/scripts/setup/env-gen.sh"

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
    # shellcheck disable=SC2034 # read by _stage3_apply_runtime_override in scripts/setup/stage3/jellyfin.sh
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

scenario_end "$CURRENT_SCENARIO"
summary
