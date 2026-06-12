assert_seerr_configured() {
    local jf_password="$1"
    local jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    local seerr_pub
    seerr_pub=$(dind_exec "curl -sf http://localhost:5055/api/v1/settings/public")
    if echo "$seerr_pub" | grep -q '"initialized":true'; then
        pass "step 6 Seerr: initialized"
    else
        fail "step 6 Seerr: initialized"
    fi

    local seerr_url="http://localhost:5055"
    local seerr_cookie="/tmp/seerr-test-cookie"
    local seerr_auth_body
    seerr_auth_body=$(dind_exec "JF_USER='$jf_user' JF_PW='$jf_password' python3 -c '
import os, json
print(json.dumps({\"username\": os.environ[\"JF_USER\"], \"password\": os.environ[\"JF_PW\"]}))'")
    local seerr_auth_http
    seerr_auth_http=$(dind_exec "curl -sS -o /dev/null -w '%{http_code}' \
        -c $seerr_cookie -b $seerr_cookie \
        -H 'Content-Type: application/json' \
        -X POST $seerr_url/api/v1/auth/jellyfin \
        -d '$seerr_auth_body'" | tr -d '\r\n')
    if [[ "$seerr_auth_http" == "200" ]]; then
        local seerr_sonarr_settings seerr_radarr_settings
        seerr_sonarr_settings=$(dind_exec "curl -sf -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/sonarr")
        seerr_radarr_settings=$(dind_exec "curl -sf -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/radarr")
        if echo "$seerr_sonarr_settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) and len(d)>0 else 1)' 2>/dev/null; then
            pass "step 6 Seerr: Sonarr connected"
        else
            fail "step 6 Seerr: Sonarr connected" "GET /settings/sonarr returned empty"
        fi
        if echo "$seerr_radarr_settings" | python3 -c 'import sys,json; d=json.load(sys.stdin); exit(0 if isinstance(d,list) and len(d)>0 else 1)' 2>/dev/null; then
            pass "step 6 Seerr: Radarr connected"
        else
            fail "step 6 Seerr: Radarr connected" "GET /settings/radarr returned empty"
        fi

        local seerr_jf_settings seerr_lib_names
        seerr_jf_settings=$(dind_exec "curl -sf -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/jellyfin")
        seerr_lib_names=$(echo "$seerr_jf_settings" | python3 -c '
import sys, json
d = json.load(sys.stdin)
libs = d.get("libraries", [])
names = sorted(l.get("name","") for l in libs if l.get("enabled"))
print(",".join(names))' 2>/dev/null)
        if echo "$seerr_lib_names" | grep -q 'Movies' && echo "$seerr_lib_names" | grep -q 'TV Shows'; then
            pass "step 6 Seerr: libraries synced (${seerr_lib_names})"
        else
            fail "step 6 Seerr: libraries synced (Movies + TV Shows)" "got '${seerr_lib_names}'"
        fi

        # trustProxy ("Enable Proxy Support") must be on behind NPM so Seerr
        # reads the real client IP. It lives in settings.network (NOT settings.main)
        # and is enabled only when remote-ready — which this scenario is.
        local seerr_net seerr_trust
        seerr_net=$(dind_exec "curl -sf -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/network")
        seerr_trust=$(echo "$seerr_net" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("trustProxy"))' 2>/dev/null)
        if [[ "$seerr_trust" == "True" ]]; then
            pass "step 6 Seerr: trustProxy enabled (remote-ready)"
        else
            fail "step 6 Seerr: trustProxy enabled (remote-ready)" "settings/network trustProxy=$seerr_trust"
        fi
    else
        fail "step 6 Seerr: Sonarr connected" "could not authenticate to Seerr (HTTP $seerr_auth_http)"
        fail "step 6 Seerr: Radarr connected" "could not authenticate to Seerr"
        fail "step 6 Seerr: libraries synced" "could not authenticate to Seerr"
    fi
}
