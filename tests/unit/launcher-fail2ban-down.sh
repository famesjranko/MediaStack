#!/usr/bin/env bash
# tests/unit/launcher-fail2ban-down.sh
#
# The "Manage fail2ban" entry guard when fail2ban is not running. A host without
# a domain never had fail2ban (LAN-only); a remote-access host whose fail2ban
# stopped is unprotected and must be told how to start it. The launcher is
# sourced for its real submenu_fail2ban; docker and the UI helpers are stubbed.
#
# Run directly: ./tests/unit/launcher-fail2ban-down.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-fail2ban-down"
scenario_begin "$CURRENT_SCENARIO"

_open_menu() { # $1 = exit code of _health_f2b_installed
    MEDIASTACK_NONINTERACTIVE=1 INSTALLED_RC="$1" bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      _docker_reachable(){ return 0; }
      _health_f2b_running(){ return 1; }
      _health_f2b_installed(){ return "$INSTALLED_RC"; }
      ui_log(){ shift; echo "$*"; }
      launcher_pause_for_menu(){ :; }
      submenu_fail2ban
    ' 2>&1
}

# Given: fail2ban is not installed (LAN-only host)
# When: the fail2ban menu opens
lan_out=$(_open_menu 1)
# Then: it explains that LAN-only installs have nothing to protect
assert_contains "$lan_out" "fail2ban isn't installed" "LAN-only host: says fail2ban is not installed"
assert_contains "$lan_out" "LAN-only installs" "LAN-only host: explains why there is nothing to protect"
assert_not_contains "$lan_out" "Start a service" "LAN-only host: gives no start instruction"

# Given: fail2ban is installed (remote-access host) but stopped
# When: the fail2ban menu opens
stopped_out=$(_open_menu 0)
# Then: it says fail2ban is stopped and how to start it
assert_contains "$stopped_out" "fail2ban is installed but not running" "stopped host: says installed but not running"
assert_contains "$stopped_out" "Start a service > fail2ban" "stopped host: says how to start it"
# And: it does not call the host LAN-only
assert_not_contains "$stopped_out" "LAN-only" "stopped host: not reported as LAN-only"

scenario_end "$CURRENT_SCENARIO"
summary
