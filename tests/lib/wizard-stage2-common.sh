# Common fixture helpers for Stage 2 (remote access) PTY wizard scenarios.
#
# Mirrors wizard-stage1-common.sh. Writes a fixture that sources setup.sh,
# seeds a post-Stage-1 .env baseline (STAGE_1_COMPLETE=1 + admin/storage values
# so _stage2_seed_wizard_defaults has coherent inputs), and stubs every slow,
# networked, or dangerous operation Stage 2 would otherwise perform: image
# pulls, stack start, NPM/Let's-Encrypt cert issuance, and the DNS / Dynu /
# router-port probes. Scenarios override individual stubs (net_dns_classify,
# ddns_verify_via_container, stage2_check_http_ports, stage2_le_classify, ...) to
# exercise a specific branch, then append the runner and drive via wizard_pty.

wizard_stage2_write_base_fixture() {
    local fixture_path="$1"

    dind_exec "cat >$fixture_path <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
mkdir -p config/ddns-updater config/npm/data/logs config/state /tmp/ms-wizard-remote
sed -i \
  -e 's#^TZ=.*#TZ=Etc/UTC#' \
  -e 's#^DATA_DIR=.*#DATA_DIR=/tmp/ms-wizard-remote#' \
  -e 's#^HOST_ADDRESS=.*#HOST_ADDRESS=192.168.1.50#' \
  -e 's#^JELLYFIN_ADMIN_USER=.*#JELLYFIN_ADMIN_USER=admin#' \
  -e 's#^JELLYFIN_ADMIN_PASSWORD=.*#JELLYFIN_ADMIN_PASSWORD=WizardAdminPass123#' \
  -e 's#^NPM_ADMIN_EMAIL=.*#NPM_ADMIN_EMAIL=owner@remote.test#' \
  -e 's#^STAGE_1_COMPLETE=.*#STAGE_1_COMPLETE=1#' \
  .env

source ./setup.sh

# Shared executor stubs live in one place — tests/lib/wizard-stub-common.sh.
# Sourced AFTER setup.sh so the stubs shadow the real functions; Stage 2 keeps a
# plain no-op configure.sh (no api key) and adds the remote-access services to the
# compose-config stub.
source tests/lib/wizard-stub-common.sh
ms_stub_core
ms_stub_common_env
ms_stub_service_lifecycle
_stub_compose_service_list() { printf '%s\n' jellyfin sonarr radarr jackett qbittorrent seerr homepage portainer unpackerr flaresolverr uptime-kuma npm wireguard ddns-updater; }
_stub_compose_image_list() { printf '%s\n' i1 i2 i3 i4 i5 i6 i7 i8 i9 i10 i11 i12 i13 i14; }
# Stage 2 networked/heavy operations — overridable per scenario.
net_dns_classify() { printf 'ok\n'; }
stage2_check_http_ports() { printf 'ok\n'; }
ddns_verify_via_container() { return 0; }
net_detect_lan_cidr() { printf '192.168.1.0/24\n'; }
stage2_le_classify() { STAGE2_LE_CLASSIFICATION=ready; STAGE2_LE_READY_HOSTS=\"jellyfin.\$1, seerr.\$1\"; printf 'ready\\n'; return 0; }
BASH
chmod +x $fixture_path"
}

wizard_stage2_append_runner() {
    local fixture_path="$1"
    dind_exec "cat >>$fixture_path <<'BASH'

detect_env
_wizard_load_existing_env
run_stage2
BASH"
}

# Shared step-builder (prompt regexes live in tests/lib/wizard_prompts.json). The stage-2
# scenarios call wizard_stage2_steps; the implementation is wizard_build_steps.
source tests/lib/wizard-steps-common.sh
wizard_stage2_steps() { wizard_build_steps "$@"; }

wizard_stage2_run_pty() {
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
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi
}
