#!/usr/bin/env bash
# tests/unit/stage2-ports.sh
#
# Contract tests for Stage 2 TCP 80/443 gate and residential failure
# classification. Network primitives are stubbed; no external probes run.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage2-ports"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/network.sh"
[[ -f "$REPO_ROOT/scripts/lib/validators.sh" ]] && source "$REPO_ROOT/scripts/lib/validators.sh"
source "$REPO_ROOT/scripts/setup/stages/stage2.sh"

set +e
set +u

WARN_COUNT=0
LAST_WARN=""
ui_log() {
    local level="$1"
    shift
    if [[ "$level" == "warn" ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        LAST_WARN="$*"
    fi
}
reset_warn() {
    WARN_COUNT=0
    LAST_WARN=""
}
sudo() { "$@"; }

STAGE2_PORT80_OPEN=1
STAGE2_PORT443_OPEN=1
# stage2_check_http_ports now uses net_check_tcp_port_external (true
# external probe via portchecker.io / canyouseeme.org / yougetsignal),
# replacing the old hairpin-NAT-dependent net_check_tcp_port. Tests
# stub the external probe since these are unit tests with no network.
net_check_tcp_port_external() {
    case "$1" in
        80)
            [[ "$STAGE2_PORT80_OPEN" == "2" ]] && return 2
            [[ "$STAGE2_PORT80_OPEN" == "1" ]]
            ;;
        443)
            [[ "$STAGE2_PORT443_OPEN" == "2" ]] && return 2
            [[ "$STAGE2_PORT443_OPEN" == "1" ]]
            ;;
        *) return 1 ;;
    esac
}

if ! type validate_wireguard_port >/dev/null 2>&1; then
    validate_wireguard_port() { return 99; }
fi

STAGE2_PORT80_OPEN=1 STAGE2_PORT443_OPEN=1
assert_eq "ok" "$(stage2_check_http_ports)" "TCP 80 and 443 open classifies as ok"

STAGE2_PORT80_OPEN=0 STAGE2_PORT443_OPEN=1
assert_eq "closed:80" "$(stage2_check_http_ports)" "closed TCP 80 is reported"

STAGE2_PORT80_OPEN=1 STAGE2_PORT443_OPEN=0
assert_eq "closed:443" "$(stage2_check_http_ports)" "closed TCP 443 is reported"

STAGE2_PORT80_OPEN=2 STAGE2_PORT443_OPEN=1
assert_eq "probe-unavailable:80" "$(stage2_check_http_ports)" "external probe failure is not reported as closed TCP 80"

STAGE2_PORT80_OPEN=1 STAGE2_PORT443_OPEN=2
assert_eq "probe-unavailable:443" "$(stage2_check_http_ports)" "external probe failure is not reported as closed TCP 443"

STAGE2_PORT80_OPEN=2 STAGE2_PORT443_OPEN=2
assert_eq "probe-unavailable:80,443" "$(stage2_check_http_ports)" "both external probe failures are reported separately"

STAGE2_PORT80_OPEN=0 STAGE2_PORT443_OPEN=0
assert_eq "cgnat" "$(stage2_classify_port_failure "100.64.10.2" "ok" "closed:80,443")" "RFC6598 public IP classifies as cgnat"
assert_eq "aaaa-mismatch" "$(stage2_classify_port_failure "203.0.113.10" "aaaa-mismatch" "closed:80,443")" "AAAA mismatch is surfaced"
assert_eq "cloudflare" "$(stage2_classify_port_failure "203.0.113.10" "cloudflare" "closed:80,443")" "Cloudflare DNS state cross-links to port failure"
assert_eq "hairpin-ambiguous" "$(stage2_classify_port_failure "203.0.113.10" "ok" "closed:80,443" "hairpin")" "closed ports with hairpin caveat are ambiguous"
assert_eq "carrier-block" "$(stage2_classify_port_failure "203.0.113.10" "ok" "closed:80,443" "carrier")" "carrier/ISP block is classified"
assert_eq "probe-unavailable" "$(stage2_classify_port_failure "203.0.113.10" "ok" "probe-unavailable:80,443")" "unavailable external probe services classify separately"

STAGE2_PORT_GATE_TMP="$(mktemp -d)"
printf '0\n' >"$STAGE2_PORT_GATE_TMP/calls"
printf '\n' >"$STAGE2_PORT_GATE_TMP/default"
ui_section() { :; }
sleep() { :; }
stage2_check_http_ports() {
    local calls
    calls=$(cat "$STAGE2_PORT_GATE_TMP/calls")
    calls=$((calls + 1))
    printf '%s\n' "$calls" >"$STAGE2_PORT_GATE_TMP/calls"
    printf '%s\n' 'probe-unavailable:80,443'
}
ui_choose() {
    shift # prompt arg unused by this mock
    local items=("$@")
    local default_index="${UI_CHOOSE_DEFAULT_INDEX:-1}"
    printf '%s\n' "$default_index" >"$STAGE2_PORT_GATE_TMP/default"
    printf '%s\n' "${items[$((default_index - 1))]}"
}
if UI_DEMO=1 _stage2_port_gate >/dev/null 2>&1; then
    pass "UI_DEMO continues when external port probes are unavailable"
else
    fail "UI_DEMO continues when external port probes are unavailable"
fi
assert_eq "2" "$(cat "$STAGE2_PORT_GATE_TMP/default")" "UI_DEMO defaults port probe-unavailable to manual verification"
assert_eq "3" "$(cat "$STAGE2_PORT_GATE_TMP/calls")" "UI_DEMO does not loop after probe-unavailable menu"
unset -f ui_section sleep stage2_check_http_ports ui_choose
rm -rf "$STAGE2_PORT_GATE_TMP"

reset_warn
ss() { printf 'Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'; }
validate_wireguard_port "51820"
rc=$?
assert_eq "0" "$rc" "validate_wireguard_port accepts free default UDP port"
unset -f ss

for port in "notaport" "0" "70000"; do
    reset_warn
    validate_wireguard_port "$port"
    rc=$?
    assert_eq "1" "$rc" "validate_wireguard_port rejects '$port'"
    assert_eq "1" "$WARN_COUNT" "validate_wireguard_port warns once for '$port'"
done

reset_warn
ss() {
    printf 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process\n'
    printf 'udp   UNCONN 0      0            0.0.0.0:51820      0.0.0.0:*     users:(("other-vpn",pid=333,fd=7))\n'
}
validate_wireguard_port "51820"
rc=$?
assert_eq "1" "$rc" "validate_wireguard_port rejects UDP collision"
assert_contains "$LAST_WARN" "other-vpn" "validate_wireguard_port collision names process"
unset -f ss

reset_warn
WG_PORT="51820"
ss() {
    printf 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process\n'
    printf 'udp   UNCONN 0      0            0.0.0.0:51820      0.0.0.0:*     users:(("docker-proxy",pid=333,fd=7))\n'
}
docker() {
    if [[ "${1:-}" == "ps" ]]; then
        printf 'wireguard 0.0.0.0:51820->51820/udp\n'
    fi
}
validate_wireguard_port "51820"
rc=$?
assert_eq "0" "$rc" "validate_wireguard_port allows existing MediaStack wireguard listener"
assert_eq "0" "$WARN_COUNT" "existing MediaStack wireguard listener does not warn"
unset WG_PORT
unset -f ss docker

reset_warn
# Consumed by _validators_wireguard_port_is_mediastack in scripts/lib/validators/network.sh.
# shellcheck disable=SC2034
WG_PORT="51820"
ss() {
    printf 'Netid State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process\n'
    printf 'udp   UNCONN 0      0            0.0.0.0:51820      0.0.0.0:*     users:(("docker-proxy",pid=333,fd=7))\n'
}
docker() {
    if [[ "${1:-}" == "ps" ]]; then
        printf 'not-wireguard 0.0.0.0:51820->51820/udp\n'
    fi
}
validate_wireguard_port "51820"
rc=$?
assert_eq "1" "$rc" "validate_wireguard_port rejects non-MediaStack docker listener"
assert_contains "$LAST_WARN" "docker-proxy" "non-MediaStack docker listener names process"
unset WG_PORT
unset -f ss docker

scenario_end "$CURRENT_SCENARIO"
summary
