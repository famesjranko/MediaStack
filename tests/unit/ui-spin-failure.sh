#!/usr/bin/env bash
# tests/unit/ui-spin-failure.sh
#
# Unit test for what ui_spin shows when its command fails (scripts/lib/ui.sh and
# the spinner backends). The spinner hides the command's output while it runs, so
# a failed apt install must surface its last lines and the failing command: a
# bare "exited with code 100" gave the user nothing to act on. Under `set -e` a
# bare `wait` in the backend once ended the caller's shell before any of that was
# shown, so this runs the spinner the way install_base_packages calls it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-spin-failure"
scenario_begin "$CURRENT_SCENARIO"

export UI_BACKEND=fallback UI_DEMO=0
source "$REPO_ROOT/scripts/lib/ui.sh"

# An apt-like tool: 30 progress lines (colour codes, a carriage-return repaint),
# then the 404 error, then exit 100. Runs in the spinner's background subshell.
fake_apt() {
    local i
    for i in $(seq 1 30); do
        printf '\033[1;32mGet:%s\033[0m http://deb.example/pool/pkg%s.deb\n' "$i" "$i"
    done
    printf 'Fetched 10%%\rFetched 100%%\n'
    printf 'E: Failed to fetch http://deb.example/pool/git.deb  404  Not Found\n'
    return 100
}

# Given a failing apt-like command run through a bare ui_spin under set -e,
# When the spinner finishes,
# Then the shell exits with the command's code and stderr carries the failing
# command and the last lines of its output.
out=$(
    set -e
    ui_spin "Installing base packages..." fake_apt 2>&1 >/dev/null
    echo "REACHED"
) 2>&1
rc=$?
assert_eq "100" "$rc" "ui_spin failure: the caller's shell exits with the command's own code"
assert_contains "$out" "Command failed (exit 100): fake_apt" "ui_spin failure: names the failing command"
assert_contains "$out" "E: Failed to fetch http://deb.example/pool/git.deb  404  Not Found" "ui_spin failure: shows the error line"
assert_contains "$out" "Fetched 100%" "ui_spin failure: a carriage-return repaint shows only its final text"
assert_not_contains "$out" "REACHED" "ui_spin failure: errexit still stops a bare caller after the output"

# Given the same failure,
# When the output is read,
# Then it is bounded to the last 15 lines and carries no terminal escapes.
assert_not_contains "$out" "Get:1 " "ui_spin failure: early output beyond the last 15 lines is dropped"
assert_contains "$out" "Get:18 " "ui_spin failure: the output window starts at the 15th line from the end"
shown=$(grep -c '^    ' <<<"$out")
assert_eq "15" "$shown" "ui_spin failure: exactly 15 output lines are shown"
if [[ "$out" == *$'\033'* ]]; then
    fail "ui_spin failure: output carries no terminal escapes"
else
    pass "ui_spin failure: output carries no terminal escapes"
fi

# Given a command that succeeds after the spinner has time to paint,
# When the spinner finishes,
# Then the final cursor return erases the spinner line and prints no more text.
out=$(ui_spin "Working..." sleep 0.2 2>&1)
assert_eq $'\033[K' "${out##*$'\r'}" "ui_spin success: erases its final terminal frame"

# Given apt cannot fetch a package while install_base_packages runs under set -e (the 404 that
# left the audit user with only "exited with code 100"),
# When the base packages are installed,
# Then the user sees the apt command, apt's error line and a message with the next step.
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/packages.sh"
sudo() {
    case "${1:-}" in
        -v) return 0 ;;
        apt-get)
            [[ "${2:-}" == "update" ]] && return 0
            ;;
        env)
            printf 'Reading package lists...\n'
            printf 'E: Failed to fetch https://deb.example/pool/git.deb  404  Not Found\n'
            return 100
            ;;
    esac
    return 0
}
out=$(
    set -e
    install_base_packages 2>&1
    echo "REACHED"
)
rc=$?
assert_eq "1" "$rc" "install_base_packages: an apt failure ends the install with a failing status"
assert_contains "$out" "Command failed (exit 100): sudo env DEBIAN_FRONTEND=noninteractive apt-get install" "install_base_packages: shows the apt command that failed"
assert_contains "$out" "E: Failed to fetch https://deb.example/pool/git.deb  404  Not Found" "install_base_packages: shows apt's own error"
assert_contains "$out" "Could not install the base packages" "install_base_packages: says what failed and the next step"
assert_not_contains "$out" "REACHED" "install_base_packages: setup stops there"

scenario_end "$CURRENT_SCENARIO"
summary
