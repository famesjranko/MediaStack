#!/usr/bin/env bash
# tests/unit/apt-noninteractive.sh
#
# Repo-wide guard: every `apt-get install` in the shipped scripts runs through
# MS_APT_INSTALL, and every remove or purge through MS_APT_REMOVE/MS_APT_PURGE
# (scripts/lib/apt.sh). A bare call lets a debconf dialog open behind ui_spin,
# which makes the install look hung.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="apt-noninteractive"
scenario_begin "$CURRENT_SCENARIO"

# Scan the production population unchanged: mediastack, setup.sh, and every
# scripts/**/*.sh except scripts/lib/apt.sh. Exclude real comments, literal
# quoted arguments to direct log_*/ui_log calls, and a complete quoted
# MS_APT_* array expansion. Double-quoted arguments with an unescaped $(...)
# or backtick substitution stay scanned because they execute. This is a
# line-oriented classifier for these boundaries, not a complete Bash parser.
# Output is file:line matches only.
_scan_apt_file() {
    local file="$1" grep_rc=0

    grep -nE 'apt(-get)?[[:space:]]+(install|remove|purge|upgrade|dist-upgrade|full-upgrade)' "$file" >/dev/null || grep_rc=$?
    if ((grep_rc != 0 && grep_rc != 1)); then
        printf 'ERROR: apt guard grep failed for %s (exit %s)\n' "$file" "$grep_rc" >&2
        return "$grep_rc"
    fi

    python3 - "$file" <<'PY'
import re
import sys

COMMAND = re.compile(
    r"(?:^|[;&|()\s'\"`])(?:sudo\s+)?apt(?:-get)?\s+"
    r"(?:install|remove|purge|upgrade|dist-upgrade|full-upgrade)(?:\s|$)"
)
MESSAGE = re.compile(
    r"(?:^\s*|[;&|]\s*|&&\s*|\|\|\s*)"
    r"(?:log_[A-Za-z0-9_]+|ui_log(?:\s+[A-Za-z0-9_]+)?)\s*$"
)
SHARED_ARRAY = re.compile(r"^['\"]\$\{MS_APT_[A-Z0-9_]+\[@\]\}['\"]$")


def starts_comment(text: str, index: int) -> bool:
    """Return whether an unquoted # starts a Bash comment in supported syntax."""
    return index == 0 or text[index - 1].isspace() or text[index - 1] in ";|&()"


def has_executable_substitution(quoted: str) -> bool:
    """Return whether supported double-quoted text has an unescaped substitution."""
    index = 1
    while index < len(quoted) - 1:
        if quoted[index] == "\\":
            index += 2
            continue
        if quoted[index] == "`" or quoted[index : index + 2] == "$(":
            return True
        index += 1
    return False


def mask_non_code(text: str) -> str:
    """Blank comments and the narrow quoted content that is not executable."""
    masked = list(text)
    index = 0
    while index < len(text):
        if text[index] == "#" and starts_comment(text, index):
            masked[index:] = " " * (len(text) - index)
            break
        if text[index] not in "'\"":
            index += 1
            continue

        start = index
        quote = text[index]
        index += 1
        while index < len(text):
            if text[index] == "\\":
                index += 2
                continue
            if text[index] == quote:
                index += 1
                break
            index += 1
        quoted = text[start:index]
        prefix = text[:start]
        if SHARED_ARRAY.fullmatch(quoted) or (
            MESSAGE.search(prefix)
            and not (quote == '"' and has_executable_substitution(quoted))
        ):
            masked[start:index] = " " * (index - start)
    return "".join(masked)


path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    physical = source.readlines()

line_number = 1
while line_number <= len(physical):
    start = line_number
    logical = physical[line_number - 1].rstrip("\n")
    while logical.rstrip().endswith("\\") and line_number < len(physical):
        logical = logical.rstrip()[:-1] + " " + physical[line_number].rstrip("\n")
        line_number += 1
    if COMMAND.search(mask_non_code(logical)):
        print(f"{path}:{start}")
    line_number += 1
PY
}

_bare_calls() {
    local root files_text find_rc=0
    local -a files=()

    if (($# == 0)); then
        root="$REPO_ROOT"
    elif [[ "$1" == "--root" && $# == 2 ]]; then
        root="$2"
    else
        files=("$@")
    fi

    if [[ -n "${root:-}" ]]; then
        files_text=$(find "$root/scripts" -name '*.sh' ! -path "$root/scripts/lib/apt.sh") || find_rc=$?
        if ((find_rc != 0)); then
            printf 'ERROR: apt guard discovery failed for %s (exit %s)\n' "$root/scripts" "$find_rc" >&2
            return "$find_rc"
        fi
        mapfile -t files <<<"$files_text"
        files=("$root/mediastack" "$root/setup.sh" "${files[@]}")
    fi

    local file
    for file in "${files[@]}"; do
        _scan_apt_file "$file" || return $?
    done
}

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FIXTURE="$TMP_ROOT/fixture"
mkdir -p "$FIXTURE/scripts/lib"
touch "$FIXTURE/mediastack" "$FIXTURE/setup.sh"
printf '%s\n' 'apt-get install shared-prefix-package' >"$FIXTURE/scripts/lib/apt.sh"
printf '%s\n' \
    '# apt-get install comment-package' \
    'apt-get install -y foo || log_warn "x"' \
    'MS_APT_INSTALL foo; apt-get install bar' \
    'apt-get purge foo && ui_log info "done"' \
    'apt install alternate-package' \
    'sudo apt-get install sudo-package' \
    "apt-get \\" \
    '    install continued-package' \
    "bash -c 'MS_APT_NOTE=hint; apt-get install quoted-command-package'" \
    "bash -c 'apt-get install direct-quoted-command-package'" \
    'log_info "$(apt-get install substitution-package)"' \
    'log_info "backtick `apt-get install backtick-substitution-package`"' \
    'printf %s foo#bar; apt-get install hash-word-package' >"$FIXTURE/scripts/cases.sh"
printf '%s\n' 'log_info "run: apt-get install message-package"' >"$FIXTURE/scripts/log-message.sh"
printf '%s\n' 'ui_log warn "apt-get install failed"' >"$FIXTURE/scripts/ui-message.sh"
printf '%s\n' \
    'log_info "literal \$(apt-get install escaped-dollar-package)"' \
    'log_info "literal \`apt-get install escaped-backtick-package\`"' >"$FIXTURE/scripts/escaped-message.sh"
printf '%s\n' '"${MS_APT_INSTALL[@]}" array-package' >"$FIXTURE/scripts/prefix.sh"

# Given real calls alongside each allowed exclusion,
# When the fixture root is scanned,
# Then only executable apt calls are reported as file:line matches.
run_cmd _bare_calls --root "$FIXTURE"
assert_rc "0" "fixture guard scan succeeds"
expected="$FIXTURE/scripts/cases.sh:2
$FIXTURE/scripts/cases.sh:3
$FIXTURE/scripts/cases.sh:4
$FIXTURE/scripts/cases.sh:5
$FIXTURE/scripts/cases.sh:6
$FIXTURE/scripts/cases.sh:7
$FIXTURE/scripts/cases.sh:9
$FIXTURE/scripts/cases.sh:10
$FIXTURE/scripts/cases.sh:11
$FIXTURE/scripts/cases.sh:12
$FIXTURE/scripts/cases.sh:13"
assert_eq "$expected" "$OUT" "fixture guard catches executable calls and literal exclusions"
assert_not_contains "$OUT" "log-message.sh" "quoted log message is excluded"
assert_not_contains "$OUT" "ui-message.sh" "quoted ui_log message is excluded"
assert_not_contains "$OUT" "escaped-message.sh" "escaped message substitutions are excluded"
assert_not_contains "$OUT" "prefix.sh" "quoted MS_APT_ array use is excluded"
assert_not_contains "$OUT" "apt.sh" "shared apt prefix file is excluded"

# Given a direct file list,
# When a fixture with real calls is scanned,
# Then it reports the same file:line matches without discovery.
run_cmd _bare_calls "$FIXTURE/scripts/cases.sh"
assert_rc "0" "file-list guard scan succeeds"
assert_eq "$expected" "$OUT" "file-list guard catches every executable fixture call"

FAKE_BIN="$TMP_ROOT/fake-bin"
mkdir "$FAKE_BIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$FAKE_BIN/find"
chmod +x "$FAKE_BIN/find"

# Given discovery fails,
# When the fixture root is scanned,
# Then the guard fails instead of treating the result as empty.
OUT=$(PATH="$FAKE_BIN:$PATH" _bare_calls --root "$FIXTURE" 2>&1)
RC=$?
assert_rc "2" "find error fails the guard"
assert_contains "$OUT" "discovery failed" "find error is reported"

printf '%s\n' '#!/usr/bin/env bash' 'exit 2' >"$FAKE_BIN/grep"
chmod +x "$FAKE_BIN/grep"

# Given the scanner fails,
# When an explicit fixture file is scanned,
# Then the guard fails instead of treating the result as empty.
OUT=$(PATH="$FAKE_BIN:$PATH" _bare_calls "$FIXTURE/scripts/cases.sh" 2>&1)
RC=$?
assert_rc "2" "grep error fails the guard"
assert_contains "$OUT" "grep failed" "grep error is reported"

# Given every shipped script that changes packages,
# When searched for an apt install, remove, or purge outside the shared prefixes,
# Then none exists.
run_cmd _bare_calls
assert_rc "0" "real-tree guard scan succeeds"
assert_eq "" "$OUT" "no script runs apt commands without the MS_APT_* prefixes"

# Given the shared prefixes,
# When their words are read,
# Then each is non-interactive, and install adds conffile defaults.
source "$REPO_ROOT/scripts/lib/apt.sh"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold" \
    "${MS_APT_INSTALL[*]}" "MS_APT_INSTALL: non-interactive with conffile defaults"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq" "${MS_APT_REMOVE[*]}" "MS_APT_REMOVE: non-interactive"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq" "${MS_APT_PURGE[*]}" "MS_APT_PURGE: non-interactive"

scenario_end "$CURRENT_SCENARIO"
summary
