# tests/scenarios/wizard-ui-stage1-local.sh — Stage 1 local-storage wizard UX.
#
# Drives real Stage 1 prompts through a PTY while stubbing slow/dangerous install
# operations. This validates interactive UI flow and generated state without
# pulling images or starting the stack.

# Self-contained scenario (invokes wizard_pty.py directly, no wizard_stage1_run_pty): pull in
# only the side-effect-free shared step-builder. Sourcing wizard_stage1_common.sh would re-source
# setup.sh (set -euo pipefail) into this shell, which this scenario deliberately avoids.
source tests/lib/wizard_steps_common.sh

wizard_ui_stage1_local_write_fixture() {
    dind_exec "cat >/tmp/wizard-stage1-local.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env
mkdir -p /tmp/ms-wizard-local-data config/ddns-updater

source ./setup.sh

sudo() { \"\$@\"; }
cat > scripts/configure.sh <<'CONFIGURE'
#!/usr/bin/env bash
sed -i 's/^JELLYFIN_API_KEY=.*/JELLYFIN_API_KEY=wizard-local-key/' .env
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
# Report ample free space so validate_data_dir's <30GB \"Continue anyway?\" prompt
# never fires (these scenarios otherwise depend on the host having >30GB free).
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted on\n/dev/ms-test 500G 50G 450G 10%% /\n'; }
net_detect_public_ip() { _NET_PUBLIC_IP=203.0.113.10; return 0; }
net_run_speedtest() { _NET_DL_MBPS=120; _NET_UL_MBPS=40; return 0; }
net_check_port_status() { _NET_PORT_STATUS[\"\$1\"]=closed; }
net_is_port_locally_bound() { return 1; }
validate_smb_port() { return 0; }
stop_existing_stack() { log_info \"stub stop_existing_stack\"; }
create_data_dirs() { mkdir -p \"\${DATA_DIR:-/tmp/ms-wizard-local-data}\"; log_info \"stub create_data_dirs\"; }
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
chmod +x /tmp/wizard-stage1-local.sh"
}

wizard_ui_stage1_local_write_steps() {
    wizard_build_steps "/tmp/wizard-stage1-local.steps.json" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@lan.test \
        stage1_admin_password MaskMe-Secret-Pw123 \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-local-data \
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
}

run_scenario() {
    local plain_log="/tmp/wizard-stage1-local.plain.log"
    wizard_ui_stage1_local_write_fixture
    wizard_ui_stage1_local_write_steps

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command /tmp/wizard-stage1-local.sh \
        --steps /tmp/wizard-stage1-local.steps.json \
        --raw-log /tmp/wizard-stage1-local.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui stage1 local: PTY flow exits 0"
    else
        fail "wizard-ui stage1 local: PTY flow exits 0"
        dind_exec "tail -100 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Where should MediaStack store media and downloads?" "wizard-ui stage1 local: storage menu shown"
    assert_contains "$transcript" "Local disk (/data)" "wizard-ui stage1 local: local storage option shown"
    assert_contains "$transcript" "Stage 1: Install Plan" "wizard-ui stage1 local: confirm plan shown"
    assert_contains "$transcript" "local at /tmp/ms-wizard-local-data" "wizard-ui stage1 local: plan summarizes local storage"

    assert_eq "local" "$(env_get STORAGE_MODE)" "wizard-ui stage1 local: STORAGE_MODE=local"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 local: app wiring managed"
    assert_eq "/tmp/ms-wizard-local-data" "$(env_get DATA_DIR)" "wizard-ui stage1 local: DATA_DIR from prompt"
    assert_eq "" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 local: NFS host blank"
    assert_eq "/tmp/ms-wizard-local-data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 local: local sentinel default"
    assert_eq "false" "$(env_get BAZARR_ENABLED)" "wizard-ui stage1 local: Bazarr disabled by default"
    assert_eq "false" "$(env_get SMB_ENABLED)" "wizard-ui stage1 local: SMB disabled by prompt"

    # Issue #6: the admin password is collected via the masked ui_password_validated.
    # Positive control — the typed value was accepted and persisted:
    assert_eq "MaskMe-Secret-Pw123" "$(env_get JELLYFIN_ADMIN_PASSWORD)" "wizard-ui stage1 local: typed admin password persisted"
    # Masking proof — the typed value must NOT be echoed into the terminal transcript
    # (it would appear here under the old read -rp; read -rsp suppresses it).
    case "$transcript" in
        *MaskMe-Secret-Pw123*) fail "AUDIT: stage1 admin password is masked (not echoed to terminal scrollback)" "typed password leaked into transcript" ;;
        *)                     pass "AUDIT: stage1 admin password is masked (not echoed to terminal scrollback)" ;;
    esac
}
