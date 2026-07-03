# tests/scenarios/demo-lan.sh — DEMO=1 Stage-1/LAN-safe setup contract.

demo_lan_reset_config_marker() {
    dind_exec "python3 - <<'PY'
from pathlib import Path
p = Path('config.yml')
# config.yml is gitignored (seeded from its template on install); dind_copy_repo
# does not carry it in on a clean checkout, so seed it here before resetting.
if not p.exists():
    p.write_text(Path('config/examples/config.yml').read_text())
text = p.read_text()
text = text.replace('wizard_completed: true', 'wizard_completed: false')
p.write_text(text)
PY"
}

run_scenario() {
    dind_exec "docker compose --profile proxy --profile remote --profile subtitles down -v --remove-orphans 2>/dev/null || true"
    dind_exec "rm -rf config/jellyfin config/sonarr config/radarr config/jackett config/qbittorrent config/seerr config/homepage config/portainer config/npm config/ddns-updater config/bazarr config/uptime-kuma config/beszel docker-compose.override.yml docker-compose.acme-test.yml"
    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    demo_lan_reset_config_marker

    dind_exec "cp .env.example .env"
    env_set DATA_DIR /tmp/ms-data
    env_set NPM_ADMIN_EMAIL owner@demo.test
    env_set JELLYFIN_ADMIN_PASSWORD changeme
    env_set TORRENT_PORT 6999
    env_set BAZARR_ENABLED true
    env_set SMB_ENABLED true
    env_set WG_INIT_PASSWORD "''"
    env_set REMOTE_WEB_STATE ""

    local log_path=/tmp/demo-lan.out
    if dind_exec "DEMO=1 bash -lc '
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
_stage1_install() {
    WIZARD_RAN_INSTALL=true
    _wizard_apply_settings 1080p balanced english 0
    sed -i \"s/^STAGE_1_COMPLETE=.*/STAGE_1_COMPLETE=1/\" \"\$SCRIPT_DIR/.env\"
    log_ok \"Stage 1 complete (STAGE_1_COMPLETE=1)\"
}
main --full
'" >"$log_path" 2>&1; then
        pass "demo lan: DEMO=1 setup control flow exits 0"
    else
        fail "demo lan: DEMO=1 setup control flow exits 0"
        tail -80 "$log_path"
        return 1
    fi

    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "demo lan: STAGE_1_COMPLETE=1"
    assert_eq "owner@demo.test" "$(env_get NPM_ADMIN_EMAIL)" "demo lan: pre-seeded email preserved"
    assert_eq "example.com" "$(env_get DOMAIN)" "demo lan: Stage 1 stays LAN-only"
    assert_eq "6999" "$(env_get TORRENT_PORT)" "demo lan: pre-seeded torrent port preserved"
    assert_eq "51820" "$(env_get WG_PORT)" "demo lan: default WireGuard port retained"
    assert_eq "true" "$(env_get BAZARR_ENABLED)" "demo lan: pre-seeded Bazarr enabled preserved"
    assert_eq "true" "$(env_get SMB_ENABLED)" "demo lan: pre-seeded SMB enabled preserved"
    assert_eq "" "$(env_get WG_INIT_PASSWORD)" "demo lan: WireGuard init password remains empty"

    local remote_state
    remote_state=$(env_get REMOTE_WEB_STATE)
    if [[ "$remote_state" != "ready" ]]; then
        pass "demo lan: REMOTE_WEB_STATE is not ready"
    else
        fail "demo lan: REMOTE_WEB_STATE is not ready" "got ready"
    fi

    if dind_exec "docker compose --profile proxy ps -q npm 2>/dev/null | grep -q ."; then
        fail "demo lan: proxy services are not published" "npm container is running"
    else
        pass "demo lan: proxy services are not published"
    fi
}
