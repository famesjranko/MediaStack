#!/usr/bin/env bash
# tests/unit/stage1-qbit-math.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-qbit-math"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/checks.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

set +e
set +u

export UI_DEMO=1
_discovery_speed_ok=true
_NET_PUBLIC_IP="203.0.113.42"
_NET_DL_MBPS=120
_NET_UL_MBPS=40

LOG_CAPTURE=""
ui_log() {
    local level="$1"
    shift
    LOG_CAPTURE+="${level}:$*\n"
}

net_is_port_locally_bound() { return 0; } # simulate local bind conflict
_stage1_collect_qbit

assert_eq "7.5" "$_WIZ_DL_LIMIT" "stage1-qbit-math: 50% download default"
assert_eq "1.2" "$_WIZ_UL_LIMIT" "stage1-qbit-math: 25% upload default"
assert_eq "6881" "$_WIZ_TORRENT_PORT" "stage1-qbit-math: default torrent port"
# Semantics flipped: at this point qBittorrent isn't running, so a port that
# IS open from this host means another process is squatting (real conflict);
# closed means "free for qBit to bind, public reachability TBD after install."
# net_is_port_locally_bound is stubbed to 0 (line 35) so port 6881 reads as
# bound — that should warn about a real conflict, not celebrate reachability.
assert_contains "$LOG_CAPTURE" "already in use by another process" "stage1-qbit-math: open-port flagged as real conflict (qBit not started yet)"
if [[ "$LOG_CAPTURE" == *"hairpin NAT"* ]]; then
    fail "stage1-qbit-math: legacy hairpin caveat must not appear under new semantics"
else
    pass "stage1-qbit-math: legacy hairpin caveat removed"
fi

# Closed port = available for qBit to bind. The wizard should NOT warn about
# router forwarding here — that check belongs after the stack starts.
LOG_CAPTURE=""
net_is_port_locally_bound() { return 1; } # simulate "nothing listening" (the GOOD case)
_NET_PUBLIC_IP="203.0.113.42"
_WIZ_TORRENT_PORT=6881
_stage1_collect_qbit

assert_contains "$LOG_CAPTURE" "available" "stage1-qbit-math: closed-port reported as available"
assert_contains "$LOG_CAPTURE" "public reachability will be verified after qBittorrent starts" "stage1-qbit-math: defers public-reachability message to post-install"
if [[ "$LOG_CAPTURE" == *"appears closed from this host"* || "$LOG_CAPTURE" == *"Router forwarding may still be needed"* ]]; then
    fail "stage1-qbit-math: legacy 'closed/router forwarding' warn must not appear before qBit starts"
else
    pass "stage1-qbit-math: no premature router-forwarding warn on closed-port branch"
fi
unset -f net_is_port_locally_bound

# Public IP detection is irrelevant to the Stage 1 qBittorrent prompt now.
# This is a local bind check only: no public IP should still report whether
# the port is available for qBittorrent to bind.
LOG_CAPTURE=""
_NET_PUBLIC_IP=""
net_is_port_locally_bound() { return 1; }
_stage1_collect_qbit
assert_contains "$LOG_CAPTURE" "available" "stage1-qbit-math: no-public-IP still performs local availability check"
unset -f net_is_port_locally_bound

unset UI_DEMO

scenario_end "$CURRENT_SCENARIO"
summary
