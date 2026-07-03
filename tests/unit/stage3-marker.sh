#!/usr/bin/env bash
# tests/unit/stage3-marker.sh
#
# Contract tests for the NVIDIA post-reboot marker.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-marker"
scenario_begin "$CURRENT_SCENARIO"

[[ -f "$REPO_ROOT/scripts/setup/stages/stage3.sh" ]] && source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

if ! type stage3_write_nvidia_marker >/dev/null 2>&1; then
    stage3_write_nvidia_marker() { printf '__not_implemented__'; return 1; }
fi
if ! type stage3_marker_exists >/dev/null 2>&1; then
    stage3_marker_exists() { [[ -f "${SCRIPT_DIR:-$PWD}/.nvidia-finalize-pending" ]]; }
fi
if ! type stage3_remove_nvidia_marker >/dev/null 2>&1; then
    stage3_remove_nvidia_marker() { rm -f "${SCRIPT_DIR:-$PWD}/.nvidia-finalize-pending"; }
fi
if ! type stage3_reboot_prompt_needed >/dev/null 2>&1; then
    stage3_reboot_prompt_needed() { [[ "${NEEDS_REBOOT:-false}" == "true" ]] && stage3_marker_exists; }
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
SCRIPT_DIR="$TMP_ROOT"

stage3_write_nvidia_marker >/dev/null 2>&1
marker="$SCRIPT_DIR/.nvidia-finalize-pending"

if [[ -f "$marker" ]]; then
    pass "FIN-02: NVIDIA marker is written"
else
    fail "FIN-02: NVIDIA marker is written"
fi

if [[ -f "$marker" ]]; then
    schema=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("schema"))' "$marker" 2>/dev/null)
    gpu_type=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("gpu_type"))' "$marker" 2>/dev/null)
    encoder=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("encoder"))' "$marker" 2>/dev/null)
    boot_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("created_boot_id"))' "$marker" 2>/dev/null)
    pending=$(python3 -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).get("pending", [])))' "$marker" 2>/dev/null)
    driver_mode=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("nvidia_driver_mode"))' "$marker" 2>/dev/null)
    install_source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("install_source"))' "$marker" 2>/dev/null)
    mode=$(stat -c '%a' "$marker")

    assert_eq "3" "$schema" "FIN-02: marker schema is 3"
    assert_eq "nvidia" "$gpu_type" "FIN-02: marker gpu_type is nvidia"
    assert_eq "nvenc" "$encoder" "FIN-02: marker encoder is nvenc"
    assert_eq "unlock" "$driver_mode" "FIN-02: marker records nvidia_driver_mode (default unlock)"
    assert_eq "run" "$install_source" "FIN-02: marker records install_source (default run)"
    assert_eq "$(stage3_current_boot_id)" "$boot_id" "FIN-02: marker records creation boot id"
    assert_contains "$pending" "driver_verify" "FIN-02: marker tracks driver verification"
    assert_contains "$pending" "docker_runtime_verify" "FIN-02: marker tracks Docker runtime verification"
    assert_contains "$pending" "encoder_config" "FIN-02: marker tracks encoder config"
    assert_contains "$pending" "test_transcode" "FIN-02: marker tracks test transcode"
    assert_contains "$pending" "summary" "FIN-02: marker tracks final summary"
    assert_eq "600" "$mode" "FIN-02: marker mode is 600"

    marker_text="$(cat "$marker")"
    if [[ "$marker_text" == *"PASSWORD"* || "$marker_text" == *"API_KEY"* || "$marker_text" == *"TOKEN"* ]]; then
        fail "FIN-02: marker contains no secrets"
    else
        pass "FIN-02: marker contains no secrets"
    fi
fi

stage3_write_nvidia_marker unlock run-update 550.90 >/dev/null 2>&1
assert_eq "550.90" "$(stage3_marker_expected_driver_version)" \
    "FIN-03: update marker records expected driver version"
assert_eq "run-update" "$(stage3_marker_install_source)" \
    "FIN-03: update marker identifies verify-only post-reboot flow"

if stage3_marker_ready_to_finalize; then
    fail "FIN-03: same-boot NVIDIA marker does not finalize immediately"
else
    pass "FIN-03: same-boot NVIDIA marker does not finalize immediately"
fi

stage3_current_boot_id() { printf '%s\n' "different-test-boot"; }
if stage3_marker_ready_to_finalize; then
    pass "FIN-03: changed boot id allows NVIDIA finalization"
else
    fail "FIN-03: changed boot id allows NVIDIA finalization"
fi
unset -f stage3_current_boot_id
source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
SCRIPT_DIR="$TMP_ROOT"

python3 - "$marker" <<'PY'
import json
import sys

with open(sys.argv[1], "w") as fh:
    json.dump({"schema": 1, "gpu_type": "nvidia", "encoder": "nvenc"}, fh)
    fh.write("\n")
PY
if stage3_marker_ready_to_finalize; then
    fail "FIN-03: marker without boot id does not finalize blindly"
else
    pass "FIN-03: marker without boot id does not finalize blindly"
fi

NEEDS_REBOOT=true
if stage3_reboot_prompt_needed; then
    pass "FIN-02: reboot prompt requires reboot flag plus marker"
else
    fail "FIN-02: reboot prompt requires reboot flag plus marker"
fi

NEEDS_REBOOT=false
if stage3_reboot_prompt_needed; then
    fail "FIN-02: reboot prompt is not shown without reboot flag"
else
    pass "FIN-02: reboot prompt is not shown without reboot flag"
fi

stage3_remove_nvidia_marker
if [[ -f "$marker" ]]; then
    fail "FIN-03: marker removal deletes pending file"
else
    pass "FIN-03: marker removal deletes pending file"
fi

stage3_source="$(cat "$REPO_ROOT/scripts/setup/stages/stage3.sh")"
assert_contains "$stage3_source" "Reboot needed to finish NVIDIA transcoding" "FIN-02: reboot prompt title matches UI-SPEC"
assert_contains "$stage3_source" "MediaStack has prepared the NVIDIA driver setup." "FIN-02: reboot prompt setup copy"
assert_contains "$stage3_source" "After reboot, setup will resume automatically." "FIN-02: reboot prompt resume copy"
assert_contains "$stage3_source" "It will verify nvidia-smi, restart Docker, write Jellyfin NVENC settings, run a test transcode, and print the final summary." "FIN-02: reboot prompt finalize copy"
assert_contains "$stage3_source" "Reboot now" "FIN-02: reboot prompt includes Reboot now"
assert_contains "$stage3_source" "Reboot manually later" "FIN-02: reboot prompt includes manual option"
assert_contains "$stage3_source" "schedule_post_reboot" "FIN-02: reboot prompt uses existing schedule helper"
assert_contains "$stage3_source" "install_post_reboot_banner" "FIN-02: reboot prompt uses existing banner helper"
assert_contains "$stage3_source" "print_reboot_notice" "FIN-02: reboot prompt uses existing notice helper"
assert_contains "$stage3_source" "Reboot manually when ready. MediaStack will resume GPU finalization automatically on the next boot." "FIN-02: manual reboot copy"
assert_contains "$stage3_source" "stage3_finalize_nvidia()" "FIN-03: NVIDIA finalize function exists"
assert_contains "$stage3_source" "Resuming hardware transcoding: NVIDIA finalization" "FIN-03: finalize resume copy"
assert_contains "$stage3_source" "Verifying NVIDIA driver..." "FIN-03: finalize driver verification copy"
assert_contains "$stage3_source" "Restarting Docker so NVIDIA runtime is available..." "FIN-03: finalize Docker restart copy"
assert_contains "$stage3_source" "Writing Jellyfin encoder: nvenc" "FIN-03: finalize encoder copy"
assert_contains "$stage3_source" "Restarting Jellyfin..." "FIN-03: finalize Jellyfin restart copy"
assert_contains "$stage3_source" "Running test transcode..." "FIN-03: finalize transcode copy"
assert_contains "$stage3_source" "NVIDIA NVENC configured and verified." "FIN-03: finalize success copy"
assert_contains "$stage3_source" "Post-reboot GPU finalization complete." "FIN-03: finalize complete copy"
assert_contains "$stage3_source" "NVIDIA finalization did not complete. MediaStack is falling back to software transcoding; check journalctl -u mediastack-setup --no-pager, fix the driver/runtime issue, then choose Manage hardware transcoding (GPU) from the menu." "FIN-03: finalize failure copy"

schedule_calls=0
banner_calls=0
notice_calls=0
confirm_calls=0
reboot_calls=0
ui_box() { :; }
ui_choose() { printf '%s\n' "${STAGE3_TEST_REBOOT_CHOICE:-Reboot manually later}"; }
ui_confirm() { confirm_calls=$((confirm_calls + 1)); return "${STAGE3_TEST_CONFIRM_RC:-0}"; }
schedule_post_reboot() { schedule_calls=$((schedule_calls + 1)); }
install_post_reboot_banner() { banner_calls=$((banner_calls + 1)); }
print_reboot_notice() { notice_calls=$((notice_calls + 1)); }
sudo() {
    if [[ "${1:-}" == "reboot" ]]; then
        reboot_calls=$((reboot_calls + 1))
    fi
}
sleep_calls=0
sleep() { sleep_calls=$((sleep_calls + 1)); }

stage3_write_nvidia_marker >/dev/null 2>&1
NEEDS_REBOOT=true
STAGE3_TEST_REBOOT_CHOICE="Reboot manually later"
stage3_prompt_nvidia_reboot >/dev/null 2>&1
assert_eq "1" "$schedule_calls" "FIN-02: manual reboot option schedules post-reboot resume"
assert_eq "1" "$banner_calls" "FIN-02: manual reboot option installs post-reboot banner"
assert_eq "1" "$notice_calls" "FIN-02: manual reboot option prints reboot notice"
assert_eq "0" "$reboot_calls" "FIN-02: manual reboot option does not reboot immediately"

schedule_calls=0
banner_calls=0
notice_calls=0
confirm_calls=0
reboot_calls=0
sleep_calls=0
STAGE3_TEST_REBOOT_CHOICE="Reboot now"
# </dev/null forces a non-TTY stdin so [[ -t 0 ]] is false: the countdown must be
# skipped (no sleep) but the reboot must still fire. Guards the non-interactive
# determinism fix (#197 item 4) — the old code always slept 10x here.
stage3_prompt_nvidia_reboot >/dev/null 2>&1 </dev/null
assert_eq "0" "$sleep_calls" "FIN-02: non-interactive reboot-now skips the 10s countdown (no sleep)"
assert_eq "1" "$schedule_calls" "FIN-02: reboot-now option schedules post-reboot resume"
assert_eq "1" "$banner_calls" "FIN-02: reboot-now option installs post-reboot banner"
assert_eq "1" "$notice_calls" "FIN-02: reboot-now option prints reboot notice"
# The "Reboot now?" menu is the single reboot gate (#100): choosing "Reboot now"
# arms the resume hooks and reboots directly, with no redundant second ui_confirm.
assert_eq "0" "$confirm_calls" "FIN-02: reboot-now is the single gate (#100) - no redundant second confirm"
assert_eq "1" "$reboot_calls" "FIN-02: reboot-now option invokes reboot"

scenario_end "$CURRENT_SCENARIO"
summary
