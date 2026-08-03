# tests/scenarios/stage2-skip.sh — Stage 2 skipped HTTPS path.
#
# This focused scenario reuses remote-gating assertions to prove that skipping
# Stage 2 leaves LAN consumers intact and creates no public hosts.

source tests/assertions/remote_gating.sh

stage2_skip_assert_test03_postconditions() {
    local state homepage_check network_json known_proxies published

    state="$(env_get REMOTE_WEB_STATE)"
    assert_eq "skipped" "$state" "TEST-03 skipped-state LAN-only: REMOTE_WEB_STATE remains skipped after configure"

    homepage_check="$(dind_exec "python3 - <<'PY'
import pathlib
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
            if not isinstance(svc, dict):
                continue
            for details in svc.values():
                if isinstance(details, dict) and details.get('href'):
                    hrefs.append(str(details['href']))

bad = [h for h in hrefs if h in ('https://jellyfin.gate.test', 'https://seerr.gate.test')]
has_jellyfin_lan = any('jellyfin.gate.test' not in h and (h.endswith(':8096') or ':8096/' in h) for h in hrefs)
has_seerr_lan = any('seerr.gate.test' not in h and (h.endswith(':5055') or ':5055/' in h) for h in hrefs)
if bad:
    print('public_https=' + ','.join(bad))
elif not (has_jellyfin_lan and has_seerr_lan):
    print('missing_lan=' + repr(hrefs))
else:
    print('OK')
PY
" | tr -d '\r')"
    if [[ "$homepage_check" == "OK" ]]; then
        pass "TEST-03 skipped-state LAN-only: Homepage keeps Jellyfin/Seerr LAN hrefs"
    else
        fail "TEST-03 skipped-state LAN-only: Homepage keeps Jellyfin/Seerr LAN hrefs" "$homepage_check"
    fi

    network_json="$(remote_gating_fetch_jellyfin_network)"
    local managed_npm_ip
    managed_npm_ip="$(env_get MEDIASTACK_NPM_IP)"
    managed_npm_ip="${managed_npm_ip:-172.28.0.10}"
    known_proxies="$(echo "$network_json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
print("|".join(data.get("KnownProxies") or []))
' 2>/dev/null)"
    # Skipped state must clear the legacy "npm" hostname and any managed
    # pinned-IP form of the KnownProxies entry. Compare exact entries so a user
    # proxy like 172.28.0.100 is not mistaken for 172.28.0.10.
    if echo "$network_json" | MANAGED_NPM_IP="$managed_npm_ip" python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
managed = {"npm", "172.28.0.10", os.environ.get("MANAGED_NPM_IP", "172.28.0.10")}
sys.exit(1 if any(item in managed for item in (data.get("KnownProxies") or [])) else 0)
' 2>/dev/null; then
        pass "TEST-03 skipped-state LAN-only: Jellyfin does not trust ready-only npm proxy"
    else
        fail "TEST-03 skipped-state LAN-only: Jellyfin does not trust ready-only npm proxy" "KnownProxies=$known_proxies"
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
        fail "TEST-03 skipped-state LAN-only: Jellyfin omits ready-only HTTPS published URL" "$published"
    else
        pass "TEST-03 skipped-state LAN-only: Jellyfin omits ready-only HTTPS published URL"
    fi
}

stage2_skip_configure() {
    local log_path="/tmp/stage2-skip.out"
    if dind_exec "./scripts/configure.sh --only jellyfin,homepage,npm" >"$log_path" 2>&1; then
        pass "TEST-03 skipped-state LAN-only: configure.sh --only jellyfin,homepage,npm exits 0"
    else
        fail "TEST-03 skipped-state LAN-only: configure.sh --only jellyfin,homepage,npm exits 0"
        tail -40 "$log_path"
        return 1
    fi
}

stage2_seed_remote_env() {
    local state="$1"
    local jf_password='Gate!$tack"with\special#chars^&*'

    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind

    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL admin@gate.test
    env_set JELLYFIN_ADMIN_USER admin
    env_set JELLYFIN_ADMIN_PASSWORD "$jf_password"
    env_set JELLYFIN_GPU none
    env_set DOMAIN gate.test
    env_set REMOTE_WEB_STATE "$state"
    env_set WG_HOST gate.test
    env_set WG_DEFAULT_DNS 1.1.1.1
    env_set WG_INIT_PASSWORD "''"
    env_set NPM_LE_SERVER https://pebble:14000/dir
    env_set STAGE_1_COMPLETE 1

    if [[ "$(env_get REMOTE_WEB_STATE)" != "$state" ]]; then
        env_set REMOTE_WEB_STATE "$state"
    fi
}

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin config/ddns-updater"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"

    stage2_seed_remote_env skipped
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "TEST-03 skipped-state LAN-only: skipped path starts with REMOTE_WEB_STATE=skipped"

    if dind_exec "docker compose --profile proxy up -d jellyfin seerr homepage npm fail2ban ddns-updater" >/dev/null 2>&1; then
        pass "TEST-03 skipped-state LAN-only: proxy-profile services start for skipped fixture"
    else
        fail "TEST-03 skipped-state LAN-only: proxy-profile services start for skipped fixture"
        dind_exec "docker compose ps"
        return 1
    fi

    local svc ok=true
    for svc in jellyfin seerr homepage npm fail2ban ddns-updater; do
        if wait_healthy "$svc" 360; then
            pass "stage2 skip: $svc healthy"
        else
            fail "stage2 skip: $svc healthy"
            ok=false
        fi
    done
    $ok || {
        dind_exec "docker compose ps"
        return 1
    }

    stage2_skip_configure || return 1

    # Skipped HTTPS keeps LAN URLs and no public NPM hosts.
    stage2_skip_assert_test03_postconditions
    assert_remote_gating_skipped /tmp/stage2-skip.out
}
