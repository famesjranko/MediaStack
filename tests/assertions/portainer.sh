assert_portainer_configured() {
    local jf_password="$1"
    local jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    if svc_stripped portainer; then
        skip "step 7 Portainer: admin initialized" "stripped via MS_TEST_STRIP_SERVICES"
        skip "step 7 Portainer: admin auth with shared password" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local portainer_check_http
    portainer_check_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' http://localhost:9000/api/users/admin/check" | tr -d '\r\n')
    if [[ "$portainer_check_http" == "204" ]]; then
        pass "step 7 Portainer: admin initialized"
    else
        fail "step 7 Portainer: admin initialized" "HTTP $portainer_check_http (expected 204)"
    fi

    local portainer_auth_result
    portainer_auth_result=$(docker exec -e "JF_USER=$jf_user" -e "JF_PW=$jf_password" "$DIND_NAME" python3 -c '
import os, json, urllib.request
user = os.environ["JF_USER"]
pw = os.environ["JF_PW"]
body = json.dumps({"Username": user, "Password": pw}).encode()
req = urllib.request.Request("http://localhost:9000/api/auth", data=body, headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req) as r:
        d = json.loads(r.read()); print("ok" if d.get("jwt") else "no-jwt")
except Exception as e:
    print(f"fail: {e}")
' 2>/dev/null | tr -d '\r\n')
    if [[ "$portainer_auth_result" == "ok" ]]; then
        pass "step 7 Portainer: admin auth with shared password"
    else
        fail "step 7 Portainer: admin auth with shared password" "$portainer_auth_result"
    fi

    local portainer_endpoints
    portainer_endpoints=$(docker exec -e "JF_USER=$jf_user" -e "JF_PW=$jf_password" "$DIND_NAME" python3 -c '
import os, json, urllib.request
user = os.environ["JF_USER"]
pw = os.environ["JF_PW"]
body = json.dumps({"Username": user, "Password": pw}).encode()
req = urllib.request.Request("http://localhost:9000/api/auth", data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req) as r:
    jwt = json.loads(r.read())["jwt"]
req2 = urllib.request.Request("http://localhost:9000/api/endpoints", headers={"Authorization": "Bearer " + jwt})
with urllib.request.urlopen(req2) as r:
    print(len(json.loads(r.read())))
' 2>/dev/null | tr -d '\r\n')
    if [[ "$portainer_endpoints" -ge 1 ]] 2>/dev/null; then
        pass "step 7 Portainer: local Docker endpoint created"
    else
        fail "step 7 Portainer: local Docker endpoint created" "endpoints=$portainer_endpoints"
    fi
}
