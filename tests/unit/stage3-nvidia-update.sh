#!/usr/bin/env bash
# tests/unit/stage3-nvidia-update.sh
#
# Contract tests for Jellyfin encoding-wait retries and NVIDIA driver-update/action-menu paths.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-nvidia-update"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT/stage3-encoding-verify"
mkdir -p "$SCRIPT_DIR"
cat >"$SCRIPT_DIR/.env" <<'ENV'
JELLYFIN_API_KEY=verify-token
ENV
# shellcheck disable=SC2034 # read by _stage3_jellyfin_api_key fallback in scripts/setup/stage3/jellyfin.sh
JELLYFIN_API_KEY=verify-token
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
STAGE_3_GPU_HW_DECODING_CODECS=h264,hevc
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
STAGE_3_GPU_DECODE_HEVC_10BIT=true
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
STAGE_3_GPU_DECODE_VP9_10BIT=false
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
STAGE_3_GPU_ALLOW_HEVC_ENCODING=true
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
STAGE_3_GPU_ALLOW_AV1_ENCODING=false
# shellcheck disable=SC2034 # read by stage3_set_gpu_env in scripts/setup/stage3/state.sh
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
# shellcheck disable=SC2034 # read by _stage3_wait_for_jellyfin_encoding in scripts/setup/stage3/jellyfin.sh
STAGE3_ENCODING_VERIFY_TIMEOUT=1
# shellcheck disable=SC2034 # read by _stage3_wait_for_jellyfin_encoding in scripts/setup/stage3/jellyfin.sh
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
printf 'JELLYFIN_GPU=none\nSTAGE_3_GPU_STATE=pending\n' >"$SCRIPT_DIR/.env"
stage3_write_nvidia_marker unlock run-update 550.90
command() {
    [[ "${1:-}:${2:-}" == "-v:nvidia-smi" ]] && return 0
    builtin command "$@"
}
nvidia-smi() { return 0; }
nvidia_driver_version() { printf '535.100'; }
install_nvidia_drivers() { UPDATE_FINALIZE_INSTALLS=$((UPDATE_FINALIZE_INSTALLS + 1)); }
apply_nvidia_patch() { UPDATE_FINALIZE_PATCHES=$((UPDATE_FINALIZE_PATCHES + 1)); }
_env_write_kv() {
    printf 'changed\n'
    return 0
}
_env_write_kv_warn() { :; }
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
    _env_write_kv _env_write_kv_warn _stage3_nvidia_finalize_failure ui_log
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
