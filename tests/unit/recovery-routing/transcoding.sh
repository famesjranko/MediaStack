#!/usr/bin/env bash
# tests/unit/recovery-routing/transcoding.sh
#
# --transcoding requires Stage 1 and isolates to Stage 3.

reset_route_state
seed_script_dir "transcoding-no-env"
out=$(run_transcoding_recovery 2>&1)
rc=$?
if is_pending_helper run_transcoding_recovery; then
    skip "run_transcoding_recovery .env precondition pending implementation"
else
    assert_eq "1" "$rc" "--transcoding without .env exits non-zero"
    assert_contains "$out" "Run ./setup.sh first" "--transcoding without .env tells user to run setup first"
fi

reset_route_state
seed_script_dir "transcoding-stage3"
seed_env "skipped" "none" "skipped"
GPU_TYPE="intel"
if is_pending_helper run_transcoding_recovery; then
    skip "run_transcoding_recovery route isolation pending implementation"
else
    run_transcoding_recovery >/dev/null 2>&1
    assert_order_has "stash_gpu_type" "transcoding recovery re-detects GPU"
    assert_order_has "run_stage3" "transcoding recovery calls Stage 3"
    assert_order_lacks "run_stage1" "transcoding recovery does not call Stage 1"
    assert_order_lacks "run_stage2" "transcoding recovery does not call Stage 2"
fi
