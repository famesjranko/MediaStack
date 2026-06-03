# tests/scenarios/wireguard-server.sh — Server-tier firewallIps shape (ADR-29).
# Brings up wg-easy v15, enables the per-client firewall, creates a peer, and
# writes the server-tier firewallIps (server IP /32, all ports — includes host
# services like SSH). Verifies the shape round-trips through wg-easy's
# possibly-500-but-persisted mutation path documented in ADR-28.
#
# Wall-time budget: ~3-5 min cold, ~1-2 min warm.

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: populate .env at the server tier with firewall on.
    # ------------------------------------------------------------------
    dind_exec "cp .env.example .env"

    local wg_password="wg-test-password"

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@wg.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD "$wg_password"
    env_set JELLYFIN_GPU none
    env_set DOMAIN wg.test
    env_set WG_HOST 10.0.0.1
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "'$wg_password'"
    env_set WG_ACCESS_TIER server
    env_set WG_LAN_CIDR ""
    env_set WG_SERVER_LAN_IP 127.0.0.1
    env_set WG_INIT_ALLOWED_IPS "127.0.0.1/32"
    env_set WG_PER_CLIENT_FIREWALL true

    create_config_dirs_in_dind
    dind_exec "mkdir -p /tmp/ms-data"

    # ------------------------------------------------------------------
    # 1. Bring up wireguard via --profile remote
    # ------------------------------------------------------------------
    echo "  starting wireguard (pulling image)…"
    dind_exec "docker compose --profile remote up -d wireguard" >/dev/null 2>&1
    local up_rc=$?
    if (( up_rc != 0 )); then
        fail "docker compose up wireguard" "exit $up_rc"
        dind_exec "docker compose --profile remote logs wireguard" 2>&1 | tail -30
        return 1
    fi
    pass "docker compose --profile remote up -d wireguard"

    if wait_healthy wireguard 120; then
        pass "wireguard healthy"
    else
        fail "wireguard healthy"
        dind_exec "docker logs wireguard" 2>&1 | tail -30
        return 1
    fi

    # Production configurator path applies the initial admin peer. The family
    # peer below still exercises manual UI/API templates.
    if dind_exec "./scripts/configure.sh --only wireguard" >/dev/null 2>&1; then
        pass "configure.sh --only wireguard succeeds"
    else
        fail "configure.sh --only wireguard succeeds"
        dind_exec "./scripts/configure.sh --only wireguard" 2>&1 | tail -40
        return 1
    fi
    local admin_fw_state
    admin_fw_state=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client | IPS='127.0.0.1/32' python3 -c 'import os,sys,json; clients=json.load(sys.stdin); want=[x.strip() for x in os.environ[\"IPS\"].split(\",\") if x.strip()]; admin=next((c for c in clients if c.get(\"name\") == \"admin\"), {}); got=admin.get(\"firewallIps\") or []; print(\"yes\" if set(got) == set(want) else json.dumps(got))'" | tr -d '\r\n')
    assert_eq "yes" "$admin_fw_state" "configure.sh initial admin peer firewallIps = Server tier"

    # ------------------------------------------------------------------
    # 2. Enable per-client firewall via Basic Auth API. Classify on read-back
    # because v15.3.0 can return 500 while still persisting firewallEnabled=true
    # (ip6tables touched even with DISABLE_IPV6=true). ADR-28.
    # ------------------------------------------------------------------
    local interface_body enable_http
    interface_body=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/admin/interface" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read())
d["firewallEnabled"] = True
print(json.dumps(d))')
    enable_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -u admin:$wg_password -X POST http://localhost:51821/api/admin/interface -H 'Content-Type: application/json' -d '$interface_body'" | tr -d '\r\n')
    sleep 1
    local fw_state
    fw_state=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/admin/interface | python3 -c 'import sys,json; d=json.load(sys.stdin); print(\"yes\" if d.get(\"firewallEnabled\") else \"no\")'" | tr -d '\r\n')
    case "$enable_http:$fw_state" in
        2*:yes) pass "per-client firewall enabled (HTTP $enable_http, state=yes)" ;;
        *:yes)  pass "per-client firewall enabled — POST returned HTTP $enable_http but state persisted (ADR-28 read-back path)" ;;
        *)      fail "per-client firewall enabled" "HTTP $enable_http, state=$fw_state"; return 1 ;;
    esac

    # ------------------------------------------------------------------
    # 3. Create a server-tier peer (server IP /32, all ports). This is the
    # "co-admin" tier — gives the peer raw IP-level access to the box,
    # including host services like SSH. firewallIps is a bare /32 entry.
    # ------------------------------------------------------------------
    local family_fw_ips="127.0.0.1/32"
    local create_result create_resp create_http
    local create_body
    create_body=$(python3 -c 'import json; print(json.dumps({"name": "family-test", "expiresAt": None}))')
    create_result=$(dind_exec "resp=\$(mktemp); http=\$(curl -s -o \"\$resp\" -w '%{http_code}' -u admin:$wg_password -X POST http://localhost:51821/api/client -H 'Content-Type: application/json' -d '$create_body'); printf '%s\n' \"\$http\"; cat \"\$resp\"; rm -f \"\$resp\"")
    create_http=$(printf '%s\n' "$create_result" | sed -n '1p' | tr -d '\r\n')
    create_resp=$(printf '%s\n' "$create_result" | sed '1d')

    local peer_id
peer_id=$(echo "$create_resp" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    pid = d.get("id") or (d.get("client", {}) if isinstance(d.get("client"), dict) else {}).get("id", "")
    if pid:
        print(pid)
' 2>/dev/null)
    if [[ -z "$peer_id" ]]; then
        peer_id=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client | python3 -c 'import sys,json; clients=json.load(sys.stdin); print(next((str(c.get(\"id\", \"\")) for c in clients if c.get(\"name\") == \"family-test\"), \"\"))'" | tr -d '\r\n')
    fi
    if [[ -z "$peer_id" ]]; then
        fail "POST /api/client creates family peer" "HTTP $create_http, body='${create_resp:0:200}'"
        return 1
    fi
    case "$create_http" in
        200|201) pass "POST /api/client creates family peer (HTTP $create_http)" ;;
        *)       pass "POST /api/client returned HTTP $create_http but family peer persisted (ADR-28 read-back path)" ;;
    esac
    pass "family peer id extracted: ${peer_id:0:8}…"

    # GET current peer, merge firewallIps, POST back full body.
    local peer_obj peer_update_body peer_update_http
    peer_obj=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client/$peer_id")
    peer_update_body=$(IPS="$family_fw_ips" python3 -c '
import os, sys, json
d = json.loads(sys.stdin.read())
d["firewallIps"] = [x.strip() for x in os.environ["IPS"].split(",") if x.strip()]
print(json.dumps(d))' <<< "$peer_obj")
    peer_update_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -u admin:$wg_password -X POST http://localhost:51821/api/client/$peer_id -H 'Content-Type: application/json' -d '$peer_update_body'" | tr -d '\r\n')

    # ------------------------------------------------------------------
    # 4. Re-read peer and verify firewallIps echo back.
    # ------------------------------------------------------------------
    local peer_after_state
    peer_after_state=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client/$peer_id | IPS='$family_fw_ips' python3 -c 'import os,sys,json; d=json.load(sys.stdin); got=d.get(\"firewallIps\") or []; want=[x.strip() for x in os.environ[\"IPS\"].split(\",\") if x.strip()]; print(\"yes\" if set(got) == set(want) else json.dumps(got))'" | tr -d '\r\n')
    case "$peer_update_http:$peer_after_state" in
        2*:yes) pass "POST /api/client/<id> updates firewallIps (HTTP $peer_update_http)" ;;
        *:yes)  pass "POST /api/client/<id> returned HTTP $peer_update_http but firewallIps persisted (ADR-28 read-back path)" ;;
        *)      fail "family peer firewallIps persisted" "HTTP $peer_update_http, got='${peer_after_state:0:200}'" ;;
    esac

    # ------------------------------------------------------------------
    # 5. MASQUERADE still present in bridge mode — required for VPN→LAN.
    # ------------------------------------------------------------------
    local nat_rules
    nat_rules=$(dind_exec "docker exec wireguard iptables -t nat -S POSTROUTING 2>&1")
    if echo "$nat_rules" | grep -q "MASQUERADE"; then
        pass "iptables NAT MASQUERADE rule present"
    else
        fail "iptables NAT MASQUERADE rule present" "${nat_rules:0:200}"
    fi
}
