#!/usr/bin/env bash
# tests/unit/sudo-prime.sh
#
# Unit test for ui_sudo_prime (scripts/lib/ui.sh), the one helper behind every
# sudo timestamp-priming site. sudo writes its password prompt to /dev/tty, so
# `sudo -v 2>/dev/null || true` showed a prompt with no cause and swallowed a
# failure. A real executable `sudo` stub on PATH stands in for sudo; it appends
# every call to the same trace file the helper's output goes to, so the order
# of reason line and prompt is observable. No real sudo ever runs.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="sudo-prime"
scenario_begin "$CURRENT_SCENARIO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export TRACE="$WORK/trace"
cat >"$WORK/bin/sudo" <<'STUB'
#!/usr/bin/env bash
# N_RC: exit code of `sudo -n -v` (1 = cold timestamp). V_RC: exit code of `sudo -v`.
echo "sudo $*" >>"$TRACE"
case "$*" in
    "-n -v") exit "${N_RC:-1}" ;;
    "-v")
        echo "[sudo] password prompt" >>"$TRACE"
        exit "${V_RC:-0}"
        ;;
esac
exit 0
STUB
chmod +x "$WORK/bin/sudo"
export PATH="$WORK/bin:$PATH"

export UI_BACKEND=fallback UI_DEMO=0 NO_COLOR=1
source "$REPO_ROOT/scripts/lib/ui.sh"

# prime REASON [CONSEQUENCE] -> trace in $OUT_TRACE, helper exit code in $PRIME_RC.
# stdin is /dev/null so a hang on a missing tty would show as a timeout.
prime() {
    : >"$TRACE"
    timeout 10 bash -c 'source "$1"; shift; ui_sudo_prime "$@"' _ \
        "$REPO_ROOT/scripts/lib/ui.sh" "$@" >>"$TRACE" 2>&1 </dev/null
    PRIME_RC=$?
    OUT_TRACE="$(<"$TRACE")"
}

# 1) Given a warm timestamp, when primed, then nothing is printed and nothing prompts.
N_RC=0 prime "Remote-access setup needs your sudo password."
assert_eq "sudo -n -v" "$OUT_TRACE" "a warm timestamp prints no reason and runs no prompt"
assert_eq 0 "$PRIME_RC" "a warm timestamp returns 0"

# 2) Given a cold timestamp, when primed, then the reason line comes before the prompt.
N_RC=1 V_RC=0 prime "Remote-access setup needs your sudo password."
reason_line=$(grep -n 'Remote-access setup needs your sudo password.' "$TRACE" | head -1 | cut -d: -f1)
prompt_line=$(grep -n 'password prompt' "$TRACE" | head -1 | cut -d: -f1)
assert_eq 1 "$(((reason_line > 0 && prompt_line > reason_line) ? 1 : 0))" \
    "the reason line is printed before the sudo prompt (reason line $reason_line, prompt line $prompt_line)"
assert_not_contains "$OUT_TRACE" "Could not get sudo access" "a successful prompt prints no warning"
assert_eq 0 "$PRIME_RC" "a successful prompt returns 0"

# 3) Given a failed prompt, when primed, then a warning names the consequence and the helper returns 0.
N_RC=1 V_RC=1 prime "Remote-access setup needs your sudo password."
assert_contains "$OUT_TRACE" "Could not get sudo access: later steps can stop at a password prompt or fail." \
    "a failed prompt warns that later steps can stop or fail"
assert_eq 0 "$PRIME_RC" "a failed prompt still returns 0 so setup continues"

# 4) Given a caller-supplied consequence, when the prompt fails, then that text replaces the default.
N_RC=1 V_RC=1 prime "Firewall and certificate checks need sudo access." "those checks will be skipped."
assert_contains "$OUT_TRACE" "Could not get sudo access: those checks will be skipped." \
    "a caller can name its own consequence"
assert_contains "$OUT_TRACE" "Firewall and certificate checks need sudo access." \
    "the caller's reason line is kept"

# 5) Given no tty (stdin is /dev/null) and a failing sudo, when primed, then it warns and finishes instead of hanging.
N_RC=1 V_RC=1 prime "Setup needs your sudo password."
assert_contains "$OUT_TRACE" "Could not get sudo access" "a non-interactive failure warns"
assert_not_contains "$OUT_TRACE" "Terminated" "a non-interactive run does not hang"
assert_eq 0 "$PRIME_RC" "a non-interactive failure returns 0, not a timeout"

# 6) Given the repository, then no site primes sudo with stderr discarded.
bad=$(cd "$REPO_ROOT" && grep -rnE 'sudo -v( |$).*2>/dev/null' scripts setup.sh mediastack 2>/dev/null || true)
assert_eq "" "$bad" "no priming site discards sudo -v stderr"
for f in scripts/setup/stage2/install.sh scripts/setup/packages.sh scripts/launcher/diagnostics.sh scripts/lib/ui.sh; do
    assert_file_contains "$REPO_ROOT/$f" "ui_sudo_prime" "$f primes through ui_sudo_prime"
done

scenario_end "$CURRENT_SCENARIO"
summary
