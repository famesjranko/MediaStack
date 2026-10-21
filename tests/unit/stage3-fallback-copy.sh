#!/usr/bin/env bash
# tests/unit/stage3-fallback-copy.sh
#
# Contract test for the closing line after a software fallback (_stage3_fallback in
# scripts/setup/stage3/jellyfin.sh). Setup did finish, on software transcoding, so
# the line says so and gives the reason. It must never read as a verified success
# and never blame "verification" when the cause was a driver that is too old.

# shellcheck disable=SC2034 # STAGE3_FALLBACK_REASON is read by the product code under test
set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-fallback-copy"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

UI_LINES=()
ui_log() { UI_LINES+=("$1: $2"); }
stage3_set_gpu_env() { return 0; }
stage3_remove_nvidia_marker() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
_stage3_apply_runtime_override() { return 0; }
_stage3_print_final_summary() { return 0; }

# Given the installer recorded driver_too_old as the reason,
# When the software fallback runs,
# Then the closing line says setup finished with software transcoding and gives the reason.
STAGE3_FALLBACK_REASON=driver_too_old
UI_LINES=()
_stage3_fallback nvidia nvenc driver_install_failed
closing="${UI_LINES[*]}"
assert_contains "$closing" "Hardware transcoding finished with software transcoding" "fallback closing line: says it finished on software transcoding"
assert_contains "$closing" "too old for Jellyfin's NVENC" "fallback closing line: gives the driver_too_old reason"
assert_not_contains "$closing" "could not be verified" "fallback closing line: does not blame verification for a too-old driver"
assert_not_contains "$closing" "completed successfully" "fallback closing line: never claims success"

# Given the caller passes only its default reason,
# When the software fallback runs,
# Then the closing line gives that reason.
STAGE3_FALLBACK_REASON=""
UI_LINES=()
_stage3_fallback nvidia nvenc verify_failed
assert_contains "${UI_LINES[*]}" "the GPU did not pass the transcode test" "fallback closing line: gives the caller's default reason"

scenario_end "$CURRENT_SCENARIO"
summary
