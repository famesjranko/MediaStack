#!/usr/bin/env bash
# tests/unit/ui-color-leak.sh
#
# Regression for #7. The UI palette (scripts/lib/ui_fallback.sh) and the
# configure-time log_* helpers (scripts/lib/common.sh) used to hardcode ANSI
# colour with no gating, so anyone who piped the installer to `tee setup.log`,
# redirected it for a bug report, or ran in a non-TTY captured escape-code soup
# (^[[0;36m ...). term_caps.sh:_color_enabled now blanks the palette unless the
# output is a real TTY (or colour is force-enabled), so captured output is clean.
#
# These tests render ui_log + log_* in a NON-TTY subprocess (a command
# substitution pipe — exactly the "save the output" case) and assert:
#   - by default no ESC byte leaks into the capture,
#   - UI_FORCE_COLOR=1 still forces colour (demo / screenshots through a pipe),
#   - the folded-in palette changes hold: [INFO] is bright blue (0;94, was the
#     unreadable 0;34) and skip is grey (0;90), distinct from warn's yellow.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-color-leak"
scenario_begin "$CURRENT_SCENARIO"

ESC=$'\033'
UI="$REPO_ROOT/scripts/lib/ui.sh"          # sources ui_fallback.sh (-> term_caps.sh)
COMMON="$REPO_ROOT/scripts/lib/common.sh"  # sources term_caps.sh

# Render a snippet with ui.sh + common.sh sourced, in a clean subprocess whose
# stdout/stderr are the command-substitution pipe (i.e. NOT a TTY) — the exact
# shape of `./setup.sh | tee setup.log`. Forcing vars are scrubbed unless the
# caller re-sets them. ui_log / log_* both write to stderr, so capture 2>&1.
_render() {  # $1 = extra env assignment (e.g. "UI_FORCE_COLOR=1" or ""); rest = snippet
    local assign="$1"; shift
    local -a env_args=(-u UI_FORCE_COLOR -u FORCE_COLOR -u NO_COLOR TERM=xterm)
    [[ -n "$assign" ]] && env_args+=("$assign")
    env "${env_args[@]}" bash -c "source '$UI'; source '$COMMON'; $*" 2>&1
}

assert_no_esc() {  # $1 = text, $2 = name
    if [[ "$1" == *"$ESC"* ]]; then
        fail "$2" "ESC byte present in captured output"
    else
        pass "$2"
    fi
}

# --- Default (captured / non-TTY): zero colour escapes ---
out_ui=$(_render "" 'ui_log ok done; ui_log info hi; ui_log warn careful; ui_log skip later')
assert_no_esc "$out_ui" "ui_log: no ANSI leaks into a captured pipe"
assert_contains "$out_ui" "done" "ui_log: message text still emitted when colour is off"

out_log=$(_render "" 'log_ok done; log_info hi; log_warn careful; log_skip later')
assert_no_esc "$out_log" "common.sh log_*: no ANSI leaks into a captured pipe"
# The marker (✓ vs [OK]) is now capability-dependent (see ui-ascii-fallback.sh);
# here we only assert the message text survives when colour is gated off.
assert_contains "$out_log" "done" "log_*: message text still emitted when colour is off"

# --- UI_FORCE_COLOR=1: the escape hatch keeps colour through a pipe ---
out_force=$(_render "UI_FORCE_COLOR=1" 'ui_log ok done; ui_log info hi; ui_log warn careful; ui_log skip later')
if [[ "$out_force" == *"$ESC"* ]]; then
    pass "UI_FORCE_COLOR=1: colour forced on through a pipe"
else
    fail "UI_FORCE_COLOR=1: colour forced on through a pipe" "no ESC byte found"
fi

# Folded-in palette fixes (verify against the forced-colour render):
assert_contains "$out_force" "${ESC}[0;94m" "info uses bright blue 0;94 (contrast fix), not dark 0;34"
assert_contains "$out_force" "${ESC}[0;90m" "skip uses grey 0;90 (distinct from warn)"
assert_contains "$out_force" "${ESC}[1;33m" "warn still uses yellow 1;33"
if [[ "$out_force" == *"${ESC}[0;34m"* ]]; then
    fail "old dark-blue 0;34 is gone" "0;34 still emitted"
else
    pass "old dark-blue 0;34 is gone"
fi

# common.sh honours the force too (configure-time logs):
out_force_log=$(_render "UI_FORCE_COLOR=1" 'log_info hi; log_skip later')
assert_contains "$out_force_log" "${ESC}[0;94m" "log_info uses bright blue 0;94 under force"
assert_contains "$out_force_log" "${ESC}[0;90m" "log_skip uses grey 0;90 under force"

summary
