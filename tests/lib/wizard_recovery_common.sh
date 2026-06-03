# Common fixture helpers for day-2 recovery-menu PTY scenarios.
#
# Seeds a completed install (STAGE_1_COMPLETE=1 + a ddns config file, which is
# one of the two evidences detect_existing_install looks for) so the re-run
# recovery menu appears, then stubs the destructive/heavy actions. The runner
# calls detect_existing_install — the real entry setup.sh uses on a re-run.

wizard_recovery_write_base_fixture() {
    local fixture_path="$1"

    dind_exec "cat >$fixture_path <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
mkdir -p config/ddns-updater /tmp/ms-wizard-recovery
printf '{}\\n' > config/ddns-updater/config.json
sed -i \
  -e 's#^TZ=.*#TZ=Etc/UTC#' \
  -e 's#^DATA_DIR=.*#DATA_DIR=/tmp/ms-wizard-recovery#' \
  -e 's#^JELLYFIN_ADMIN_USER=.*#JELLYFIN_ADMIN_USER=admin#' \
  -e 's#^JELLYFIN_ADMIN_PASSWORD=.*#JELLYFIN_ADMIN_PASSWORD=WizardAdminPass123#' \
  -e 's#^STAGE_1_COMPLETE=.*#STAGE_1_COMPLETE=1#' \
  -e 's#^JELLYFIN_GPU=.*#JELLYFIN_GPU=none#' \
  .env

source ./setup.sh

sudo() { \"\$@\"; }
docker() { return 0; }
storage_pause_watchdog_for_install() { return 0; }
run_remote_recovery() { log_info \"stub run_remote_recovery\"; }
run_transcoding_recovery() { log_info \"stub run_transcoding_recovery\"; }
BASH
chmod +x $fixture_path"
}

wizard_recovery_append_runner() {
    local fixture_path="$1"
    dind_exec "cat >>$fixture_path <<'BASH'

detect_existing_install
BASH"
}

wizard_recovery_run_pty() {
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
