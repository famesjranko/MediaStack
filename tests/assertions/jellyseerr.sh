assert_jellyseerr_configured() {
    local jf_password="$1"
    local jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    local js_pub
    js_pub=$(dind_exec "curl -sf http://localhost:5055/api/v1/settings/public")
    if echo "$js_pub" | grep -q '"initialized":true'; then
        pass "step 6 Jellyseerr: initialized"
    else
        fail "step 6 Jellyseerr: initialized"
    fi

    local js_url="http://localhost:5055"
    local js_cookie="/tmp/js-test-cookie"
    local js_auth_body
    js_auth_body=$(dind_exec "JF_USER='$jf_user' JF_PW='$jf_password' python3 -c '
import os, json
print(json.dumps({\"username\": os.environ[\"JF_USER\"], \"password\": os.environ[\"JF_PW\"]}))'")
    local js_auth_http
    js_auth_http=$(dind_exec "curl -sS -o /dev/null -w '%{http_code}' \
        -c $js_cookie -b $js_cookie \
        -H 'Content-Type: application/json' \
        -X POST $js_url/api/v1/auth/jellyfin \
        -d '$js_auth_body'" | tr -d '\r\n')
    if [[ "$js_auth_http" == "200" ]]; then
        local js_sonarr_settings js_radarr_settings
        js_sonarr_settings=$(dind_exec "curl -sf -c $js_cookie -b $js_cookie $js_url/api/v1/settings/sonarr")
        js_radarr_settings=$(dind_exec "curl -sf -c $js_cookie -b $js_cookie $js_url/api/v1/settings/radarr")
        if echo "$js_sonarr_settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) and len(d)>0 else 1)' 2>/dev/null; then
            pass "step 6 Jellyseerr: Sonarr connected"
        else
            fail "step 6 Jellyseerr: Sonarr connected" "GET /settings/sonarr returned empty"
        fi
        if echo "$js_radarr_settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) and len(d)>0 else 1)' 2>/dev/null; then
            pass "step 6 Jellyseerr: Radarr connected"
        else
            fail "step 6 Jellyseerr: Radarr connected" "GET /settings/radarr returned empty"
        fi

        local js_jf_settings js_lib_names
        js_jf_settings=$(dind_exec "curl -sf -c $js_cookie -b $js_cookie $js_url/api/v1/settings/jellyfin")
        js_lib_names=$(echo "$js_jf_settings" | python3 -c '
import sys, json
d = json.load(sys.stdin)
libs = d.get("libraries", [])
names = sorted(l.get("name","") for l in libs if l.get("enabled"))
print(",".join(names))' 2>/dev/null)
        if echo "$js_lib_names" | grep -q 'Movies' && echo "$js_lib_names" | grep -q 'TV Shows'; then
            pass "step 6 Jellyseerr: libraries synced (${js_lib_names})"
        else
            fail "step 6 Jellyseerr: libraries synced (Movies + TV Shows)" "got '${js_lib_names}'"
        fi

        # trustProxy ("Enable Proxy Support") must be on behind NPM so Jellyseerr
        # reads the real client IP. It lives in settings.network (NOT settings.main)
        # and is enabled only when remote-ready — which this scenario is.
        local js_net js_trust
        js_net=$(dind_exec "curl -sf -c $js_cookie -b $js_cookie $js_url/api/v1/settings/network")
        js_trust=$(echo "$js_net" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("trustProxy"))' 2>/dev/null)
        if [[ "$js_trust" == "True" ]]; then
            pass "step 6 Jellyseerr: trustProxy enabled (remote-ready)"
        else
            fail "step 6 Jellyseerr: trustProxy enabled (remote-ready)" "settings/network trustProxy=$js_trust"
        fi
    else
        fail "step 6 Jellyseerr: Sonarr connected" "could not authenticate to Jellyseerr (HTTP $js_auth_http)"
        fail "step 6 Jellyseerr: Radarr connected" "could not authenticate to Jellyseerr"
        fail "step 6 Jellyseerr: libraries synced" "could not authenticate to Jellyseerr"
    fi
}
