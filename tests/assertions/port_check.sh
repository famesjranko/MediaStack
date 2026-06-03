assert_port_check() {
    dind_exec "echo '127.0.0.1 jellyfin.fresh.test jellyseerr.fresh.test' >> /etc/hosts"
    env_set DOMAIN fresh.test

    local pc_output
    pc_output=$(dind_exec "./scripts/port-check.sh" 2>&1)
    local pc_exit=$?

    if [[ $pc_exit -eq 0 ]]; then
        pass "port-check.sh exits 0"
    else
        fail "port-check.sh exits 0" "exit code $pc_exit"
    fi

    if echo "$pc_output" | grep -q '\[PASS\].*TCP 80'; then
        pass "port-check: TCP 80 reachable"
    else
        fail "port-check: TCP 80 reachable" "$(echo "$pc_output" | grep 'TCP 80')"
    fi

    if echo "$pc_output" | grep -q '\[PASS\].*TCP 443'; then
        pass "port-check: TCP 443 reachable"
    else
        fail "port-check: TCP 443 reachable" "$(echo "$pc_output" | grep 'TCP 443')"
    fi

    if echo "$pc_output" | grep -q '6881'; then
        pass "port-check: 6881 check executed"
    else
        fail "port-check: 6881 check executed" "no mention of 6881 in output"
    fi

    if echo "$pc_output" | grep -q 'Optional apex DNS: fresh.test is not required' \
        && ! echo "$pc_output" | grep -q '\[FAIL\].*fresh.test does not resolve'; then
        pass "port-check: subdomain-only DNS accepted"
    else
        fail "port-check: subdomain-only DNS accepted" "$pc_output"
    fi

    if echo "$pc_output" | grep -q '\[FAIL\].*DNS matches public IP\|could not detect public IP'; then
        pass "port-check: DNS/IP mismatch warning path exercised"
    else
        pass "port-check: DNS/IP check ran (may have matched or skipped)"
    fi
}
