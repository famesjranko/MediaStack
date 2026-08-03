# tests/assertions/remote_gating.sh — remote publication gates.
#
# Sourced by tests/scenarios/remote-gating.sh.

remote_gating_env() {
    local key="$1"
    env_get "$key" 2>/dev/null | tr -d '\r\n'
}

remote_gating_npm_token() {
    local email password
    email="$(remote_gating_env NPM_ADMIN_EMAIL)"
    password="$(remote_gating_env JELLYFIN_ADMIN_PASSWORD)"
    docker exec -i -w /root/MediaStack \
        -e NPM_EMAIL="$email" \
        -e NPM_PASSWORD="$password" \
        "$DIND_NAME" python3 <<'PY'
import json
import os
import sys
import urllib.request

body = json.dumps({
    "identity": os.environ["NPM_EMAIL"],
    "secret": os.environ["NPM_PASSWORD"],
}).encode()
req = urllib.request.Request(
    "http://localhost:81/api/tokens",
    data=body,
    method="POST",
    headers={"Content-Type": "application/json"},
)
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        print(json.load(resp).get("token", ""), end="")
except Exception as exc:
    print(f"remote_gating_npm_token: {exc}", file=sys.stderr)
PY
}

remote_gating_fetch_npm_hosts() {
    local token="$1"
    if [[ -z "$token" ]]; then
        echo "[]"
        return
    fi
    dind_exec "curl -sf -H 'Authorization: Bearer $token' http://localhost:81/api/nginx/proxy-hosts" 2>/dev/null || echo "[]"
}

remote_gating_fetch_jellyfin_network() {
    local api_key
    api_key="$(remote_gating_env JELLYFIN_API_KEY)"
    if [[ -z "$api_key" ]]; then
        api_key="$(dind_exec "python3 - <<'PY'
import pathlib
import re

for path in (
    pathlib.Path('config/jellyfin/config/system.xml'),
    pathlib.Path('config/jellyfin/config/network.xml'),
):
    if path.exists():
        match = re.search(r'<ApiKey>([^<]+)</ApiKey>', path.read_text())
        if match:
            print(match.group(1), end='')
            break
PY
" | tr -d '\r\n')"
    fi
    if [[ -z "$api_key" ]]; then
        echo "{}"
        return
    fi
    dind_exec "curl -sf -H 'X-Emby-Token: $api_key' http://localhost:8096/System/Configuration/network" 2>/dev/null || echo "{}"
}

remote_gating_assert_jellyfin_lan_only() {
    local state="$1"
    local network_json host_addr known_proxies published published_env published_container managed_npm_ip
    network_json="$(remote_gating_fetch_jellyfin_network)"
    host_addr="$(remote_gating_env HOST_ADDRESS)"
    managed_npm_ip="$(remote_gating_env MEDIASTACK_NPM_IP)"
    managed_npm_ip="${managed_npm_ip:-172.28.0.10}"

    known_proxies="$(echo "$network_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print("|".join(data.get("KnownProxies") or []))
' 2>/dev/null)"
    # Non-ready states must omit the legacy "npm" hostname and any managed
    # pinned-IP form of the proxy entry. Compare exact entries so a user proxy
    # like 172.28.0.100 is not mistaken for 172.28.0.10.
    if echo "$network_json" | MANAGED_NPM_IP="$managed_npm_ip" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
managed = {"npm", "172.28.0.10", os.environ.get("MANAGED_NPM_IP", "172.28.0.10")}
sys.exit(1 if any(item in managed for item in (data.get("KnownProxies") or [])) else 0)
' 2>/dev/null; then
        pass "remote gating: $state Jellyfin does not trust npm proxy"
    else
        fail "remote gating: $state Jellyfin does not trust npm proxy" "KnownProxies=$known_proxies"
    fi

    published="$(echo "$network_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print("|".join(data.get("PublishedServerUriBySubnet") or []))
' 2>/dev/null)"
    if [[ "$published" == *"external=https://jellyfin.gate.test"* ]]; then
        fail "remote gating: $state Jellyfin omits external HTTPS URL" "$published"
    else
        pass "remote gating: $state Jellyfin omits external HTTPS URL"
    fi

    if [[ "$published" != *"internal=http://127.0.0.1:8096"* && "$published" != *"internal=http://${host_addr}:8096"* ]]; then
        for _ in $(seq 1 15); do
            sleep 2
            network_json="$(remote_gating_fetch_jellyfin_network)"
            published="$(echo "$network_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print("|".join(data.get("PublishedServerUriBySubnet") or []))
' 2>/dev/null)"
            [[ "$published" == *"internal=http://127.0.0.1:8096"* || "$published" == *"internal=http://${host_addr}:8096"* ]] && break
        done
    fi
    if [[ "$published" == *"internal=http://127.0.0.1:8096"* || "$published" == *"internal=http://${host_addr}:8096"* ]]; then
        pass "remote gating: $state Jellyfin keeps internal LAN URL"
    else
        fail "remote gating: $state Jellyfin keeps internal LAN URL" "$published"
    fi

    published_env="$(remote_gating_env JELLYFIN_PUBLISHED_URL)"
    if [[ "$published_env" == "http://${host_addr}:8096" ]]; then
        pass "remote gating: $state .env Jellyfin published URL is LAN"
    else
        fail "remote gating: $state .env Jellyfin published URL is LAN" "$published_env"
    fi

    published_container="$(dind_exec "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' jellyfin | sed -n 's/^JELLYFIN_PublishedServerUrl=//p'" | tr -d '\r\n')"
    if [[ "$published_container" == "http://${host_addr}:8096" ]]; then
        pass "remote gating: $state Jellyfin container published URL is LAN"
    else
        fail "remote gating: $state Jellyfin container published URL is LAN" "$published_container"
    fi
}

remote_gating_assert_homepage_lan_only() {
    local state="$1" homepage_check
    homepage_check="$(dind_exec "python3 - <<'PY'
import pathlib
import sys
import yaml

path = pathlib.Path('config/homepage/services.yaml')
if not path.exists():
    print('missing services.yaml')
    raise SystemExit(0)
data = yaml.safe_load(path.read_text()) or []
hrefs = []
for group in data:
    if not isinstance(group, dict):
        continue
    for services in group.values():
        for svc in services or []:
            if isinstance(svc, dict):
                for details in svc.values():
                    if isinstance(details, dict) and details.get('href'):
                        hrefs.append(str(details['href']))
bad = [h for h in hrefs if h in ('https://jellyfin.gate.test', 'https://seerr.gate.test')]
needles = ('http://127.0.0.1:8096', ':8096', 'http://127.0.0.1:5055', ':5055')
has_jellyfin_lan = any('jellyfin.gate.test' not in h and (h.endswith(':8096') or ':8096/' in h) for h in hrefs)
has_seerr_lan = any('seerr.gate.test' not in h and (h.endswith(':5055') or ':5055/' in h) for h in hrefs)
if bad:
    print('bad_https=' + ','.join(bad))
elif not (has_jellyfin_lan and has_seerr_lan):
    print('missing_lan=' + repr(hrefs))
else:
    print('OK')
PY
" | tr -d '\r')"
    if [[ "$homepage_check" == "OK" ]]; then
        pass "remote gating: $state Homepage uses LAN hrefs"
    else
        fail "remote gating: $state Homepage uses LAN hrefs" "$homepage_check"
    fi
}

remote_gating_assert_no_managed_proxy_hosts() {
    local state="$1" token proxy_hosts count
    token="$(remote_gating_npm_token)"
    proxy_hosts="$(remote_gating_fetch_npm_hosts "$token")"
    count="$(echo "$proxy_hosts" | python3 -c '
import json, sys
try:
    hosts = json.load(sys.stdin)
except Exception:
    hosts = []
managed = {"jellyfin.gate.test", "seerr.gate.test"}
print(sum(
    1 for host in hosts
    if host.get("enabled") and managed.intersection(set(host.get("domain_names") or []))
))
' 2>/dev/null | tr -d '\r\n')"
    if [[ "${count:-0}" == "0" ]]; then
        pass "remote gating: $state NPM has zero enabled MediaStack proxy hosts"
    else
        fail "remote gating: $state NPM has zero enabled MediaStack proxy hosts" "count=$count"
    fi
}

remote_gating_assert_npm_hardening_logs() {
    local state="$1"
    local log_path="${2:-/tmp/remote-gating-${state}.out}"
    local log_plain
    if [[ -f "$log_path" ]]; then
        log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path")"
    else
        log_plain=""
    fi
    # Rate limiting ships disabled; the zone + jail steps still RUN outside
    # the ready gate, now emitting their disabled-path log lines.
    assert_contains "$log_plain" "NPM rate limiting: disabled" "remote gating: $state NPM rate limiting step still ran"
    assert_contains "$log_plain" "Fail2ban: npm-ratelimit jail" "remote gating: $state Fail2ban: npm-ratelimit jail step still ran"
}

assert_remote_gating_unchecked() {
    local log_path="${1:-/tmp/remote-gating-unchecked.out}"
    remote_gating_assert_jellyfin_lan_only "unchecked"
    remote_gating_assert_homepage_lan_only "unchecked"
    remote_gating_assert_no_managed_proxy_hosts "unchecked"
    remote_gating_assert_npm_hardening_logs "unchecked" "$log_path"
}

assert_remote_gating_skipped() {
    local log_path="${1:-/tmp/remote-gating-skipped.out}"
    remote_gating_assert_jellyfin_lan_only "skipped"
    remote_gating_assert_homepage_lan_only "skipped"
    remote_gating_assert_no_managed_proxy_hosts "skipped"
    remote_gating_assert_npm_hardening_logs "skipped" "$log_path"
}

assert_remote_gating_ready() {
    local log_path="${1:-/tmp/remote-gating-ready.out}"
    local token proxy_hosts ready_check pebble_check
    token="$(remote_gating_npm_token)"
    proxy_hosts="$(remote_gating_fetch_npm_hosts "$token")"
    ready_check="$(echo "$proxy_hosts" | DIND="$DIND_NAME" python3 -c '
import json
import os
import subprocess
import sys

managed = {"jellyfin.gate.test", "seerr.gate.test"}
try:
    hosts = json.load(sys.stdin)
except Exception:
    hosts = []

published = []
orphans = []
for host in hosts:
    domains = set(host.get("domain_names") or [])
    if not managed.intersection(domains):
        continue
    if not host.get("enabled"):
        continue
    cid = int(host.get("certificate_id") or 0)
    hid = host.get("id")
    if cid <= 0 or not host.get("ssl_forced"):
        orphans.append(("uncertified", hid, sorted(domains)))
        continue
    fullchain = f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/fullchain.pem"
    privkey = f"/root/MediaStack/config/npm/letsencrypt/live/npm-{cid}/privkey.pem"
    conf = f"/root/MediaStack/config/npm/data/nginx/proxy_host/{hid}.conf"
    for path in (fullchain, privkey, conf):
        if subprocess.run(["docker", "exec", os.environ["DIND"], "test", "-f", path]).returncode != 0:
            orphans.append(("missing_file", hid, path))
    published.extend(managed.intersection(domains))

missing = sorted(managed - set(published))
if missing or orphans:
    print("missing={} orphans={}".format(missing, orphans))
else:
    print("OK")
' 2>/dev/null | tr -d '\r')"
    if [[ "$ready_check" == "OK" ]]; then
        pass "remote gating: ready NPM publishes cert-backed proxy hosts"
    else
        fail "remote gating: ready NPM publishes cert-backed proxy hosts" "$ready_check"
    fi

    local published_env published_container
    published_env="$(remote_gating_env JELLYFIN_PUBLISHED_URL)"
    if [[ "$published_env" == "https://jellyfin.gate.test" ]]; then
        pass "remote gating: ready .env Jellyfin published URL is HTTPS"
    else
        fail "remote gating: ready .env Jellyfin published URL is HTTPS" "$published_env"
    fi

    published_container="$(dind_exec "docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' jellyfin | sed -n 's/^JELLYFIN_PublishedServerUrl=//p'" | tr -d '\r\n')"
    if [[ "$published_container" == "https://jellyfin.gate.test" ]]; then
        pass "remote gating: ready Jellyfin container published URL is HTTPS"
    else
        fail "remote gating: ready Jellyfin container published URL is HTTPS" "$published_container"
    fi

    pebble_check="$(dind_exec "test -f docker-compose.acme-test.yml && grep -q 'LE_SERVER=https://pebble:14000/dir' docker-compose.acme-test.yml && echo OK || true" | tr -d '\r\n')"
    if [[ "$pebble_check" == "OK" ]]; then
        pass "remote gating: ready NPM_LE_SERVER/Pebble override is active"
    else
        fail "remote gating: ready NPM_LE_SERVER/Pebble override is active"
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"
    # Rate limiting ships disabled; the zone + jail steps still RUN outside
    # the ready gate, now emitting their disabled-path log lines.
    assert_contains "$log_plain" "NPM rate limiting: disabled" "remote gating: ready NPM rate limiting step still ran"
    assert_contains "$log_plain" "Fail2ban: npm-ratelimit jail" "remote gating: ready Fail2ban: npm-ratelimit jail step still ran"
}
