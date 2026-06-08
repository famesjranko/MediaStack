# tests/scenarios/existing-install-nuke.sh — existing-install wipe gate.

existing_nuke_reset_config_marker() {
    dind_exec "python3 - <<'PY'
from pathlib import Path
p = Path('config.yml')
text = p.read_text()
text = text.replace('wizard_completed: true', 'wizard_completed: false')
p.write_text(text)
PY"
}

existing_nuke_set_stage1_complete() {
    dind_exec "python3 - <<'PY'
from pathlib import Path
p = Path('.env')
lines = p.read_text().splitlines()
out = []
done = False
for line in lines:
    if line.startswith('STAGE_1_COMPLETE='):
        out.append('STAGE_1_COMPLETE=1')
        done = True
    else:
        out.append(line)
if not done:
    out.append('STAGE_1_COMPLETE=1')
p.write_text('\\n'.join(out) + '\\n')
PY"
}

run_scenario() {
    dind_exec "docker compose --profile proxy --profile remote --profile subtitles --profile autoheal down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/jellyfin config/sonarr config/radarr config/jackett config/qbittorrent config/jellyseerr config/homepage config/portainer config/npm config/ddns-updater config/bazarr config/uptime-kuma config/beszel docker-compose.override.yml docker-compose.acme-test.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    dind_exec "touch /tmp/ms-data/media/tv/.phase7-sentinel"
    existing_nuke_reset_config_marker
    dind_exec "rm -f /tmp/existing-install-nuke-docker.log"

    dind_exec "cp .env.example .env && mkdir -p config/ddns-updater && printf '{}' > config/ddns-updater/config.json"
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set NPM_ADMIN_EMAIL owner@nuke.test
    env_set JELLYFIN_ADMIN_PASSWORD NukeDemoPassword123
    env_set DOMAIN nuke.test
    env_set REMOTE_WEB_STATE skipped
    env_set WG_INIT_PASSWORD "'nukewireguardpassword'"
    env_set BAZARR_ENABLED true
    env_set AUTOHEAL_ENABLED true
    existing_nuke_set_stage1_complete

    local log_path=/tmp/existing-install-nuke.out
    if dind_exec "printf '2\nDESTROY\n' | DEMO=1 bash -lc '
set -euo pipefail
source setup.sh
check_not_root() { :; }
check_debian() { :; }
check_disk_floor() { :; }
check_internet_reachability() { :; }
check_ram_warn() { :; }
prompt_sudo_cache() { :; }
stash_gpu_type() { GPU_TYPE=none; }
install_base_packages() { :; }
install_docker() { :; }
check_docker() { :; }
check_compose() { :; }
cleanup_post_reboot() { :; }
detect_host_memory() { :; }
setup_hardening() { :; }
setup_ufw_service_ports() { :; }
setup_samba() { :; }
print_access_info() { :; }
docker() {
    printf \"%s\n\" \"\$*\" >> /tmp/existing-install-nuke-docker.log
    return 0
}
_stage1_install() {
    WIZARD_RAN_INSTALL=true
    _wizard_apply_settings 1080p balanced english 0
    sed -i \"s/^STAGE_1_COMPLETE=.*/STAGE_1_COMPLETE=1/\" \"\$SCRIPT_DIR/.env\"
    log_ok \"Stage 1 complete (STAGE_1_COMPLETE=1)\"
}
main --full
'" >"$log_path" 2>&1; then
        pass "existing install nuke: setup control flow exits 0 after wipe"
    else
        fail "existing install nuke: setup control flow exits 0 after wipe"
        tail -100 "$log_path"
        return 1
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"
    assert_contains "$log_plain" "Wipe everything and start fresh" "existing install nuke: wipe menu option was presented"
    assert_contains "$log_plain" "This will DELETE:" "existing install nuke: destructive preview printed"
    assert_contains "$log_plain" "This will PRESERVE:" "existing install nuke: preserve preview printed"
    assert_contains "$log_plain" "Existing install removed. Continuing with fresh setup." "existing install nuke: DESTROY accepted"
    assert_contains "$log_plain" "compose --profile '*' down -v" "existing install nuke: destructive preview uses all-profile wildcard"

    local docker_log
    docker_log="$(dind_exec "cat /tmp/existing-install-nuke-docker.log 2>/dev/null || true" | tr -d '\r')"
    assert_contains "$docker_log" "compose --profile * down -v" "existing install nuke: remote/proxy/subtitles fixture invokes all-profile compose down"

    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "existing install nuke: reinstall completes with STAGE_1_COMPLETE=1"
    if dind_exec "test -s .env"; then
        pass "existing install nuke: .env regenerated"
    else
        fail "existing install nuke: .env regenerated"
    fi
    if dind_exec "test -f /tmp/ms-data/media/tv/.phase7-sentinel"; then
        pass "existing install nuke: data bind-mount sentinel survives"
    else
        fail "existing install nuke: data bind-mount sentinel survives"
    fi
}
