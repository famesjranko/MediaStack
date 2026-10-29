#!/usr/bin/env bash
# Regression tests for standalone unit environment and verdict hygiene.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="test-hygiene"
scenario_begin "$CURRENT_SCENARIO"

# Given the caller keeps its cache mirror between runs.
RUNNER_SUITE="$SCRIPT_DIR/test-runner.sh"

# When the runner unit inherits that exported setting with its own verdict.
run_cmd env -u MS_UNIT_VERDICT_FILE MS_CACHE_MIRROR_KEEP=1 bash "$RUNNER_SUITE" </dev/null

# Then its cleanup and explicit mirror-retention cases both pass.
assert_rc 0 "test-runner passes with MS_CACHE_MIRROR_KEEP exported"

# Given the caller disables the cache for real scenario runs.
RUNNER_NO_CACHE=1

# When the runner unit inherits that setting with its own verdict.
run_cmd env -u MS_UNIT_VERDICT_FILE MS_TEST_NO_CACHE="$RUNNER_NO_CACHE" bash "$RUNNER_SUITE" </dev/null

# Then its normal-cache and explicit no-cache cases both pass.
assert_rc 0 "test-runner passes with MS_TEST_NO_CACHE exported"

# Given the standalone fail2ban unit has its own verdict.
FAIL2BAN_SUITE="$SCRIPT_DIR/launcher-fail2ban.sh"

# When the unit completes without caller input.
run_cmd env -u MS_UNIT_VERDICT_FILE bash "$FAIL2BAN_SUITE" </dev/null

# Then it passes and prints one scenario ending and one verdict.
assert_rc 0 "launcher-fail2ban passes"
assert_eq "1" "$(grep -c '^◀ ' <<<"$OUT" || true)" "launcher-fail2ban prints one scenario ending"
assert_eq "1" "$(grep -c ' passed,' <<<"$OUT" || true)" "launcher-fail2ban prints one verdict"

scenario_end "$CURRENT_SCENARIO"
summary
