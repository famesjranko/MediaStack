# tests/scenarios/wireguard.sh — full wg-easy v15 startup inside DinD.
# Brings up the wireguard service via --profile remote, verifies the WireGuard
# kernel interface, web UI, Basic Auth API, peer creation, persistence, bridge
# network attachment, and custom-port propagation.
#
# Wall-time budget: ~4-6 min cold (single image pull + custom-port restart),
# ~2 min warm.

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: populate .env with v15 INIT_* contract.
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
    env_set WG_PORT 51820
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "'$wg_password'"
    env_set WG_ACCESS_TIER full-lan
    env_set WG_LAN_CIDR "192.168.1.0/24"
    env_set WG_SERVER_LAN_IP 127.0.0.1
    env_set WG_INIT_ALLOWED_IPS "192.168.1.0/24"
    env_set WG_PER_CLIENT_FIREWALL true

    create_config_dirs_in_dind
    dind_exec "mkdir -p /tmp/ms-data"

    # ------------------------------------------------------------------
    # 0b. Compose contract: image pin, capability set (ADR-17 still applies),
    # bridge attach with pinned IPv4. Config dir is user-owned to mirror
    # setup.sh's non-root install path; DAC_OVERRIDE lets container root
    # write wg0.conf and wg-easy.db there.
    # ------------------------------------------------------------------
    local wg_dir_stat cap_config cap_add cap_drop image_tag bridge_ip
    wg_dir_stat=$(dind_exec "stat -c '%u:%g %a' config/wireguard" | tr -d '\r\n')
    assert_eq "1000:1000 755" "$wg_dir_stat" "WireGuard config dir mirrors non-root setup ownership"

    # Default run asserts the v15.3.0 pin; under a candidate-image override
    # (MS_TEST_IMAGE_OVERRIDES) this becomes a tag-propagation check instead, so
    # a valid candidate isn't failed before its behavior is exercised.
    local expected_image
    expected_image=$(ms_test_image wireguard "ghcr.io/wg-easy/wg-easy:15.3.0")
    image_tag=$(dind_exec "docker compose --profile remote config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"services\"][\"wireguard\"][\"image\"])'" | tr -d '\r\n')
    if [[ "$expected_image" == "ghcr.io/wg-easy/wg-easy:15.3.0" ]]; then
        if [[ "$image_tag" =~ ^ghcr\.io/wg-easy/wg-easy:15\.3\.0(@sha256:[0-9a-f]{64})?$ ]]; then
            pass "WireGuard image pinned to v15.3.0"
        else
            fail "WireGuard image pinned to v15.3.0" "actual='$image_tag'"
        fi
    else
        assert_eq "$expected_image" "$image_tag" "WireGuard candidate image override propagated to compose"
    fi

    cap_config=$(dind_exec "docker compose --profile remote config --format json | python3 -c 'import json,sys; svc=json.load(sys.stdin)[\"services\"][\"wireguard\"]; print(\",\".join(svc.get(\"cap_add\", []))); print(\",\".join(svc.get(\"cap_drop\", [])))'" | tr -d '\r')
    cap_add=$(printf '%s\n' "$cap_config" | sed -n '1p')
    cap_drop=$(printf '%s\n' "$cap_config" | sed -n '2p')
    assert_eq "NET_ADMIN,NET_RAW,SYS_MODULE,DAC_OVERRIDE" "$cap_add" "WireGuard cap_add matches ADR-17"
    assert_eq "ALL" "$cap_drop" "WireGuard drops default capabilities"

    bridge_ip=$(dind_exec "docker compose --profile remote config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"services\"][\"wireguard\"][\"networks\"][\"mediastack\"][\"ipv4_address\"])'" | tr -d '\r\n')
    assert_eq "172.28.0.11" "$bridge_ip" "WireGuard pinned to mediastack .11 (ADR-23)"

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

    # ------------------------------------------------------------------
    # 2. Wait for healthy (healthcheck: wg show | grep -q interface)
    # ------------------------------------------------------------------
    if wait_healthy wireguard 120; then
        pass "wireguard healthy"
    else
        fail "wireguard healthy"
        dind_exec "docker logs wireguard" 2>&1 | tail -30
        return 1
    fi

    # ------------------------------------------------------------------
    # 3. wg0 interface exists inside the container
    # ------------------------------------------------------------------
    local wg_iface
    wg_iface=$(dind_exec "docker exec wireguard wg show wg0 2>&1")
    if echo "$wg_iface" | grep -q "listening port"; then
        pass "wg0 interface active"
    else
        fail "wg0 interface active" "${wg_iface:0:120}"
    fi

    # ------------------------------------------------------------------
    # 4. Web UI responds on port 51821
    # ------------------------------------------------------------------
    local ui_http
    ui_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:51821" | tr -d '\r\n')
    if [[ "$ui_http" =~ ^(200|301|302|304)$ ]]; then
        pass "web UI responds (HTTP $ui_http)"
    else
        fail "web UI responds" "HTTP $ui_http"
    fi

    # ------------------------------------------------------------------
    # 5. Basic Auth probe: GET /api/client returns JSON array.
    # ------------------------------------------------------------------
    local client_list_http client_list_body
    client_list_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -u admin:$wg_password http://localhost:51821/api/client" | tr -d '\r\n')
    assert_eq "200" "$client_list_http" "Basic Auth GET /api/client succeeds"
    client_list_body=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client")
    if echo "$client_list_body" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)' >/dev/null 2>&1; then
        pass "GET /api/client returns JSON array"
    else
        fail "GET /api/client returns JSON array" "${client_list_body:0:200}"
    fi

    # ------------------------------------------------------------------
    # 5b. Production configurator path applies the initial admin peer and
    # tier firewallIps. The later test-peer checks still exercise raw v15 API
    # creation, but this protects the actual setup/configure path.
    # ------------------------------------------------------------------
    if dind_exec "./scripts/configure.sh --only wireguard" >/dev/null 2>&1; then
        pass "configure.sh --only wireguard succeeds"
    else
        fail "configure.sh --only wireguard succeeds"
        dind_exec "./scripts/configure.sh --only wireguard" 2>&1 | tail -40
        return 1
    fi
    local admin_fw_state
    admin_fw_state=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client | IPS='192.168.1.0/24' python3 -c 'import os,sys,json; clients=json.load(sys.stdin); want=[x.strip() for x in os.environ[\"IPS\"].split(\",\") if x.strip()]; admin=next((c for c in clients if c.get(\"name\") == \"admin\"), {}); got=admin.get(\"firewallIps\") or []; print(\"yes\" if set(got) == set(want) else json.dumps(got))'" | tr -d '\r\n')
    assert_eq "yes" "$admin_fw_state" "configure.sh initial admin peer firewallIps = Full LAN tier"

    # ------------------------------------------------------------------
    # 6. Create a peer via the v15 API
    # ------------------------------------------------------------------
    local peer_http test_peer_id
    peer_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -u admin:$wg_password -X POST http://localhost:51821/api/client -H 'Content-Type: application/json' -d '{\"name\":\"test-peer\",\"expiresAt\":null}'" | tr -d '\r\n')
    test_peer_id=$(dind_exec "curl -s -u admin:$wg_password http://localhost:51821/api/client | python3 -c 'import sys,json; clients=json.load(sys.stdin); print(next((str(c.get(\"id\", \"\")) for c in clients if c.get(\"name\") == \"test-peer\"), \"\"))'" | tr -d '\r\n')
    case "$peer_http" in
        200|201) pass "POST /api/client creates peer (HTTP $peer_http)" ;;
        *)
            if [[ -n "$test_peer_id" ]]; then
                pass "POST /api/client returned HTTP $peer_http but peer persisted (ADR-28 read-back path)"
            else
                fail "POST /api/client creates peer" "HTTP $peer_http"
            fi
            ;;
    esac

    # ------------------------------------------------------------------
    # 7. Created peer visible in wg show
    # ------------------------------------------------------------------
    local peers
    peers=$(dind_exec "docker exec wireguard wg show wg0 peers 2>&1" | tr -d '\r\n')
    if [[ -n "$peers" && "$peers" != *"Unable"* && "$peers" != *"error"* ]]; then
        pass "peer visible in wg show (${peers:0:12}…)"
    else
        fail "peer visible in wg show" "peers='$peers'"
    fi

    # ------------------------------------------------------------------
    # 8. wg0.conf + wg-easy.db persisted to config volume
    # ------------------------------------------------------------------
    local wg_conf
    wg_conf=$(dind_exec "cat config/wireguard/wg0.conf 2>/dev/null")
    if echo "$wg_conf" | grep -q "PrivateKey"; then
        pass "wg0.conf persisted to volume"
    else
        fail "wg0.conf persisted to volume" "file missing or no PrivateKey"
    fi
    if dind_exec "docker exec wireguard test -f /etc/wireguard/wg-easy.db" >/dev/null 2>&1; then
        pass "wg-easy.db persisted (v15 SQLite store)"
    else
        fail "wg-easy.db persisted (v15 SQLite store)"
    fi

    # ------------------------------------------------------------------
    # 9. UDP listen port honors WG_PORT (default 51820 in this pass).
    # ------------------------------------------------------------------
    local udp_listen
    udp_listen=$(dind_exec "docker exec wireguard wg show wg0 listen-port 2>/dev/null" | tr -d '\r\n')
    if [[ "$udp_listen" == "51820" ]]; then
        pass "WireGuard UDP listening on port $udp_listen"
    else
        fail "WireGuard UDP listening on port 51820" "got='$udp_listen'"
    fi

    # ------------------------------------------------------------------
    # 10. Custom WG_PORT propagates end-to-end (compose binding, container
    # listen-port, wg0.conf). Regression for the v14 hardcoded-51820 bug.
    # ------------------------------------------------------------------
    dind_exec "docker compose --profile remote down wireguard >/dev/null 2>&1 && rm -rf config/wireguard/*"
    create_config_dirs_in_dind
    env_set WG_PORT 51920
    dind_exec "docker compose --profile remote up -d wireguard" >/dev/null 2>&1
    if wait_healthy wireguard 120; then
        pass "wireguard healthy after WG_PORT=51920"
    else
        fail "wireguard healthy after WG_PORT=51920"
        dind_exec "docker logs wireguard" 2>&1 | tail -30
        return 1
    fi

    local custom_listen custom_published custom_conf_port
    custom_listen=$(dind_exec "docker exec wireguard wg show wg0 listen-port 2>/dev/null" | tr -d '\r\n')
    assert_eq "51920" "$custom_listen" "WG_PORT=51920 propagates to wg show listen-port"

    custom_conf_port=$(dind_exec "grep -oP '^ListenPort\\s*=\\s*\\K[0-9]+' config/wireguard/wg0.conf 2>/dev/null" | tr -d '\r\n')
    assert_eq "51920" "$custom_conf_port" "WG_PORT=51920 propagates to wg0.conf ListenPort"

    custom_published=$(dind_exec "docker port wireguard 2>/dev/null | grep -oP '^51920/udp' | head -1" | tr -d '\r\n')
    assert_eq "51920/udp" "$custom_published" "WG_PORT=51920 propagates to compose published binding"
}
