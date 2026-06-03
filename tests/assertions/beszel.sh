assert_beszel_configured() {
    if svc_stripped beszel; then
        skip "Beszel: hub accessible" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local http_code
    http_code=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:8090" 2>/dev/null | tr -d '\r\n')
    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        pass "Beszel: hub accessible at port 8090 (HTTP $http_code)"
    else
        fail "Beszel: hub accessible at port 8090" "got HTTP $http_code"
    fi

    local configure_log="$1"

    local agent_key
    agent_key=$(env_get BESZEL_AGENT_KEY)
    if [[ -n "$agent_key" ]]; then
        pass "Beszel: agent key saved to .env"
    else
        fail "Beszel: agent key saved to .env" "BESZEL_AGENT_KEY is empty"
    fi

    # Agent crash-loops with empty KEY until configure.sh provides it and
    # recreates the container. Check running status here (post-configure),
    # not in the pre-configure health loop.
    local agent_status
    agent_status=$(dind_exec "docker inspect --format '{{.State.Status}}' beszel-agent 2>/dev/null" | tr -d '\r\n')
    if [[ "$agent_status" == "running" ]]; then
        pass "Beszel: agent running (post-configure)"
    else
        fail "Beszel: agent running (post-configure)" "status=$agent_status"
    fi

    local sys_ok sys_skip
    sys_ok=$(grep -c '\[OK\].*Beszel system' "$configure_log" 2>/dev/null) || sys_ok=0
    sys_skip=$(grep -c '\[SKIP\].*Beszel system' "$configure_log" 2>/dev/null) || sys_skip=0
    if [[ "$sys_ok" -gt 0 || "$sys_skip" -gt 0 ]]; then
        pass "Beszel: system registered (OK=$sys_ok SKIP=$sys_skip)"
    else
        fail "Beszel: system registered" "no OK or SKIP lines for system registration in configure.sh output"
    fi

    local services_yaml
    services_yaml=$(dind_exec "cat config/homepage/services.yaml 2>/dev/null")
    if echo "$services_yaml" | grep -q "type: beszel"; then
        pass "Beszel: Homepage widget configured"
    else
        fail "Beszel: Homepage widget configured" "type: beszel not found in services.yaml"
    fi
}
