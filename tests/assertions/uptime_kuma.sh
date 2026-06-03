assert_uptime_kuma_configured() {
    if svc_stripped uptime-kuma; then
        skip "Uptime Kuma: monitors created" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local http_code
    http_code=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:3001" 2>/dev/null | tr -d '\r\n')
    if [[ "$http_code" == "200" || "$http_code" == "302" ]]; then
        pass "Uptime Kuma: accessible at port 3001 (HTTP $http_code)"
    else
        fail "Uptime Kuma: accessible at port 3001" "got HTTP $http_code"
    fi

    local configure_log="$1"
    local monitors_ok
    monitors_ok=$(grep -c '\[OK\].*Monitors created' "$configure_log" 2>/dev/null) || monitors_ok=0
    local monitors_skip
    monitors_skip=$(grep -c '\[SKIP\].*Monitors already exist' "$configure_log" 2>/dev/null) || monitors_skip=0
    if [[ "$monitors_ok" -gt 0 || "$monitors_skip" -gt 0 ]]; then
        pass "Uptime Kuma: monitors provisioned (OK=$monitors_ok SKIP=$monitors_skip)"
    else
        fail "Uptime Kuma: monitors provisioned" "no OK or SKIP lines in configure.sh output"
    fi

    local services_yaml
    services_yaml=$(dind_exec "cat config/homepage/services.yaml 2>/dev/null")
    if echo "$services_yaml" | grep -q "type: uptimekuma"; then
        pass "Uptime Kuma: Homepage widget configured"
    else
        fail "Uptime Kuma: Homepage widget configured" "type: uptimekuma not found in services.yaml"
    fi

    local sp_json
    sp_json=$(dind_exec "curl -s http://localhost:3001/api/status-page/mediastack" 2>/dev/null | tr -d '\r')
    local group_count
    group_count=$(echo "$sp_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('publicGroupList',[])))" 2>/dev/null) || group_count=0
    if [[ "$group_count" -gt 0 ]]; then
        pass "Uptime Kuma: status page has monitor groups ($group_count)"
    else
        fail "Uptime Kuma: status page has monitor groups" "publicGroupList is empty"
    fi
}

assert_uptime_kuma_idempotent() {
    if svc_stripped uptime-kuma; then
        skip "Uptime Kuma: idempotent re-run" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local rerun_log=/tmp/configure-rerun.out
    dind_exec "./scripts/configure.sh --only uptime-kuma" >"$rerun_log" 2>&1

    local skip_count
    skip_count=$(grep -c '\[SKIP\].*Monitors already exist' "$rerun_log" 2>/dev/null) || skip_count=0
    local created_count
    created_count=$(grep -c '\[OK\].*Monitors created' "$rerun_log" 2>/dev/null) || created_count=0

    if [[ "$skip_count" -gt 0 && "$created_count" -eq 0 ]]; then
        pass "Uptime Kuma: idempotent re-run (all monitors skipped)"
    else
        fail "Uptime Kuma: idempotent re-run" "expected all SKIP, got OK=$created_count SKIP=$skip_count"
    fi
}
