#!/usr/bin/env bash
# tests/unit/stage1-system-screen.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-system-screen"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/checks.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"
# stack.sh defines gpu_brand_label, used by _stage1_show_system for the GPU row's
# brand casing (production sources it via setup.sh before Stage 1 runs).
source "$REPO_ROOT/scripts/setup/stack.sh"

set +e
set +u

_ENV_HOST_ADDRESS="192.168.1.10"
_ENV_TZ="Etc/UTC"
_NET_PUBLIC_IP="203.0.113.42"
GPU_TYPE="intel"

docker() {
    if [[ "${1:-}" == "--version" ]]; then
        echo "Docker version 27.0.1, build test"
        return 0
    fi
    command docker "$@"
}

ui_kv() {
    printf '%s=%s' "$1" "$2"
}

SCREEN_CAPTURE=""
ui_box() {
    SCREEN_CAPTURE=$(printf '%s\n' "$@")
}

ui_choose() { echo "Continue"; }

_stage1_show_system

assert_contains "$SCREEN_CAPTURE" "Detected your system" "stage1-show-system: title"
assert_contains "$SCREEN_CAPTURE" "Hostname=" "stage1-show-system: hostname row"
assert_contains "$SCREEN_CAPTURE" "LAN IP=192.168.1.10" "stage1-show-system: LAN IP row"
assert_contains "$SCREEN_CAPTURE" "Public IP=203.0.113.42" "stage1-show-system: public IP row"
assert_contains "$SCREEN_CAPTURE" "Docker version=27.0.1" "stage1-show-system: docker version row"
assert_contains "$SCREEN_CAPTURE" "GPU=Intel" "stage1-show-system: GPU row"
assert_contains "$SCREEN_CAPTURE" "Timezone=Etc/UTC" "stage1-show-system: timezone row"

line_count=$(printf '%s\n' "$SCREEN_CAPTURE" | awk 'END {print NR}')
assert_eq "10" "$line_count" "stage1-show-system: title + 9 rows"

scenario_end "$CURRENT_SCENARIO"
summary
