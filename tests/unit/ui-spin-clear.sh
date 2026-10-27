#!/usr/bin/env bash
# tests/unit/ui-spin-clear.sh
#
# Terminal-capture test for the spinner repaint (#128). A command behind the
# spinner may write to the tty (a sudo whose timestamp expired prompts there).
# Each repaint must clear the rest of the line (\033[K) so that text is not
# left behind the title. The spinner runs under `script` so its bytes are real
# terminal output; a small line emulator replays them (\r, \033[K, text).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-spin-clear"
scenario_begin "$CURRENT_SCENARIO"

if ! command -v script >/dev/null 2>&1; then
    skip "script(1) not installed; cannot capture a terminal"
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Given a command that writes a prompt to the tty while the spinner runs.
# Stub command: writes text longer than the title straight to the tty, then
# lets the spinner repaint a few more times.
cat >"$WORK/stub.sh" <<'STUB'
#!/usr/bin/env bash
sleep 0.3
printf '[sudo] password for someone-with-a-long-name: ' >/dev/tty
sleep 0.6
STUB

# Replays the capture; prints the line as the user sees it on the last frame.
cat >"$WORK/replay.py" <<'PY'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace", newline="").read()
# Drop script(1)'s "Script started" header and "Script done" footer lines.
data = data.split("\n", 1)[1].split("Script done", 1)[0]
line, col, snaps = [], 0, []
for tok in re.findall(r"\x1b\[[0-9;]*[A-Za-z]|\r|\n|.", data, re.S):
    if tok == "\r":
        snaps.append("".join(line)); col = 0
    elif tok == "\x1b[K":
        del line[col:]
    elif tok.startswith("\x1b"):
        pass
    elif tok == "\n":
        line, col = [], 0
    else:
        line[col:col + 1] = [tok]; col += 1
# The final clear starts with \r, so the last snapshot is the last frame.
print(snaps[-1] if snaps else "")
PY

# The gum backend's spinner is plain bash and never calls gum, but ui.sh only
# loads that backend when a `gum` binary exists, so a no-op stand-in is enough.
mkdir "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/gum"
chmod +x "$WORK/bin/gum"
export PATH="$PATH:$WORK/bin"

run_backend() {
    local backend="$1" out="$WORK/$1.typescript"
    UI_BACKEND="$backend" UI_DEMO=0 script -qfec \
        "source '$REPO_ROOT/scripts/lib/ui.sh'; _render_spin 'Requesting certificates...' bash '$WORK/stub.sh'" \
        "$out" </dev/null >/dev/null 2>&1
    python3 -I "$WORK/replay.py" "$out"
}

for backend in fallback gum; do
    # When the spinner repaints afterwards.
    last_frame="$(run_backend "$backend")"

    # Then the last frame still shows the title.
    assert_contains "$last_frame" "Requesting certificates..." \
        "$backend: spinner frame shows the title"
    # And the prompt text is no longer behind it
    assert_not_contains "$last_frame" "password for" \
        "$backend: repaint clears tty text left behind the title"
done

scenario_end "$CURRENT_SCENARIO"
summary
