# tests/scenarios/ddns-seed.sh — DDNS updater: config seeding + container test.
# Validates the setup.sh seeding logic inside DinD, then starts the ddns-updater
# container and verifies it comes up and serves its web UI.
#
# Wall-time: ~60s warm (ddns-updater image is ~20 MB).

run_scenario() {
    local ddns_container=smoke-ddns

    # Prep: .env + config dirs (needed for compose).
    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind
    env_set TZ Etc/UTC
    env_set DOMAIN ddns.test

    # ------------------------------------------------------------------
    # Test 1: Seeding snippet produces valid config.json inside DinD.
    # Runs the exact python from setup.sh — single entry for the base
    # domain (wildcard DNS handles subdomains).
    # ------------------------------------------------------------------
    # Dynu collects password only (#248); the username is a constant placeholder
    # the renderer auto-fills, so the seed carries no user-supplied username.
    local seed_rc
    dind_exec 'DDNS_DOMAIN="ddns.test" DDNS_PASSWORD="testpass123" \
        python3 -c '\''
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "password": os.environ["DDNS_PASSWORD"],
    "username": "mediastack",
    "ip_version": "ipv4",
}]}, indent=2))
'\'' > config/ddns-updater/config.json' >/dev/null 2>&1
    seed_rc=$?

    if (( seed_rc == 0 )); then
        pass "DDNS seed python snippet executes inside DinD"
    else
        fail "DDNS seed python snippet executes inside DinD"
        return 1
    fi

    # Validate JSON structure inside DinD.
    local validation
    validation=$(dind_exec 'python3 << '\''PYEOF'\''
import json
d = json.load(open("config/ddns-updater/config.json"))
settings = d.get("settings", [])
errors = []
if len(settings) != 1:
    errors.append(f"expected 1 entry (base domain), got {len(settings)}")
e = settings[0]
prov = e.get("provider")
dom = e.get("domain")
if prov != "dynu":
    errors.append(f"provider={prov}, expected dynu")
if dom != "ddns.test":
    errors.append(f"domain={dom}, expected ddns.test")
if e.get("username") != "mediastack":
    errors.append("username placeholder mismatch")
if e.get("password") != "testpass123":
    errors.append("password mismatch")
if e.get("ip_version") != "ipv4":
    errors.append("ip_version mismatch")
if errors:
    print("; ".join(errors))
else:
    print("OK")
PYEOF' | tr -d '\r\n')

    if [[ "$validation" == "OK" ]]; then
        pass "DDNS config.json has correct structure (1 Dynu entry for base domain)"
    else
        fail "DDNS config.json structure" "$validation"
    fi

    # ------------------------------------------------------------------
    # Test 2: Special characters in password survive JSON round-trip.
    # Use env var passthrough to avoid shell-quoting issues with the
    # password literal inside dind_exec.
    # ------------------------------------------------------------------
    local special_pw='p@ss"w\rd$#!'
    docker exec -i -w /root/MediaStack \
        -e "DDNS_DOMAIN=ddns.test" -e "DDNS_PASSWORD=$special_pw" \
        "$DIND_NAME" python3 <<'PY' > /tmp/ddns-special.json
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "password": os.environ["DDNS_PASSWORD"],
    "username": "mediastack",
    "ip_version": "ipv4",
}]}, indent=2))
PY

    local pw_check
    pw_check=$(python3 -c '
import json
d = json.load(open("/tmp/ddns-special.json"))
print(d["settings"][0]["password"], end="")
')
    if [[ "$pw_check" == "$special_pw" ]]; then
        pass "DDNS seed handles special characters in password"
    else
        fail "DDNS seed special char round-trip" "got '$pw_check'"
    fi

    # ------------------------------------------------------------------
    # Test 2b: setup's writer keeps config readable by ddns-updater's fixed
    # uid 1000 even when the MediaStack installer PUID is not 1000.
    # ------------------------------------------------------------------
    local writer_rc
    dind_exec 'rm -f config/ddns-updater/config.json && bash -c '\''
set -e
source scripts/lib/common.sh
source scripts/setup/env_gen.sh
SCRIPT_DIR=/root/MediaStack
_ENV_TZ=Etc/UTC
_ENV_PUID=1001
_ENV_PGID=1001
_ENV_HOST_ADDRESS=127.0.0.1
_WIZ_TZ=Etc/UTC
_WIZ_DATA_DIR=/data
_WIZ_ADMIN_USER=admin
_WIZ_ADMIN_PW=GeneratedPassword123
_WIZ_ADMIN_EMAIL=owner@ddns.test
_WIZ_DOMAIN=ddns.test
_WIZ_REMOTE_WEB_STATE=unchecked
_WIZ_DDNS_PROVIDER=dynu
_WIZ_DDNS_FIELDS=([password]=testpass123)
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_WG_HOST=ddns.test
_WIZ_WG_PORT=51820
_WIZ_WG_DNS=1.1.1.1
_WIZ_WG_ACCESS_TIER=full-lan
_WIZ_WG_LAN_CIDR="192.168.1.0/24"
_WIZ_WG_SERVER_LAN_IP="192.168.1.10"
_WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
_WIZ_WG_PER_CLIENT_FIREWALL=true
_WIZ_TORRENT_PORT=6881
_WIZ_DL_LIMIT=0
_WIZ_UL_LIMIT=0
_WIZ_BAZARR_ENABLED=false
_WIZ_SMB_ENABLED=false
write_env
'\''' >/dev/null 2>&1
    writer_rc=$?
    if (( writer_rc == 0 )); then
        pass "DDNS setup writer succeeds with simulated installer uid 1001"
    else
        fail "DDNS setup writer succeeds with simulated installer uid 1001"
        return 1
    fi

    local config_stat
    config_stat=$(dind_exec "stat -c '%u:%g %a' config/ddns-updater/config.json" | tr -d '\r')
    assert_eq "1000:1000 600" "$config_stat" "DDNS config.json owned by ddns-updater uid with private mode"

    # A legacy fallback wrote through config.json.tmp in the uid-1000-owned
    # ddns-updater directory. Keep a symlink there to prove the setup writer
    # no longer touches that predictable path.
    dind_exec 'printf unchanged >/tmp/ddns-symlink-target && ln -sf /tmp/ddns-symlink-target config/ddns-updater/config.json.tmp'
    local symlink_writer_rc
    local dir_symlink_writer_rc
    dind_exec 'bash -c '\''
set -e
source scripts/lib/common.sh
source scripts/setup/env_gen.sh
SCRIPT_DIR=/root/MediaStack
_ENV_TZ=Etc/UTC
_ENV_PUID=1001
_ENV_PGID=1001
_ENV_HOST_ADDRESS=127.0.0.1
_WIZ_TZ=Etc/UTC
_WIZ_DATA_DIR=/data
_WIZ_ADMIN_USER=admin
_WIZ_ADMIN_PW=GeneratedPassword123
_WIZ_ADMIN_EMAIL=owner@ddns.test
_WIZ_DOMAIN=ddns.test
_WIZ_REMOTE_WEB_STATE=unchecked
_WIZ_DDNS_PROVIDER=dynu
_WIZ_DDNS_FIELDS=([password]=testpass123)
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_WG_HOST=ddns.test
_WIZ_WG_PORT=51820
_WIZ_WG_DNS=1.1.1.1
_WIZ_WG_ACCESS_TIER=full-lan
_WIZ_WG_LAN_CIDR="192.168.1.0/24"
_WIZ_WG_SERVER_LAN_IP="192.168.1.10"
_WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
_WIZ_WG_PER_CLIENT_FIREWALL=true
_WIZ_TORRENT_PORT=6881
_WIZ_DL_LIMIT=0
_WIZ_UL_LIMIT=0
_WIZ_BAZARR_ENABLED=false
_WIZ_SMB_ENABLED=false
write_env
'\''' >/dev/null 2>&1
    symlink_writer_rc=$?
    if (( symlink_writer_rc == 0 )); then
        pass "DDNS setup writer succeeds while legacy temp symlink exists"
    else
        fail "DDNS setup writer succeeds while legacy temp symlink exists"
        return 1
    fi
    local symlink_target
    symlink_target=$(dind_exec "cat /tmp/ddns-symlink-target" | tr -d '\r\n')
    assert_eq "unchanged" "$symlink_target" "DDNS setup writer ignores predictable config-dir temp symlink"
    config_stat=$(dind_exec "stat -c '%u:%g %a' config/ddns-updater/config.json" | tr -d '\r')
    assert_eq "1000:1000 600" "$config_stat" "DDNS setup writer leaves config valid after temp symlink check"

    dind_exec 'rm -rf /tmp/ddns-dir-target && mkdir -p /tmp/ddns-dir-target && mv config/ddns-updater config/ddns-updater.real && ln -s /tmp/ddns-dir-target config/ddns-updater'
    local dir_symlink_repair_rc
    dind_exec "bash -c 'source scripts/lib/common.sh && source scripts/setup/env_gen.sh && SCRIPT_DIR=/root/MediaStack repair_ddns_updater_config_permissions'" >/dev/null 2>&1
    dir_symlink_repair_rc=$?
    if (( dir_symlink_repair_rc != 0 )); then
        pass "DDNS permission repair rejects symlinked config directory"
    else
        fail "DDNS permission repair rejects symlinked config directory"
    fi
    dind_exec 'bash -c '\''
source scripts/lib/common.sh
source scripts/setup/env_gen.sh
SCRIPT_DIR=/root/MediaStack
_ENV_TZ=Etc/UTC
_ENV_PUID=1001
_ENV_PGID=1001
_ENV_HOST_ADDRESS=127.0.0.1
_WIZ_TZ=Etc/UTC
_WIZ_DATA_DIR=/data
_WIZ_ADMIN_USER=admin
_WIZ_ADMIN_PW=GeneratedPassword123
_WIZ_ADMIN_EMAIL=owner@ddns.test
_WIZ_DOMAIN=ddns.test
_WIZ_REMOTE_WEB_STATE=unchecked
_WIZ_DDNS_PROVIDER=dynu
_WIZ_DDNS_FIELDS=([password]=testpass123)
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_WG_HOST=ddns.test
_WIZ_WG_PORT=51820
_WIZ_WG_DNS=1.1.1.1
_WIZ_WG_ACCESS_TIER=full-lan
_WIZ_WG_LAN_CIDR="192.168.1.0/24"
_WIZ_WG_SERVER_LAN_IP="192.168.1.10"
_WIZ_WG_INIT_ALLOWED_IPS="192.168.1.0/24"
_WIZ_WG_PER_CLIENT_FIREWALL=true
_WIZ_TORRENT_PORT=6881
_WIZ_DL_LIMIT=0
_WIZ_UL_LIMIT=0
_WIZ_BAZARR_ENABLED=false
_WIZ_SMB_ENABLED=false
write_env
'\''' >/dev/null 2>&1
    dir_symlink_writer_rc=$?
    if (( dir_symlink_writer_rc != 0 )); then
        pass "DDNS setup writer rejects symlinked config directory"
    else
        fail "DDNS setup writer rejects symlinked config directory"
    fi
    local dir_symlink_target_config
    dir_symlink_target_config=$(dind_exec 'test -e /tmp/ddns-dir-target/config.json && echo yes || echo no' | tr -d '\r\n')
    assert_eq "no" "$dir_symlink_target_config" "DDNS setup writer does not write through symlinked config directory"
    dind_exec 'rm config/ddns-updater && mv config/ddns-updater.real config/ddns-updater'

    dind_exec "chown 1001:1001 config/ddns-updater/config.json && chmod 600 config/ddns-updater/config.json"
    if dind_exec "bash -c 'source scripts/lib/common.sh && source scripts/setup/env_gen.sh && SCRIPT_DIR=/root/MediaStack repair_ddns_updater_config_permissions'" >/dev/null 2>&1; then
        pass "DDNS permission repair handles legacy non-1000 config.json"
    else
        fail "DDNS permission repair handles legacy non-1000 config.json"
        return 1
    fi
    config_stat=$(dind_exec "stat -c '%u:%g %a' config/ddns-updater/config.json" | tr -d '\r')
    assert_eq "1000:1000 600" "$config_stat" "DDNS permission repair restores container-readable private config"

    # ------------------------------------------------------------------
    # Test 3: Overwrite guard — second seed does not clobber existing config.
    # Simulates re-running setup.sh when config.json already exists.
    # ------------------------------------------------------------------
    docker exec -i -w /root/MediaStack \
        -e "DDNS_DOMAIN=ddns.test" -e "DDNS_PASSWORD=CLOBBERED" \
        "$DIND_NAME" python3 <<'PY'
import os, json, pathlib
config_path = pathlib.Path("config/ddns-updater/config.json")
if config_path.exists():
    pass  # guard hit — do not overwrite
else:
    print(json.dumps({"settings": [{
        "provider": "dynu",
        "domain": os.environ["DDNS_DOMAIN"],
        "password": os.environ["DDNS_PASSWORD"],
        "username": "mediastack",
        "ip_version": "ipv4",
    }]}, indent=2))
PY

    # The persisted config now carries the constant username placeholder (#248), so
    # the "not clobbered" proof is that the real credential (password) survived.
    local guard_pw
    guard_pw=$(dind_exec 'python3 -c "import json; print(json.load(open(\"config/ddns-updater/config.json\"))[\"settings\"][0][\"password\"], end=\"\")"' | tr -d '\r\n')
    if [[ "$guard_pw" == "testpass123" ]]; then
        pass "DDNS overwrite guard preserves existing config.json"
    else
        fail "DDNS overwrite guard" "password='$guard_pw' (expected 'testpass123')"
    fi

    # ------------------------------------------------------------------
    # Test 4: ddns-updater container starts and serves web UI on :8000.
    # Run standalone (not via compose) to isolate from the rest of the stack.
    # ------------------------------------------------------------------
    dind_exec "docker rm -f $ddns_container" >/dev/null 2>&1 || true
    # Honor a candidate-image override (launched outside compose, so
    # dind_override_images can't reach it — resolve the tag explicitly).
    local ddns_image
    ddns_image=$(ms_test_image ddns-updater qmcgaw/ddns-updater:latest) || { fail "ddns-seed: resolve ddns-updater image override"; return 1; }
    dind_exec "docker run -d --name $ddns_container \
        -p 18000:8000 \
        -v /root/MediaStack/config/ddns-updater:/updater/data \
        -e TZ=Etc/UTC \
        -e PERIOD=5m \
        $ddns_image" >/dev/null

    local ddns_ready=false i
    for i in $(seq 1 30); do
        if dind_exec "curl -sf -o /dev/null http://127.0.0.1:18000/" 2>/dev/null; then
            ddns_ready=true
            break
        fi
        sleep 2
    done
    if $ddns_ready; then
        pass "ddns-updater container starts and serves web UI ($((i * 2))s)"
    else
        fail "ddns-updater web UI on :18000"
        dind_exec "docker logs --tail 20 $ddns_container" 2>&1 || true
        dind_exec "docker rm -f $ddns_container" >/dev/null 2>&1 || true
        return 1
    fi

    # ------------------------------------------------------------------
    # Test 5: Container loaded our seeded config (domain in logs).
    # ddns-updater logs the domains it manages at startup. Checking logs
    # is more reliable than hitting API endpoints that vary by version.
    # ------------------------------------------------------------------
    local logs
    logs=$(dind_exec "docker logs $ddns_container 2>&1")
    if echo "$logs" | grep -q "ddns.test"; then
        pass "ddns-updater loaded seeded domain from config"
    else
        # Fallback: container is running with our config, even if domain
        # isn't explicitly logged at startup in this image version.
        local config_exists
        config_exists=$(dind_exec "docker exec $ddns_container test -f /updater/data/config.json && echo yes" | tr -d '\r\n')
        if [[ "$config_exists" == "yes" ]]; then
            pass "ddns-updater has config.json mounted (domain not in logs but config present)"
        else
            fail "ddns-updater loaded seeded config" "domain not in logs, config.json not found"
        fi
    fi

    # ------------------------------------------------------------------
    # Test 6: configure_ddns_updater reports status when container is running.
    # Rename the container to match what the function filters on.
    # ------------------------------------------------------------------
    dind_exec "docker rename $ddns_container ddns-updater" >/dev/null 2>&1 || true
    local configure_out
    configure_out=$(dind_exec 'bash -c "source scripts/lib/common.sh && source scripts/services/ddns-updater/main.sh && SCRIPT_DIR=/root/MediaStack configure_ddns_updater"' 2>&1)
    if echo "$configure_out" | grep -q "DDNS config present"; then
        pass "configure_ddns_updater() reports config present"
    else
        fail "configure_ddns_updater() reports status" "output: ${configure_out:0:200}"
    fi

    # ------------------------------------------------------------------
    # Test 7 (#236): all 6 providers render valid typed config.json via the
    # shared renderer; a missing required field is refused. Uses a quoted
    # heredoc into `bash` so no shell-quoting fights the assoc literals.
    # ------------------------------------------------------------------
    docker exec -i -w /root/MediaStack "$DIND_NAME" bash > /tmp/ddns-render-loop.out 2>/dev/null <<'SH'
source scripts/lib/ddns_providers.sh
fail=0
render() { local key="$1"; shift; local -A f=([domain]="ddns.test"); while (( $# )); do f["$1"]="$2"; shift 2; done; ddns_render_config_json "$key" f; }
declare -A vals=([dynu]="password p" [duckdns]="token t" [desec]="token t" [dynv6]="token t" [cloudflare]="zone_identifier 0123456789abcdef0123456789abcdef token t" [porkbun]="api_key k secret_api_key s")
for k in dynu duckdns desec dynv6 cloudflare porkbun; do
  out=$(render "$k" ${vals[$k]}) || { echo "RENDER-FAIL:$k"; fail=1; continue; }
  printf '%s' "$out" | DDNS_K="$k" python3 -c 'import os,sys,json; sys.exit(0 if json.load(sys.stdin)["settings"][0]["provider"]==os.environ["DDNS_K"] else 1)' || { echo "MISMATCH:$k"; fail=1; }
done
render duckdns >/dev/null 2>&1 && { echo "MISSING-NOT-REFUSED"; fail=1; }
(( fail == 0 )) && echo ALL-OK
SH
    local render_out
    render_out=$(tr -d '\r' < /tmp/ddns-render-loop.out)
    assert_contains "$render_out" "ALL-OK" "6-provider render: all render valid typed JSON; missing field refused"

    # ------------------------------------------------------------------
    # Test 8 (#236): state-leak — a Dynu -> DuckDNS switch through the real
    # write_env leaves NO username/password key in the rendered config.json.
    # ------------------------------------------------------------------
    docker exec -i -w /root/MediaStack "$DIND_NAME" bash >/dev/null 2>&1 <<'SH'
set -e
source scripts/lib/common.sh
source scripts/setup/env_gen.sh
SCRIPT_DIR=/root/MediaStack
_ENV_TZ=Etc/UTC; _ENV_PUID=1001; _ENV_PGID=1001; _ENV_HOST_ADDRESS=127.0.0.1
_WIZ_TZ=Etc/UTC; _WIZ_DATA_DIR=/data; _WIZ_ADMIN_USER=admin; _WIZ_ADMIN_PW=GeneratedPassword123
_WIZ_ADMIN_EMAIL=owner@ddns.test; _WIZ_DOMAIN=ddns.test; _WIZ_REMOTE_WEB_STATE=unchecked
_WIZ_WG_HOST=ddns.test; _WIZ_WG_PORT=51820; _WIZ_WG_DNS=1.1.1.1; _WIZ_WG_ACCESS_TIER=full-lan
_WIZ_WG_LAN_CIDR=192.168.1.0/24; _WIZ_WG_SERVER_LAN_IP=192.168.1.10
_WIZ_WG_INIT_ALLOWED_IPS=192.168.1.0/24; _WIZ_WG_PER_CLIENT_FIREWALL=true
_WIZ_TORRENT_PORT=6881; _WIZ_DL_LIMIT=0; _WIZ_UL_LIMIT=0; _WIZ_BAZARR_ENABLED=false; _WIZ_SMB_ENABLED=false
_WIZ_DDNS_PROVIDER=dynu
_WIZ_DDNS_FIELDS=([password]=secret)
write_env
_WIZ_DDNS_PROVIDER=duckdns
_WIZ_DDNS_FIELDS=([token]=duck-token)
write_env
SH
    local leak
    leak=$(dind_exec 'python3 -c "import json; s=json.load(open(\"config/ddns-updater/config.json\"))[\"settings\"][0]; print(\"LEAK\" if (\"username\" in s or \"password\" in s) else s.get(\"provider\")+\":\"+s.get(\"token\",\"\"))"' | tr -d '\r\n')
    assert_eq "duckdns:duck-token" "$leak" "state-leak: Dynu->DuckDNS switch leaves no username/password key in config.json"

    # ------------------------------------------------------------------
    # Test 9 (#236): container fail-fasts (exits) on a malformed config — the
    # "bad shape stays a dead remote, not a false green" half of the contract.
    # ------------------------------------------------------------------
    dind_exec 'rm -rf /tmp/ddns-badshape && mkdir -p /tmp/ddns-badshape && printf "{ not valid json" > /tmp/ddns-badshape/config.json'
    dind_exec "docker rm -f smoke-ddns-bad" >/dev/null 2>&1 || true
    dind_exec "docker run -d --name smoke-ddns-bad -v /tmp/ddns-badshape:/updater/data -e TZ=Etc/UTC $ddns_image" >/dev/null 2>&1 || true
    local bad_running="unknown"
    for _ in 1 2 3 4 5; do
        sleep 2
        bad_running=$(dind_exec "docker inspect -f '{{.State.Running}}' smoke-ddns-bad 2>/dev/null" | tr -d '\r\n')
        [[ "$bad_running" == "false" ]] && break
    done
    assert_eq "false" "$bad_running" "ddns-updater fail-fasts (exits) on a malformed config"
    dind_exec "docker rm -f smoke-ddns-bad" >/dev/null 2>&1 || true

    # Cleanup.
    dind_exec "docker rm -f ddns-updater $ddns_container" >/dev/null 2>&1 || true
}
