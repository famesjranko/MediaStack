assert_ratelimit_configured() {
    if svc_stripped npm || svc_stripped fail2ban; then
        skip "rate limiting: verification" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    # Tier 1 — static verification: http_top.conf and advanced_config
    local http_top_content
    http_top_content=$(dind_exec "cat config/npm/data/nginx/custom/http_top.conf 2>/dev/null" | tr -d '\r')
    if [[ "$http_top_content" == *"limit_req_zone"* && "$http_top_content" == *"mediastack_ratelimit"* ]]; then
        pass "rate limiting: http_top.conf has limit_req_zone for mediastack_ratelimit"
    else
        fail "rate limiting: http_top.conf has limit_req_zone" "content: ${http_top_content:0:200}"
    fi

    local rl_proxy_hosts rl_count
    rl_proxy_hosts=$(dind_exec "curl -sf -H 'Authorization: Bearer $NPM_TOKEN' http://localhost:81/api/nginx/proxy-hosts" 2>/dev/null || echo "[]")
    rl_count=$(echo "$rl_proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
print(sum(1 for h in hosts if "limit_req zone=mediastack_ratelimit" in (h.get("advanced_config","") or "")))
' 2>/dev/null | tr -d '\r\n')
    if [[ "$rl_count" -ge 2 ]]; then
        pass "rate limiting: $rl_count proxy hosts have limit_req in advanced_config"
    else
        fail "rate limiting: proxy hosts have limit_req" "expected >=2, got ${rl_count:-0}"
    fi

    assert_contains "$F2B_STATUS" "npm-ratelimit" "fail2ban: npm-ratelimit jail loaded"

    # Tier 2 — rate limiting triggers 429s under burst traffic.
    local rl_responses rl_429_count
    rl_responses=$(dind_exec "seq 1 200 | xargs -P50 -I{} curl -sk -o /dev/null -w '%{http_code}\n' --resolve 'jellyfin.fresh.test:443:127.0.0.1' https://jellyfin.fresh.test/health 2>/dev/null" | tr -d '\r')
    rl_429_count=$(echo "$rl_responses" | grep -c "429" || true)
    if [[ "$rl_429_count" -ge 1 ]]; then
        pass "rate limiting: burst traffic triggers 429 responses ($rl_429_count of 200)"
    else
        fail "rate limiting: burst traffic triggers 429" "0 of 200 requests got 429"
    fi

    # Tier 3 — fail2ban filter regex matches 429 log lines
    sleep 3
    local f2b_rl_regex_out rl_matched
    f2b_rl_regex_out=$(dind_exec "docker exec fail2ban sh -c 'cat /var/log/npm/proxy-host-*_*.log > /tmp/f2b-rl-test.log 2>/dev/null && fail2ban-regex /tmp/f2b-rl-test.log /data/filter.d/npm-ratelimit.conf 2>&1; rm -f /tmp/f2b-rl-test.log'" | tr -d '\r')
    rl_matched=$(echo "$f2b_rl_regex_out" | sed -n 's/.*[[:space:]]\([0-9]*\) matched.*/\1/p' | head -1)
    [[ -z "$rl_matched" ]] && rl_matched=0
    if [[ "$rl_matched" -ge 1 ]]; then
        pass "fail2ban: npm-ratelimit filter matches 429 log lines ($rl_matched hits)"
    else
        fail "fail2ban: npm-ratelimit filter matches 429 log lines" "0 matched"
    fi

    # Tier 4 — ban pipeline: lower maxretry, trigger 429 flood, verify ban
    dind_exec "docker exec fail2ban fail2ban-client set npm-ratelimit maxretry 3" >/dev/null 2>&1
    dind_exec "docker exec fail2ban fail2ban-client set npm-ratelimit delignoreip 10.0.0.0/8" >/dev/null 2>&1 || true
    dind_exec "docker exec fail2ban fail2ban-client set npm-ratelimit delignoreip 172.16.0.0/12" >/dev/null 2>&1 || true
    dind_exec "docker exec fail2ban fail2ban-client set npm-ratelimit delignoreip 192.168.0.0/16" >/dev/null 2>&1 || true

    dind_exec "seq 1 200 | xargs -P50 -I{} curl -sk -o /dev/null --resolve 'jellyfin.fresh.test:443:127.0.0.1' https://jellyfin.fresh.test/health 2>/dev/null" || true

    local rl_ban_waited=0 rl_ban_status=""
    while ((rl_ban_waited < 30)); do
        rl_ban_status=$(dind_exec "docker exec fail2ban fail2ban-client status npm-ratelimit" | tr -d '\r')
        if echo "$rl_ban_status" | grep -qE "Currently banned:[[:space:]]*[1-9]"; then
            break
        fi
        sleep 3
        rl_ban_waited=$((rl_ban_waited + 3))
    done

    if echo "$rl_ban_status" | grep -qE "Currently banned:[[:space:]]*[1-9]"; then
        pass "fail2ban: npm-ratelimit jail bans IP after repeated 429s"
    else
        fail "fail2ban: npm-ratelimit jail bans IP" "$(echo "$rl_ban_status" | grep -E 'Currently banned|Banned IP')"
    fi

    local f2b_rl_ipt
    f2b_rl_ipt=$(dind_exec "iptables -S DOCKER-USER 2>/dev/null" | tr -d '\r')
    if echo "$f2b_rl_ipt" | grep -q "f2b-npm-ratelimit"; then
        pass "fail2ban: f2b-npm-ratelimit chain jumped from DOCKER-USER"
    else
        fail "fail2ban: f2b-npm-ratelimit chain jumped from DOCKER-USER" "not found in DOCKER-USER"
    fi
}

# Default state (config.yml rate_limiting.enabled=false): rate limiting is
# off, so NO limit_req_zone is written, NO proxy host carries limit_req, and the
# npm-ratelimit jail is not loaded. Static/structural checks only — asserting a
# "zero 429s under burst" negative would be flaky and prove nothing.
assert_ratelimit_disabled() {
    if svc_stripped npm || svc_stripped fail2ban; then
        skip "rate limiting: disabled verification" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local http_top_content
    http_top_content=$(dind_exec "cat config/npm/data/nginx/custom/http_top.conf 2>/dev/null" | tr -d '\r')
    if [[ "$http_top_content" != *"limit_req_zone"* ]]; then
        pass "rate limiting (disabled): no limit_req_zone in http_top.conf"
    else
        fail "rate limiting (disabled): no limit_req_zone in http_top.conf" "content: ${http_top_content:0:200}"
    fi

    local rl_proxy_hosts rl_count
    rl_proxy_hosts=$(dind_exec "curl -sf -H 'Authorization: Bearer $NPM_TOKEN' http://localhost:81/api/nginx/proxy-hosts" 2>/dev/null || echo "[]")
    rl_count=$(echo "$rl_proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
print(sum(1 for h in hosts if "limit_req zone=mediastack_ratelimit" in (h.get("advanced_config","") or "")))
' 2>/dev/null | tr -d '\r\n')
    if [[ "${rl_count:-0}" -eq 0 ]]; then
        pass "rate limiting (disabled): 0 proxy hosts carry limit_req in advanced_config"
    else
        fail "rate limiting (disabled): proxy hosts must not carry limit_req" "got ${rl_count:-0}"
    fi

    if echo "$F2B_STATUS" | grep -q "npm-ratelimit"; then
        fail "rate limiting (disabled): npm-ratelimit jail must not be loaded" "found in fail2ban status"
    else
        pass "rate limiting (disabled): npm-ratelimit jail not loaded"
    fi
}
