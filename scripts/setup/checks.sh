# =============================================================================
# MediaStack Setup — Prerequisite checks
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.

_CHECKS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Topic modules, split out of this file for size: pre-flight hard-fail/warn
# checks, existing-install detection + the keep/wipe/abort prompt, and the
# typed-DESTROY teardown sequence. Kept in this one place so every sourcer
# (setup.sh and the unit/scenario tests) gets the full checks.sh surface
# from a single source.
# shellcheck source=checks/preflight.sh
source "$_CHECKS_MODULE_DIR/checks/preflight.sh"
# shellcheck source=checks/existing_install.sh
source "$_CHECKS_MODULE_DIR/checks/existing_install.sh"
# shellcheck source=checks/destroy.sh
source "$_CHECKS_MODULE_DIR/checks/destroy.sh"

unset _CHECKS_MODULE_DIR

# Tell the day-2 launcher (mediastack) the real recovery outcome. The launcher
# runs setup.sh as a child process and can't see RECOVERY_MENU_ACTION across the
# boundary, so it can't tell a real wipe/reinstall (exit 0) from a user who
# backed out (also exit 0) or a deliberate abort (exit 1) from a crash. When the
# launcher wants to know, it sets MEDIASTACK_LAUNCHER_RESULT to a file path and
# we drop a one-word token in it. No-op for direct `./setup.sh` runs (and the
# DinD recovery fixtures), which never set the variable. set -u safe.
#
# Kept in the entry point (not a topic file) because both existing_install.sh
# and destroy.sh call it.
record_launcher_outcome() {
    [[ -n "${MEDIASTACK_LAUNCHER_RESULT:-}" ]] || return 0
    printf '%s\n' "$1" >"$MEDIASTACK_LAUNCHER_RESULT" 2>/dev/null || true
}
