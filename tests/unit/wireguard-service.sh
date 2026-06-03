#!/usr/bin/env bash
# Focused unit coverage for the wg-easy v15 service configurator.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wireguard-service"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CURL_LOG="$TMP_DIR/curl.log"
BODY_LOG="$TMP_DIR/body.log"
# State files survive the subshells that $(curl ...) spawns, so the mock can
# transition firewallEnabled across the read → POST → re-read sequence.
CLIENTS_STATE_FILE="$TMP_DIR/clients-state"
INTERFACE_STATE_FILE="$TMP_DIR/interface-state"
PEER_FIREWALL_STATE_FILE="$TMP_DIR/peer-firewall-state"

source "$REPO_ROOT/scripts/lib/network.sh"
source "$REPO_ROOT/scripts/services/wireguard/main.sh"

BOLD=""
NC=""
JELLYFIN_ADMIN_USER="mediaadmin"
JELLYFIN_ADMIN_PASSWORD="shared-wireguard-password"
WG_SERVER_LAN_IP="192.168.1.50"
WG_LAN_CIDR="192.168.1.0/24"
WG_ACCESS_TIER="full-lan"
WG_PER_CLIENT_FIREWALL="true"

OK_MESSAGES=()
WARN_MESSAGES=()
SKIP_MESSAGES=()

log_ok() { OK_MESSAGES+=("$1"); }
log_warn() { WARN_MESSAGES+=("$1"); }
log_skip() { SKIP_MESSAGES+=("$1"); }

docker() {
    if [[ "${1:-}" == "ps" ]]; then
        printf 'wireguard\n'
        return 0
    fi
    return 0
}

sleep() { :; }

reset_fixture() {
    : > "$CURL_LOG"
    : > "$BODY_LOG"
    OK_MESSAGES=()
    WARN_MESSAGES=()
    SKIP_MESSAGES=()
    CLIENTS_JSON='[]'
    printf '%s' "$CLIENTS_JSON" > "$CLIENTS_STATE_FILE"
    printf 'false' > "$INTERFACE_STATE_FILE"
    printf 'null' > "$PEER_FIREWALL_STATE_FILE"
    CREATE_HTTP='201'
    CREATE_BODY='{"id":"peer-uuid-1","name":"mediaadmin"}'
    CREATE_PERSISTS='false'
    POST_INTERFACE_HTTP='200'
    POST_INTERFACE_PERSISTS='true'
    POST_PEER_HTTP='200'
    POST_PEER_PERSISTS='true'
    unset INJECT_BROAD_ENTRY
}

# Minimal v15 curl mock. Routes by URL and method, captures POST bodies for
# assertions. Honors Basic Auth (-u user:pass), not session cookies.
curl() {
    local arg method="GET" url="" body_arg="" want_body=false want_code=false output_file=""
    local prev=""
    for arg in "$@"; do
        case "$prev" in
            -X) method="$arg" ;;
            -d) body_arg="$arg" ;;
            -o) output_file="$arg" ;;
            -w) want_code=true ;;
        esac
        case "$arg" in
            -X) ;;
            -d) ;;
            -o) ;;
            -w) ;;
            -u|-H|-b|-c|-s|-f|-sf|--max-time|-)  ;;
            http*) url="$arg" ;;
        esac
        prev="$arg"
    done

    printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
    if [[ -n "$body_arg" ]]; then
        printf '%s %s :: %s\n' "$method" "$url" "$body_arg" >> "$BODY_LOG"
    fi

    local body_out="" http_out="200"
    case "$method:$url" in
        GET:*/api/client) body_out="$(cat "$CLIENTS_STATE_FILE")"; http_out="200" ;;
        POST:*/api/client)
            if [[ "$CREATE_PERSISTS" == "true" ]]; then
                printf '[{"id":"peer-uuid-1","name":"mediaadmin"}]' > "$CLIENTS_STATE_FILE"
            fi
            body_out="$CREATE_BODY"; http_out="$CREATE_HTTP"
            ;;
        GET:*/api/client/*)
            local peer_fw
            peer_fw=$(cat "$PEER_FIREWALL_STATE_FILE")
            body_out="{\"id\":\"peer-uuid-1\",\"name\":\"mediaadmin\",\"enabled\":true,\"expiresAt\":null,\"ipv4Address\":\"10.8.0.2\",\"ipv6Address\":\"fdcc:ad94:bacf:61a4::cafe:2\",\"preUp\":\"\",\"postUp\":\"\",\"preDown\":\"\",\"postDown\":\"\",\"allowedIps\":null,\"serverAllowedIps\":[],\"firewallIps\":$peer_fw,\"persistentKeepalive\":0,\"mtu\":1420,\"jC\":7,\"jMin\":10,\"jMax\":1000,\"i1\":null,\"i2\":null,\"i3\":null,\"i4\":null,\"i5\":null,\"dns\":null,\"serverEndpoint\":null}"
            http_out="200"
            ;;
        POST:*/api/client/*)
            if [[ "$POST_PEER_PERSISTS" == "true" ]]; then
                INJECT_BROAD="${INJECT_BROAD_ENTRY:-}" python3 -c '
import json, os, sys
try:
    body = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
fw = body.get("firewallIps") or []
extra = os.environ.get("INJECT_BROAD", "")
if extra:
    # Simulate wg-easy persisting an additional broader entry (race, retry,
    # or future merge semantics) that would silently neutralize the tier.
    fw = [extra] + list(fw)
print(json.dumps(fw))
' "$body_arg" > "$PEER_FIREWALL_STATE_FILE"
            fi
            body_out=""; http_out="$POST_PEER_HTTP"
            ;;
        GET:*/api/admin/interface)
            local fw_state
            fw_state=$(cat "$INTERFACE_STATE_FILE" 2>/dev/null || printf 'false')
            if [[ "$fw_state" == "true" ]]; then
                body_out='{"device":"eth0","port":51820,"ipv4Cidr":"10.8.0.0/24","ipv6Cidr":"fdcc:ad94:bacf:61a4::cafe:0/112","mtu":1420,"jC":7,"jMin":10,"jMax":1000,"s1":128,"s2":56,"s3":null,"s4":null,"h1":"1","h2":"2","h3":"3","h4":"4","i1":null,"i2":null,"i3":null,"i4":null,"i5":null,"enabled":true,"firewallEnabled":true}'
            else
                body_out='{"device":"eth0","port":51820,"ipv4Cidr":"10.8.0.0/24","ipv6Cidr":"fdcc:ad94:bacf:61a4::cafe:0/112","mtu":1420,"jC":7,"jMin":10,"jMax":1000,"s1":128,"s2":56,"s3":null,"s4":null,"h1":"1","h2":"2","h3":"3","h4":"4","i1":null,"i2":null,"i3":null,"i4":null,"i5":null,"enabled":true,"firewallEnabled":false}'
            fi
            http_out="200"
            ;;
        POST:*/api/admin/interface)
            # Honor what the POST body says, modeling persisted state.
            if [[ "$POST_INTERFACE_PERSISTS" == "true" ]]; then
                if [[ "$body_arg" == *'"firewallEnabled": true'* ]]; then
                    printf 'true' > "$INTERFACE_STATE_FILE"
                else
                    printf 'false' > "$INTERFACE_STATE_FILE"
                fi
            fi
            body_out=""; http_out="$POST_INTERFACE_HTTP"
            ;;
        *) body_out=""; http_out="200" ;;
    esac

    if [[ -n "$output_file" && "$output_file" != "/dev/null" ]]; then
        printf '%s' "$body_out" > "$output_file"
        body_out=""
    elif [[ -n "$output_file" && "$output_file" == "/dev/null" ]]; then
        body_out=""
    fi

    if $want_code; then
        printf '%s' "$http_out"
    else
        printf '%s' "$body_out"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Case 1: full-lan tier (default) → firewall enabled, initial peer firewallIps
# = LAN CIDR.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
configure_wireguard
assert_contains "$(cat "$BODY_LOG")" '"name": "mediaadmin"' \
    "full-lan: peer creation POSTs wizard admin username"
assert_contains "$(cat "$BODY_LOG")" '"firewallEnabled": true' \
    "full-lan: POSTs firewallEnabled=true on /api/admin/interface"
assert_contains "$(cat "$BODY_LOG")" '"firewallIps": ["192.168.1.0/24"]' \
    "full-lan: initial peer firewallIps = LAN CIDR"
post_peer_id_calls=$(grep -cE '^POST .*/api/client/peer-uuid-1$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "1" "$post_peer_id_calls" \
    "full-lan: POSTs /api/client/<id> exactly once (firewallIps update)"
assert_contains "${OK_MESSAGES[*]:-}" "wg-easy per-client firewall enabled" \
    "full-lan: firewall enable logs OK"

# -----------------------------------------------------------------------------
# Case 2: server tier → firewall enabled, initial peer firewallIps = server /32.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="server"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
configure_wireguard
assert_contains "$(cat "$BODY_LOG")" '"firewallIps": ["192.168.1.50/32"]' \
    "server: initial peer firewallIps = server /32 (all ports)"

# -----------------------------------------------------------------------------
# Case 3: containers tier → firewall enabled, initial peer firewallIps =
# enumerated MediaStack container ports (51821 excluded).
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="containers"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
configure_wireguard
assert_contains "$(cat "$BODY_LOG")" '"192.168.1.50:8096/tcp"' \
    "containers: Jellyfin port appears in initial peer firewallIps"
assert_contains "$(cat "$BODY_LOG")" '"192.168.1.50:5055/tcp"' \
    "containers: Jellyseerr port appears in initial peer firewallIps"
assert_contains "$(cat "$BODY_LOG")" '"192.168.1.50:7359/udp"' \
    "containers: Jellyfin auto-discovery (UDP) appears in initial peer firewallIps"
peer_post_body=$(grep "POST .*/api/client/peer-uuid-1" "$BODY_LOG" | sed 's/^[^:]*:: //' || true)
case "$peer_post_body" in
    *'192.168.1.50:51821/'*) fail "containers: wg-easy admin (51821) MUST NOT appear in initial peer firewallIps" ;;
    *) pass "containers: wg-easy admin (51821) excluded from initial peer firewallIps" ;;
esac

# -----------------------------------------------------------------------------
# Case 4: Re-run, peer already present → log_skip; no POST /api/client.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
CLIENTS_JSON='[{"id":"peer-uuid-1","name":"mediaadmin"}]'
printf '%s' "$CLIENTS_JSON" > "$CLIENTS_STATE_FILE"
configure_wireguard
create_calls=$(grep -c '^POST .*/api/client$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$create_calls" \
    "Re-run: does not POST /api/client when peer already exists"
assert_contains "${SKIP_MESSAGES[*]:-}" "WireGuard peer 'mediaadmin' already exists" \
    "Re-run: log_skip uses wizard username"

# -----------------------------------------------------------------------------
# Case 5: Escape hatch — WG_PER_CLIENT_FIREWALL=false → no firewall enable,
# no peer firewallIps written. Documented advanced full-tunnel path.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="false"
configure_wireguard
post_interface_calls=$(grep -c '^POST .*/api/admin/interface' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$post_interface_calls" \
    "escape-hatch: WG_PER_CLIENT_FIREWALL=false skips firewall enable"
post_peer_id_calls=$(grep -cE '^POST .*/api/client/peer-uuid-1$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$post_peer_id_calls" \
    "escape-hatch: WG_PER_CLIENT_FIREWALL=false skips peer firewallIps update"

# -----------------------------------------------------------------------------
# Case 6: Sanity warning — WG_PER_CLIENT_FIREWALL=false with non-full-lan tier
# emits a warning (likely user error).
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="containers"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="false"
configure_wireguard
assert_contains "${WARN_MESSAGES[*]:-}" "WG_PER_CLIENT_FIREWALL=false with WG_ACCESS_TIER='containers'" \
    "sanity: warns when escape hatch is combined with restrictive tier"

# -----------------------------------------------------------------------------
# Case 7: Invalid WG_PER_CLIENT_FIREWALL value warns and fails safe by enforcing.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="containers"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="yes"
configure_wireguard
assert_contains "${WARN_MESSAGES[*]:-}" "WG_PER_CLIENT_FIREWALL='yes' is not valid" \
    "firewall bool: invalid value warns"
assert_contains "$(cat "$BODY_LOG")" '"firewallEnabled": true' \
    "firewall bool: invalid value defaults to enforced firewall"
assert_contains "$(cat "$BODY_LOG")" '"192.168.1.50:8096/tcp"' \
    "firewall bool: invalid value still applies tier firewallIps"

# -----------------------------------------------------------------------------
# Case 8: Missing full-lan CIDR fails closed instead of writing 0.0.0.0/0.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
configure_wireguard
rc=$?
assert_eq "1" "$rc" "fail-closed: missing WG_LAN_CIDR returns nonzero"
assert_contains "${WARN_MESSAGES[*]:-}" "leaving initial peer restricted until .env is fixed" \
    "fail-closed: missing WG_LAN_CIDR warns"
case "$(cat "$BODY_LOG")" in
    *'0.0.0.0/0'*) fail "fail-closed: missing WG_LAN_CIDR must not write broad firewallIps" ;;
    *) pass "fail-closed: missing WG_LAN_CIDR does not write broad firewallIps" ;;
esac

# -----------------------------------------------------------------------------
# Case 9: Unknown access tier fails closed instead of granting broad access.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="bogus"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
configure_wireguard
rc=$?
assert_eq "1" "$rc" "fail-closed: unknown WG_ACCESS_TIER returns nonzero"
case "$(cat "$BODY_LOG")" in
    *'0.0.0.0/0'*) fail "fail-closed: unknown WG_ACCESS_TIER must not write broad firewallIps" ;;
    *) pass "fail-closed: unknown WG_ACCESS_TIER does not write broad firewallIps" ;;
esac

# -----------------------------------------------------------------------------
# Case 10: Firewall enable failure that does not persist returns nonzero and
# stops before peer creation/firewallIps writes.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
POST_INTERFACE_HTTP='500'
POST_INTERFACE_PERSISTS='false'
configure_wireguard
rc=$?
assert_eq "1" "$rc" "fail-closed: non-persisted firewall enable failure returns nonzero"
create_calls=$(grep -c '^POST .*/api/client$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "0" "$create_calls" "fail-closed: firewall enable failure stops before peer creation"

# -----------------------------------------------------------------------------
# Case 11: Peer firewallIps failure that does not persist returns nonzero.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="streaming"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
POST_PEER_HTTP='500'
POST_PEER_PERSISTS='false'
configure_wireguard
rc=$?
assert_eq "1" "$rc" "fail-closed: non-persisted peer firewallIps failure returns nonzero"
assert_contains "${WARN_MESSAGES[*]:-}" "Setting initial peer firewallIps failed" \
    "fail-closed: non-persisted peer firewallIps failure warns"

# -----------------------------------------------------------------------------
# Case 12: full-lan tier, peer create returns 500 after persistence → read back +
# firewallIps still applied.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
CREATE_HTTP='500'
CREATE_BODY='{"error":true,"statusCode":500}'
CREATE_PERSISTS='true'
POST_INTERFACE_HTTP='500'
POST_PEER_HTTP='500'
configure_wireguard
assert_contains "${WARN_MESSAGES[*]:-}" "state persisted as enabled" \
    "full-lan: firewall enable accepts HTTP 500 with persisted state"
assert_contains "${WARN_MESSAGES[*]:-}" "firewallIps returned HTTP 500 but state persisted" \
    "full-lan: peer firewallIps accepts HTTP 500 with persisted state"
post_peer_id_calls=$(grep -cE '^POST .*/api/client/peer-uuid-1$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "1" "$post_peer_id_calls" \
    "full-lan: persisted peer read-back still receives firewallIps update"

# -----------------------------------------------------------------------------
# Case 13 (regression): mock simulates wg-easy persisting an
# extra broad entry alongside the tier's firewallIps. The read-back check must
# reject this (set equality, not subset) so a stale 0.0.0.0/0 cannot silently
# certify a restricted tier as enforced.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="streaming"
WG_LAN_CIDR=""
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
export INJECT_BROAD_ENTRY="0.0.0.0/0"
configure_wireguard
rc=$?
unset INJECT_BROAD_ENTRY
assert_eq "1" "$rc" \
    "regression: extra broad firewallIps entry returns nonzero"
assert_contains "${WARN_MESSAGES[*]:-}" "Setting initial peer firewallIps failed" \
    "regression: subset-match would have passed; set equality must reject the extra 0.0.0.0/0"

# -----------------------------------------------------------------------------
# Case 14: full-lan tier, peer create returns 2xx without id → read back.
# -----------------------------------------------------------------------------
reset_fixture
WG_ACCESS_TIER="full-lan"
WG_LAN_CIDR="192.168.1.0/24"
WG_SERVER_LAN_IP="192.168.1.50"
WG_PER_CLIENT_FIREWALL="true"
CREATE_HTTP='201'
CREATE_BODY='{"success":true}'
CREATE_PERSISTS='true'
configure_wireguard
assert_contains "${OK_MESSAGES[*]:-}" "WireGuard peer 'mediaadmin' created" \
    "full-lan: 2xx peer creation without id reads back persisted peer"
post_peer_id_calls=$(grep -cE '^POST .*/api/client/peer-uuid-1$' "$CURL_LOG" 2>/dev/null || true)
assert_eq "1" "$post_peer_id_calls" \
    "full-lan: 2xx-without-id read-back still receives firewallIps update"

scenario_end "$CURRENT_SCENARIO"
summary
