#!/usr/bin/env bash
# tests/unit/wizard-flow.sh
#
# Unit test for the wizard flows (run_wizard) and env generation
# (detect_env, write_env). Exercises the interactive UI_DEMO=1 path and the
# non-interactive DEMO=1 path, then verifies .env and config.yml outputs.
#
# No DinD, no Docker needed. Shims docker/speedtest-cli/timedatectl so the
# wizard runs entirely offline.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WIZARD_FLOW_TEST_DIR="$SCRIPT_DIR/wizard-flow"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-flow"
scenario_begin "$CURRENT_SCENARIO"

# --- Temp workspace (acts as SCRIPT_DIR for the wizard) ---
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$REPO_ROOT/config/examples/config.yml" "$TMP_DIR/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR/scripts"
mkdir -p "$TMP_DIR/config/ddns-updater"

reset_fixture_config() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("wizard_completed: true", "wizard_completed: false")
path.write_text(text)
PY
}

reset_fixture_config "$TMP_DIR/config.yml"

# --- Shim externals ---
# Docker: shim so WG hash generation doesn't need a real daemon
docker() {
    if [[ "${1:-}" == "run" ]]; then
        echo "'fakehash\$2b\$10\$test'"
        return 0
    fi
    if [[ "${1:-}" == "--version" ]]; then
        echo "Docker version 27.0.1, build test"
        return 0
    fi
    if [[ "${1:-}" == "compose" ]]; then
        case " $* " in
            *" config --services "*)
                printf '%s\n' jellyfin sonarr radarr jackett qbittorrent seerr homepage portainer uptime-kuma beszel
                if [[ " $* " == *" --profile subtitles "* ]]; then
                    printf '%s\n' bazarr
                fi
                return 0
                ;;
            *" config --images "*)
                printf '%s\n' image{1..10}
                if [[ " $* " == *" --profile subtitles "* ]]; then
                    printf '%s\n' image11
                fi
                return 0
                ;;
        esac
    fi
    command docker "$@"
}
export -f docker

# Speed test tools: not available in unit test. The wizard runs under
# UI_DEMO=1/DEMO=1 which short-circuits net_run_speedtest before any tool, so
# these are belt-and-suspenders. Do NOT stub curl here — the wizard uses it for
# public-IP/Cloudflare/port checks, and the speed-test path's primary method is
# curl+Cloudflare.
librespeed-cli() { return 1; }
export -f librespeed-cli

# openssl: deterministic password generation for both demo paths
openssl() {
    if [[ "${1:-}" == "rand" && "${2:-}" == "-base64" ]]; then
        echo "GeneratedDemoPassword123"
        return 0
    fi
    command openssl "$@"
}
export -f openssl

# timedatectl: deterministic timezone
timedatectl() { echo "Etc/UTC"; }
export -f timedatectl

# Silence log_* — assertions drive output
log_ok() { :; }
log_info() { :; }
log_warn() { printf '%s\n' "$1"; }
log_skip() { :; }
log_error() { :; }

# --- Source all modules (setup.sh guard prevents main() from running) ---
# We need to set up the same environment as setup.sh
SCRIPT_DIR="$TMP_DIR"
export UI_DEMO=1

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/checks.sh"
source "$REPO_ROOT/scripts/setup/env-gen.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

_stage1_install() {
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        _wizard_apply_settings "1080p" "balanced" "english" "0"
    fi
    return 0
}

RUN_STAGE2_COUNT=0
run_stage2() {
    RUN_STAGE2_COUNT=$((RUN_STAGE2_COUNT + 1))
    return 0
}

RUN_STAGE3_COUNT=0
run_stage3() {
    RUN_STAGE3_COUNT=$((RUN_STAGE3_COUNT + 1))
    return 0
}

# Relax strict mode for test assertions
set +e
set +u

GPU_TYPE="none"

# Keep the historical assertion order: the children are sourced, not run as
# independent suites, so the frozen output and summary remain one suite.
# shellcheck source=wizard-flow/ui-input-exhaustion.sh
source "$WIZARD_FLOW_TEST_DIR/ui-input-exhaustion.sh"
# shellcheck source=wizard-flow/env-write.sh
source "$WIZARD_FLOW_TEST_DIR/env-write.sh"
# shellcheck source=wizard-flow/rerun-resume.sh
source "$WIZARD_FLOW_TEST_DIR/rerun-resume.sh"
# shellcheck source=wizard-flow/demo-and-full-install.sh
source "$WIZARD_FLOW_TEST_DIR/demo-and-full-install.sh"

# =========================================================================
# Summary
# =========================================================================
scenario_end "$CURRENT_SCENARIO"
summary
