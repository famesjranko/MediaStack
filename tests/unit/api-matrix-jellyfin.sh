#!/usr/bin/env bash
# tests/unit/api-matrix-jellyfin.sh
#
# Hermetic coverage for the bounded VirtualFolders read retry. The image-backed
# api-matrix scenario usually sees a ready Jellyfin service, so it cannot prove
# transient failures retry or that a persistent failure remains bounded.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="api-matrix-jellyfin"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ATTEMPTS_FILE="$TMP_DIR/attempts"
SLEEPS_FILE="$TMP_DIR/sleeps"
COMMANDS_FILE="$TMP_DIR/commands"
printf '0\n' >"$ATTEMPTS_FILE"
printf '0\n' >"$SLEEPS_FILE"
printf '0\n' >"$TMP_DIR/failures-left"

dind_exec() {
    local failures_left attempts
    printf '%s\n' "$*" >>"$COMMANDS_FILE"
    attempts=$(<"$ATTEMPTS_FILE")
    printf '%s\n' "$((attempts + 1))" >"$ATTEMPTS_FILE"
    failures_left=$(<"$TMP_DIR/failures-left")
    if ((failures_left > 0)); then
        printf '%s\n' "$((failures_left - 1))" >"$TMP_DIR/failures-left"
        return 1
    fi
    printf '%s' '[{"Name":"Movies"}]'
}

sleep() {
    local sleeps
    sleeps=$(<"$SLEEPS_FILE")
    printf '%s\n' "$((sleeps + 1))" >"$SLEEPS_FILE"
}

source "$REPO_ROOT/tests/api-matrix/jellyfin.sh"

printf '2\n' >"$TMP_DIR/failures-left"
printf '0\n' >"$ATTEMPTS_FILE"
printf '0\n' >"$SLEEPS_FILE"
: >"$COMMANDS_FILE"
libraries=$(_jfm_libraries 'api-key')
rc=$?
assert_eq '0' "$rc" "Jellyfin VirtualFolders retry succeeds after transient failures"
assert_eq '[{"Name":"Movies"}]' "$libraries" "Jellyfin VirtualFolders retry preserves successful JSON"
assert_eq '3' "$(<"$ATTEMPTS_FILE")" "Jellyfin VirtualFolders retries until the first success"
assert_eq '2' "$(<"$SLEEPS_FILE")" "Jellyfin VirtualFolders waits once per transient failure"
assert_contains "$(<"$COMMANDS_FILE")" '--max-time 3' "Jellyfin VirtualFolders retry bounds each request"

# Exhaust the whole budget: fail one more time than the retry ceiling so the
# call stays bounded. Assertions track _JFM_READY_RETRIES so the count and the
# implementation can't silently drift apart.
printf '%s\n' "$((_JFM_READY_RETRIES + 1))" >"$TMP_DIR/failures-left"
printf '0\n' >"$ATTEMPTS_FILE"
printf '0\n' >"$SLEEPS_FILE"
: >"$COMMANDS_FILE"
if _jfm_libraries 'api-key' >/dev/null; then
    fail "Jellyfin VirtualFolders retry fails after the bounded attempt count"
else
    pass "Jellyfin VirtualFolders retry fails after the bounded attempt count"
fi
assert_eq "$_JFM_READY_RETRIES" "$(<"$ATTEMPTS_FILE")" "Jellyfin VirtualFolders stops after the bounded number of failed requests"
assert_eq "$_JFM_READY_RETRIES" "$(<"$SLEEPS_FILE")" "Jellyfin VirtualFolders preserves its bounded backoff cadence"

scenario_end "$CURRENT_SCENARIO"
summary
