# tests/scenarios/npm-heal.sh — NPM proxy_host cert-drift self-heal.
#
# Locks in the recovery feature added when the GCP test surface caught NPM
# crashing because a proxy_host/N.conf referenced cert files that no longer
# existed. That state can be reached in production by an aborted setup.sh,
# a VM reboot during a certbot run, an OOM kill, or a manual cert delete —
# any path where NPM's sqlite DB and the on-disk nginx config drift apart.
#
# What this scenario asserts about configure.sh's _npm_ensure_healthy():
#   - drift is detected via host-mounted path scan, not docker exec test -f
#     (so a stopped/crash-looping NPM still reports the right host_ids)
#   - API repair is attempted first (cheap, idempotent); failure falls
#     through to offline sqlite patch, not blind retry
#   - offline path: stop NPM → sudo python3 sqlite UPDATE with row
#     verification → archive broken .conf → start NPM (one restart max)
#   - readiness gate probes a real express route (POST /api/tokens), not
#     just a static GET, so the next API call doesn't 502 on a half-warm NPM
#
# Wall-time: ~60s warm (NPM image already pulled by other scenarios).

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Prep: minimal .env. DOMAIN is intentionally blank — heal must run
    #    even on LAN-only installs (no public publication path).
    # ------------------------------------------------------------------
    # When this scenario runs as part of a battery (after fresh-install),
    # the DinD inherits a configured stack. NPM is still running with the
    # PRIOR scenario's admin baked into its sqlite, so our env_set NPM_ADMIN
    # below would silently no-op against a live container. Tear down any
    # leftover stack + state before starting our own.
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/letsencrypt"

    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@heal.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD heal-test-pw
    env_set JELLYFIN_GPU none
    env_set DOMAIN ""
    env_set WG_HOST heal.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"

    # ------------------------------------------------------------------
    # 1. Bring up NPM only and seed admin via configure.sh.
    # ------------------------------------------------------------------
    if ! dind_exec "docker compose --profile proxy up -d npm" >/dev/null 2>&1; then
        fail "docker compose up -d npm"
        dind_exec "docker compose ps"
        return 1
    fi
    if ! wait_healthy npm 120; then
        fail "npm healthy"
        return 1
    fi
    pass "npm up + healthy"

    if ! dind_exec "./scripts/configure.sh --only npm" >/tmp/heal-bootstrap.out 2>&1; then
        fail "configure.sh --only npm (bootstrap admin)"
        tail -30 /tmp/heal-bootstrap.out
        return 1
    fi
    pass "configure.sh --only npm bootstraps admin"

    # ------------------------------------------------------------------
    # 2. Create a seed proxy host via NPM API (cert_id=0, plain HTTP).
    #    We need a real proxy_host DB row + .conf so the heal scan finds
    #    something to repair when we corrupt the .conf below.
    # ------------------------------------------------------------------
    local token
    token=$(dind_exec "curl -sf -X POST http://localhost:81/api/tokens \
        -H 'Content-Type: application/json' \
        -d '{\"identity\":\"admin@heal.test\",\"secret\":\"heal-test-pw\"}'" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null \
        | tr -d '\r\n')
    if [[ -z "$token" ]]; then
        fail "obtained NPM API token"
        return 1
    fi
    pass "obtained NPM API token"

    local seed_body
    seed_body=$(python3 -c 'import json; print(json.dumps({
        "domain_names": ["heal.test"],
        "forward_scheme": "http",
        "forward_host": "127.0.0.1",
        "forward_port": 8080,
        "block_exploits": True,
        "allow_websocket_upgrade": False,
        "access_list_id": 0,
        "certificate_id": 0,
        "ssl_forced": False,
        "http2_support": False,
        "meta": {},
        "advanced_config": "",
        "locations": [],
        "caching_enabled": False,
        "hsts_enabled": False,
        "hsts_subdomains": False,
        "enabled": True,
    }))')
    local host_id
    host_id=$(dind_exec "curl -sf -X POST http://localhost:81/api/nginx/proxy-hosts \
        -H 'Authorization: Bearer $token' \
        -H 'Content-Type: application/json' \
        -d '$seed_body'" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("id",""))' 2>/dev/null \
        | tr -d '\r\n')
    if [[ -z "$host_id" ]]; then
        fail "seed proxy host created"
        return 1
    fi
    pass "seed proxy host created (id=$host_id)"

    # ------------------------------------------------------------------
    # 3. Inject the corruption: replace the generated .conf with one that
    #    references a cert path nginx can't load. NPM writes the .conf
    #    asynchronously after the POST returns, so wait for it first.
    # ------------------------------------------------------------------
    local conf_path="config/npm/data/nginx/proxy_host/${host_id}.conf"
    local i
    for i in $(seq 1 20); do
        if dind_exec "test -f $conf_path"; then break; fi
        sleep 1
    done
    if ! dind_exec "test -f $conf_path"; then
        fail "NPM wrote $conf_path"
        return 1
    fi
    pass "NPM wrote $conf_path"

    dind_exec "cat > $conf_path <<NGINX
# corruption-injected-by-heal-scenario
server {
  listen 443 ssl;
  server_name heal.test;
  ssl_certificate /etc/letsencrypt/live/npm-9999/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/npm-9999/privkey.pem;
}
NGINX"

    if dind_exec "docker exec npm nginx -t" >/dev/null 2>&1; then
        fail "nginx -t broken after injection"
        return 1
    fi
    pass "nginx -t broken after injection (drift setup)"

    # ------------------------------------------------------------------
    # 4. Run configure.sh --only npm — should self-heal end to end.
    # ------------------------------------------------------------------
    local heal_log=/tmp/heal-recovery.out
    if ! dind_exec "./scripts/configure.sh --only npm" >"$heal_log" 2>&1; then
        fail "configure.sh --only npm (heal)"
        tail -40 "$heal_log"
        return 1
    fi
    pass "configure.sh --only npm completes after corruption"

    # Strip ANSI before grepping so colour codes don't break matches.
    local heal_plain
    heal_plain=$(sed -r 's/\x1b\[[0-9;]*m//g' "$heal_log")

    # ------------------------------------------------------------------
    # 5. Heal log assertions — each line is a contract with the heal flow.
    # ------------------------------------------------------------------
    grep -q "NPM nginx -t failing" <<<"$heal_plain" \
        && pass "heal: drift detected (nginx -t signal)" \
        || fail "heal: drift detected (nginx -t signal)"

    grep -qE "Drifted host\(s\): .*\b${host_id}\b" <<<"$heal_plain" \
        && pass "heal: identified host_id=$host_id from on-disk scan" \
        || fail "heal: identified host_id=$host_id from on-disk scan"

    grep -q "Stopping NPM for offline sqlite patch" <<<"$heal_plain" \
        && pass "heal: fell through to offline path (API repair insufficient)" \
        || fail "heal: fell through to offline path"

    grep -q "rows_verified=" <<<"$heal_plain" \
        && pass "heal: sqlite UPDATE verified (row count)" \
        || fail "heal: sqlite UPDATE verified (row count)"

    grep -qE "archived ${host_id}\.conf" <<<"$heal_plain" \
        && pass "heal: ${host_id}.conf archived (not deleted)" \
        || fail "heal: ${host_id}.conf archived (not deleted)"

    grep -q "NPM healed (nginx -t clean, express alive" <<<"$heal_plain" \
        && pass "heal: readiness gate probed express route" \
        || fail "heal: readiness gate probed express route"

    # ------------------------------------------------------------------
    # 6. Post-heal state: nginx clean, host row reset, archive on disk.
    # ------------------------------------------------------------------
    if dind_exec "docker exec npm nginx -t" >/dev/null 2>&1; then
        pass "post-heal: nginx -t clean"
    else
        fail "post-heal: nginx -t clean"
    fi

    local archived_path
    archived_path=$(dind_exec "ls config/npm/data/nginx/proxy_host.broken-*/${host_id}.conf 2>/dev/null" \
        | head -1 | tr -d '\r\n')
    if [[ -n "$archived_path" ]]; then
        pass "post-heal: forensic archive contains ${host_id}.conf ($archived_path)"
    else
        fail "post-heal: forensic archive contains ${host_id}.conf"
    fi

    # The token from before heal is invalidated when heal restarts NPM —
    # re-authenticate to read post-heal DB state. This race has bitten us
    # multiple times (NPM restart + first auth call land within a few ms),
    # so retry with a short backoff and capture diagnostics on failure.
    local post_token=""
    local i token_resp
    for i in $(seq 1 8); do
        token_resp=$(dind_exec "curl -s -o /tmp/heal-tok-resp.json -w '%{http_code}' --max-time 10 \
            -X POST http://localhost:81/api/tokens \
            -H 'Content-Type: application/json' \
            -d '{\"identity\":\"admin@heal.test\",\"secret\":\"heal-test-pw\"}'" \
            | tr -d '\r\n')
        if [[ "$token_resp" == "200" ]]; then
            post_token=$(dind_exec "cat /tmp/heal-tok-resp.json" \
                | python3 -c 'import sys,json;print(json.load(sys.stdin).get("token",""))' 2>/dev/null \
                | tr -d '\r\n')
            [[ -n "$post_token" ]] && break
        fi
        sleep 1
    done

    local row_state=""
    local row_http=""
    local row_body=""
    if [[ -n "$post_token" ]]; then
        row_http=$(dind_exec "curl -s -o /tmp/heal-row-resp.json -w '%{http_code}' --max-time 10 \
            -H 'Authorization: Bearer $post_token' \
            http://localhost:81/api/nginx/proxy-hosts/$host_id" | tr -d '\r\n')
        row_body=$(dind_exec "cat /tmp/heal-row-resp.json 2>/dev/null | head -c 400" | tr -d '\r\n')
        # Python 3.11 (Debian 12 / DinD) rejects backslash escapes in f-string
        # expression parts. Build the string by hand to keep the parser happy.
        row_state=$(dind_exec "cat /tmp/heal-row-resp.json" \
            | python3 -c 'import sys,json
h=json.load(sys.stdin)
print("enabled=" + str(h.get("enabled")) + " cert_id=" + str(h.get("certificate_id")))' 2>/dev/null \
            | tr -d '\r\n')
    fi
    case "$row_state" in
        "enabled=False cert_id=0")
            pass "post-heal: host_id=$host_id row reset to enabled=False cert=0" ;;
        *)
            fail "post-heal: host_id=$host_id row reset" \
                "got '$row_state' (token HTTP=$token_resp; row HTTP=$row_http body=${row_body:0:200})" ;;
    esac

    # ------------------------------------------------------------------
    # 7. Idempotence: a second run is a no-op (no second archive, no
    #    second sqlite patch).
    # ------------------------------------------------------------------
    local archive_count_before
    archive_count_before=$(dind_exec "ls -d config/npm/data/nginx/proxy_host.broken-* 2>/dev/null | wc -l" \
        | tr -d '\r\n')

    if ! dind_exec "./scripts/configure.sh --only npm" >/tmp/heal-rerun.out 2>&1; then
        fail "configure.sh --only npm rerun"
        return 1
    fi

    local archive_count_after
    archive_count_after=$(dind_exec "ls -d config/npm/data/nginx/proxy_host.broken-* 2>/dev/null | wc -l" \
        | tr -d '\r\n')

    local rerun_plain
    rerun_plain=$(sed -r 's/\x1b\[[0-9;]*m//g' /tmp/heal-rerun.out)
    if grep -q "NPM nginx -t failing" <<<"$rerun_plain"; then
        fail "rerun is no-op (heal triggered again)"
    else
        pass "rerun is no-op (heal not retriggered when state is clean)"
    fi
    if [[ "$archive_count_before" == "$archive_count_after" ]]; then
        pass "rerun does not create a second forensic archive"
    else
        fail "rerun does not create a second forensic archive" \
            "before=$archive_count_before after=$archive_count_after"
    fi

    # ------------------------------------------------------------------
    # 8. Clean up state so subsequent scenarios in the same DinD see a
    #    fresh NPM. Scenarios share one DinD container; the NPM data
    #    volume here would otherwise carry an admin@heal.test row that
    #    breaks the user-creation idempotency expected by fresh-install.
    # ------------------------------------------------------------------
    dind_exec "docker compose down -v --remove-orphans" >/dev/null 2>&1
    dind_exec "rm -rf config/npm config/letsencrypt 2>/dev/null" >/dev/null 2>&1
    pass "cleanup: NPM stopped + data wiped for downstream scenarios"
}
