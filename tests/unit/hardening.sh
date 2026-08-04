#!/usr/bin/env bash
# Owns: the ordered hardening unit-suite entry point.
# Sources: tests/unit/hardening/* and scripts/setup/hardening.sh via setup.sh.
# tests/unit/hardening.sh
#
# Pure-bash unit test for the OS hardening + SMB helpers in hardening.sh.
# No DinD, no Docker, no network. Shims override external commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARDENING_TEST_DIR="$SCRIPT_DIR"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="hardening"
echo -e "${CYAN}${BOLD}▶ scenario: hardening${NC}"

# Source setup.sh for the helper functions (guard prevents main() from running).
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# Relax strict mode for test assertions.
set +e
set +u

# Silence log_* output — tests drive their own assertions.
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_skip() { :; }
_ms_state_set() { :; }
_ms_state_get() { echo false; }

# Characterization: the end-to-end UFW fixtures below do not reach the helper
# rejection/IPv6 branches because they supply valid ports and IPv4 clients.
assert_eq "true" "$(ufw_valid_port 65535 && echo true || echo false)" \
    "ufw_valid_port: accepts the maximum port"
assert_eq "false" "$(ufw_valid_port 0 && echo true || echo false)" \
    "ufw_valid_port: rejects zero"
assert_eq "true" "$(ufw_valid_ip_literal 2001:db8::1 && echo true || echo false)" \
    "ufw_valid_ip_literal: accepts IPv6 literals"
assert_eq "false" "$(ufw_valid_ip_literal 999.1.1.1 && echo true || echo false)" \
    "ufw_valid_ip_literal: rejects invalid IPv4 literals"

# Keep the historical assertion order: the children are sourced, not run as
# independent suites, so the frozen output and summary remain one suite.
source "$HARDENING_TEST_DIR/hardening/firewall.sh"
source "$HARDENING_TEST_DIR/hardening/ssh.sh"
source "$HARDENING_TEST_DIR/hardening/updates.sh"
source "$HARDENING_TEST_DIR/hardening/sysctl.sh"
source "$HARDENING_TEST_DIR/hardening/gpu-runtime.sh"
source "$HARDENING_TEST_DIR/hardening/samba.sh"
source "$HARDENING_TEST_DIR/hardening/ports.sh"

echo -e "${CYAN}◀ hardening done${NC}"
summary
