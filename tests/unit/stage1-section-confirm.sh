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

# --- security section: the admin-port filter opt-out ------------------------
# ui_confirm is scripted per prompt: ANSWERS maps a prompt prefix to yes/no, and
# ASKED records "<prompt>|<default>" for every prompt shown.
ui_log() { LOG_TEXT+="$2"$'\n'; }
ui_confirm() {
    ASKED+="$1|$2"$'\n'
    local k
    for k in "${!ANSWERS[@]}"; do
        [[ "$1" == "$k"* ]] && {
            [[ "${ANSWERS[$k]}" == yes ]]
            return
        }
    done
    [[ "$2" == yes ]]
}
run_security() {
    ASKED="" LOG_TEXT=""
    unset _WIZ_UFW_ENABLED _WIZ_ADMIN_PORT_FILTER _WIZ_HARDENING_ENABLED
    _stage1_collect_security
}
declare -A ANSWERS

# Given the user keeps the firewall
# When the security section runs
# Then the admin-port filter stays on and no extra question is asked
ANSWERS=(["Set up the UFW"]=yes)
unset ADMIN_PORT_FILTER
run_security
assert_eq "true" "$_WIZ_ADMIN_PORT_FILTER" "security: firewall kept -> admin-port filter on"
assert_not_contains "$ASKED" "admin-port filter" "security: firewall kept -> no admin-port question"

# Given the user declines the firewall
# When the security section runs and they keep the filter
# Then the question names the ports that open up, and the filter stays on
ANSWERS=(["Set up the UFW"]=no ["Keep the admin-port"]=yes)
run_security
assert_contains "$ASKED" "Keep the admin-port filter?|yes" "security: firewall declined -> asked, default yes"
assert_contains "$LOG_TEXT" "7359/udp" "security: the opt-out names the ports that become reachable"
assert_contains "$LOG_TEXT" "any source your router forwards" "security: the opt-out says who can reach them"
assert_eq "true" "$_WIZ_ADMIN_PORT_FILTER" "security: firewall declined, filter kept -> true"

# Given the user declines both
# When the security section runs
# Then the filter is recorded as off
ANSWERS=(["Set up the UFW"]=no ["Keep the admin-port"]=no)
run_security
assert_eq "false" "$_WIZ_ADMIN_PORT_FILTER" "security: firewall declined, filter declined -> false"

# Given an earlier run opted out of the filter and the firewall is kept
# When the security section runs
# Then they are asked with default no, so they can opt back in
ANSWERS=(["Set up the UFW"]=yes)
ADMIN_PORT_FILTER=false
run_security
assert_contains "$ASKED" "Keep the admin-port filter?|no" "security: earlier opt-out -> asked, default no"
unset ADMIN_PORT_FILTER

# Given an earlier .env holds a filter value other than exactly false (TRUE) and the firewall is kept
# When the security section runs
# Then the filter stays on without a question, because only the exact value false opts out
ANSWERS=(["Set up the UFW"]=yes)
ADMIN_PORT_FILTER=TRUE
run_security
assert_eq "true" "$_WIZ_ADMIN_PORT_FILTER" "security: ADMIN_PORT_FILTER=TRUE is not an opt-out"
assert_not_contains "$ASKED" "admin-port filter" "security: ADMIN_PORT_FILTER=TRUE -> no admin-port question"
unset ADMIN_PORT_FILTER

# Given an earlier .env holds a filter value other than exactly false (yes) and the firewall is declined
# When the security section runs
# Then the question defaults to keeping the filter
ANSWERS=(["Set up the UFW"]=no ["Keep the admin-port"]=yes)
ADMIN_PORT_FILTER=yes
run_security
assert_contains "$ASKED" "Keep the admin-port filter?|yes" "security: ADMIN_PORT_FILTER=yes -> asked, default yes"
unset ADMIN_PORT_FILTER

# Given nobody is at the keyboard (stdin closed, or the DEMO flag set) and the firewall is declined
# When the real prompt runs
# Then it takes the default and does not block
for demo in 0 1; do
    nonint=$(UI_DEMO=$demo timeout 10 bash -c '
        source "$1/scripts/lib/common.sh"; source "$1/scripts/lib/ui.sh"
        source "$1/scripts/setup/stage1/security.sh"
        _WIZ_UFW_ENABLED=false
        _stage1_collect_admin_filter >/dev/null 2>&1
        echo "$_WIZ_ADMIN_PORT_FILTER"
    ' _ "$REPO_ROOT" </dev/null 2>&1)
    assert_eq "true" "$nonint" "security: non-interactive run (UI_DEMO=$demo) takes the default, filter on, and does not block"
done

# --- the choice reaches .env, and a path that never asks keeps the old one ---
# env_filter_value <wizard value|-> <previous env value|-> prints the key as write_env wrote it.
env_filter_value() {
    local tmp out
    tmp=$(mktemp -d)
    mkdir -p "$tmp/config"
    out=$(
        source "$REPO_ROOT/scripts/setup/env-gen.sh"
        SCRIPT_DIR="$tmp"
        [[ "$1" == - ]] || _WIZ_ADMIN_PORT_FILTER="$1"
        [[ "$2" == - ]] || ADMIN_PORT_FILTER="$2"
        _ENV_PUID=1000 _ENV_PGID=1000 _ENV_HOST_ADDRESS=192.168.1.2 _WIZ_TZ=UTC _WIZ_DATA_DIR=/data
        _WIZ_ADMIN_USER=a _WIZ_ADMIN_PW=p _WIZ_ADMIN_EMAIL=a@b.c
        write_env >/dev/null 2>&1
        grep '^ADMIN_PORT_FILTER=' "$tmp/.env"
    )
    rm -rf "$tmp"
    printf '%s' "$out"
}
unset _WIZ_ADMIN_PORT_FILTER ADMIN_PORT_FILTER
# Given the wizard recorded an opt-out
# When .env is written
# Then ADMIN_PORT_FILTER=false is persisted
assert_eq "ADMIN_PORT_FILTER='false'" "$(env_filter_value false -)" ".env: the wizard's opt-out is written"
# Given no wizard answer and no earlier value
# When .env is written
# Then the filter defaults on
assert_eq "ADMIN_PORT_FILTER='true'" "$(env_filter_value - -)" ".env: an absent key is written as true"
# Given an earlier opt-out and a wizard path that never asks (demo, resume)
# When .env is written
# Then the opt-out survives
assert_eq "ADMIN_PORT_FILTER='false'" "$(env_filter_value - false)" ".env: an earlier opt-out survives a path that never asks"

scenario_end "$CURRENT_SCENARIO"
summary
