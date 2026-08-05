# Common fixture helpers for Stage 3 (hardware transcoding) PTY wizard scenarios.
#
# Mirrors the stage1/stage2 helpers. Writes a fixture that sources setup.sh,
# seeds a post-Stage-1 .env baseline, and stubs the entire GPU machinery —
# vendor driver installs (Intel/AMD/NVIDIA apt + .run), the NVIDIA container
# toolkit, nvidia-patch, capability probes, the Jellyfin encoder config/verify,
# the runtime override, and the post-reboot helpers (incl. `reboot` itself, so a
# scenario can never actually reboot the test host). Defaults drive the simplest
# success path (driver installs, no reboot, verification passes). Scenarios
# override individual stubs to exercise reboot, existing-driver, unlock, and
# fallback branches. The runner pins GPU_TYPE (none|intel|amd|nvidia) and calls
# run_stage3 directly so the reboot prompt is interactive (the wizard's
# run_hardware_transcoding_addon defers that prompt; the prompt logic is the same).

wizard_stage3_write_base_fixture() {
    local fixture_path="$1"

    dind_exec "cat >$fixture_path <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
mkdir -p config/ddns-updater config/state /tmp/ms-wizard-gpu
sed -i \
  -e 's#^TZ=.*#TZ=Etc/UTC#' \
  -e 's#^DATA_DIR=.*#DATA_DIR=/tmp/ms-wizard-gpu#' \
  -e 's#^HOST_ADDRESS=.*#HOST_ADDRESS=192.168.1.50#' \
  -e 's#^JELLYFIN_ADMIN_USER=.*#JELLYFIN_ADMIN_USER=admin#' \
  -e 's#^JELLYFIN_ADMIN_PASSWORD=.*#JELLYFIN_ADMIN_PASSWORD=WizardAdminPass123#' \
  -e 's#^NPM_ADMIN_EMAIL=.*#NPM_ADMIN_EMAIL=owner@gpu.test#' \
  -e 's#^STAGE_1_COMPLETE=.*#STAGE_1_COMPLETE=1#' \
  -e 's#^JELLYFIN_GPU=.*#JELLYFIN_GPU=none#' \
  .env

source ./setup.sh

# Shared external-command stubs live in one place — tests/lib/wizard-stub-common.sh.
# Stage 3 shares only the core set (sudo/curl/docker/openssl + a no-op configure.sh);
# the GPU machinery below stays stage-specific.
source tests/lib/wizard-stub-common.sh
ms_stub_core
reboot() { log_info \"stub reboot (suppressed)\"; }
detect_host_memory() { HOST_MEMORY_MB=16000; }
generate_override() { printf 'services: {}\\n' > docker-compose.override.yml; }
print_access_info() { log_info \"stub print_access_info\"; }
print_final_summary() { log_info \"stub print_final_summary\"; }
# GPU driver installs — default: succeed, no reboot needed.
install_intel_drivers() { return 0; }
install_amd_drivers() { return 0; }
install_nvidia_drivers_apt() { NEEDS_REBOOT=false; return 0; }
install_nvidia_drivers() { NEEDS_REBOOT=false; return 0; }
apply_nvidia_patch() { return 0; }
prepare_nvidia_debian_to_unlock() { NEEDS_REBOOT=false; return 0; }
_install_nvidia_container_toolkit() { return 0; }
nvidia_driver_source() { printf 'none\\n'; }
nvidia_driver_check_secure_boot() { printf 'disabled\\n'; }
nvidia_driver_nouveau_is_active() { return 1; }
verify_gpu_usable() { return 0; }
# Capability probe + Jellyfin encoder verification — default: pass.
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_wait_for_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 0; }
_stage3_disable_jellyfin_hardware() { return 0; }
_stage3_encoder_disabled() { return 0; }
_stage3_apply_runtime_override() { return 0; }
# Post-reboot helpers — no systemd/banner side effects in tests.
schedule_post_reboot() { :; }
install_post_reboot_banner() { :; }
print_reboot_notice() { :; }
BASH
chmod +x $fixture_path"
}

# Append the runner. Pins GPU_TYPE so run_stage3 takes the chosen vendor branch.
wizard_stage3_append_runner() {
    local fixture_path="$1"
    local gpu="${2:-nvidia}"
    dind_exec "cat >>$fixture_path <<RUNNER

detect_env
GPU_TYPE=$gpu
run_stage3
RUNNER"
}

# Shared step-builder (prompt regexes live in tests/lib/wizard_prompts.json). The stage-3
# scenarios call wizard_stage3_steps; the implementation is wizard_build_steps.
source tests/lib/wizard-steps-common.sh
wizard_stage3_steps() { wizard_build_steps "$@"; }

wizard_stage3_run_pty() {
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
