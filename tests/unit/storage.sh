#!/usr/bin/env bash
# Owns: the ordered storage unit-suite entry point.
# Sources: tests/unit/storage/* and scripts/setup/storage.sh (+ stack.sh,
# stages/stage1.sh, env-gen.sh for the wizard-integration scenarios).
# tests/unit/storage.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORAGE_TEST_DIR="$SCRIPT_DIR/storage"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="storage"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/setup/storage.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
source "$REPO_ROOT/scripts/setup/stages/stage1.sh"
source "$REPO_ROOT/scripts/setup/env-gen.sh"

set +e
set +u

# Keep the historical assertion order: the children are sourced, not run as
# independent suites, so the frozen output and summary remain one suite.
source "$STORAGE_TEST_DIR/core.sh"
source "$STORAGE_TEST_DIR/mount.sh"
source "$STORAGE_TEST_DIR/preflight.sh"
source "$STORAGE_TEST_DIR/watchdog.sh"
source "$STORAGE_TEST_DIR/wizard-nas.sh"
source "$STORAGE_TEST_DIR/wizard-smb.sh"

scenario_end "$CURRENT_SCENARIO"
summary
