#!/usr/bin/env bash
# tests/unit/assertions.sh
#
# Fail-closed proof for the fresh-install evidence assertions under
# tests/assertions/ (sonarr, radarr, jackett, seerr). Each case runs the real
# assertion function against stubbed DinD helpers and captures the verdict
# lines it emits, so a read that fails, a fixture that cannot be read or a
# malformed response must produce a FAIL and never a vacuous PASS.
#
# The assertion files are sourced from MS_TEST_ASSERT_ROOT (default: this
# checkout) so the suite can be pointed at an older tree to show it fails there.
# Pure bash + python3; no DinD, no Docker, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ASSERT_ROOT="${MS_TEST_ASSERT_ROOT:-$REPO_ROOT}"

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="assertions"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# The assertion files source siblings by repo-relative path.
cd "$ASSERT_ROOT" || exit 1

# Run one assertion function in a subshell whose pass/fail/skip print verdict
# lines instead of counting, and print those lines. The suite's own counters
# stay untouched. Usage: verdicts <function> [args...]
verdicts() {
    (
        pass() { printf 'PASS\t%s\n' "$1"; }
        fail() { printf 'FAIL\t%s\t%s\n' "$1" "${2:-}"; }
        skip() { printf 'SKIP\t%s\t%s\n' "$1" "${2:-}"; }
        "$@"
    ) 2>/dev/null
}

# Count verdict lines of one kind whose name contains a substring.
# Usage: verdict_count <lines> <PASS|FAIL|SKIP> <substring>
verdict_count() {
    printf '%s\n' "$1" | grep -c "^$2"$'\t'"[^"$'\t'"]*$3" || true
}

# Stubs shared by every fragment; each fragment refines them.
svc_stripped() { return 1; }
env_get() { printf 'admin'; }
get_api_key_from_xml() { printf 'KEY-%s' "$(basename "$(dirname "$1")")"; }
dind_write_file() { cat >/dev/null; }

# shellcheck source=tests/unit/assertions/arr.sh
source "$SCRIPT_DIR/assertions/arr.sh"
# shellcheck source=tests/unit/assertions/jackett.sh
source "$SCRIPT_DIR/assertions/jackett.sh"
# shellcheck source=tests/unit/assertions/seerr.sh
source "$SCRIPT_DIR/assertions/seerr.sh"

summary
