# =============================================================================
# MediaStack terminal-capability detection (single source of truth)
# =============================================================================
# Decides whether the current terminal can render ANSI colour (and, from PR-B
# onward, unicode glyphs). Both scripts/lib/common.sh and scripts/lib/ui-render-fallback.sh
# source this file and gate their own palettes on the predicates here, so the
# decision lives in exactly one place.
#
# Zero external dependencies beyond bash 4+. Safe to source under
# `set -euo pipefail`:
#   - every predicate is only ever CALLED inside a conditional (a bare
#     `_color_enabled` as a statement would abort under `set -e` when it
#     returns 1), and
#   - every environment read uses a `${VAR:-}` / `${VAR+x}` default so an unset
#     var never trips `set -u`.
#
# Include-guarded: common.sh + ui-render-fallback.sh (via ui.sh) both source it during
# a single `./setup.sh`, so it is sourced 2-3 times per process.

[[ -n "${_TERM_CAPS_SOURCED:-}" ]] && return 0
_TERM_CAPS_SOURCED=1

# _color_enabled — true (0) when ANSI colour escapes should be emitted.
#
# Disabled when output is being captured (so a user who pipes the installer to
# `tee setup.log` or redirects it for a bug report gets clean text, not escape
# soup), or when the environment asks for no colour. Gated on BOTH stdout and
# stderr because banners/boxes go to stdout while log lines go to stderr — a
# single palette cannot colour-per-stream, so if either is redirected we drop
# colour rather than leak half-coloured output into a captured file.
#
# Honoured signals (first match wins):
#   UI_FORCE_COLOR / FORCE_COLOR  set -> force colour ON  (demo, screenshots)
#   NO_COLOR                      set -> colour OFF        (any value, incl. "")
#   stdout or stderr not a TTY         -> colour OFF
#   TERM empty or "dumb"               -> colour OFF
_color_enabled() {
    [[ -n "${UI_FORCE_COLOR:-}${FORCE_COLOR:-}" ]] && return 0
    [[ -n "${NO_COLOR+x}" ]] && return 1
    [[ ! -t 1 || ! -t 2 ]] && return 1
    case "${TERM:-}" in
        '' | dumb) return 1 ;;
    esac
    return 0
}

# _glyphs_enabled — true (0) when unicode box-drawing / icons / spinner / bar
# should be emitted; false -> ASCII fallbacks.
#
# The wizard leans on ═╔╗ boxes, a braille spinner, a █░ bar and ✓✗•→ icons.
# Two real environments cannot render these and would show mojibake:
#   - a non-UTF-8 locale (LANG=C / unset — common on minimal/netinst Debian),
#     where every multi-byte glyph is decoded byte-by-byte, and
#   - the bare Linux VT console (TERM=linux), whose default font ships box
#     drawing but commonly lacks ✓ (U+2713) / ✗ (U+2717).
# Both are most likely at the physical console during first install — exactly
# where ASCII is safest. The two conditions are independent AND-gates, so a
# UTF-8 tmux/xterm renders glyphs while a UTF-8 bare console does not.
#
# Honoured signals (first match wins):
#   UI_FORCE_GLYPHS  set -> glyphs ON  (demo, screenshots)
#   UI_ASCII         set -> glyphs OFF (force the fallback, e.g. for tests)
#   locale not UTF-8      -> glyphs OFF
#   TERM linux/dumb/empty -> glyphs OFF
_glyphs_enabled() {
    [[ -n "${UI_FORCE_GLYPHS:-}" ]] && return 0
    [[ -n "${UI_ASCII:-}" ]] && return 1
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
        *[Uu][Tt][Ff]8* | *[Uu][Tt][Ff]-8*) ;; # en_US.UTF-8 / utf8 / C.UTF-8
        *) return 1 ;;
    esac
    case "${TERM:-}" in
        '' | dumb | linux) return 1 ;;
    esac
    return 0
}

# --- Glyph vocabulary -------------------------------------------------------
# Frozen once, here, from _glyphs_enabled (env is stable for a run). Box/bar/
# spinner values are SINGLE characters because the renderers use them as
# repeat/fill units; multi-char tokens (arrow, bullet, status tags) are only
# ever placed inline, never repeated, so they cannot break width math.
if _glyphs_enabled; then
    _G_UNICODE=1
    _G_H='─'
    _G_V='│'
    _G_TL='╭'
    _G_TR='╮'
    _G_BL='╰'
    _G_BR='╯' # light box
    _G_DH='═'
    _G_DV='║'
    _G_DTL='╔'
    _G_DTR='╗'
    _G_DBL='╚'
    _G_DBR='╝' # double box (banner)
    _G_BAR_FILL='█'
    _G_BAR_EMPTY='░'
    _G_CHECK='✓'
    _G_CROSS='✗' # status icons (prose →/•/— are ASCII-ified, not gated)
    _G_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
else
    _G_UNICODE=0
    _G_H='-'
    _G_V='|'
    _G_TL='+'
    _G_TR='+'
    _G_BL='+'
    _G_BR='+'
    _G_DH='='
    _G_DV='|'
    _G_DTL='+'
    _G_DTR='+'
    _G_DBL='+'
    _G_DBR='+'
    _G_BAR_FILL='#'
    _G_BAR_EMPTY='.'
    _G_CHECK='+'
    _G_CROSS='x'
    _G_SPIN=('|' '/' '-' '\')
fi

# --- ANSI color palette (shared by all rendering backends) ------------------
# Frozen here at source time. Both ui-render-fallback.sh and ui-render-gum.sh
# source term-caps.sh, so defining the palette here makes it available to any
# code regardless of which backend is active.
if _color_enabled; then
    _UI_RESET='\033[0m'
    _UI_BOLD='\033[1m'
    _UI_RED='\033[0;31m'
    _UI_GREEN='\033[0;32m'
    _UI_YELLOW='\033[1;33m'
    _UI_BLUE='\033[0;94m'
    _UI_CYAN='\033[0;36m'
    _UI_GRAY='\033[0;90m'
else
    _UI_RESET='' _UI_BOLD='' _UI_RED='' _UI_GREEN='' _UI_YELLOW='' _UI_BLUE='' _UI_CYAN='' _UI_GRAY=''
fi

# _ui_status_token — the leading marker for a log line, unified across the
# wizard (ui_log) and the configure-time helpers (common.sh log_*). In glyph
# mode it is the icon (✓ ! ✗ • →); in ASCII mode it is the bracket tag
# ([OK]/[WARN]/[ERROR]/[INFO]/[SKIP]) — byte-identical to the historical
# configure.sh output, so the degraded surface is exactly today's look.
_ui_status_token() { # $1 = level
    if [[ "$_G_UNICODE" == 1 ]]; then
        case "$1" in
            ok) printf '✓' ;; warn) printf '!' ;; error) printf '✗' ;;
            info) printf '•' ;; skip) printf '→' ;; *) printf ' ' ;;
        esac
    else
        case "$1" in
            ok) printf '[OK]' ;; warn) printf '[WARN]' ;; error) printf '[ERROR]' ;;
            info) printf '[INFO]' ;; skip) printf '[SKIP]' ;; *) printf '[*]' ;;
        esac
    fi
}

# _g_repeat <width> <char> — emit <char> repeated <width> times. For horizontal
# rules / box borders drawn OUTSIDE the ui_render_fallback layer (configure.sh,
# stack.sh, stage2.sh etc., which source common.sh but not ui.sh). Uses a gated
# _G_* char so the rule degrades to ASCII with everything else.
_g_repeat() { # $1 = width, $2 = char (default _G_H)
    local n="${1:-0}" ch="${2:-$_G_H}" out="" i
    for ((i = 0; i < n; i++)); do out+="$ch"; done
    printf '%s' "$out"
}
