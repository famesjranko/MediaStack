assert_jellyfin_configured() {
    local jf_password="$1"
    local jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    local jf_info
    jf_info=$(dind_exec "curl -sf http://localhost:8096/System/Info/Public")
    assert_contains "$jf_info" '"StartupWizardCompleted":true' "step 5 Jellyfin: wizard complete"

    JF_AUTH_HEADER='MediaBrowser Client="Test", Device="Test", DeviceId="fresh-install", Version="1.0"'

    local jf_auth_resp
    jf_auth_resp=$(docker exec -e "JF_USER=$jf_user" -e "JF_PW=$jf_password" "$DIND_NAME" python3 -c '
import os, json, urllib.request, sys
body = json.dumps({"Username": os.environ["JF_USER"], "Pw": os.environ["JF_PW"]}).encode()
req = urllib.request.Request(
    "http://localhost:8096/Users/AuthenticateByName",
    data=body, method="POST",
    headers={
        "Content-Type": "application/json",
        "Authorization": "MediaBrowser Client=\"Test\", Device=\"Test\", DeviceId=\"fresh-install\", Version=\"1.0\"",
    })
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.read().decode())
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
')
    JF_TOKEN=$(echo "$jf_auth_resp" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("AccessToken",""))
except Exception: pass' 2>/dev/null | tr -d '\r\n')
    if [[ -n "$JF_TOKEN" ]]; then
        pass "step 5 Jellyfin: admin auth returns AccessToken"
        local jf_libs
        jf_libs=$(dind_exec "curl -sf -H 'Authorization: $JF_AUTH_HEADER, Token=\"$JF_TOKEN\"' http://localhost:8096/Library/VirtualFolders")
        assert_contains "$jf_libs" '"Name":"Movies"' "step 5 Jellyfin: Movies library"
        assert_contains "$jf_libs" '"Name":"TV Shows"'   "step 5 Jellyfin: TV Shows library"

        local jf_encoding
        jf_encoding=$(dind_exec "curl -sf -H 'Authorization: $JF_AUTH_HEADER, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/encoding")
        local jf_accel
        jf_accel=$(echo "$jf_encoding" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("HardwareAccelerationType",""))' 2>/dev/null | tr -d '\r\n')
        assert_eq "none" "$jf_accel" "step 5 Jellyfin: encoding skipped when JELLYFIN_GPU=none"

        local jf_netcfg
        jf_netcfg=$(dind_exec "curl -sf -H 'Authorization: $JF_AUTH_HEADER, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration/network")
        local jf_auto_disc jf_known_proxies jf_published
        jf_auto_disc=$(echo "$jf_netcfg" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("AutoDiscovery",""))' 2>/dev/null | tr -d '\r\n')
        jf_known_proxies=$(echo "$jf_netcfg" | python3 -c 'import sys,json; print(",".join(json.load(sys.stdin).get("KnownProxies",[])))' 2>/dev/null | tr -d '\r\n')
        jf_published=$(echo "$jf_netcfg" | python3 -c 'import sys,json; print("|".join(json.load(sys.stdin).get("PublishedServerUriBySubnet",[])))' 2>/dev/null | tr -d '\r\n')
        assert_eq "True" "$jf_auto_disc" "step 5 Jellyfin: AutoDiscovery enabled"
        local remote_state
        remote_state=$(env_get REMOTE_WEB_STATE)
        if [[ "$remote_state" != "ready" ]]; then
            fail "step 5 Jellyfin: ready-state HTTPS assertions require REMOTE_WEB_STATE=ready" "DOMAIN=fresh.test REMOTE_WEB_STATE=${remote_state:-unset}"
        fi
        local expected_npm_ip
        expected_npm_ip=$(env_get MEDIASTACK_NPM_IP)
        expected_npm_ip="${expected_npm_ip:-172.28.0.10}"
        assert_eq "$expected_npm_ip" "$jf_known_proxies" "step 5 Jellyfin: ready-state KnownProxies set to npm pinned IP"
        assert_contains "$jf_published" "external=https://jellyfin.fresh.test" "step 5 Jellyfin: ready-state PublishedServerUriBySubnet external URL"
        assert_contains "$jf_published" "internal=http://127.0.0.1:8096" "step 5 Jellyfin: PublishedServerUriBySubnet internal URL"

        local jf_servercfg jf_bitrate_limit
        jf_servercfg=$(dind_exec "curl -sf -H 'Authorization: $JF_AUTH_HEADER, Token=\"$JF_TOKEN\"' http://localhost:8096/System/Configuration")
        jf_bitrate_limit=$(echo "$jf_servercfg" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("RemoteClientBitrateLimit",0))' 2>/dev/null | tr -d '\r\n')
        assert_eq "0" "$jf_bitrate_limit" "step 5 Jellyfin: RemoteClientBitrateLimit is 0 (unlimited)"

        local jf_server_name
        jf_server_name=$(echo "$jf_servercfg" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("ServerName",""))' 2>/dev/null | tr -d '\r\n')
        assert_eq "MediaStack" "$jf_server_name" "step 5 Jellyfin: ServerName set to MediaStack"

        local jf_ports
        jf_ports=$(dind_exec "docker port jellyfin 7359/udp 2>/dev/null" | tr -d '\r\n')
        if [[ -n "$jf_ports" ]]; then
            pass "step 5 Jellyfin: UDP 7359 auto-discovery port published"
        else
            fail "step 5 Jellyfin: UDP 7359 auto-discovery port published" "port not mapped"
        fi
    else
        fail "step 5 Jellyfin: admin auth returns AccessToken"
    fi
}
