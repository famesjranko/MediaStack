#!/usr/bin/env bash
# Tests the IPv6 DOCKER-USER jump order without reading host firewall state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="health-docker-user-ipv6"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/health.sh"
set -eo pipefail

AF_TMP=$(mktemp -d)
export MEDIASTACK_ADMIN_FILTER_DROPIN="$AF_TMP/mediastack-admin-filter.conf"
export MEDIASTACK_ADMIN_FILTER_UNIT="$AF_TMP/mediastack-admin-filter.service"
touch "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_UNIT"

DU6_PRESENT=1
DU6_JUMP=1
DU6_RULES="-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 80 -j DROP"
DU6_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n-A DOCKER-USER -j RETURN'

admin_filter_opted_out() { return 1; }
_health_sudo_ok() { return 0; }
systemctl() { [[ "$1" == is-active ]]; }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "$1" in
        iptables)
            case "$*" in
                *"-C DOCKER-USER"*) return 0 ;;
                *"-S DOCKER-USER"*) printf '%s\n' '-N DOCKER-USER' '-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT' ;;
                *"-S "*) printf '%s\n' '-A MEDIASTACK-DOCKER-RESTRICT -p tcp -m multiport --dports 80 -j DROP' ;;
            esac
            ;;
        ip6tables)
            case "$*" in
                *"-S DOCKER-USER"*) ((DU6_PRESENT)) && printf '%s\n' "$DU6_USER_RULES" ;;
                *"-C DOCKER-USER"*) return $((1 - DU6_JUMP)) ;;
                *"-S "*) printf '%s\n' "$DU6_RULES" ;;
            esac
            ;;
    esac
}

_v() {
    local expected="$1" label="$2" out
    out=$(health_docker_user_restrict)
    assert_eq "$expected" "${out%%|*}" "$label -> $out"
}

# Given an IPv6 jump behind Docker's RETURN rule
# When the port-lock health check runs
# Then it fails and names IPv6
DU6_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j RETURN\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT'
_v fail "docker-user IPv6: jump behind RETURN"
assert_contains "$(health_docker_user_restrict)" "IPv6" "docker-user IPv6: failure names IPv6"

# Given an IPv6 jump ahead of Docker's RETURN rule
# When the port-lock health check runs
# Then it reports active protection
DU6_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n-A DOCKER-USER -j RETURN'
_v ok "docker-user IPv6: jump ahead of RETURN"

# Given Docker has no IPv6 DOCKER-USER chain
# When the port-lock health check runs
# Then IPv6 contributes no failure
DU6_PRESENT=0
_v ok "docker-user IPv6: no chain is silent"

rm -rf "$AF_TMP"
scenario_end "$CURRENT_SCENARIO"
summary
