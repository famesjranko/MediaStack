# tests/scenarios/wireguard-add-after-https.sh — add WireGuard to a ready-HTTPS install.
#
# Reuses the remote-ready-idempotent fixture (Pebble ACME + fixture DNS in DinD) to
# reach REMOTE_WEB_STATE=ready with WireGuard declined, enables UFW, then drives
# `./setup.sh --wireguard` (the Features & settings "Add WireGuard VPN" action)
# over a PTY as a non-root user:
#   1. decline at the opt-in prompt -> .env, config.yml, compose containers and UFW
#      rules are byte-for-byte unchanged
#   2. accept (Server-only tier)     -> remote profile on, wg-easy up, initial peer
#      carries the tier's firewallIps, UFW rules applied, HTTPS state and domain intact
#   3. re-run                        -> `--wireguard` is a no-op; `--remote` heals;
#      WG_INIT_PASSWORD, other credentials and a peer added in wg-easy are unchanged
#
# Does not prove public WAN reachability, real DDNS, or production Let's Encrypt.
# Wall-time budget: ~12-15 min cold (image pulls), shorter with the registry mirror.

source tests/scenarios/remote-ready-idempotent.sh

WG_ADD_COMPOSE_FILE="docker-compose.yml:docker-compose.acme-test.yml"

# Reach "HTTPS ready, WireGuard declined": the shared establish step runs
# _stage2_install, which commits WireGuard unless _WIZ_WG_ENABLED=false. Its shell is
# a login shell, so a profile.d snippet carries the opt-out into it for this one call.
wireguard_add_establish_ready_without_wg() {
    dind_exec "printf 'export _WIZ_WG_ENABLED=false\n' > /etc/profile.d/ms-wg-declined.sh"
    remote_ready_idempotent_establish_ready
    local rc=$?
    dind_exec "rm -f /etc/profile.d/ms-wg-declined.sh"
    return $rc
}

wireguard_add_enable_ufw() {
    dind_exec "apt-get -o Acquire::Retries=3 install -y -qq ufw >/dev/null && ufw --force enable >/dev/null"
}

# Everything the "unchanged" claims cover: env, config, containers, firewall.
wireguard_add_snapshot() {
    dind_exec "sha256sum .env config.yml; docker ps -a --format '{{.Names}} {{.Image}}' | sort; ufw status numbered"
}

# Peers as wg-easy reports them: id, name, key and tier ips, sorted. The admin
# password has shell-special characters, so it goes in through the environment.
wireguard_add_peers() {
    docker exec -i -w /root/MediaStack -e "WG_PW=$(env_get JELLYFIN_ADMIN_PASSWORD)" "$DIND_NAME" python3 <<'PY'
import base64, json, os, urllib.request
req = urllib.request.Request("http://localhost:51821/api/client")
req.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{os.environ['WG_PW']}".encode()).decode())
clients = json.load(urllib.request.urlopen(req, timeout=15))
rows = sorted((c.get("name", ""), str(c.get("id", "")), c.get("publicKey", ""), ",".join(c.get("firewallIps") or [])) for c in clients)
print("\n".join("|".join(r) for r in rows))
PY
}

wireguard_add_create_peer() {
    docker exec -i -w /root/MediaStack -e "WG_PW=$(env_get JELLYFIN_ADMIN_PASSWORD)" "$DIND_NAME" python3 <<'PY'
import base64, json, os, urllib.request
req = urllib.request.Request("http://localhost:51821/api/client", data=json.dumps({"name": "friend", "expiresAt": None}).encode(), method="POST")
req.add_header("Content-Type", "application/json")
req.add_header("Authorization", "Basic " + base64.b64encode(f"admin:{os.environ['WG_PW']}".encode()).decode())
try:
    urllib.request.urlopen(req, timeout=15).read()
except Exception:
    pass  # wg-easy can answer 500 and still persist; the caller reads the peer list back
PY
}

# Run `./setup.sh <flag>` as the non-root user under a PTY with the given steps.
wireguard_add_run_pty() {
    local name="$1" flag="$2" steps_json="$3"
    local steps="/tmp/wg-add-$name.steps.json" plain="/tmp/wg-add-$name.plain.log"
    dind_exec "cat >$steps <<'JSON'
$steps_json
JSON
chmod 644 $steps; rm -f $plain /tmp/wg-add-$name.raw.log"
    if dind_exec "su -s /bin/bash mstest -c 'cd /root/MediaStack && COMPOSE_FILE=$WG_ADD_COMPOSE_FILE timeout 900 python3 tests/lib/wizard_pty.py --command \"./setup.sh $flag\" --steps $steps --raw-log /tmp/wg-add-$name.raw.log --plain-log $plain --step-timeout 600 --exit-timeout 600'"; then
        pass "wireguard add [$name]: ./setup.sh $flag exits 0"
    else
        fail "wireguard add [$name]: ./setup.sh $flag exits 0"
        dind_exec "tail -120 $plain 2>/dev/null || true"
        return 1
    fi
}

# assert_remote_gating_ready reads a host-side log, so copy the PTY transcript out of DinD.
wireguard_add_assert_ready() {
    local host_log
    host_log="$(mktemp)"
    dind_exec "cat /tmp/wg-add-$1.plain.log" >"$host_log"
    assert_remote_gating_ready "$host_log"
    rm -f "$host_log"
}

wireguard_add_ufw_text() { dind_exec "ufw status numbered" | tr -s ' '; }

wireguard_add_scenario_body() {
    dind_exec "docker compose down -v --remove-orphans 2>/dev/null || true"
    dind_exec "ids=\$(docker ps -aq); [ -z \"\$ids\" ] || docker rm -f \$ids >/dev/null 2>&1 || true"
    dind_exec "docker rm -f pebble pebble-challtestsrv 2>/dev/null || true"
    dind_exec "rm -rf config/npm config/homepage config/jellyfin config/ddns-updater config/wireguard docker-compose.acme-test.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"

    remote_ready_idempotent_seed_env
    remote_ready_idempotent_start_proxy_fixture || return 1
    wireguard_add_establish_ready_without_wg || return 1
    remote_ready_idempotent_prepare_public_route_user
    remote_ready_idempotent_watch_fixture_state
    dind_exec "cp config/examples/config.yml config.yml && chown mstest:mstest config.yml"
    wireguard_add_enable_ufw || {
        fail "wireguard add: UFW installed and enabled in DinD"
        return 1
    }

    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "wireguard add: precondition HTTPS ready"
    assert_eq "" "$(env_get WG_INIT_PASSWORD)" "wireguard add: precondition WireGuard absent"
    assert_eq "" "$(dind_exec "docker ps -a --filter name=^wireguard\$ --format '{{.Names}}'" | tr -d '\r\n')" "wireguard add: precondition no wg-easy container"

    # ---- 1. Decline leaves everything byte-for-byte unchanged ------------------
    local before after
    before="$(wireguard_add_snapshot)"
    wireguard_add_run_pty decline --wireguard '[
  {"expect": "Set up a WireGuard VPN for admin access\\?"},
  {"send": "n\n"},
  {"expect": "No changes made"}
]' || return 1
    after="$(wireguard_add_snapshot)"
    assert_eq "$before" "$after" "wireguard add [decline]: .env, config.yml, containers and UFW rules unchanged"

    # ---- 2. Accept: Server-only tier ------------------------------------------
    remote_ready_idempotent_watch_fixture_state
    wireguard_add_run_pty accept --wireguard '[
  {"expect": "Set up a WireGuard VPN for admin access\\?"},
  {"send": "y\n"},
  {"expect": "WireGuard UDP port"},
  {"send": "\n"},
  {"expect": "VPN access level for your admin device"},
  {"send": "2\n"},
  {"expect": "Start WireGuard with these settings\\?"},
  {"send": "y\n"}
]' || return 1

    assert_eq "$(env_get JELLYFIN_ADMIN_PASSWORD)" "$(env_get WG_INIT_PASSWORD)" "wireguard add [accept]: WG_INIT_PASSWORD is the admin password"
    assert_eq "server" "$(env_get WG_ACCESS_TIER)" "wireguard add [accept]: selected access tier saved"
    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "wireguard add [accept]: REMOTE_WEB_STATE stays ready"
    assert_eq "gate.test" "$(env_get DOMAIN)" "wireguard add [accept]: DOMAIN unchanged"
    wireguard_add_assert_ready accept
    assert_contains "$(dind_exec "bash -c 'source scripts/lib/profiles.sh; profiles_build_args p .env; echo \"\${p[*]}\"'")" "--profile remote" "wireguard add [accept]: remote profile enabled"
    if wait_healthy wireguard 180; then
        pass "wireguard add [accept]: wg-easy started and healthy"
    else
        fail "wireguard add [accept]: wg-easy started and healthy"
        return 1
    fi
    local peers
    peers="$(wireguard_add_peers)"
    assert_contains "$peers" "admin|" "wireguard add [accept]: initial admin peer exists"
    assert_contains "$peers" "|127.0.0.1/32" "wireguard add [accept]: initial peer carries the Server tier firewallIps"
    local ufw_text
    ufw_text="$(wireguard_add_ufw_text)"
    assert_contains "$ufw_text" "Status: active" "wireguard add [accept]: UFW still active"
    assert_contains "$ufw_text" "MediaStack:WireGuard-clients" "wireguard add [accept]: UFW rule for WireGuard tier traffic applied"
    assert_contains "$ufw_text" "172.28.0.11" "wireguard add [accept]: tier rule is scoped to the wg-easy container address"
    assert_contains "$ufw_text" "51820/udp ALLOW IN Anywhere # MediaStack:WireGuard" "wireguard add [accept]: UFW rule for the WireGuard UDP port applied"

    # ---- 3. Re-run keeps credentials and peers --------------------------------
    wireguard_add_create_peer
    peers="$(wireguard_add_peers)"
    assert_contains "$peers" "friend|" "wireguard add [rerun]: extra peer created in wg-easy"
    local env_before env_after
    env_before="$(dind_exec "grep -E '^(JELLYFIN_ADMIN_PASSWORD|NPM_ADMIN_EMAIL|WG_[A-Z_]+|DOMAIN|REMOTE_WEB_STATE)=' .env | sort")"

    wireguard_add_run_pty rerun-wireguard --wireguard '[]' || return 1
    assert_contains "$(dind_exec "cat /tmp/wg-add-rerun-wireguard.plain.log")" "already set up" "wireguard add [rerun]: --wireguard reports WireGuard already set up"
    assert_eq "$peers" "$(wireguard_add_peers)" "wireguard add [rerun]: --wireguard leaves peers unchanged"

    remote_ready_idempotent_watch_fixture_state
    wireguard_add_run_pty rerun-remote --remote '[]' || return 1
    env_after="$(dind_exec "grep -E '^(JELLYFIN_ADMIN_PASSWORD|NPM_ADMIN_EMAIL|WG_[A-Z_]+|DOMAIN|REMOTE_WEB_STATE)=' .env | sort")"
    assert_eq "$env_before" "$env_after" "wireguard add [rerun]: WG_INIT_PASSWORD and other credentials unchanged"
    assert_eq "$peers" "$(wireguard_add_peers)" "wireguard add [rerun]: --remote heal keeps existing peers"
    wireguard_add_assert_ready rerun-remote
}

# UFW lives in the shared DinD; later scenarios in a --reset-between battery must
# start without it active. The wrapper resets it on pass and fail paths alike.
wireguard_add_disable_ufw() {
    dind_exec "command -v ufw >/dev/null && ufw --force reset >/dev/null || true"
}

run_scenario() {
    local rc=0
    wireguard_add_scenario_body || rc=$?
    wireguard_add_disable_ufw
    return "$rc"
}
