#!/usr/bin/env bash
# tests/unit/stack-network.sh
#
# Unit tests for adaptive MediaStack Docker subnet selection. Host networking
# and Docker are shimmed; no real routes, addresses, or containers are touched.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stack-network"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"

if bash -euo pipefail -c "SCRIPT_DIR=/tmp; CONFIG_FILE=/dev/null; source '$REPO_ROOT/scripts/lib/common.sh'; source '$REPO_ROOT/scripts/setup/stack.sh'; source '$REPO_ROOT/scripts/setup/stack.sh'; declare -F ensure_mediastack_network_config >/dev/null"; then
    pass "stack.sh module can be re-sourced under strict mode"
else
    fail "stack.sh module can be re-sourced under strict mode"
fi

set +e
set +u

NETWORK_SELECTOR="$REPO_ROOT/scripts/setup/render/network_selector.py"

ROUTES_TEXT=""
ADDRS_TEXT=""
DOCKER_JSON="[]"
MEDIASTACK_JSON=""

ip() {
    case "$*" in
        "-o -4 route show") printf '%s\n' "$ROUTES_TEXT" ;;
        "-o -4 addr show") printf '%s\n' "$ADDRS_TEXT" ;;
        *) return 1 ;;
    esac
}

docker() {
    if [[ "${1:-}" == "network" && "${2:-}" == "ls" && "${3:-}" == "-q" ]]; then
        printf 'net1\n'
        return 0
    fi
    if [[ "${1:-}" == "network" && "${2:-}" == "inspect" && "${3:-}" == "mediastack" ]]; then
        [[ -n "$MEDIASTACK_JSON" ]] || return 1
        printf '%s\n' "$MEDIASTACK_JSON"
        return 0
    fi
    if [[ "${1:-}" == "network" && "${2:-}" == "inspect" ]]; then
        printf '%s\n' "$DOCKER_JSON"
        return 0
    fi
    return 0
}

log_ok() { :; }
log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*"; }
log_skip() { :; }

_tmpdirs=()
setup_env() {
    local stage1="${1:-}"
    local prefix="${2:-}"
    local dir
    dir=$(mktemp -d)
    _tmpdirs+=("$dir")
    SCRIPT_DIR="$dir"
    {
        printf 'STAGE_1_COMPLETE=%s\n' "$stage1"
        if [[ -n "$prefix" ]]; then
            printf 'MEDIASTACK_NETWORK_PREFIX=%s\n' "$prefix"
            printf 'MEDIASTACK_SUBNET=%s.0/24\n' "$prefix"
            printf 'MEDIASTACK_GATEWAY=%s.1\n' "$prefix"
            printf 'MEDIASTACK_NPM_IP=%s.10\n' "$prefix"
        fi
    } >"$dir/.env"
    unset MEDIASTACK_NETWORK_PREFIX MEDIASTACK_SUBNET MEDIASTACK_GATEWAY MEDIASTACK_NPM_IP STAGE_1_COMPLETE
}

cleanup_envs() {
    local dir
    for dir in "${_tmpdirs[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup_envs EXIT

run_selector() {
    local routes="$1" addrs="$2" docker_json="$3" mediastack_json="$4"
    shift 4
    local dir
    dir=$(mktemp -d)
    _tmpdirs+=("$dir")
    printf '%s' "$routes" >"$dir/routes.txt"
    printf '%s' "$addrs" >"$dir/addrs.txt"
    printf '%s' "$docker_json" >"$dir/docker.json"
    printf '%s' "$mediastack_json" >"$dir/mediastack.json"
    env "$@" python3 "$NETWORK_SELECTOR" "$dir/routes.txt" "$dir/addrs.txt" "$dir/docker.json" "$dir/mediastack.json"
}

selector_out=$(run_selector \
    $'default via 192.168.1.1 dev eth0\n192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[]' '')
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.28.0" "network selector render: default prefix protocol"
assert_contains "$selector_out" "MEDIASTACK_SUBNET=172.28.0.0/24" "network selector render: default subnet protocol"

selector_out=$(run_selector \
    'default via 192.168.1.1 dev eth0' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[]' '' \
    REQUESTED_PREFIX=172.30.42 REQUESTED_SUBNET=172.30.42.0/25 REQUESTED_GATEWAY=172.30.42.1)
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.30.42" "network selector render: valid requested prefix wins"
assert_contains "$selector_out" "MEDIASTACK_SUBNET=172.30.42.0/24" "network selector render: fresh requested prefix uses canonical /24"
assert_contains "$selector_out" "MEDIASTACK_GATEWAY=172.30.42.1" "network selector render: requested gateway preserved"

selector_out=$(run_selector \
    'default via 192.168.1.1 dev eth0' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[]' '' \
    REQUESTED_PREFIX=172.30.42 REQUESTED_SUBNET=172.30.42.0/24 REQUESTED_GATEWAY=not-an-ip)
assert_contains "$selector_out" "MEDIASTACK_GATEWAY=172.30.42.1" "network selector render: invalid requested gateway falls back"

selector_out=$(run_selector \
    'default via 192.168.1.1 dev eth0' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[{"Name":"other","IPAM":{"Config":[{"Subnet":"not-a-network"}]}}]' '')
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.28.0" "network selector render: invalid Docker subnet is ignored"

selector_out=$(run_selector \
    'default via 192.168.1.1 dev eth0' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[]' '' \
    REQUESTED_PREFIX=172.99.0)
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.28.0" "network selector render: invalid requested prefix falls back"

selector_out=$(run_selector \
    '172.28.0.0/24 dev tun0 scope link' \
    '10: tun0    inet 172.28.0.5/24 scope global tun0' \
    '[]' '' \
    STAGE1_COMPLETE=true REQUESTED_PREFIX=172.28.0 REQUESTED_SUBNET=172.28.0.0/24 REQUESTED_GATEWAY=172.28.0.1)
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.29.0" "network selector render: STAGE1_COMPLETE true is not completed"

selector_out=$(run_selector \
    '172.28.0.0/24 dev tun0 scope link' \
    '10: tun0    inet 172.28.0.5/24 scope global tun0' \
    '[]' '' \
    STAGE1_COMPLETE=1 REQUESTED_PREFIX=172.28.0 REQUESTED_SUBNET=172.28.0.0/24 REQUESTED_GATEWAY=172.28.0.1 2>&1)
selector_rc=$?
if [[ "$selector_rc" -ne 0 ]]; then
    pass "network selector render: completed conflict exits non-zero"
else
    fail "network selector render: completed conflict exits non-zero" "expected non-zero"
fi
assert_contains "$selector_out" "ERROR: MediaStack is already installed" "network selector render: completed conflict emits ERROR"
assert_contains "$selector_out" "INFO: MediaStack will not silently migrate" "network selector render: completed conflict emits INFO"

selector_out=$(run_selector \
    '172.29.0.0/24 dev br-mediastack proto kernel scope link src 172.29.0.1' \
    '9: br-mediastack    inet 172.29.0.1/24 scope global br-mediastack' \
    '[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.29.0.0/24","Gateway":"172.29.0.1"}]}}]' \
    '[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.29.0.0/24","Gateway":"172.29.0.1"}]}}]' \
    STAGE1_COMPLETE=1 REQUESTED_PREFIX=172.28.0 REQUESTED_SUBNET=172.28.0.0/24 REQUESTED_GATEWAY=172.28.0.1)
assert_contains "$selector_out" "MEDIASTACK_NETWORK_PREFIX=172.29.0" "network selector render: completed install follows live network"

selector_out=$(run_selector \
    $'default via 192.168.1.1 dev eth0\n192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50' \
    '2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0' \
    '[]' '' \
    STAGE1_COMPLETE=1 REQUESTED_PREFIX=172.28.0 REQUESTED_SUBNET=172.28.0.0/16 REQUESTED_GATEWAY=172.28.0.1)
assert_contains "$selector_out" "MEDIASTACK_SUBNET=172.28.0.0/16" "network selector render: completed legacy /16 preserved"
assert_contains "$selector_out" "MEDIASTACK_GATEWAY=172.28.0.1" "network selector render: completed requested gateway preserved"

selector_out=$(run_selector \
    '172.16.0.0/12 dev tun0 scope link' \
    '10: tun0    inet 172.16.4.5/12 scope global tun0' \
    '[]' '' 2>&1)
selector_rc=$?
if [[ "$selector_rc" -ne 0 ]]; then
    pass "network selector render: exhausted range exits non-zero"
else
    fail "network selector render: exhausted range exits non-zero" "expected non-zero"
fi
assert_contains "$selector_out" "ERROR: No available MediaStack Docker subnet" "network selector render: exhaustion emits ERROR"
assert_contains "$selector_out" "INFO: Disconnect or narrow the conflicting VPN route" "network selector render: exhaustion emits INFO"

# No conflicts: default /24 is selected and written.
ROUTES_TEXT=$'default via 192.168.1.1 dev eth0\n192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50'
ADDRS_TEXT='2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env ""
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: no conflict succeeds"
assert_eq "172.28.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: no conflict selects default prefix"
assert_eq "172.28.0.0/24" "$(_stack_env_get MEDIASTACK_SUBNET)" "network selector: writes /24 subnet"

# Default route is ignored, but a specific 172.28 route causes fallback.
ROUTES_TEXT=$'default via 172.28.0.1 dev tun0\n172.28.0.0/16 dev tun0'
ADDRS_TEXT='7: tun0    inet 172.28.4.20/16 scope global tun0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env ""
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: 172.28 conflict falls back"
assert_eq "172.29.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: fallback prefers 172.29.0"

# Split-default VPN routes are catchall internet routing, not specific subnet
# ownership. They should not make every Docker 172.16/12 candidate look taken.
ROUTES_TEXT=$'0.0.0.0/1 dev tun0\n128.0.0.0/1 dev tun0'
ADDRS_TEXT='7: tun0    inet 10.8.0.5/24 scope global tun0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env ""
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: split-default VPN routes are ignored"
assert_eq "172.28.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: split-default VPN keeps default prefix"

# Existing Docker networks are collision sources.
ROUTES_TEXT=$'default via 192.168.1.1 dev eth0'
ADDRS_TEXT='2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0'
DOCKER_JSON='[{"Name":"other","IPAM":{"Config":[{"Subnet":"172.28.0.0/24"}]}}]'
MEDIASTACK_JSON=''
setup_env ""
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: Docker network conflict falls back"
assert_eq "172.29.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: Docker conflict selects next prefix"

# Existing MediaStack network routes are ignored for completed installs.
ROUTES_TEXT='172.28.0.0/16 dev br-mediastack proto kernel scope link src 172.28.0.1'
ADDRS_TEXT='9: br-mediastack    inet 172.28.0.1/16 scope global br-mediastack'
DOCKER_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.28.0.0/16"}]}}]'
MEDIASTACK_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.28.0.0/16"}]}}]'
setup_env "1" "172.28.0"
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: existing MediaStack route ignored"
assert_eq "172.28.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: completed install keeps locked prefix"
assert_eq "172.28.0.0/16" "$(_stack_env_get MEDIASTACK_SUBNET)" "network selector: completed install preserves existing network IPAM"

# Completed installs use the live Docker network as source of truth when .env is stale.
ROUTES_TEXT='172.29.0.0/24 dev br-mediastack proto kernel scope link src 172.29.0.1'
ADDRS_TEXT='9: br-mediastack    inet 172.29.0.1/24 scope global br-mediastack'
DOCKER_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.29.0.0/24","Gateway":"172.29.0.1"}]}}]'
MEDIASTACK_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.29.0.0/24","Gateway":"172.29.0.1"}]}}]'
setup_env "1" "172.28.0"
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: stale completed .env follows live network"
assert_eq "172.29.0" "$(_stack_env_get MEDIASTACK_NETWORK_PREFIX)" "network selector: stale completed .env prefix corrected"
assert_eq "172.29.0.0/24" "$(_stack_env_get MEDIASTACK_SUBNET)" "network selector: stale completed .env subnet corrected"

# Same CIDR on a non-MediaStack interface is still a real collision.
ROUTES_TEXT=$'172.28.0.0/16 dev br-mediastack proto kernel scope link src 172.28.0.1\n172.28.0.0/16 dev tun0 scope link'
ADDRS_TEXT=$'9: br-mediastack    inet 172.28.0.1/16 scope global br-mediastack\n10: tun0    inet 172.28.4.20/16 scope global tun0'
DOCKER_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.28.0.0/16"}]}}]'
MEDIASTACK_JSON='[{"Name":"mediastack","IPAM":{"Config":[{"Subnet":"172.28.0.0/16"}]}}]'
setup_env "1" "172.28.0"
out=$(ensure_mediastack_network_config 2>&1)
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "network selector: same-CIDR VPN route conflicts"
else
    fail "network selector: same-CIDR VPN route conflicts" "expected non-zero"
fi
assert_contains "$out" "now overlaps host networking" "network selector: same-CIDR VPN explains overlap"

# Completed installs fail instead of silently migrating to another subnet.
ROUTES_TEXT='172.28.0.0/24 dev tun0 scope link'
ADDRS_TEXT='10: tun0    inet 172.28.0.5/24 scope global tun0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env "1" "172.28.0"
out=$(ensure_mediastack_network_config 2>&1)
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "network selector: completed install conflict fails"
else
    fail "network selector: completed install conflict fails" "expected non-zero"
fi
assert_contains "$out" "will not silently migrate" "network selector: completed conflict explains no silent migration"

# Completed installs also preserve a saved legacy /16 when the live Docker
# network is absent, such as after `docker compose down` removed it.
ROUTES_TEXT=$'default via 192.168.1.1 dev eth0\n192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.50'
ADDRS_TEXT='2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env "1" "172.28.0"
cat >"$SCRIPT_DIR/.env" <<'EOF'
STAGE_1_COMPLETE=1
MEDIASTACK_NETWORK_PREFIX=172.28.0
MEDIASTACK_SUBNET=172.28.0.0/16
MEDIASTACK_GATEWAY=172.28.0.1
MEDIASTACK_NPM_IP=172.28.0.10
EOF
ensure_mediastack_network_config >/dev/null 2>&1
rc=$?
assert_eq "0" "$rc" "network selector: saved legacy subnet without live network succeeds"
assert_eq "172.28.0.0/16" "$(_stack_env_get MEDIASTACK_SUBNET)" "network selector: saved legacy subnet is preserved without live network"

# Exhausted conservative range fails with VPN/LAN guidance.
ROUTES_TEXT='172.16.0.0/12 dev tun0 scope link'
ADDRS_TEXT='10: tun0    inet 172.16.4.5/12 scope global tun0'
DOCKER_JSON='[]'
MEDIASTACK_JSON=''
setup_env ""
out=$(ensure_mediastack_network_config 2>&1)
rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "network selector: exhausted 172.16/12 fails"
else
    fail "network selector: exhausted 172.16/12 fails" "expected non-zero"
fi
assert_contains "$out" "No available MediaStack Docker subnet" "network selector: exhaustion message names Docker subnet"
assert_contains "$out" "VPN" "network selector: exhaustion message mentions VPN"

scenario_end "$CURRENT_SCENARIO"
summary
