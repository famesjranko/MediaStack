#!/usr/bin/env bash
# tests/unit/configure-unpackerr.sh
#
# Unit tests for configure.sh's Unpackerr recreate step. Docker is a stub;
# no daemon, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="configure-unpackerr"
echo -e "${CYAN}${BOLD}▶ scenario: configure-unpackerr${NC}"

set +e

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/storage/core.sh"
eval "$(sed -n '/^_record_configure_result()/,/^}/p; /^_recreate_unpackerr()/,/^}/p' "$REPO_ROOT/scripts/configure.sh")"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# docker stub: DOCKER_RC sets the exit status, DOCKER_OUT the output.
docker() {
    printf '%s\n' "$*" >>"$TMP/docker.calls"
    [[ -n "${DOCKER_OUT:-}" ]] && printf '%s\n' "$DOCKER_OUT"
    return "${DOCKER_RC:-0}"
}

reset() {
    _CONFIGURE_OK=()
    _CONFIGURE_WARN=()
    _LOG_COUNTS_WARN=0
    _LOG_COUNTS_ERROR=0
    : >"$TMP/docker.calls"
    unset STORAGE_APP_WIRING
    DOCKER_RC=0
    DOCKER_OUT=
}

# Given Compose recreates Unpackerr, When the step runs, Then it reports success only.
reset
_recreate_unpackerr >"$TMP/out" 2>&1
out=$(<"$TMP/out")
assert_contains "$out" "Unpackerr restarted" "successful recreate logs success"
assert_not_contains "$out" "not recreated" "successful recreate logs no warning"
assert_contains "$(cat "$TMP/docker.calls")" "compose up -d unpackerr" "recreate runs compose up -d unpackerr"
assert_eq "0" "${#_CONFIGURE_WARN[@]}" "successful recreate adds no summary warning"

# Given Compose fails with long output containing an API key,
# When the step runs,
# Then it warns with bounded, redacted output, records Unpackerr and still returns 0.
reset
SONARR_API_KEY="REDACTME"
DOCKER_RC=23
DOCKER_OUT=$(
    printf 'line %s\n' 1 2 3 4 5 6 7 8
    echo "failing with key $SONARR_API_KEY"
)
_recreate_unpackerr >"$TMP/out" 2>&1
rc=$?
out=$(<"$TMP/out")
assert_eq "0" "$rc" "failed recreate keeps the continue-after-failure policy"
assert_contains "$out" "Unpackerr was not recreated" "failed recreate shows a warning"
assert_contains "$out" "exit 23" "warning names the compose exit status"
assert_not_contains "$out" "Unpackerr restarted" "failed recreate does not claim success"
assert_not_contains "$out" "line 1" "diagnostic output is bounded to the last lines"
assert_contains "$out" "line 8" "diagnostic output keeps the last lines"
assert_not_contains "$out" "$SONARR_API_KEY" "diagnostic output hides the API key"
assert_eq "Unpackerr|unpackerr" "${_CONFIGURE_WARN[*]}" "failed recreate is listed in the summary warnings"
assert_eq "0" "${#_CONFIGURE_OK[@]}" "failed recreate is not listed as ok"
unset SONARR_API_KEY

# Given manual app wiring, When the step runs, Then Compose is not called.
reset
STORAGE_APP_WIRING=manual
_recreate_unpackerr >"$TMP/out" 2>&1
out=$(<"$TMP/out")
assert_contains "$out" "Unpackerr recreate skipped" "manual wiring logs the skip"
assert_eq "" "$(cat "$TMP/docker.calls")" "manual wiring does not call compose"
assert_eq "0" "$((${#_CONFIGURE_OK[@]} + ${#_CONFIGURE_WARN[@]}))" "manual wiring records no summary entry"

# Given a targeted --only run and a failing docker,
# When the real configure.sh runs,
# Then it never recreates Unpackerr and writes no issues file.
reset
RUN="$TMP/run"
mkdir -p "$RUN/bin"
cp -r "$REPO_ROOT/scripts" "$RUN/scripts"
cp "$REPO_ROOT/config/examples/config.yml" "$RUN/config.yml"
printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexit 23\n' "$TMP/docker.calls" >"$RUN/bin/docker"
chmod +x "$RUN/bin/docker"
PATH="$RUN/bin:$PATH" bash "$RUN/scripts/configure.sh" --only none </dev/null >"$TMP/out" 2>&1
out=$(<"$TMP/out")
assert_contains "$out" "Targeted run: none" "targeted run reaches the summary"
assert_not_contains "$out" "Recreating Unpackerr" "--only does not start the Unpackerr recreate"
assert_not_contains "$(cat "$TMP/docker.calls")" "unpackerr" "--only does not call compose for Unpackerr"
assert_file_absent "$RUN/.configure_issues" "--only run writes no issues file"

summary
