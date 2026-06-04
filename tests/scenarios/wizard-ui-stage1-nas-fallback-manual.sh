# tests/scenarios/wizard-ui-stage1-nas-fallback-manual.sh — NAS failure to manual app wiring with NAS guard.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-nas-fallback-manual.sh"
    local steps="/tmp/wizard-stage1-nas-fallback-manual.steps.json"
    local plain_log="/tmp/wizard-stage1-nas-fallback-manual.plain.log"

    dind_exec "mkdir -p config/qbittorrent/qBittorrent && cat >config/qbittorrent/qBittorrent/qBittorrent.conf <<'CONF'
[Preferences]
Downloads\\SavePath=/data/torrents
Downloads\\TempPath=/data/torrents/incomplete
Downloads\\TempPathEnabled=true
WebUI\\Port=8080
CONF
cat >config/qbittorrent/qBittorrent/categories.json <<'JSON'
{\"tv-sonarr\":{\"savePath\":\"/data/torrents/tv\"},\"radarr\":{\"savePath\":\"/data/torrents/movies\"}}
JSON"

    wizard_stage1_write_base_fixture "$fixture" "wizard-nas-manual-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-nas-manual
storage_mount_nfs() {
    local attempts=0
    [[ -f /tmp/wizard-nas-manual-mount-attempts ]] && attempts=\$(cat /tmp/wizard-nas-manual-mount-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' "\$attempts" > /tmp/wizard-nas-manual-mount-attempts
    (( attempts >= 2 ))
}
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@fallback-manual.test \
        stage1_admin_password ENTER \
        stage1_storage_location 2 \
        stage1_nas_local_mountpoint /tmp/ms-wizard-nas-manual \
        stage1_nas_host 127.0.0.1 \
        stage1_nas_nfs_export /exports/bad \
        stage1_nas_nfs_options ENTER \
        stage1_nas_sentinel ENTER \
        stage1_nas_mount_failed 4 \
        stage1_nas_manual_guard y \
        stage1_nas_share_empty NONE \
        stage1_bazarr ENTER \
        stage1_smb ENTER \
        stage1_quality 1 \
        stage1_subtitle_langs ENTER \
        stage1_indexers ENTER \
        stage1_image_channel 1 \
        stage1_qbt_download ENTER \
        stage1_qbt_upload ENTER \
        stage1_qbt_port ENTER \
        stage1_proceed 1

    wizard_stage1_run_pty "wizard-ui stage1 NAS fallback manual" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Advanced manual storage" "wizard-ui stage1 NAS fallback manual: manual fallback option shown"
    assert_contains "$transcript" "Still enable NAS mount guard/watchdog for this manual storage?" "wizard-ui stage1 NAS fallback manual: NAS guard prompt shown"
    assert_contains "$transcript" "nas at /tmp/ms-wizard-nas-manual (manual app wiring)" "wizard-ui stage1 NAS fallback manual: plan summarizes NAS-protected manual storage"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-manual-mount-attempts")" "wizard-ui stage1 NAS fallback manual: mount retried after choosing manual guard"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS fallback manual: STORAGE_MODE=nas"
    assert_eq "manual" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS fallback manual: app wiring manual"
    assert_eq "/tmp/ms-wizard-nas-manual" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS fallback manual: DATA_DIR preserved for manual mode"
    assert_eq "nfs" "$(env_get STORAGE_PROTOCOL)" "wizard-ui stage1 NAS fallback manual: protocol preserved"
    assert_eq "127.0.0.1" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS fallback manual: NFS host preserved"
    assert_eq "/exports/bad" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS fallback manual: NFS export preserved"
    assert_eq "/tmp/ms-wizard-nas-manual/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS fallback manual: sentinel preserved"
    assert_eq "" "$(env_get UNPACKERR_TORRENT_PATHS)" "wizard-ui stage1 NAS fallback manual: Unpackerr managed path cleared"

    if dind_exec "bash -lc '! grep -q \"/data/torrents\" config/qbittorrent/qBittorrent/qBittorrent.conf config/qbittorrent/qBittorrent/categories.json'"; then
        pass "wizard-ui stage1 NAS fallback manual: qBittorrent seed does not advertise managed torrent paths"
    else
        fail "wizard-ui stage1 NAS fallback manual: qBittorrent seed does not advertise managed torrent paths"
    fi

    if dind_exec "python3 - <<'PY'
import json
from pathlib import Path
cats = json.loads(Path('config/qbittorrent/qBittorrent/categories.json').read_text())
raise SystemExit(0 if cats == {} else 1)
PY"; then
        pass "wizard-ui stage1 NAS fallback manual: qBittorrent seed categories are empty"
    else
        fail "wizard-ui stage1 NAS fallback manual: qBittorrent seed categories are empty"
    fi

    if dind_exec "docker compose config | python3 -c '
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
env = cfg[\"services\"][\"unpackerr\"].get(\"environment\", {})
if isinstance(env, list):
    env = dict(item.split(\"=\", 1) for item in env)
want = {\"UN_SONARR_0_PATHS_0\": \"\", \"UN_RADARR_0_PATHS_0\": \"\"}
raise SystemExit(0 if all(env.get(k, \"\") == v for k, v in want.items()) else 1)
'"; then
        pass "wizard-ui stage1 NAS fallback manual: compose clears Unpackerr watched paths"
    else
        fail "wizard-ui stage1 NAS fallback manual: compose clears Unpackerr watched paths"
    fi

    env_set UNPACKERR_TORRENT_PATHS "/mnt/custom downloads/\$USER/torrents"
    if dind_exec "docker compose config | python3 -c '
import sys, yaml
cfg = yaml.safe_load(sys.stdin)
env = cfg[\"services\"][\"unpackerr\"].get(\"environment\", {})
if isinstance(env, list):
    env = dict(item.split(\"=\", 1) for item in env)
want = \"/mnt/custom downloads/\$\$USER/torrents\"
raise SystemExit(0 if env.get(\"UN_SONARR_0_PATHS_0\") == want and env.get(\"UN_RADARR_0_PATHS_0\") == want else 1)
'"; then
        pass "wizard-ui stage1 NAS fallback manual: compose preserves custom Unpackerr path"
    else
        fail "wizard-ui stage1 NAS fallback manual: compose preserves custom Unpackerr path"
    fi
}
