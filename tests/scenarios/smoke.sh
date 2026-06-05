# tests/scenarios/smoke.sh — fast checks of the changes from the security review.
# Defines run_scenario(). Sourced by run.sh after lib/{assert,dind,stack}.sh.
#
# These checks cover the install-flow smoke-test regressions.

run_scenario() {
    local smoke_npm=smoke-npm
    dind_exec "docker rm -f $smoke_npm" >/dev/null 2>&1 || true

    # ------------------------------------------------------------------
    # Prep: generate a test .env with deterministic values.
    # ------------------------------------------------------------------
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@smoke.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD test-jf
    env_set JELLYFIN_GPU none
    env_set DOMAIN smoke.test
    env_set WG_HOST smoke.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_ACCESS_TIER full-lan
    env_set WG_LAN_CIDR "192.168.1.0/24"
    env_set WG_SERVER_LAN_IP 127.0.0.1
    env_set WG_INIT_ALLOWED_IPS "192.168.1.0/24"
    env_set WG_PER_CLIENT_FIREWALL true

    # ------------------------------------------------------------------
    # Test 1: plaintext INIT_PASSWORD survival — v15 takes the literal
    # password (no bcrypt). Includes a shell-special char to prove the
    # single-quote envelope holds through .env → compose → container.
    # ------------------------------------------------------------------
    local wg_init_pw='smoke-test-pw-with-$pecial-chars'
    env_set WG_INIT_PASSWORD "'$wg_init_pw'"

    # ------------------------------------------------------------------
    # Test 2: compose config parses with both profiles.
    # ------------------------------------------------------------------
    if dind_exec "docker compose config --quiet" >/dev/null 2>&1; then
        pass "compose config parses (default profile)"
    else
        fail "compose config parses (default profile)"
    fi
    if dind_exec "docker compose --profile remote config --quiet" >/dev/null 2>&1; then
        pass "compose config parses (remote profile)"
    else
        fail "compose config parses (remote profile)"
    fi
    if dind_exec "docker compose --profile proxy config --quiet" >/dev/null 2>&1; then
        pass "compose config parses (proxy profile)"
    else
        fail "compose config parses (proxy profile)"
    fi
    if dind_exec "docker compose --profile remote --profile proxy config --quiet" >/dev/null 2>&1; then
        pass "compose config parses (remote+proxy combined)"
    else
        fail "compose config parses (remote+proxy combined)"
    fi

    # ------------------------------------------------------------------
    # Test 3: INIT_PASSWORD plaintext (incl. shell-special chars) survives
    # compose → container. `docker compose config` is insufficient — it shows
    # YAML-escaped $$; we want the exact bytes the container sees.
    # ------------------------------------------------------------------
    dind_exec "docker compose --profile remote pull wireguard" >/dev/null 2>&1
    local actual_init_pw
    actual_init_pw=$(dind_exec "docker compose --profile remote run --rm --quiet-pull --entrypoint /bin/sh wireguard -c 'printf %s \"\$INIT_PASSWORD\"' 2>/dev/null" | tr -d '\r\n')
    assert_eq "$wg_init_pw" "$actual_init_pw" "container receives INIT_PASSWORD byte-for-byte"

    # ------------------------------------------------------------------
    # Test 3b: INIT_ALLOWED_IPS survives .env → compose → container.
    # ------------------------------------------------------------------
    local actual_ips
    actual_ips=$(dind_exec "docker compose --profile remote run --rm --quiet-pull \
        --entrypoint /bin/sh wireguard -c 'printf %s \"\$INIT_ALLOWED_IPS\"' 2>/dev/null" | tr -d '\r\n')
    assert_eq "192.168.1.0/24" "$actual_ips" \
        "container receives INIT_ALLOWED_IPS from .env"

    # ------------------------------------------------------------------
    # Test 4: NPM + fail2ban + ddns-updater on proxy profile, not default.
    # Capture-then-grep instead of piping: `grep -q` exits on first match
    # and SIGPIPEs the upstream `docker exec`, whose non-zero exit then
    # trips run.sh's pipefail and flipped the `if` to the fail branch
    # even when the match succeeded. $(...) waits for the command to
    # finish before grepping — no pipe, no race.
    # ------------------------------------------------------------------
    local proxy_services default_services
    proxy_services=$(dind_exec "docker compose --profile proxy config --services 2>&1")
    default_services=$(dind_exec "docker compose config --services 2>&1")
    for svc in npm fail2ban ddns-updater; do
        if echo "$proxy_services" | grep -Fxq "$svc"; then
            pass "$svc in proxy profile"
        else
            fail "$svc in proxy profile" "compose --profile proxy services: ${proxy_services//$'\n'/ | }"
        fi
        if echo "$default_services" | grep -Fxq "$svc"; then
            fail "$svc excluded from default profile" "$svc still in default config --services"
        else
            pass "$svc excluded from default profile"
        fi
    done

    # ------------------------------------------------------------------
    # Test 5: NPM port 81 is LAN-reachable (no host_ip binding).
    # ------------------------------------------------------------------
    if dind_exec "docker compose --profile proxy config 2>/dev/null | grep -q 'host_ip: 127.0.0.1'"; then
        fail "NPM port 81 is LAN-reachable" "some port still bound to 127.0.0.1"
    else
        pass "NPM port 81 is LAN-reachable (no host_ip)"
    fi

    # ------------------------------------------------------------------
    # Test 6: fresh NPM accepts unauthenticated POST /api/users (seed path).
    # Launch NPM standalone (no compose) with required volumes and unique ports.
    # ------------------------------------------------------------------
    dind_exec "mkdir -p /tmp/smoke-npm/data /tmp/smoke-npm/letsencrypt"
    # Honor a candidate-image override (this NPM is launched outside compose, so
    # dind_override_images can't reach it — resolve the tag explicitly).
    local npm_image
    npm_image=$(ms_test_image npm jc21/nginx-proxy-manager:2) || { fail "smoke: resolve NPM image override"; return 1; }
    dind_exec "docker run -d --name $smoke_npm \
        -p 18181:81 -p 18180:80 -p 18443:443 \
        -v /tmp/smoke-npm/data:/data \
        -v /tmp/smoke-npm/letsencrypt:/etc/letsencrypt \
        $npm_image" >/dev/null

    # Wait for NPM API to respond.
    local npm_ready=false
    for _ in $(seq 1 60); do
        if dind_exec "curl -sf http://127.0.0.1:18181/api/ >/dev/null"; then
            npm_ready=true
            break
        fi
        sleep 2
    done
    if ! $npm_ready; then
        fail "NPM API comes up in <120s"
        dind_exec "docker logs --tail 20 $smoke_npm"
        dind_exec "docker rm -f $smoke_npm" >/dev/null 2>&1 || true
        return 1
    fi
    pass "NPM API comes up in <120s"

    # Seed admin user with rotated creds (the configure_npm fresh-install path).
    local create_http
    create_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18181/api/users \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"Administrator\",\"nickname\":\"Admin\",\"email\":\"admin@smoke.test\",\"roles\":[\"admin\"],\"is_disabled\":false,\"auth\":{\"type\":\"password\",\"secret\":\"SmokeTest_NPM_456\"}}'" | tr -d '\r\n')
    assert_eq 201 "$create_http" "POST /api/users seeds admin (HTTP 201)"

    # ------------------------------------------------------------------
    # Test 7: new creds authenticate; defaults do not.
    # ------------------------------------------------------------------
    local verify_token
    verify_token=$(dind_exec "curl -sf -X POST http://127.0.0.1:18181/api/tokens \
        -H 'Content-Type: application/json' \
        -d '{\"identity\":\"admin@smoke.test\",\"secret\":\"SmokeTest_NPM_456\"}' \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get(\"token\",\"\"))'" | tr -d '\r\n')
    if [[ -n "$verify_token" ]]; then
        pass "new NPM credentials authenticate"
    else
        fail "new NPM credentials authenticate"
    fi

    local defaults_http
    defaults_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18181/api/tokens \
        -H 'Content-Type: application/json' \
        -d '{\"identity\":\"admin@example.com\",\"secret\":\"changeme\"}'" | tr -d '\r\n')
    case "$defaults_http" in
        400|401) pass "NPM defaults never active (HTTP $defaults_http)" ;;
        *)       fail "NPM defaults never active" "got HTTP $defaults_http" ;;
    esac

    # ------------------------------------------------------------------
    # Test 8: second POST /api/users rejected → configure.sh falls through to
    # rotation path, which will then log_skip (defaults don't work either).
    # ------------------------------------------------------------------
    local second_http
    second_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:18181/api/users \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"A\",\"nickname\":\"A\",\"email\":\"x@y.z\",\"roles\":[\"admin\"],\"is_disabled\":false,\"auth\":{\"type\":\"password\",\"secret\":\"x\"}}'" | tr -d '\r\n')
    if [[ "$second_http" != "201" ]]; then
        pass "second POST /api/users rejected (HTTP $second_http) — idempotency path"
    else
        fail "second POST /api/users rejected" "unexpected HTTP 201 (endpoint still open?)"
    fi

    # Cleanup the throwaway NPM.
    dind_exec "docker rm -f $smoke_npm" >/dev/null 2>&1 || true
    dind_exec "rm -rf /tmp/smoke-npm" >/dev/null 2>&1 || true
}
