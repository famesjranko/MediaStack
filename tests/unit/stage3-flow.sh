#!/usr/bin/env bash
# tests/unit/stage3-flow.sh
#
# Contract tests for the Stage 3 GPU flow.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage3-flow"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/stages/stage3.sh"
# gpu_brand_label (used by _stage3_offer for the "Detected GPU" box brand casing)
# now lives in gpu.sh, but sourcing all of gpu.sh here would clobber the
# gpu_render_device_* helpers that the render-device tests below deliberately drive
# without gpu.sh loaded. Provide just the brand-label helper for the offer test.
[[ -f "$REPO_ROOT/scripts/setup/stack.sh" ]] && source "$REPO_ROOT/scripts/setup/stack.sh"
if ! type gpu_brand_label >/dev/null 2>&1; then
    gpu_brand_label() {
        case "${1:-}" in
            nvidia) printf 'NVIDIA' ;;
            amd) printf 'AMD' ;;
            intel) printf 'Intel' ;;
            none | "") printf 'none' ;;
            *) printf '%s' "$1" ;;
        esac
    }
fi

set +e
set +u

if ! type stage3_offer_choices >/dev/null 2>&1; then
    stage3_offer_choices() { printf '__not_implemented__'; }
fi

# shellcheck disable=SC2034 # read by _stage3_choose_gpu_vendor in scripts/setup/stage3/jellyfin.sh
GPU_CANDIDATES=(nvidia amd intel)
GPU_TYPE=amd
# ui_section (section-header rendering) lives in scripts/lib/ui.sh, which this
# unit test does not source. Stub it globally as a silent no-op so the real
# stage3 menu functions under test don't spew "ui_section: command not found".
ui_section() { :; }

GPU_MENU_CAPTURE=$(mktemp)
ui_choose() {
    shift
    printf '%s\n%s' "${UI_CHOOSE_DEFAULT_INDEX:-}" "$*" >"$GPU_MENU_CAPTURE"
    printf '%s\n' "Intel — Quick Sync"
}
_stage3_choose_gpu_vendor
assert_eq "intel" "$GPU_TYPE" "multi-GPU menu routes to the selected vendor"
assert_eq "2" "$(head -1 "$GPU_MENU_CAPTURE")" "configured available vendor is the multi-GPU default"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "NVIDIA — NVENC" "multi-GPU menu includes detected NVIDIA"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "AMD — VAAPI" "multi-GPU menu includes detected AMD"
assert_contains "$(tail -1 "$GPU_MENU_CAPTURE")" "Intel — Quick Sync" "multi-GPU menu includes detected Intel"
unset -f ui_choose
rm -f "$GPU_MENU_CAPTURE"
unset GPU_CANDIDATES GPU_TYPE GPU_MENU_CAPTURE
if ! type stage3_tell_me_more_copy >/dev/null 2>&1; then
    stage3_tell_me_more_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_skip_summary_copy >/dev/null 2>&1; then
    stage3_skip_summary_copy() { printf '__not_implemented__'; }
fi
if ! type stage3_set_gpu_env >/dev/null 2>&1; then
    stage3_set_gpu_env() {
        printf '__not_implemented__'
        return 1
    }
fi

offer_choices="$(stage3_offer_choices)"
if [[ "$offer_choices" == "__not_implemented__" ]]; then
    skip "offer choices pending Stage 3 controller"
else
    assert_contains "$offer_choices" "Configure hardware transcoding" "offer includes Configure hardware transcoding"
    assert_contains "$offer_choices" "Skip for now" "offer includes Skip for now"
    assert_contains "$offer_choices" "Tell me more" "offer includes Tell me more"
fi

if type _stage3_offer >/dev/null 2>&1; then
    offer_stderr="$(mktemp)"
    GPU_TYPE=nvidia
    ui_section() { printf 'SECTION:%s\n' "$*"; }
    ui_box() { printf 'BOX:%s\n' "$*"; }
    ui_choose() { printf '%s\n' "Configure hardware transcoding"; }
    offer_answer="$(_stage3_offer 2>"$offer_stderr")"
    assert_eq "Configure hardware transcoding" "$offer_answer" "offer stdout contains only selected answer"
    assert_contains "$(cat "$offer_stderr")" "Detected GPU: NVIDIA" "offer explains detected GPU outside captured answer"
    rm -f "$offer_stderr"
    unset -f ui_box ui_choose
    ui_section() { :; } # restore the global no-op (this block overrode it above)
    unset GPU_TYPE offer_answer offer_stderr
fi

if type stage3_verify_retry_choices >/dev/null 2>&1; then
    retry_choices="$(stage3_verify_retry_choices)"
    assert_contains "$retry_choices" "Retry verification" "verification failure offers retry"
    assert_contains "$retry_choices" "Use software transcoding" "verification failure offers software fallback"
    assert_contains "$retry_choices" "Skip for now" "verification failure offers skip"
else
    skip "verification retry choices pending Stage 3 controller"
fi

tell_more="$(stage3_tell_me_more_copy)"
if [[ "$tell_more" == "__not_implemented__" ]]; then
    skip "tell-me-more copy pending Stage 3 controller"
else
    assert_contains "$tell_more" "Intel" "tell-me-more covers Intel"
    assert_contains "$tell_more" "AMD" "tell-me-more covers AMD"
    assert_contains "$tell_more" "NVIDIA" "tell-me-more covers NVIDIA"
    assert_contains "$tell_more" "reboot" "tell-me-more explains NVIDIA reboot"
fi

skip_copy="$(stage3_skip_summary_copy)"
if [[ "$skip_copy" == "__not_implemented__" ]]; then
    skip "skip copy pending Stage 3 controller"
else
    if [[ "$skip_copy" == *"Manage hardware transcoding"* ]]; then
        assert_contains "$skip_copy" "Hardware transcoding skipped. Jellyfin will use software transcoding. Choose Manage hardware transcoding (GPU) from the menu to try again." "skip copy names transcoding recovery route"
    else
        skip "skip copy names hardware transcoding recovery route pending recovery hook"
    fi
fi

stage3_path="$REPO_ROOT/scripts/setup/stages/stage3.sh"
if [[ -f "$stage3_path" ]]; then
    stage3_source="$(cat "$stage3_path" "$REPO_ROOT"/scripts/setup/stage3/*.sh)"
    assert_contains "$stage3_source" "run_stage3()" "run_stage3 controller exists"
    assert_contains "$stage3_source" "Hardware transcoding skipped (no supported GPU detected)." "no-GPU skip copy"
    assert_contains "$stage3_source" "install_intel_drivers" "Intel branch calls existing installer"
    assert_contains "$stage3_source" "install_amd_drivers" "AMD branch calls existing installer"
    assert_contains "$stage3_source" "install_nvidia_drivers" "NVIDIA branch calls existing installer"
    assert_contains "$stage3_source" "stage3_set_gpu_env" "Stage 3 owns Jellyfin GPU env writes"
    assert_contains "$stage3_source" "qsv" "Intel encoder is qsv"
    assert_contains "$stage3_source" "vaapi" "AMD encoder is vaapi"
    assert_contains "$stage3_source" ".nvidia-finalize-pending" "NVIDIA pre-reboot writes finalize marker"
    assert_contains "$stage3_source" "stage3_verify_transcode_evidence" "vendor branches call transcode evidence helper"
    assert_contains "$stage3_source" 'stage3_set_gpu_env "none"' "failed proof falls back to software"
    assert_contains "$stage3_source" "print_final_summary" "Stage 3 terminal paths print final summary"
else
    skip "Stage 3 controller source checks pending implementation"
fi

setup_source="$(sed -n '1,760p' "$REPO_ROOT/setup.sh")"
stage1_source="$(cat "$REPO_ROOT/scripts/setup/stage1/install.sh")"
assert_contains "$setup_source" "stash_gpu_type" "setup stashes detected GPU type"
assert_contains "$stage1_source" 'generate_override "none"' "Stage 1 starts baseline stack without GPU runtime override"
if [[ -f "$stage3_path" && "$setup_source" == *"install_nvidia_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_intel_drivers"*"run_wizard"* || -f "$stage3_path" && "$setup_source" == *"install_amd_drivers"*"run_wizard"* ]]; then
    fail "setup.sh does not run old GPU install path before Stage 3"
elif [[ -f "$stage3_path" ]]; then
    pass "setup.sh does not run old GPU install path before Stage 3"
else
    skip "setup legacy GPU path check pending Stage 3 controller"
fi

scenario_end "$CURRENT_SCENARIO"
summary
