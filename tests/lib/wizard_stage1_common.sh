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

# Shared executor stubs (run-real-in-sandbox philosophy) live in one place —
# tests/lib/wizard_stub_common.sh. Sourced here at fixture-run time, AFTER
# setup.sh, so the stubs shadow the real functions.
source tests/lib/wizard_stub_common.sh
ms_stub_core $api_key
ms_stub_common_env
ms_stub_service_lifecycle
ms_stub_stage1_storage
ms_stub_stage1_install
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
