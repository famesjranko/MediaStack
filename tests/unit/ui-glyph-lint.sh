#!/usr/bin/env bash
# tests/unit/ui-glyph-lint.sh
#
# Static completeness guard for the terminal-capability series. Every structural
# glyph the product prints (box-drawing, the █░ bar, the braille spinner, the
# ✓/✗ status icons) MUST come from term_caps.sh's _G_* vocabulary so it degrades
# to ASCII on a non-UTF-8 locale or the bare Linux console. A raw glyph literal
# in an output line bypasses the gate and mojibakes — this test fails on any.
#
# Scope: all tracked product shell (scripts/**, mediastack, setup.sh). Comment
# lines are ignored. One file is allowed to hold raw structural glyphs:
#   - scripts/lib/term_caps.sh : defines the _G_* vocabulary itself.
# (reboot.sh's login banner — baked into /etc/profile.d at write time, run
#  outside the MediaStack process where term_caps is unavailable — was made
#  unconditionally ASCII, so it is no longer exempt.)
#
# NOTE: this guards STRUCTURAL glyphs only — prose symbols (→ • — …) are
# ASCII-ified in the sweep but are not enforced here.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-glyph-lint"
scenario_begin "$CURRENT_SCENARIO"

# Byte-exact glyph match (grep -F), so this is locale-independent.
GLYPHS=(─ ═ │ ║ ╔ ╗ ╚ ╝ ╭ ╮ ╰ ╯ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ █ ░ ✓ ✗ ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
GREP_ARGS=()
for g in "${GLYPHS[@]}"; do GREP_ARGS+=(-e "$g"); done

ALLOW=" scripts/lib/term_caps.sh "

cd "$REPO_ROOT" || exit 1
# Via a temp file, not a pipeline: a subshell would hide a nonzero git exit
# behind a partial list, and the two literals below would keep the population
# looking non-empty.
discover_out=$(mktemp) || exit 1
trap 'rm -f "$discover_out"' EXIT
if git ls-files scripts >"$discover_out" 2>/dev/null; then
    pass "tracked script discovery ran"
else
    fail "tracked script discovery ran" "git ls-files scripts exited nonzero"
fi
mapfile -t script_files < <(grep -E '\.sh$' "$discover_out")

# Fail closed: with an empty scripts/ population this lints two files and
# reports success over the whole product surface.
if ((${#script_files[@]} > 0)); then
    pass "scripts/ shell population is non-empty (${#script_files[@]} files)"
else
    fail "scripts/ shell population is non-empty" "git ls-files scripts matched no .sh files"
fi

mapfile -t files < <(printf '%s\n' "${script_files[@]+"${script_files[@]}"}" mediastack setup.sh | sort -u)

violations=()
for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    case "$ALLOW" in *" $f "*) continue ;; esac
    # structural glyph in a NON-comment line
    while IFS= read -r hit; do
        [[ -n "$hit" ]] && violations+=("$f:$hit")
    done < <(grep -nF "${GREP_ARGS[@]}" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')
done

if ((${#violations[@]} == 0)); then
    pass "no raw structural glyph literals in product output (all routed via _G_*)"
else
    fail "raw structural glyph literals bypass the ASCII fallback" "${#violations[@]} line(s)"
    printf '      %s\n' "${violations[@]}" >&2
fi

summary
