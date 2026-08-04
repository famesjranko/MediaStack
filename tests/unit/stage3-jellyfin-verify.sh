#!/usr/bin/env bash
# tests/unit/stage3-jellyfin-verify.sh
#
# Contract tests for Stage 3 Jellyfin verification retry/skip/fallback paths.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-jellyfin-verify"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"

set +e
set +u

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

SCRIPT_DIR="$TMP_ROOT/transcode-retry"
mkdir -p "$SCRIPT_DIR"
gpu_env_calls=()
verify_attempts=0
runtime_calls=0
configure_calls=0
probe_calls=0
summary_calls=0
ui_choose() { printf '%s\n' "Retry verification"; }
ui_log() { :; }
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); }
_stage3_apply_runtime_override() {
    runtime_calls=$((runtime_calls + 1))
    return 0
}
stage3_probe_capabilities() {
    probe_calls=$((probe_calls + 1))
    return 0
}
_stage3_configure_jellyfin() {
    configure_calls=$((configure_calls + 1))
    return 0
}
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() {
    verify_attempts=$((verify_attempts + 1))
    [[ "$verify_attempts" -ge 2 ]]
}
print_final_summary() { summary_calls=$((summary_calls + 1)); }
if _stage3_configure_and_verify "intel" "qsv" "Intel Quick Sync configured and verified."; then
    pass "verification retry can recover before fallback"
else
    fail "verification retry can recover before fallback"
fi
assert_eq "2" "$verify_attempts" "retry path reruns transcode evidence"
assert_eq "2" "$runtime_calls" "retry path reapplies runtime override"
assert_eq "2" "$probe_calls" "retry path reruns capability probes"
assert_eq "2" "$configure_calls" "retry path reruns Jellyfin configure"
assert_contains "${gpu_env_calls[*]}" "intel:complete:intel:qsv" "successful retry marks GPU complete"
assert_eq "1" "$summary_calls" "successful retry prints final summary once"
unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override stage3_probe_capabilities _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence print_final_summary
unset gpu_env_calls verify_attempts runtime_calls probe_calls configure_calls summary_calls

gpu_env_calls=()
runtime_calls=()
disable_calls=0
encoder_disabled_arg=""
SCRIPT_DIR="$TMP_ROOT/skip-after-failed-proof"
mkdir -p "$SCRIPT_DIR"
stage3_write_nvidia_marker >/dev/null 2>&1
ui_choose() { printf '%s\n' "Skip for now"; }
ui_log() { :; }
stage3_set_gpu_env() { gpu_env_calls+=("$1:$2:$3:$4"); }
_stage3_apply_runtime_override() {
    runtime_calls+=("$1")
    return 0
}
stage3_probe_capabilities() { return 0; }
_stage3_configure_jellyfin() { return 0; }
_stage3_verify_jellyfin_encoding() { return 0; }
stage3_verify_transcode_evidence() { return 1; }
_stage3_disable_jellyfin_hardware() {
    disable_calls=$((disable_calls + 1))
    return 0
}
_stage3_encoder_disabled() {
    encoder_disabled_arg="$1"
    return 0
}
print_final_summary() { :; }
if _stage3_configure_and_verify "nvidia" "nvenc" "NVIDIA NVENC configured and verified."; then
    fail "skip after verification failure does not mark GPU complete"
else
    pass "skip after verification failure does not mark GPU complete"
fi
assert_eq "1" "$disable_calls" "skip after failed verification disables Jellyfin hardware acceleration"
assert_eq "nvenc" "$encoder_disabled_arg" "skip verifies Jellyfin software mode after disable"
assert_contains "${gpu_env_calls[*]}" "none:skipped::" "skip records software transcoding state"
assert_contains "${runtime_calls[*]}" "none" "skip removes GPU runtime override"
if stage3_marker_exists; then
    fail "skip after failed verification clears stale NVIDIA marker"
else
    pass "skip after failed verification clears stale NVIDIA marker"
fi
unset -f ui_choose ui_log stage3_set_gpu_env _stage3_apply_runtime_override _stage3_configure_jellyfin _stage3_verify_jellyfin_encoding stage3_verify_transcode_evidence _stage3_disable_jellyfin_hardware _stage3_encoder_disabled print_final_summary
unset -f stage3_probe_capabilities
unset gpu_env_calls runtime_calls disable_calls encoder_disabled_arg

for top_level_skip_path in "no supported GPU" "initial Skip for now"; do
    gpu_env_calls=()
    runtime_calls=()
    disable_calls=0
    software_verify_calls=0
    summary_calls=0
    SCRIPT_DIR="$TMP_ROOT/top-level-${top_level_skip_path// /-}"
    mkdir -p "$SCRIPT_DIR"
    stage3_write_nvidia_marker >/dev/null 2>&1
    GPU_TYPE=intel
    JELLYFIN_GPU=intel
    ui_log() { :; }
    ui_banner() { :; }
    _stage3_offer() { printf '%s\n' "Skip for now"; }
    stage3_set_gpu_env() {
        gpu_env_calls+=("$1:$2:$3:$4")
        JELLYFIN_GPU="$1"
        return 0
    }
    _stage3_disable_jellyfin_hardware() {
        disable_calls=$((disable_calls + 1))
        return 0
    }
    _stage3_encoder_disabled() {
        software_verify_calls=$((software_verify_calls + 1))
        return 0
    }
    _stage3_apply_runtime_override() {
        runtime_calls+=("$1")
        return 0
    }
    print_final_summary() { summary_calls=$((summary_calls + 1)); }

    if [[ "$top_level_skip_path" == "no supported GPU" ]]; then
        GPU_TYPE=none
    fi

    run_stage3
    assert_contains "${gpu_env_calls[*]}" "none:skipped::" "top-level $top_level_skip_path records skipped state"
    assert_eq "1" "$disable_calls" "top-level $top_level_skip_path disables Jellyfin hardware"
    assert_eq "1" "$software_verify_calls" "top-level $top_level_skip_path verifies Jellyfin software mode"
    assert_contains "${runtime_calls[*]}" "none" "top-level $top_level_skip_path removes GPU runtime override"
    assert_eq "1" "$summary_calls" "top-level $top_level_skip_path prints final summary once"
    if stage3_marker_exists; then
        fail "top-level $top_level_skip_path clears stale NVIDIA marker"
    else
        pass "top-level $top_level_skip_path clears stale NVIDIA marker"
    fi

    unset -f ui_log ui_banner _stage3_offer stage3_set_gpu_env _stage3_disable_jellyfin_hardware _stage3_encoder_disabled _stage3_apply_runtime_override print_final_summary
    unset gpu_env_calls runtime_calls disable_calls software_verify_calls summary_calls GPU_TYPE JELLYFIN_GPU
done

for failed_vendor in intel amd nvidia; do
    fallback_args=()
    verify_calls=0
    configure_calls=0
    GPU_TYPE="$failed_vendor"
    NEEDS_REBOOT=false
    ui_log() { :; }
    ui_banner() { :; }
    _stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
    # NVIDIA now asks a driver-management mode first; force Unlock so the mocked
    # install_nvidia_drivers below is the installer under test. nvidia_driver_source
    # is mocked to "none" so the real Standard→Unlock purge path is never reached.
    _stage3_choose_nvidia_mode() { printf 'unlock'; }
    nvidia_driver_source() { printf 'none'; }
    install_intel_drivers() { [[ "$failed_vendor" != "intel" ]]; }
    install_amd_drivers() { [[ "$failed_vendor" != "amd" ]]; }
    install_nvidia_drivers() { [[ "$failed_vendor" != "nvidia" ]]; }
    verify_gpu_usable() {
        verify_calls=$((verify_calls + 1))
        return 0
    }
    _stage3_fallback() {
        fallback_args+=("$1:$2")
        GPU_TYPE=none
        return 0
    }
    _stage3_configure_intel() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    _stage3_configure_and_verify() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    stage3_write_nvidia_marker() {
        configure_calls=$((configure_calls + 1))
        return 0
    }
    stage3_prompt_nvidia_reboot() {
        configure_calls=$((configure_calls + 1))
        return 0
    }

    run_stage3

    case "$failed_vendor" in
        intel) expected_fallback="intel:qsv" ;;
        amd) expected_fallback="amd:vaapi" ;;
        nvidia) expected_fallback="nvidia:nvenc" ;;
    esac
    assert_contains "${fallback_args[*]}" "$expected_fallback" "$failed_vendor installer failure falls back to software"
    assert_eq "none" "$GPU_TYPE" "$failed_vendor installer failure downgrades GPU type"
    assert_eq "0" "$verify_calls" "$failed_vendor installer failure skips GPU verification"
    assert_eq "0" "$configure_calls" "$failed_vendor installer failure skips hardware configure/reboot path"

    unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_mode nvidia_driver_source install_intel_drivers install_amd_drivers install_nvidia_drivers verify_gpu_usable _stage3_fallback _stage3_configure_intel _stage3_configure_and_verify stage3_write_nvidia_marker stage3_prompt_nvidia_reboot
    unset fallback_args verify_calls configure_calls GPU_TYPE NEEDS_REBOOT expected_fallback
done

GPU_TYPE=nvidia
NEEDS_REBOOT=false
prepare_calls=0
install_calls=0
configured_mode=""
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_action() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() {
    prepare_calls=$((prepare_calls + 1))
    return 0
}
install_nvidia_drivers() {
    install_calls=$((install_calls + 1))
    return 0
}
apply_nvidia_patch() { return 0; }
verify_gpu_usable() { return 0; }
_stage3_configure_and_verify() {
    configured_mode="${5:-}"
    return 0
}
_stage3_fallback() { fail "Standard→Unlock conversion should not fall back when prepare/install succeed"; }
run_stage3
assert_eq "1" "$prepare_calls" "Standard→Unlock conversion prepares Debian driver removal"
assert_eq "1" "$install_calls" "Standard→Unlock conversion runs patch-managed installer after prepare"
assert_eq "unlock" "$configured_mode" "Standard→Unlock conversion records Unlock mode"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_action nvidia_driver_source \
    prepare_nvidia_debian_to_unlock install_nvidia_drivers apply_nvidia_patch verify_gpu_usable \
    _stage3_configure_and_verify _stage3_fallback
unset GPU_TYPE NEEDS_REBOOT prepare_calls install_calls configured_mode

GPU_TYPE=nvidia
NEEDS_REBOOT=false
prepare_calls=0
install_calls=0
marker_args=""
ui_log() { :; }
ui_banner() { :; }
_stage3_offer() { printf '%s\n' "Configure hardware transcoding"; }
_stage3_choose_nvidia_action() { printf 'unlock'; }
nvidia_driver_source() { printf 'debian'; }
prepare_nvidia_debian_to_unlock() {
    prepare_calls=$((prepare_calls + 1))
    # shellcheck disable=SC2034 # read across stage3.sh dispatch (production global set by gpu.sh/stage3 install flows)
    NEEDS_REBOOT=true
    return 0
}
install_nvidia_drivers() {
    install_calls=$((install_calls + 1))
    return 0
}
stage3_set_gpu_env() { return 0; }
# shellcheck disable=SC2120 # real callers (with args) live in scripts/setup/stage3/nvidia-flow.sh
stage3_write_nvidia_marker() {
    marker_args="$1:$2"
    return 0
}
stage3_prompt_nvidia_reboot() { return 0; }
_stage3_fallback() { fail "Standard→Unlock conversion reboot path should not fall back"; }
run_stage3
assert_eq "1" "$prepare_calls" "Standard→Unlock conversion can queue reboot after prepare"
assert_eq "0" "$install_calls" "Standard→Unlock reboot path defers patch-managed install"
assert_eq "unlock:run" "$marker_args" "Standard→Unlock reboot path writes Unlock run marker"
unset -f ui_log ui_banner _stage3_offer _stage3_choose_nvidia_action nvidia_driver_source \
    prepare_nvidia_debian_to_unlock install_nvidia_drivers stage3_set_gpu_env \
    stage3_write_nvidia_marker stage3_prompt_nvidia_reboot _stage3_fallback
unset GPU_TYPE NEEDS_REBOOT prepare_calls install_calls marker_args

scenario_end "$CURRENT_SCENARIO"
summary
