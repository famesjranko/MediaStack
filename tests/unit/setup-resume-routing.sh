#!/usr/bin/env bash
# tests/unit/setup-resume-routing.sh
#
# Contract tests for setup.sh hardware transcoding ownership and NVIDIA marker resume.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="setup-resume-routing"
scenario_begin "$CURRENT_SCENARIO"

set +e
set +u

setup_source="$(sed -n '1,900p' "$REPO_ROOT/setup.sh")"
if [[ "$setup_source" == *"stage3_finalize_nvidia"* ]]; then
    assert_contains "$setup_source" "stage3_marker_exists" "setup.sh checks NVIDIA finalize marker"
    assert_contains "$setup_source" "stage3_marker_ready_to_finalize" "setup.sh guards finalization by boot id"
    assert_contains "$setup_source" "stage3_finalize_nvidia" "setup.sh routes marker to stage3_finalize_nvidia"
else
    skip "marker-first resume route pending post-reboot finalize plan"
fi
assert_contains "$setup_source" "stash_gpu_type" "setup.sh stashes GPU type before wizard"
assert_contains "$setup_source" "run_wizard" "setup.sh reaches staged wizard"
assert_contains "$setup_source" 'write_setup_result "ok"' "post-reboot marker route can write ok result"

if [[ "$setup_source" == *"stage3_finalize_nvidia"* && "$setup_source" == *"stage3_marker_exists"*"detect_existing_install"* ]]; then
    pass "marker branch appears before existing-install detection"
elif [[ "$setup_source" == *"stage3_finalize_nvidia"* ]]; then
    fail "marker branch appears before existing-install detection"
else
    skip "marker branch ordering pending post-reboot finalize plan"
fi

if [[ "$setup_source" == *"stage3_finalize_nvidia"* && "$setup_source" == *"--remote"* ]]; then
    if [[ "$setup_source" == *"stage3_marker_exists"*"--remote"* ]]; then
        pass "marker branch appears before --remote recovery routing"
    else
        fail "marker branch appears before --remote recovery routing"
    fi
else
    skip "marker before --remote pending recovery routing"
fi

if [[ "$setup_source" == *"stage3_finalize_nvidia"* && "$setup_source" == *"--transcoding"* ]]; then
    if [[ "$setup_source" == *"stage3_marker_exists"*"--transcoding"* ]]; then
        pass "marker branch appears before --transcoding recovery routing"
    else
        fail "marker branch appears before --transcoding recovery routing"
    fi
else
    skip "marker before --transcoding pending recovery routing"
fi

if [[ "$setup_source" == *"stage3_finalize_nvidia"* && "$setup_source" == *"stage3_marker_exists"*"run_wizard"* ]]; then
    pass "marker branch appears before normal wizard routing"
elif [[ "$setup_source" == *"stage3_finalize_nvidia"* ]]; then
    fail "marker branch appears before normal wizard routing"
else
    skip "marker branch before wizard pending post-reboot finalize plan"
fi

if [[ "$setup_source" == *"install_nvidia_drivers"*"run_wizard"* || "$setup_source" == *"verify_gpu_usable"*"run_wizard"* || "$setup_source" == *"schedule_post_reboot"*"run_wizard"* ]]; then
    fail "setup.sh has no legacy GPU install/reboot path before hardware transcoding"
else
    pass "setup.sh has no legacy GPU install/reboot path before hardware transcoding"
fi

wizard_source="$(sed -n '1,500p' "$REPO_ROOT/scripts/setup/wizard.sh")"
assert_contains "$wizard_source" "run_stage1" "wizard keeps Stage 1"
assert_contains "$wizard_source" "run_hardware_transcoding_addon" "wizard calls hardware transcoding add-on"
assert_contains "$wizard_source" "run_stage2" "wizard keeps Stage 2"
assert_contains "$wizard_source" "stage3_prompt_pending_nvidia_reboot" "wizard has final pending reboot gate"

if [[ "$wizard_source" == *"run_stage1"*"run_hardware_transcoding_addon"*"run_stage2"*"stage3_prompt_pending_nvidia_reboot"* ]]; then
    pass "wizard sequence is Stage 1 -> hardware transcoding -> Stage 2 -> final reboot gate"
else
    fail "wizard sequence is Stage 1 -> hardware transcoding -> Stage 2 -> final reboot gate"
fi

# --- Behaviour: a finalize that cannot persist must be reported, not fatal ----
# setup.sh runs under errexit, so a bare finalize call would abort main() mid
# branch: no result file, no recorded outcome, and — because the marker is kept
# for the retry — the identical abort on every later run. Drive the real main()
# with a ripe marker and a finalize that fails to persist.
run_marker_route() {
    local finalize_rc="$1"
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" FINALIZE_RC="$finalize_rc" bash -c '
    cd "$REPO_ROOT" || exit 1
    # Sourcing defines main() without running it (the BASH_SOURCE guard) but
    # also turns on errexit — exactly the condition under test.
    source ./setup.sh
    set +e
    set +u
    tmp=$(mktemp -d); SCRIPT_DIR="$tmp"
    # A marker created under a different boot id is "ripe": setup routes to
    # finalization ahead of every other branch.
    printf "{\"schema\": 3, \"created_boot_id\": \"other-boot\"}\n" >"$tmp/.nvidia-finalize-pending"
    ui_banner(){ :; }
    check_not_root(){ :; }
    check_debian(){ :; }
    cleanup_post_reboot(){ :; }
    log_error(){ echo "ERROR $*"; }
    log_info(){ :; }
    log_warn(){ :; }
    log_ok(){ :; }
    write_setup_result(){ echo "RESULT $1"; }
    record_launcher_outcome(){ echo "OUTCOME $1"; }
    stage3_finalize_nvidia(){ echo "FINALIZE"; return "$FINALIZE_RC"; }
    main
    echo "MAIN_RC=$?"
    [[ -f "$tmp/.nvidia-finalize-pending" ]] && echo "MARKER_KEPT"
    rm -rf "$tmp"
  ' 2>&1
}

marker_fail_out="$(run_marker_route 3)"
assert_contains "$marker_fail_out" "FINALIZE" "failed finalize: marker route still reaches finalization"
assert_contains "$marker_fail_out" "MAIN_RC=3" "failed finalize: setup returns the durable-state status"
assert_contains "$marker_fail_out" "OUTCOME failed" "failed finalize: run is recorded as failed, not completed"
assert_not_contains "$marker_fail_out" "OUTCOME completed" "failed finalize: run is not recorded as completed"
assert_contains "$marker_fail_out" "ERROR" "failed finalize: the operator is told what to fix"
assert_contains "$marker_fail_out" "MARKER_KEPT" "failed finalize: marker is kept so the next run retries"

marker_ok_out="$(run_marker_route 0)"
assert_contains "$marker_ok_out" "MAIN_RC=0" "successful finalize: marker route still succeeds"
assert_contains "$marker_ok_out" "OUTCOME completed" "successful finalize: run is recorded as completed"

scenario_end "$CURRENT_SCENARIO"
summary
