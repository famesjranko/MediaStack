#!/usr/bin/env bash
# tests/unit/nvidia-repatch.sh
#
# Contract test for scripts/nvidia-repatch.sh reading the quoted .env mode.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="nvidia-repatch"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT
mkdir -p "$TMP_ROOT/scripts/lib" "$TMP_ROOT/bin"
cp "$REPO_ROOT/scripts/nvidia-repatch.sh" "$TMP_ROOT/scripts/"
cp "$REPO_ROOT/scripts/lib/nvidia-patch.sh" "$TMP_ROOT/scripts/lib/"
# Failing nvidia-smi: a run past the mode guard stops at the driver check and
# can never touch a real host driver.
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP_ROOT/bin/nvidia-smi"
chmod +x "$TMP_ROOT/bin/nvidia-smi"

run_repatch() {
    PATH="$TMP_ROOT/bin:$PATH" bash "$TMP_ROOT/scripts/nvidia-repatch.sh" 2>&1
}

# Given .env stores the unlock mode quoted, as env-write.sh writes it
# When nvidia-repatch runs without --force
# Then it proceeds past the mode guard instead of saying there is nothing to repatch
printf "NVIDIA_DRIVER_MODE='unlock'\n" >"$TMP_ROOT/.env"
out=$(run_repatch)
case "$out" in
    *"nothing to repatch"*) fail "nvidia-repatch: quoted unlock mode must not be treated as not-unlock" ;;
    *) pass "nvidia-repatch: quoted unlock mode passes the mode guard" ;;
esac

# Given .env stores the standard mode quoted
# When nvidia-repatch runs without --force
# Then it reports the clean mode name, with no doubled quotes
printf "NVIDIA_DRIVER_MODE='standard'\n" >"$TMP_ROOT/.env"
out=$(run_repatch)
assert_contains "$out" "NVIDIA_DRIVER_MODE='standard'" "nvidia-repatch: standard mode is reported without doubled quotes"
assert_contains "$out" "nothing to repatch" "nvidia-repatch: standard mode is a no-op"

scenario_end "$CURRENT_SCENARIO"
summary
