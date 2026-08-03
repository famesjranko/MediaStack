#!/usr/bin/env bash
# tests/unit/speedtest.sh
#
# Unit coverage for net_run_speedtest (scripts/lib/network.sh): the curl+Cloudflare
# primary method, the librespeed-cli fallback, graceful failure, and the UI_DEMO
# short-circuit. External commands (curl, librespeed-cli, timeout) are stubbed;
# real python3 does the byte/sec -> Mbps and JSON parsing so the parser is exercised.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="speedtest"
scenario_begin "$CURRENT_SCENARIO"

# shellcheck source=../../scripts/lib/network.sh
source "$REPO_ROOT/scripts/lib/network.sh"

set +e
set +u

# --- 1. curl+Cloudflare primary path --------------------------------------
# 12_500_000 B/s * 8 / 1e6 = 100 Mbps; 5_000_000 B/s = 40 Mbps.
curl() {
    if [[ "$*" == *"__down"* ]]; then
        echo "12500000"
        return 0
    fi
    if [[ "$*" == *"__up"* ]]; then
        cat >/dev/null 2>&1
        echo "5000000"
        return 0
    fi
    return 0
}
net_run_speedtest
rc=$?
assert_eq "0" "$rc" "curl path: returns success"
assert_eq "100" "$_NET_DL_MBPS" "curl path: download bytes/sec -> integer Mbps"
assert_eq "40" "$_NET_UL_MBPS" "curl path: upload bytes/sec -> integer Mbps"
unset -f curl

# --- 2. librespeed-cli fallback when curl fails ----------------------------
curl() {
    cat >/dev/null 2>&1 || true
    return 1
} # primary method fails
timeout() {
    shift
    "$@"
} # strip duration, resolve the stub fn
librespeed-cli() { printf '%s\n' '[{"download":97.68,"upload":28.23,"ping":12}]'; }
net_run_speedtest
rc=$?
assert_eq "0" "$rc" "fallback: returns success via librespeed-cli"
assert_eq "97" "$_NET_DL_MBPS" "fallback: librespeed download Mbps (int-truncated)"
assert_eq "28" "$_NET_UL_MBPS" "fallback: librespeed upload Mbps (int-truncated)"
unset -f librespeed-cli

# --- 3. both methods fail -> graceful 1, globals cleared -------------------
librespeed-cli() { return 1; }
net_run_speedtest
rc=$?
assert_eq "1" "$rc" "both fail: returns failure"
assert_eq "" "$_NET_DL_MBPS" "both fail: download global cleared"
assert_eq "" "$_NET_UL_MBPS" "both fail: upload global cleared"
unset -f curl timeout librespeed-cli

# --- 4. malformed curl output is rejected (no bogus values leak) -----------
curl() {
    if [[ "$*" == *"__down"* ]]; then
        echo "not-a-number"
        return 0
    fi
    if [[ "$*" == *"__up"* ]]; then
        cat >/dev/null 2>&1
        echo "5000000"
        return 0
    fi
}
librespeed-cli() { return 1; }
timeout() {
    shift
    "$@"
}
net_run_speedtest
rc=$?
assert_eq "1" "$rc" "malformed: non-numeric curl output rejected"
assert_eq "" "$_NET_DL_MBPS" "malformed: download global left empty"
unset -f curl timeout librespeed-cli

# --- 4b. slow-link timeout: curl exits 28 but still emits the sustained rate -
# A downlink too slow to finish the fixed payload within --max-time times out
# (exit 28) yet curl still prints %{speed_*}. That is a valid measurement and
# must be kept. Under the old `|| return 1` the value was
# discarded and the whole method failed; librespeed-cli is absent here, so a
# regression surfaces as rc=1 with empty globals.
curl() {
    if [[ "$*" == *"__down"* ]]; then
        echo "1250000"
        return 28
    fi # 10 Mbps, timed out
    if [[ "$*" == *"__up"* ]]; then
        cat >/dev/null 2>&1
        echo "625000"
        return 28
    fi # 5 Mbps
}
librespeed-cli() { return 1; }
timeout() {
    shift
    "$@"
}
net_run_speedtest
rc=$?
assert_eq "0" "$rc" "slow-link timeout: measurement kept despite curl exit 28"
assert_eq "10" "$_NET_DL_MBPS" "slow-link timeout: download rate still recorded"
assert_eq "5" "$_NET_UL_MBPS" "slow-link timeout: upload rate still recorded"
unset -f curl timeout librespeed-cli

# --- 5. UI_DEMO short-circuit ----------------------------------------------
export UI_DEMO=1 # export: consumed inside sourced network.sh (avoids shellcheck SC2034)
net_run_speedtest
rc=$?
assert_eq "0" "$rc" "UI_DEMO: returns success without any network"
assert_eq "120" "$_NET_DL_MBPS" "UI_DEMO: fixed 120 Mbps download"
assert_eq "40" "$_NET_UL_MBPS" "UI_DEMO: fixed 40 Mbps upload"
unset UI_DEMO

scenario_end "$CURRENT_SCENARIO"
summary
