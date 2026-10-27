#!/usr/bin/env bash
# tests/unit/ui-spin-sudo-prime.sh
#
# Unit test for the ui_spin sudo-prime guard (scripts/lib/ui.sh). A
# spinner-wrapped `sudo` command must have its credential timestamp warmed in
# the FOREGROUND before _render_spin backgrounds it — otherwise, on a cold
# cache, sudo's /dev/tty prompt is clobbered by the spinner repaint and the
# install hangs invisibly. Every other unit test stubs ui_spin, so this is the
# only coverage of the guard itself.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-spin-sudo-prime"
scenario_begin "$CURRENT_SCENARIO"

export UI_BACKEND=fallback UI_DEMO=0
source "$REPO_ROOT/scripts/lib/ui.sh"

# Spies replace the backend primitives and sudo AFTER sourcing, so we observe
# the exact call order the guard produces. ui_spin invokes the renderer as
# `_render_spin "$label" "$@"`, so the label is the renderer's first argument.
CALLS=""
sudo() {
    CALLS+="sudo:$*|"
    [[ "$*" == "-n -v" ]] && return "${SUDO_N_RC:-1}"
    return "${SUDO_RC:-0}"
}
_render_spin() {
    CALLS+="render:$*|"
    return 0
}
_render_spin_demo() {
    CALLS+="demo:$*|"
    return 0
}

# 1) sudo-wrapped, cold cache: the prime (`sudo -n -v`, then `sudo -v`) fires
#    first, then the spinner renders. ui_log output goes to /dev/null here; the
#    reason line itself is covered by tests/unit/sudo-prime.sh.
CALLS=""
ui_spin "Installing..." sudo apt-get install foo >/dev/null
assert_eq "sudo:-n -v|sudo:-v|render:Installing... sudo apt-get install foo|" "$CALLS" \
    "ui_spin primes sudo in the foreground before the spinner backgrounds it"

# 1b) warm cache: no prompt at all.
CALLS=""
SUDO_N_RC=0 ui_spin "Installing..." sudo apt-get install foo
assert_eq "sudo:-n -v|render:Installing... sudo apt-get install foo|" "$CALLS" \
    "ui_spin skips the prompt when the sudo timestamp is warm"

# 2) non-sudo command: no prime.
CALLS=""
ui_spin "Working..." echo hello
assert_eq "render:Working... echo hello|" "$CALLS" \
    "ui_spin does not prime sudo for a non-sudo command"

# 3) cold cache / no tty: `sudo -v` fails, but the guard's `|| true` holds ui_spin
#    at exit 0, so a caller under `set -e` is not aborted. Enable errexit here so
#    the failing-prime path is genuinely exercised under it — if the guard dropped
#    the `|| true`, set -e would abort this line before rc is captured.
CALLS=""
set -e
SUDO_RC=1 ui_spin "Installing..." sudo apt-get install bar >/dev/null
rc=$?
set +e
assert_eq 0 "$rc" "a failing prime returns 0 under set -e (does not abort the caller)"
assert_eq "sudo:-n -v|sudo:-v|render:Installing... sudo apt-get install bar|" "$CALLS" \
    "a failing prime still primes then renders"

# 4) demo mode short-circuits before the guard: no prime.
CALLS=""
UI_DEMO=1 UI_DEMO_DELAY=0 ui_spin "Installing..." sudo apt-get install baz
assert_eq "demo:Installing... 0|" "$CALLS" \
    "demo mode short-circuits before the sudo prime"

scenario_end "$CURRENT_SCENARIO"
summary
