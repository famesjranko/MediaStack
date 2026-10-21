assert_beszel_configured() {
    # $1 configure.sh log, $2 shared admin password (the hub login).
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

    local configure_log="$1" admin_pw="$2"

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

    # The agent shares a unix socket with the hub. Host networking would
    # expose a TCP port on every host interface, past the DOCKER-USER chain,
    # so no listener on the old agent port may exist at all (loopback or not:
    # the agent has no TCP listener left, and 0.0.0.0, [::] or a LAN address
    # would be reachable from the LAN).
    local listeners
    listeners=$(dind_exec "python3 -c '
import sys
for f in (\"/proc/net/tcp\", \"/proc/net/tcp6\"):
    try:
        rows = open(f).read().splitlines()[1:]
    except OSError:
        continue
    for r in rows:
        c = r.split()
        if c[3] == \"0A\" and int(c[1].rsplit(\":\", 1)[1], 16) == 45876:
            print(f, c[1])
'" 2>/dev/null | tr '\n' ' ')
    if [[ -z "${listeners// /}" ]]; then
        pass "Beszel: nothing listens on the old agent port 45876"
    else
        fail "Beszel: nothing listens on the old agent port 45876" "listeners: $listeners"
    fi
    if dind_exec "test -S config/beszel/socket/beszel.sock"; then
        pass "Beszel: agent listens on the shared unix socket"
    else
        fail "Beszel: agent listens on the shared unix socket" "config/beszel/socket/beszel.sock is not a socket"
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

    # The agent has no raw socket: its only Docker access is the socket-proxy.
    # Container stats land in the hub's `containers` collection only if the
    # proxy let GET /containers/json and /containers/{id}/stats through. The
    # agent's own row is the witness. The hub polls on its own schedule, so
    # wait for the first sample.
    local admin_email stats_result="" waited=0
    admin_email=$(env_get NPM_ADMIN_EMAIL)
    while ((waited < 180)); do
        stats_result=$(docker exec -e "B_EMAIL=$admin_email" -e "B_PW=$admin_pw" "$DIND_NAME" python3 -c '
import os, json, urllib.parse, urllib.request
hub = "http://localhost:8090/api/collections/"
def call(path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    with urllib.request.urlopen(urllib.request.Request(hub + path, data=data, headers=headers)) as r:
        return json.loads(r.read())
try:
    token = call("users/auth-with-password", {"identity": os.environ["B_EMAIL"], "password": os.environ["B_PW"]})["token"]
    query = urllib.parse.urlencode({"filter": "name=\"beszel-agent\""})
    rows = call("containers/records?" + query, token=token)["items"]
    print("ok" if rows and rows[0].get("memory", 0) > 0 else "no-rows")
except Exception as e:
    print("fail: " + str(e))
' 2>/dev/null | tr -d '\r\n')
        [[ "$stats_result" == "ok" ]] && break
        sleep 10
        waited=$((waited + 10))
    done
    if [[ "$stats_result" == "ok" ]]; then
        pass "Beszel: agent reports container stats through the socket-proxy (${waited}s)"
        # The agent works with the proxy's narrow allowlist; a denied request
        # in the proxy log would name a call the agent needs and the proxy
        # blocks. Denied probes of the policy assertions run after this one.
        local denied
        denied=$(dind_exec "docker logs socket-proxy 2>&1 | grep -c 'blocked request'" | tr -d '\r\n')
        if [[ "$denied" == "0" ]]; then
            pass "Beszel: the socket-proxy denied nothing beszel-agent asked for"
        else
            fail "Beszel: the socket-proxy denied nothing beszel-agent asked for" "$denied blocked requests"
            dind_exec "docker logs socket-proxy 2>&1 | grep 'blocked request' | tail -5" || true
        fi
    else
        fail "Beszel: agent reports container stats through the socket-proxy" "$stats_result after ${waited}s"
        dind_exec "docker logs --tail 20 socket-proxy 2>&1; docker logs --tail 10 beszel-agent 2>&1" || true
    fi
}
