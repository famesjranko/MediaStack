#!/usr/bin/env bash
# tests/unit/checks.sh
#
# Pure-bash unit tests for the PRE-* checks in scripts/setup/checks.sh.
# Shims df, stat, grep, awk as in-shell functions per the gpu-branching.sh
# pattern. Hard-fail (exit 1) paths are captured in a subshell:
#   ( check_x ); rc=$?
# No DinD, no Docker, no network. The host's actual disk/RAM are not touched —
# every probe used by the checks under test is shimmed before invocation.
#
# Split into tests/unit/checks/*.sh along the same topic lines as
# scripts/setup/checks/*.sh: preflight (pre-flight battery), existing-install
# (detect_existing_install), destroy (nuke_existing_install +
# _print_destroy_preview), integration (the set -euo pipefail sub-suite that
# spans all three). Children are sourced, not run as independent suites, so
# the historical assertion order and one summary count are preserved.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKS_TEST_DIR="$SCRIPT_DIR/checks"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="checks"
echo -e "${CYAN}${BOLD}▶ scenario: checks${NC}"

# Source setup.sh for the helper functions. The guard at setup.sh:206-208
# ensures main() does not run under `source`.
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# setup.sh sets -euo pipefail; relax so asserts can run a full pass/fail.
set +e
set +u

# Silence log_* output — the test drives its own assertions.
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_skip() { :; }

# Keep the historical assertion order: the children are sourced, not run as
# independent suites, so the frozen output and summary remain one suite.
# shellcheck source=checks/preflight.sh
source "$CHECKS_TEST_DIR/preflight.sh"
# shellcheck source=checks/existing-install.sh
source "$CHECKS_TEST_DIR/existing-install.sh"
# shellcheck source=checks/destroy.sh
source "$CHECKS_TEST_DIR/destroy.sh"
# shellcheck source=checks/integration.sh
source "$CHECKS_TEST_DIR/integration.sh"

echo -e "${CYAN}◀ checks done${NC}"
summary
