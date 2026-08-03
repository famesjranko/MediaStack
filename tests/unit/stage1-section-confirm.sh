#!/usr/bin/env bash
# tests/unit/stage1-section-confirm.sh
#
# Covers the "echo + confirm/re-enter" wrappers added to the Stage-1 collect
# sections (storage, quality, qbit). Each public _stage1_collect_<x> is now a
# thin loop around _stage1_collect_<x>_once + ui_kv echoes + a ui_choose review;
# "Re-enter" must re-run the section and "Use these details" must break the loop.
# The section bodies (_once) are stubbed to counters — this tests the wrapper
# logic, not the collection. (NAS mount idempotency lives in tests/unit/storage.sh.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-section-confirm"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/checks.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

set +e +u

ui_kv() { :; } # silence the echo lines; not under test here

# ui_choose runs in a $(...) subshell, so it can't keep its own counter — drive
# the decision off ONCE_COUNT, which the stubbed _once increments in the parent
# shell before each review: accept once the body has run ACCEPT_AT times.
ui_choose() {
    if ((ONCE_COUNT >= ACCEPT_AT)); then echo "Use these details"; else echo "Re-enter"; fi
}

run_case() {
    local wrapper="$1" once="$2"
    ACCEPT_AT="$3"
    ONCE_COUNT=0
    eval "${once}() { ONCE_COUNT=\$((ONCE_COUNT + 1)); }"
    "$wrapper"
}

# --- accept on first review: body runs once --------------------------------
run_case _stage1_collect_storage _stage1_collect_storage_once 1
assert_eq "1" "$ONCE_COUNT" "storage: accept on first review runs the section once"

run_case _stage1_collect_quality _stage1_collect_quality_once 1
assert_eq "1" "$ONCE_COUNT" "quality: accept on first review runs the section once"

run_case _stage1_collect_qbit _stage1_collect_qbit_once 1
assert_eq "1" "$ONCE_COUNT" "qbit: accept on first review runs the section once"

# --- Re-enter once then accept: body re-runs, loop terminates ---------------
run_case _stage1_collect_storage _stage1_collect_storage_once 2
assert_eq "2" "$ONCE_COUNT" "storage: Re-enter re-runs the section, then accept stops the loop"

run_case _stage1_collect_quality _stage1_collect_quality_once 2
assert_eq "2" "$ONCE_COUNT" "quality: Re-enter re-runs the section, then accept stops the loop"

run_case _stage1_collect_qbit _stage1_collect_qbit_once 2
assert_eq "2" "$ONCE_COUNT" "qbit: Re-enter re-runs the section, then accept stops the loop"

scenario_end "$CURRENT_SCENARIO"
summary
