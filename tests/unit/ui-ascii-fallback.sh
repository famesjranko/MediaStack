#!/usr/bin/env bash
# tests/unit/ui-ascii-fallback.sh
#
# Proves the unicode-capability gate (scripts/lib/term-caps.sh:_glyphs_enabled)
# degrades the whole TUI to ASCII when the terminal cannot render glyphs — a
# non-UTF-8 locale (LANG=C, common on minimal/netinst Debian) or the bare Linux
# console (TERM=linux) — so a first-time installer never sees mojibake.
#
# Two halves:
#   1. ASCII mode (UI_ASCII=1): render EVERY ui_* primitive + every log level +
#      the spinner frames + status tokens, and assert the captured output has
#      ZERO bytes > 0x7F. This is the completeness guarantee — if any primitive
#      still emitted a raw glyph, this fails.
#   2. Glyph mode (UI_FORCE_GLYPHS=1): assert the same render DOES contain
#      unicode, proving the gate actually flips (and glyph mode still works).
# Plus: the unified status token is the bracket tag in ASCII, the icon in glyph.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ui-ascii-fallback"
scenario_begin "$CURRENT_SCENARIO"

UI="$REPO_ROOT/scripts/lib/ui.sh"
COMMON="$REPO_ROOT/scripts/lib/common.sh"

# Exercises every glyph-bearing primitive. Message text is deliberately ASCII so
# the ONLY way a non-ASCII byte appears is a primitive that didn't degrade.
SNIP='
ui_banner "MediaStack Setup" "Turnkey Media Server";
ui_box "Detected your system" "$(ui_kv Hostname mediabox)" "$(ui_kv OS Debian13)";
ui_divider "Storage"; ui_divider;
ui_progress 3 9 "Configuring";
ui_log ok okmsg; ui_log warn warnmsg; ui_log error errmsg; ui_log info infomsg; ui_log skip skipmsg;
log_ok okmsg; log_info infomsg; log_skip skipmsg;
printf "spin:%s\n" "${_G_SPIN[*]}";
printf "tok:%s|%s|%s|%s|%s\n" "$(_ui_status_token ok)" "$(_ui_status_token warn)" "$(_ui_status_token error)" "$(_ui_status_token info)" "$(_ui_status_token skip)"
'

# Render SNIP in a clean non-TTY subprocess (so colour is off -> output is plain
# text and easy to match) with the given forcing env applied.
_render() { # $1 = space-separated env assignments; $2 = snippet
    local -a base=(-u UI_FORCE_GLYPHS -u UI_ASCII -u UI_FORCE_COLOR -u FORCE_COLOR -u NO_COLOR TERM=xterm)
    local -a extra
    read -ra extra <<<"$1"
    env "${base[@]}" "${extra[@]}" bash -c "source '$UI'; source '$COMMON'; $2" 2>&1
}

# True (0) if any byte > 0x7F is present (LC_ALL=C makes the class byte-wise).
_has_non_ascii() { LC_ALL=C grep -qP '[^\x00-\x7F]' <<<"$1"; }

# --- 1. ASCII mode: pure ASCII out of every primitive ---
ascii_out=$(_render "UI_ASCII=1" "$SNIP")
if _has_non_ascii "$ascii_out"; then
    fail "ASCII mode: every primitive renders pure ASCII (no byte >0x7F)" \
        "non-ASCII byte leaked: $(LC_ALL=C grep -aoP '[^\x00-\x7F]' <<<"$ascii_out" | sort -u | tr -d '\n')"
else
    pass "ASCII mode: every primitive renders pure ASCII (no byte >0x7F)"
fi
assert_contains "$ascii_out" "tok:[OK]|[WARN]|[ERROR]|[INFO]|[SKIP]" "ASCII mode: status tokens are bracket tags"
assert_contains "$ascii_out" "spin:| / - \\" "ASCII mode: spinner frames are ASCII"
assert_contains "$ascii_out" "[OK] okmsg" "ASCII mode: log_ok keeps the historical [OK] tag (degraded == today)"

# --- 2. Glyph mode: the gate flips back to unicode ---
glyph_out=$(_render "UI_FORCE_GLYPHS=1" "$SNIP")
if _has_non_ascii "$glyph_out"; then
    pass "glyph mode: unicode glyphs ARE emitted when forced (gate flips)"
else
    fail "glyph mode: unicode glyphs ARE emitted when forced (gate flips)" "no glyph found"
fi
assert_contains "$glyph_out" "tok:✓|!|✗|•|→" "glyph mode: status tokens are icons"
assert_contains "$glyph_out" "╭" "glyph mode: box uses a unicode corner"

# --- 3. Same vocabulary across ui_log and common.sh log_* (no clashing languages) ---
# In glyph mode both surfaces use the ✓ icon; in ASCII both use [OK].
assert_contains "$ascii_out" "[OK] okmsg" "ASCII: ui_log + log_* share the bracket tag"
if [[ "$glyph_out" == *"✓ okmsg"* ]]; then
    pass "glyph: ui_log + log_* share the ✓ icon"
else
    fail "glyph: ui_log + log_* share the ✓ icon" "✓ okmsg not found"
fi

summary
