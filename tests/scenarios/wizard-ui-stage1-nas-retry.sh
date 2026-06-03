# tests/scenarios/wizard-ui-stage1-nas-retry.sh — Stage 1 NAS retry wizard UX.
#
# Simulates an NFS mount failure followed by "Retry with the same settings".
# The scenario runs real prompts through a PTY and asserts both transcript UX
# and generated storage state.

wizard_ui_stage1_nas_retry_write_fixture() {
    dind_exec "cat >/tmp/wizard-stage1-nas-retry.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env /tmp/wizard-nas-mount-attempts
mkdir -p /tmp/ms-wizard-nas-data config/ddns-updater

source ./setup.sh

sudo() { \"\$@\"; }
cat > scripts/configure.sh <<'CONFIGURE'
#!/usr/bin/env bash
sed -i 's/^JELLYFIN_API_KEY=.*/JELLYFIN_API_KEY=wizard-nas-key/' .env
exit 0
CONFIGURE
chmod +x scripts/configure.sh
curl() { return 0; }
docker() {
    if [[ \"\${1:-}\" == \"--version\" ]]; then
        echo \"Docker version 27.0.1, build wizard\"
        return 0
    fi
    if [[ \"\${1:-}\" == \"compose\" ]]; then
        case \" \$* \" in
            *\" config --services \"*)
                printf \"%s\\n\" jellyfin sonarr radarr jackett qbittorrent jellyseerr homepage portainer unpackerr flaresolverr uptime-kuma
                return 0
                ;;
            *\" config --images \"*)
                printf \"%s\\n\" image1 image2 image3 image4 image5 image6 image7 image8 image9 image10 image11
                return 0
                ;;
        esac
        return 0
    fi
    return 0
}
openssl() {
    if [[ \"\${1:-}\" == \"rand\" ]]; then
        echo GeneratedWizardPassword123
        return 0
    fi
    command openssl \"\$@\"
}
timedatectl() { echo Etc/UTC; }
free() { printf 'Mem: 16Gi 1Gi 15Gi 0Gi 0Gi 15Gi\n'; }
net_detect_public_ip() { _NET_PUBLIC_IP=203.0.113.10; return 0; }
net_run_speedtest() { _NET_DL_MBPS=120; _NET_UL_MBPS=40; return 0; }
net_check_port_status() { _NET_PORT_STATUS[\"\$1\"]=closed; }
net_is_port_locally_bound() { return 1; }
validate_smb_port() { return 0; }
findmnt() { return 1; }
storage_ensure_nfs_common() { return 0; }
storage_mount_nfs() {
    local attempts=0
    [[ -f /tmp/wizard-nas-mount-attempts ]] && attempts=\$(cat /tmp/wizard-nas-mount-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' \"\$attempts\" > /tmp/wizard-nas-mount-attempts
    (( attempts >= 2 ))
}
storage_preflight_nas() { return 0; }
stop_existing_stack() { log_info \"stub stop_existing_stack\"; }
create_data_dirs() { mkdir -p \"\${DATA_DIR:-/tmp/ms-wizard-nas-data}\"; log_info \"stub create_data_dirs\"; }
create_config_dirs() { mkdir -p config/ddns-updater; log_info \"stub create_config_dirs\"; }
generate_override() { printf 'services: {}\\n' > docker-compose.override.yml; log_info \"stub generate_override \$1\"; }
storage_install_watchdog() { log_info \"stub storage_install_watchdog\"; }
pull_images() { log_info \"stub pull_images\"; }
start_stack() { log_info \"stub start_stack\"; }
wait_all_healthy() { log_info \"stub wait_all_healthy\"; }
print_access_info() { log_info \"stub print_access_info\"; }

detect_env
GPU_TYPE=none
run_stage1
BASH
chmod +x /tmp/wizard-stage1-nas-retry.sh"
}

wizard_ui_stage1_nas_retry_write_steps() {
    dind_exec 'cat >/tmp/wizard-stage1-nas-retry.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@nas.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "2\n"},
  {"expect": "Local mountpoint for NAS storage"},
  {"send": "/tmp/ms-wizard-nas-data\n"},
  {"expect": "NAS host/IP"},
  {"send": "127.0.0.1\n"},
  {"expect": "NFS export path"},
  {"send": "/exports/mediastack\n"},
  {"expect": "NFS mount options"},
  {"send": "vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec\n"},
  {"expect": "NAS sentinel file"},
  {"send": "\n"},
  {"expect": "NAS mount failed\\. What should setup do\\?"},
  {"send": "2\n"},
  {"expect": "NAS share is empty and ready for MediaStack\\."},
  {"expect": "Enable automatic subtitle downloads with Bazarr\\?"},
  {"send": "\n"},
  {"expect": "Enable SMB file share for LAN file access\\?"},
  {"send": "\n"},
  {"expect": "Choose how much storage to spend per movie/show:"},
  {"send": "1\n"},
  {"expect": "Subtitle languages"},
  {"send": "\n"},
  {"expect": "Enable the example public-tracker indexer preset\\?"},
  {"send": "\n"},
  {"expect": "Choose how MediaStack should update container images:"},
  {"send": "1\n"},
  {"expect": "qBittorrent download limit"},
  {"send": "\n"},
  {"expect": "qBittorrent upload limit"},
  {"send": "\n"},
  {"expect": "qBittorrent peer port"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 1 installation\\?"},
  {"send": "1\n"}
]
JSON'
}

run_scenario() {
    local plain_log="/tmp/wizard-stage1-nas-retry.plain.log"
    wizard_ui_stage1_nas_retry_write_fixture
    wizard_ui_stage1_nas_retry_write_steps

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command /tmp/wizard-stage1-nas-retry.sh \
        --steps /tmp/wizard-stage1-nas-retry.steps.json \
        --raw-log /tmp/wizard-stage1-nas-retry.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui stage1 NAS retry: PTY flow exits 0"
    else
        fail "wizard-ui stage1 NAS retry: PTY flow exits 0"
        dind_exec "tail -120 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS mount failed. What should setup do?" "wizard-ui stage1 NAS retry: failure menu shown"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 NAS retry: edit option shown"
    assert_contains "$transcript" "Retry with the same settings" "wizard-ui stage1 NAS retry: retry option shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 NAS retry: local fallback shown"
    assert_contains "$transcript" "Advanced manual storage" "wizard-ui stage1 NAS retry: manual fallback shown"
    assert_contains "$transcript" "nas at /tmp/ms-wizard-nas-data" "wizard-ui stage1 NAS retry: plan summarizes NAS storage"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-mount-attempts")" "wizard-ui stage1 NAS retry: mount retried once"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS retry: STORAGE_MODE=nas"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS retry: app wiring managed"
    assert_eq "nfs" "$(env_get STORAGE_PROTOCOL)" "wizard-ui stage1 NAS retry: protocol nfs"
    assert_eq "/tmp/ms-wizard-nas-data" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS retry: DATA_DIR is NAS mountpoint"
    assert_eq "127.0.0.1" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS retry: NFS host preserved"
    assert_eq "/exports/mediastack" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS retry: NFS export preserved"
    assert_eq "/tmp/ms-wizard-nas-data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS retry: sentinel default preserved"
}
