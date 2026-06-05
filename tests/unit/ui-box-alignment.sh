#!/usr/bin/env bash
# tests/unit/ui-box-alignment.sh
#
# Regression for F-005. _ui_strip_ansi (scripts/lib/ui_fallback.sh) was a silent
# no-op due to three independent bugs: (1) the CSI introducer was written as the
# regex '\\[' (a literal backslash) instead of '\['; (2) under non-C locales the
# CSI byte-range classes [ -/] and [@-~] do not match via bash =~; and (3) the
# match was removed with "${var/${BASH_REMATCH[0]}/}", a glob replacement that
# does not delete a string containing '['. The result: _ui_visible_len returned
# raw byte length INCLUDING escape codes, so ui_box under-padded coloured content
# rows and the right border was inset by the escape-code byte count.
#
# These tests assert the strip actually works and that ui_kv boxes render every
# line at one visible width. Visible width is graded with an independent perl
# oracle so the function under test is not used to grade itself.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="ui-box-alignment"
echo -e "${CYAN}${BOLD}▶ scenario: ui-box-alignment${NC}"

# Force colour AND glyphs ON before sourcing. This test runs non-TTY with no
# UTF-8 locale guarantee, where term_caps.sh would otherwise blank the palette
# (no ANSI to strip) and pick ASCII box chars (the grep for │/╭/╰ below would
# find nothing) — making the F-005 assertions pass vacuously. The forces keep
# the coloured unicode render path under test. Must be set BEFORE the source:
# the palette and glyph vocabulary are frozen at source time.
export UI_FORCE_COLOR=1
export UI_FORCE_GLYPHS=1
# shellcheck source=../../scripts/lib/ui_fallback.sh
source "$REPO_ROOT/scripts/lib/ui_fallback.sh"

# Independent visible-width oracle (perl), not the function under test.
_oracle_len() { printf '%b' "$1" | perl -CS -pe 's/\e\[[0-9:;<=>?]*[ -\/]*[@-~]//g; s/\R//g' | perl -CS -ne 'print length'; }

BOLD_=$'\033[1m'; RESET_=$'\033[0m'; C256=$'\033[38;5;9m'

# --- _ui_strip_ansi actually strips ---
assert_eq "X"  "$(_ui_strip_ansi "${BOLD_}X${RESET_}")"                       "_ui_strip_ansi: SGR codes removed"
assert_eq "Y"  "$(_ui_strip_ansi "${C256}Y${RESET_}")"                        "_ui_strip_ansi: 256-colour codes removed"
assert_eq "AB" "$(_ui_strip_ansi "${C256}A${RESET_}${BOLD_}B${RESET_}")"      "_ui_strip_ansi: adjacent codes removed"
assert_eq "plain" "$(_ui_strip_ansi 'plain')"                                 "_ui_strip_ansi: plain text unchanged"

# --- _ui_visible_len counts visible characters, not bytes ---
assert_eq "29" "$(_ui_visible_len "  ${BOLD_}$(printf '%-18s' Hostname)${RESET_} mediabox")" "_ui_visible_len: ignores escape codes"
assert_eq "4"  "$(_ui_visible_len 'café')"                                    "_ui_visible_len: multibyte counted as characters"

# Locale-collation guard: the bug only reproduces under a non-C-collation locale
# (the CSI ranges [ -/]/[@-~] fail to match), which is exactly what the function's
# `local LC_ALL=C` defends against. Run the strip under a real non-C UTF-8 locale
# so this test would FAIL if someone removed that line — otherwise it could pass
# vacuously on a C-locale host/runner. Skip cleanly if no such locale is installed.
_utf8_locale="$(locale -a 2>/dev/null | grep -iE 'utf-?8' | grep -ivE '^(C|POSIX|c\.utf)' | grep -iE '^[a-z]{2}_' | head -1)"
if [[ -n "$_utf8_locale" ]]; then
    assert_eq "3" "$(export LC_ALL="$_utf8_locale"; _ui_visible_len "$(printf '\033[1mABC\033[0m')")" \
        "_ui_strip_ansi: strips ANSI under non-C locale ${_utf8_locale} (LC_ALL=C guard)"
else
    skip "_ui_strip_ansi: non-C UTF-8 locale guard (no non-C UTF-8 locale installed)"
fi

# --- ui_box + ui_kv: every rendered line is one visible width ---
box="$(_ui_box_impl 'Detected your system' \
    "$(_ui_kv_impl 'Hostname' 'mediabox')" \
    "$(_ui_kv_impl 'OS' 'Debian GNU/Linux 13 (trixie)')" \
    "$(_ui_kv_impl 'Timezone' 'Etc/UTC')")"
widths="$(printf '%s\n' "$box" | grep -E '│|╭|╰' | while IFS= read -r l; do _oracle_len "$l"; echo; done | sort -u)"
distinct="$(printf '%s\n' "$widths" | grep -c .)"
assert_eq "1" "$distinct" "ui_box+ui_kv: all box lines render at one visible width (F-005)"

echo -e "${CYAN}◀ ui-box-alignment done${NC}"
summary
