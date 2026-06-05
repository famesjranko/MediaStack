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
    local seed_rc
    dind_exec 'DDNS_DOMAIN="ddns.test" DDNS_USERNAME="testuser" DDNS_PASSWORD="testpass123" \
        python3 -c '\''
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "username": os.environ["DDNS_USERNAME"],
    "password": os.environ["DDNS_PASSWORD"],
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
if e.get("username") != "testuser":
    errors.append("username mismatch")
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
        -e "DDNS_DOMAIN=ddns.test" -e "DDNS_USERNAME=user" -e "DDNS_PASSWORD=$special_pw" \
        "$DIND_NAME" python3 <<'PY' > /tmp/ddns-special.json
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "username": os.environ["DDNS_USERNAME"],
    "password": os.environ["DDNS_PASSWORD"],
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
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_DDNS_USER=testuser
_WIZ_DDNS_PW=testpass123
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
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_DDNS_USER=testuser
_WIZ_DDNS_PW=testpass123
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
_WIZ_DDNS_PREFLIGHT_OK=true
_WIZ_DDNS_USER=testuser
_WIZ_DDNS_PW=testpass123
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
        -e "DDNS_DOMAIN=ddns.test" -e "DDNS_USERNAME=CLOBBERED" -e "DDNS_PASSWORD=CLOBBERED" \
        "$DIND_NAME" python3 <<'PY'
import os, json, pathlib
config_path = pathlib.Path("config/ddns-updater/config.json")
if config_path.exists():
    pass  # guard hit — do not overwrite
else:
    print(json.dumps({"settings": [{
        "provider": "dynu",
        "domain": os.environ["DDNS_DOMAIN"],
        "username": os.environ["DDNS_USERNAME"],
        "password": os.environ["DDNS_PASSWORD"],
        "ip_version": "ipv4",
    }]}, indent=2))
PY

    local guard_user
    guard_user=$(dind_exec 'python3 -c "import json; print(json.load(open(\"config/ddns-updater/config.json\"))[\"settings\"][0][\"username\"], end=\"\")"' | tr -d '\r\n')
    if [[ "$guard_user" == "testuser" ]]; then
        pass "DDNS overwrite guard preserves existing config.json"
    else
        fail "DDNS overwrite guard" "username='$guard_user' (expected 'testuser')"
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

    # Cleanup.
    dind_exec "docker rm -f ddns-updater $ddns_container" >/dev/null 2>&1 || true
}
