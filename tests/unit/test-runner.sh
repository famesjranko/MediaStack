#!/usr/bin/env bash
# Unit test - tests/run.sh scenario loading guards
#
# Stubs Docker/DinD helpers so the real runner can be exercised without
# starting containers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="test-runner"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

setup_runner_sandbox() {
    rm -rf "$TMP_DIR/sandbox"
    mkdir -p "$TMP_DIR/sandbox/bin" \
        "$TMP_DIR/sandbox/tests/lib" \
        "$TMP_DIR/sandbox/tests/scenarios"

    cp "$REPO_ROOT/tests/run.sh" "$TMP_DIR/sandbox/tests/run.sh"

    cat >"$TMP_DIR/sandbox/tests/lib/assert.sh" <<'STUB'
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
# Colour vars the real assert.sh exposes; run.sh references ${BLUE}/${NC} on the
# preload-skip path and runs under `set -u`, so the stub must define them too.
RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
scenario_begin() { printf 'BEGIN:%s\n' "$1"; }
scenario_end() { printf 'END:%s\n' "$1"; }
fail() {
    printf 'FAIL:%s:%s\n' "$1" "${2:-}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}
summary() { printf 'SUMMARY fails=%s\n' "$FAIL_COUNT"; }
STUB
    cat >"$TMP_DIR/sandbox/tests/lib/cache.sh" <<'STUB'
cache_mirror_up() {
    if [[ "${MS_TEST_NO_CACHE:-0}" == "1" ]]; then
        printf 'CACHE_UP_SKIPPED\n'
        MS_CACHE_MIRROR_STARTED_BY_RUN=0
        return 0
    fi
    printf 'CACHE_UP\n'
    MS_CACHE_MIRROR_STARTED_BY_RUN=1
}
cache_mirror_down() {
    [[ "${MS_CACHE_MIRROR_KEEP:-0}" == "1" ]] && return 0
    [[ "${MS_CACHE_MIRROR_STARTED_BY_RUN:-0}" == "1" ]] || return 0
    printf 'CACHE_DOWN\n'
    MS_CACHE_MIRROR_STARTED_BY_RUN=0
}
cache_preload_into_dind() { :; }
STUB
    cat >"$TMP_DIR/sandbox/tests/lib/dind.sh" <<'STUB'
dind_up() { :; }
dind_copy_repo() { :; }
dind_override_images() { :; }
dind_strip_services() { :; }
dind_down() { :; }
STUB
    printf '%s\n' ':' >"$TMP_DIR/sandbox/tests/lib/stack.sh"

    cat >"$TMP_DIR/sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "info" ]] && exit 0
exit 0
STUB
    chmod +x "$TMP_DIR/sandbox/bin/docker"
}

run_sandboxed_runner() {
    PATH="$TMP_DIR/sandbox/bin:$PATH" \
        "$TMP_DIR/sandbox/tests/run.sh" "$@" 2>&1
}

count_first_runs() {
    grep -c '^RUN:first$' <<<"${1:-}" || true
}

assert_not_contains_local() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "'$needle' was found" ;;
        *) pass "$name" ;;
    esac
}

# Empty scenario files must not reuse the previous scenario's function.
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/first.sh" <<'STUB'
run_scenario() { printf 'RUN:first\n'; }
STUB
: >"$TMP_DIR/sandbox/tests/scenarios/empty.sh"
output=$(run_sandboxed_runner first empty)
rc=$?

assert_eq "1" "$(count_first_runs "$output")" "test runner does not reuse run_scenario for empty scenario"
assert_contains "$output" "FAIL:scenario missing run_scenario:empty" "test runner reports missing run_scenario"
if ((rc != 0)); then
    pass "test runner exits non-zero when a scenario is missing run_scenario"
else
    fail "test runner exits non-zero when a scenario is missing run_scenario" "$output"
fi

# Truncated/syntax-broken scenario files must fail at source time and must not
# fall through to a stale function from the previous scenario.
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/first.sh" <<'STUB'
run_scenario() { printf 'RUN:first\n'; }
STUB
cat >"$TMP_DIR/sandbox/tests/scenarios/truncated.sh" <<'STUB'
run_scenario() {
STUB
output=$(run_sandboxed_runner first truncated)
rc=$?

assert_eq "1" "$(count_first_runs "$output")" "test runner does not reuse run_scenario after source failure"
assert_contains "$output" "FAIL:scenario source failed:truncated" "test runner reports scenario source failure"
if ((rc != 0)); then
    pass "test runner exits non-zero when scenario sourcing fails"
else
    fail "test runner exits non-zero when scenario sourcing fails" "$output"
fi

# A normal run stops the runner-owned registry mirror so it does not leave a
# host-side container or port binding behind.
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/ok.sh" <<'STUB'
run_scenario() { printf 'RUN:ok\n'; }
STUB
output=$(run_sandboxed_runner ok)
rc=$?

assert_contains "$output" "RUN:ok" "test runner reaches the scenario loop on a normal run"
assert_contains "$output" "CACHE_DOWN" "test runner stops runner-owned cache mirror on normal exit"
assert_eq "0" "$rc" "test runner exits zero for successful scenario"

# --no-cache skips mirror startup and must not stop a pre-existing mirror.
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/ok.sh" <<'STUB'
run_scenario() { printf 'RUN:ok\n'; }
STUB
output=$(run_sandboxed_runner --no-cache ok)
rc=$?

assert_contains "$output" "RUN:ok" "test runner reaches the scenario loop with --no-cache"
assert_contains "$output" "CACHE_UP_SKIPPED" "test runner bypasses cache mirror with --no-cache"
assert_not_contains_local "$output" "CACHE_DOWN" "test runner does not stop cache mirror when cache was bypassed"
assert_eq "0" "$rc" "test runner --no-cache exits zero for successful scenario"

# If the user intentionally keeps DinD for failure inspection, keep the mirror
# too so the retained inner daemon can still pull through its configured mirror.
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/fails.sh" <<'STUB'
run_scenario() { printf 'RUN:fails\n'; return 1; }
STUB
output=$(run_sandboxed_runner --keep fails)
rc=$?

assert_contains "$output" "RUN:fails" "test runner reaches the scenario loop with --keep"
assert_contains "$output" "FAIL:scenario exited non-zero:fails" "test runner records kept failure"
assert_not_contains_local "$output" "CACHE_DOWN" "test runner keeps cache mirror when DinD is kept for debugging"
if ((rc != 0)); then
    pass "test runner --keep failure exits non-zero"
else
    fail "test runner --keep failure exits non-zero" "$output"
fi

# --no-preload reaches the preload-skip branch, which echoes via ${BLUE}/${NC}
# under `set -u` — the stub assert.sh must define those colour vars or the runner
# aborts before the scenario loop (same drift class as the dind_override_images gap).
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/ok.sh" <<'STUB'
run_scenario() { printf 'RUN:ok\n'; }
STUB
output=$(run_sandboxed_runner --no-preload ok)
rc=$?

assert_contains "$output" "RUN:ok" "test runner reaches the scenario loop with --no-preload"
assert_contains "$output" "host image preload skipped" "test runner takes the preload-skip branch with --no-preload"
assert_eq "0" "$rc" "test runner --no-preload exits zero for successful scenario"

# MS_CACHE_MIRROR_KEEP=1 keeps a runner-owned mirror up even on a clean exit, so
# a persistent mirror survives across runs (mirrors tests/lib/cache.sh's guard).
setup_runner_sandbox
cat >"$TMP_DIR/sandbox/tests/scenarios/ok.sh" <<'STUB'
run_scenario() { printf 'RUN:ok\n'; }
STUB
output=$(MS_CACHE_MIRROR_KEEP=1 run_sandboxed_runner ok)
rc=$?

assert_contains "$output" "RUN:ok" "test runner reaches the scenario loop with MS_CACHE_MIRROR_KEEP"
assert_not_contains_local "$output" "CACHE_DOWN" "test runner keeps cache mirror when MS_CACHE_MIRROR_KEEP=1"
assert_eq "0" "$rc" "test runner exits zero with MS_CACHE_MIRROR_KEEP=1"

scenario_end "$CURRENT_SCENARIO"
summary
