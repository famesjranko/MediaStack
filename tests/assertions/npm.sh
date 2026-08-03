assert_npm_configured() {
    local jf_password="$1"

    if svc_stripped npm; then
        skip "step 9 NPM: shared admin creds authenticate" "stripped via MS_TEST_STRIP_SERVICES"
        skip "step 9 NPM: defaults rejected" "stripped via MS_TEST_STRIP_SERVICES"
        skip "step 9 NPM: proxy hosts created" "stripped via MS_TEST_STRIP_SERVICES"
        skip "step 9 NPM: Let's Encrypt certificates" "stripped via MS_TEST_STRIP_SERVICES"
        skip "step 9 NPM: HTTPS connectivity" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local npm_resp
    npm_resp=$(docker exec -e "JF_PW=$jf_password" "$DIND_NAME" python3 -c '
import os, json, urllib.request, sys
body = json.dumps({"identity": "admin@fresh.test", "secret": os.environ["JF_PW"]}).encode()
req = urllib.request.Request(
    "http://localhost:81/api/tokens",
    data=body, method="POST",
    headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        print(r.read().decode())
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
')
    NPM_TOKEN=$(echo "$npm_resp" \
        | python3 -c 'import sys,json; print(json.load(sys.stdin).get("token",""))' 2>/dev/null | tr -d '\r\n')
    [[ -n "$NPM_TOKEN" ]] && pass "step 9 NPM: shared admin creds authenticate" || fail "step 9 NPM: shared admin creds authenticate"

    local npm_default_http
    npm_default_http=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:81/api/tokens \
        -H 'Content-Type: application/json' -d '{\"identity\":\"admin@example.com\",\"secret\":\"changeme\"}'" | tr -d '\r\n')
    case "$npm_default_http" in
        400 | 401) pass "step 9 NPM: defaults rejected (HTTP $npm_default_http)" ;;
        *) fail "step 9 NPM: defaults rejected" "HTTP $npm_default_http" ;;
    esac

    if [[ -n "$NPM_TOKEN" ]]; then
        local remote_state
        remote_state=$(env_get REMOTE_WEB_STATE)
        if [[ "$remote_state" != "ready" ]]; then
            fail "step 9 NPM: ready-state HTTPS assertions require REMOTE_WEB_STATE=ready" "DOMAIN=fresh.test REMOTE_WEB_STATE=${remote_state:-unset}"
        fi

        local proxy_hosts
        proxy_hosts=$(dind_exec "curl -sf -H 'Authorization: Bearer $NPM_TOKEN' http://localhost:81/api/nginx/proxy-hosts" 2>/dev/null)
        local proxy_count
        proxy_count=$(echo "$proxy_hosts" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null | tr -d '\r\n')
        if [[ "$proxy_count" -ge 2 ]]; then
            pass "step 9 NPM: $proxy_count ready-state proxy hosts created (user-facing only)"
        else
            fail "step 9 NPM: ready-state proxy hosts created" "expected >=2, got $proxy_count"
        fi

        local jellyfin_proxy_http
        jellyfin_proxy_http=$(dind_exec "curl -sf -o /dev/null -w '%{http_code}' -H 'Host: jellyfin.fresh.test' http://localhost:80" | tr -d '\r\n')
        if [[ "$jellyfin_proxy_http" =~ ^(200|301|302)$ ]]; then
            pass "step 9 NPM: ready-state jellyfin.fresh.test routes via proxy (HTTP $jellyfin_proxy_http)"
        else
            fail "step 9 NPM: ready-state jellyfin.fresh.test routes via proxy" "HTTP $jellyfin_proxy_http"
        fi

        local certs cert_count
        certs=$(dind_exec "curl -sf -H 'Authorization: Bearer $NPM_TOKEN' http://localhost:81/api/nginx/certificates" 2>/dev/null || echo "[]")
        cert_count=$(echo "$certs" | python3 -c 'import sys,json; print(len([c for c in json.load(sys.stdin) if c.get("provider")=="letsencrypt"]))' 2>/dev/null | tr -d '\r\n')
        if [[ "$cert_count" -ge 2 ]]; then
            pass "step 9 NPM: $cert_count ready-state Let's Encrypt certificates issued"
        else
            fail "step 9 NPM: ready-state Let's Encrypt certificates issued" "expected >=2 LE certs, got $cert_count"
        fi

        # Re-fetch proxy hosts (configure.sh updated them after cert issuance)
        proxy_hosts=$(dind_exec "curl -sf -H 'Authorization: Bearer $NPM_TOKEN' http://localhost:81/api/nginx/proxy-hosts" 2>/dev/null)
        local ssl_forced_count
        ssl_forced_count=$(echo "$proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
print(len([h for h in hosts if (h.get("certificate_id") or 0) != 0 and h.get("ssl_forced")]))
' 2>/dev/null | tr -d '\r\n')
        if [[ "$ssl_forced_count" -ge 2 ]]; then
            pass "step 9 NPM: $ssl_forced_count proxy hosts have SSL forced + cert"
        else
            fail "step 9 NPM: proxy hosts SSL forced" "expected >=2, got $ssl_forced_count"
        fi

        local unsafe_proxy_count
        unsafe_proxy_count=$(echo "$proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
print(len([h for h in hosts if bool(h.get("enabled")) and (h.get("certificate_id") or 0) == 0]))
' 2>/dev/null | tr -d '\r\n')
        if [[ "$unsafe_proxy_count" == "0" ]]; then
            pass "step 9 NPM: no enabled certless proxy hosts remain"
        else
            fail "step 9 NPM: enabled certless proxy hosts" "expected 0, got $unsafe_proxy_count"
        fi

        # Stronger guard: an enabled host with cert_id != 0 can still be
        # silently broken if NPM's API accepted publication but didn't
        # render proxy_host/$id.conf, or didn't write key+chain to
        # letsencrypt/live/npm-$cert_id/. "Enabled in DB" must mean
        # "renders + has cert material" or it's an orphan.
        local orphan_managed_count
        orphan_managed_count=$(echo "$proxy_hosts" | DIND="$DIND_NAME" python3 -c '
import sys, json, os, subprocess
managed_subdomains = ("jellyfin.", "seerr.")
hosts = json.load(sys.stdin)
def in_dind(*args):
    return subprocess.run(
        ["docker", "exec", os.environ["DIND"], *args],
        capture_output=True,
    ).returncode == 0
orphans = []
for h in hosts:
    if not h.get("enabled"):
        continue
    domains = h.get("domain_names", [])
    if not any(d.startswith(p) for p in managed_subdomains for d in domains):
        continue
    cid = int(h.get("certificate_id") or 0)
    hid = h.get("id")
    if cid == 0:
        orphans.append(("no_cert_id", hid, domains)); continue
    conf = f"/root/MediaStack/config/npm/data/nginx/proxy_host/{hid}.conf"
    if not in_dind("test", "-f", conf):
        orphans.append(("no_conf", hid, domains)); continue
    fc = f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/fullchain.pem"
    pk = f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/privkey.pem"
    if not (in_dind("test", "-f", fc) and in_dind("test", "-f", pk)):
        orphans.append(("no_cert_files", hid, domains)); continue
print(len(orphans), orphans)
' 2>/dev/null | tr -d '\r\n')
        if [[ "$orphan_managed_count" == "0 []" ]]; then
            pass "step 9 NPM: managed proxy hosts have rendered .conf + cert material"
        else
            fail "step 9 NPM: managed proxy host orphans" "$orphan_managed_count"
        fi

        local https_http
        https_http=$(dind_exec "curl -sk -o /dev/null -w '%{http_code}' --resolve 'jellyfin.fresh.test:443:127.0.0.1' https://jellyfin.fresh.test:443" | tr -d '\r\n')
        if [[ "$https_http" =~ ^(200|301|302)$ ]]; then
            pass "step 9 NPM: ready-state HTTPS serves jellyfin.fresh.test (HTTP $https_http)"
        else
            fail "step 9 NPM: ready-state HTTPS serves jellyfin.fresh.test" "HTTP $https_http"
        fi

        local adv_config_count
        adv_config_count=$(echo "$proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
count = 0
for h in hosts:
    ac = h.get("advanced_config", "") or ""
    if "X-Content-Type-Options" in ac and "Strict-Transport-Security" in ac:
        count += 1
print(count)
' 2>/dev/null | tr -d '\r\n')
        if [[ "$adv_config_count" -ge 2 ]]; then
            pass "step 9 NPM: $adv_config_count proxy hosts have security headers in advanced_config"
        else
            fail "step 9 NPM: security headers in advanced_config" "expected >=2 hosts with headers, got $adv_config_count"
        fi

        # Jellyfin host carries its upstream-recommended extras (jellyfin.org
        # nginx guide): Content-Security-Policy + client_max_body_size 20M.
        # Jellyfin-only — upstream Seerr ships neither.
        local jf_upstream
        jf_upstream=$(echo "$proxy_hosts" | python3 -c '
import sys, json
hosts = json.load(sys.stdin)
for h in hosts:
    if any(d.startswith("jellyfin.") for d in h.get("domain_names", [])):
        ac = h.get("advanced_config", "") or ""
        print("yes" if ("Content-Security-Policy" in ac and "client_max_body_size 20M" in ac) else "no")
        break
' 2>/dev/null | tr -d '\r\n')
        if [[ "$jf_upstream" == "yes" ]]; then
            pass "step 9 NPM: jellyfin host has upstream CSP + client_max_body_size 20M"
        else
            fail "step 9 NPM: jellyfin host upstream headers" "expected CSP + client_max_body_size 20M, got '$jf_upstream'"
        fi

        # Headers must actually EMIT on the wire, not merely sit in advanced_config.
        # NPM's proxy.conf adds `add_header X-Served-By` in `location /`, which makes
        # nginx drop inherited server-level add_header directives — so the security
        # headers are set with more_set_headers (headers_more) to survive that. Probe
        # the live response to prove CSP + HSTS + nosniff reach the client.
        local emit_headers emit_ok=0
        emit_headers=$(dind_exec "curl -sk -o /dev/null -D - --resolve 'jellyfin.fresh.test:443:127.0.0.1' https://jellyfin.fresh.test/System/Info/Public")
        grep -qi '^content-security-policy:' <<<"$emit_headers" && emit_ok=$((emit_ok + 1)) || true
        grep -qi '^strict-transport-security:' <<<"$emit_headers" && emit_ok=$((emit_ok + 1)) || true
        grep -qi '^x-content-type-options:' <<<"$emit_headers" && emit_ok=$((emit_ok + 1)) || true
        if [[ "$emit_ok" -eq 3 ]]; then
            pass "step 9 NPM: security headers emit on live jellyfin responses (CSP + HSTS + nosniff)"
        else
            fail "step 9 NPM: security headers emit on live jellyfin responses" \
                "only $emit_ok/3 present — more_set_headers must survive proxy.conf's location add_header"
        fi
    fi
}
