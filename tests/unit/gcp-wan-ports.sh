#!/usr/bin/env bash
# Unit test - GCP WAN blocked-port coverage
#
# Keeps tests/gcp-vm/run-fresh.sh aligned with the Docker LAN-only ports
# enforced by scripts/setup/hardening/admin-filter.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="gcp-wan-ports"
scenario_begin "$CURRENT_SCENARIO"

extract_hardening_ports() {
    # The admin-port filter keeps its TCP port groups once, in ADMIN_FILTER_TCP_GROUPS
    # (scripts/setup/hardening/admin-filter.sh), and renders both address families
    # and both install paths from it. Deduplicated and sorted: the GCP list is a
    # TCP probe list.
    sed -n 's/^ADMIN_FILTER_TCP_GROUPS=(\(.*\))$/\1/p' "$REPO_ROOT/scripts/setup/hardening/admin-filter.sh" \
        | tr -d '"' | tr ' ,' '\n' | sort -nu
}

extract_gcp_ports() {
    awk '
        /^LAN_ONLY_TCP_PORTS=\(/ { in_list = 1; next }
        in_list && /^\)/ { exit }
        in_list {
            gsub(/[[:space:]]+/, "", $0)
            if ($0 ~ /^[0-9]+$/) {
                print $0
            }
        }
    ' "$REPO_ROOT/tests/gcp-vm/run-fresh.sh" | sort -n
}

hardening_ports=$(extract_hardening_ports | paste -sd ' ' -)
gcp_ports=$(extract_gcp_ports | paste -sd ' ' -)

assert_eq "$hardening_ports" "$gcp_ports" "GCP WAN blocked-port list matches hardening Docker LAN-only ports"

step14_block=$(awk '
    /^step "14\. / { in_block = 1 }
    /^step "15\. / { exit }
    in_block { print }
' "$REPO_ROOT/tests/gcp-vm/run-fresh.sh")

assert_contains "$step14_block" 'for port in "${LAN_ONLY_TCP_PORTS[@]}"' "GCP WAN blocked-port probe iterates over canonical array"
assert_contains "$step14_block" "nc -zvw 3" "GCP WAN blocked-port probe uses TCP reachability"

if echo "$step14_block" | grep -q 'curl '; then
    fail "GCP WAN blocked-port probe does not use HTTP-only checks" "$step14_block"
else
    pass "GCP WAN blocked-port probe does not use HTTP-only checks"
fi

scenario_end "$CURRENT_SCENARIO"
summary
