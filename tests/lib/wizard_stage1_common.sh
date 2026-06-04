# Common fixture helpers for Stage 1 PTY wizard scenarios.

wizard_stage1_write_base_fixture() {
    local fixture_path="$1"
    local api_key="${2:-wizard-key}"

    dind_exec "cat >$fixture_path <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env
mkdir -p config/ddns-updater

source ./setup.sh

sudo() { \"\$@\"; }
cat > scripts/configure.sh <<CONFIGURE
#!/usr/bin/env bash
sed -i 's/^JELLYFIN_API_KEY=.*/JELLYFIN_API_KEY=$api_key/' .env
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
# never fires — otherwise these UI-flow scenarios are non-deterministic, passing
# only on hosts/runners with >30GB free on the data path (they hung on GitHub's
# smaller-disk runners). >200G also skips the min_free auto-scale branch.
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted on\n/dev/ms-test 500G 50G 450G 10%% /\n'; }
net_detect_public_ip() { _NET_PUBLIC_IP=203.0.113.10; return 0; }
net_run_speedtest() { _NET_DL_MBPS=120; _NET_UL_MBPS=40; return 0; }
net_check_port_status() { _NET_PORT_STATUS[\"\$1\"]=closed; }
net_is_port_locally_bound() { return 1; }
validate_smb_port() { return 0; }
findmnt() { return 1; }
storage_ensure_nfs_common() { return 0; }
storage_mount_nfs() { return 0; }
storage_preflight_nas() { return 0; }
stop_existing_stack() { log_info \"stub stop_existing_stack\"; }
create_data_dirs() { mkdir -p \"\${DATA_DIR:-/tmp/ms-wizard-data}\"; log_info \"stub create_data_dirs\"; }
create_config_dirs() {
    mkdir -p config/ddns-updater
    if declare -F clear_qbittorrent_managed_seed_for_manual_storage >/dev/null; then
        clear_qbittorrent_managed_seed_for_manual_storage
    fi
    log_info \"stub create_config_dirs\"
}
generate_override() { printf 'services: {}\\n' > docker-compose.override.yml; log_info \"stub generate_override \$1\"; }
storage_install_watchdog() { log_info \"stub storage_install_watchdog\"; }
pull_images() { log_info \"stub pull_images\"; }
start_stack() { log_info \"stub start_stack\"; }
wait_all_healthy() { log_info \"stub wait_all_healthy\"; }
print_access_info() { log_info \"stub print_access_info\"; }
BASH
chmod +x $fixture_path"
}
wizard_stage1_append_runner() {
    local fixture_path="$1"
    dind_exec "cat >>$fixture_path <<'BASH'

detect_env
GPU_TYPE=none
run_stage1
BASH"
}

# Shared step-builder (prompt regexes live in tests/lib/wizard_prompts.json). The stage-1
# scenarios call wizard_stage1_steps; the implementation is wizard_build_steps.
source tests/lib/wizard_steps_common.sh
wizard_stage1_steps() { wizard_build_steps "$@"; }

wizard_stage1_run_pty() {
    local label="$1"
    local fixture_path="$2"
    local steps_path="$3"
    local plain_log="$4"

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture_path \
        --steps $steps_path \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "$label: PTY flow exits 0"
    else
        fail "$label: PTY flow exits 0"
        dind_exec "tail -140 $plain_log 2>/dev/null || true"
        return 1
    fi
}
