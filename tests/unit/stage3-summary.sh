#!/usr/bin/env bash
# tests/unit/stage3-summary.sh
#
# Contract tests for hardware-transcoding final summary labels.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-summary"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/lib/common.sh" ]] && source "$REPO_ROOT/scripts/lib/common.sh"
[[ -f "$REPO_ROOT/scripts/setup/stack.sh" ]] && source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u

if ! type print_final_summary >/dev/null 2>&1; then
    print_final_summary() { printf '__not_implemented__'; }
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT_DIR="$TMP_ROOT"

write_summary_env() {
    local stage2_state="$1"
    local stage3_state="$2"
    local stage3_vendor="$3"
    local stage3_encoder="$4"
    local wg_init_pw="${5:-}"
    cat > "$SCRIPT_DIR/.env" <<EOF
STAGE_1_COMPLETE=1
REMOTE_WEB_STATE=${stage2_state}
STAGE_3_GPU_STATE=${stage3_state}
STAGE_3_GPU_VENDOR=${stage3_vendor}
STAGE_3_GPU_ENCODER=${stage3_encoder}
DOMAIN=gate.test
HOST_ADDRESS=192.168.1.10
JELLYFIN_ADMIN_USER='admin'
NPM_ADMIN_EMAIL=owner@gate.test
WG_INIT_PASSWORD='${wg_init_pw}'
EOF
}

write_summary_env "ready" "complete" "intel" "qsv" ""
intel_output="$(print_final_summary)"
assert_contains "$intel_output" "Stage 1" "FIN-01: summary includes Stage 1"
assert_contains "$intel_output" "Hardware transcoding" "FIN-01: summary labels hardware transcoding separately"
assert_contains "$intel_output" "complete" "FIN-01: Stage 1 complete label"
assert_contains "$intel_output" "ready" "FIN-01: Stage 2 ready label"
assert_contains "$intel_output" "complete (Intel QSV)" "FIN-01: Intel summary label"
assert_contains "$intel_output" "https://jellyfin.gate.test" "FIN-01: ready state prints Jellyfin remote URL"
assert_contains "$intel_output" "https://seerr.gate.test" "FIN-01: ready state prints Seerr remote URL"

write_summary_env "ready" "complete" "amd" "vaapi" ""
amd_output="$(print_final_summary)"
assert_contains "$amd_output" "complete (AMD VAAPI)" "FIN-01: AMD summary label"

write_summary_env "ready" "pending" "nvidia" "nvenc" ""
pending_output="$(print_final_summary)"
assert_contains "$pending_output" "pending reboot - NVIDIA finalization queued" "FIN-01: NVIDIA pending summary label"

write_summary_env "ready" "complete" "nvidia" "nvenc" ""
nvidia_output="$(print_final_summary)"
assert_contains "$nvidia_output" "complete (NVIDIA NVENC)" "FIN-01: NVIDIA complete summary label"

write_summary_env "skipped" "skipped" "" "" ""
skipped_output="$(print_final_summary)"
assert_contains "$skipped_output" "skipped - run ./setup.sh --remote to retry" "FIN-01: Stage 2 skipped label"
assert_contains "$skipped_output" "skipped - software transcoding" "FIN-01: hardware transcoding skipped label"
if [[ "$skipped_output" == *"https://jellyfin.gate.test"* || "$skipped_output" == *"https://seerr.gate.test"* ]]; then
    fail "FIN-01: skipped remote state does not print remote URLs"
else
    pass "FIN-01: skipped remote state does not print remote URLs"
fi

write_summary_env "failed" "skipped" "" "" ""
failed_output="$(print_final_summary)"
assert_contains "$failed_output" "failed - run ./setup.sh --remote to retry" "FIN-01: Stage 2 failed label"
if [[ "$failed_output" == *"https://jellyfin.gate.test"* || "$failed_output" == *"https://seerr.gate.test"* ]]; then
    fail "FIN-01: failed remote state does not print remote URLs"
else
    pass "FIN-01: failed remote state does not print remote URLs"
fi

write_summary_env "unchecked" "fallback" "" "" ""
fallback_output="$(print_final_summary)"
assert_contains "$fallback_output" "not configured" "FIN-01: Stage 2 unchecked label"
assert_contains "$fallback_output" "fallback - software transcoding" "FIN-01: hardware transcoding fallback label"
if [[ "$fallback_output" == *"./setup.sh --transcoding"* ]]; then
    fail "FIN-01: final summary does not advertise --transcoding"
else
    pass "FIN-01: final summary does not advertise --transcoding"
fi

write_summary_env "ready" "skipped" "" "" '$2b$12$abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
wg_output="$(print_final_summary)"
assert_contains "$wg_output" "WireGuard admin" "FIN-01: WireGuard admin appears when hash exists"

scenario_end "$CURRENT_SCENARIO"
summary
