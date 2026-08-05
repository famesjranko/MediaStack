# =============================================================================
# MediaStack UI — pure bash rendering backend
# =============================================================================
# Implements all _render_* primitives using ANSI escape codes and unicode.
# Zero external dependencies beyond bash 4+ (term-caps.sh is an internal sibling).
#
# This is one concrete backend for ui.sh's backend abstraction. Sourced by ui.sh
# via _ui_select_backend() — do not source directly in application code.
# Orchestration (demo mode, retry loops, non-TTY handling) lives in ui.sh.

# Terminal-capability detection — colour gating lives in one place (term-caps.sh).
# Resolve via BASH_SOURCE: this file may be sourced standalone by unit tests where
# $SCRIPT_DIR is the test dir, not the lib dir.
_UI_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=term-caps.sh
source "$_UI_TC_DIR/term-caps.sh"

_UI_FRAME_WIDTH=46

# --- Drawing utilities (private, not part of the backend contract) ---

_ui_repeat_char() {
    local count="${1:-0}" char="${2:- }" out="" i
    for ((i = 0; i < count; i++)); do out+="$char"; done
    printf '%s' "$out"
}

_ui_spaces() {
    _ui_repeat_char "${1:-0}" " "
}

_ui_strip_ansi() {
    # Strip ANSI/CSI escape sequences so width math measures only visible text.
    # Three things this must get right (all were previously broken, which made
    # this a silent no-op and left every coloured box mis-padded by the byte
    # length of its escape codes):
    #   1. The CSI introducer is ESC '[' — match it as $'\033' + '\[' (a single
    #      backslash escaping the bracket). The old '\\[' required a literal
    #      backslash after ESC, which never occurs, so nothing ever matched.
    #   2. Force C collation: under some UTF-8 locales the CSI byte-range classes
    #      [ -/] and [@-~] do not match via bash =~, so even a correct pattern
    #      strips nothing. LC_ALL=C makes the ranges ASCII-deterministic.
    #   3. Remove each match by literal split, not "${var/${BASH_REMATCH[0]}/}":
    #      the matched sequence contains '[', a glob metacharacter, so the
    #      replacement form does not delete it reliably.
    local text="$1"
    local LC_ALL=C
    local ansi_re=$'\033''\[[0-9:;<=>?]*[ -/]*[@-~]'
    local out="" m
    while [[ "$text" =~ $ansi_re ]]; do
        m="${BASH_REMATCH[0]}"
        out+="${text%%"$m"*}"
        text="${text#*"$m"}"
    done
    printf '%s%s' "$out" "$text"
}

_ui_visible_len() {
    local stripped
    stripped=$(_ui_strip_ansi "$1")
    printf '%s' "${#stripped}"
}

_ui_center_text() {
    local text="$1" width="$2"
    local len left right
    len=$(_ui_visible_len "$text")
    if ((len >= width)); then
        printf '%s' "$text"
        return
    fi
    left=$(((width - len) / 2))
    right=$((width - len - left))
    printf '%s%s%s' "$(_ui_spaces "$left")" "$text" "$(_ui_spaces "$right")"
}

# --- Render primitives (the backend contract) ---

_render_banner() {
    local title="${1:-MediaStack}"
    local subtitle="${2:-Turnkey Media Server for Home Networks}"
    local width="$_UI_FRAME_WIDTH"
    local _tlen _slen
    _tlen=$(_ui_visible_len "$title")
    _slen=$(_ui_visible_len "$subtitle")
    ((_tlen > width)) && width=$_tlen
    ((_slen > width)) && width=$_slen

    local title_line sub_line border
    title_line=$(_ui_center_text "$title" "$width")
    sub_line=$(_ui_center_text "$subtitle" "$width")
    border=$(_ui_repeat_char "$width" "$_G_DH")

    echo ""
    echo -e "  ${_UI_CYAN}${_G_DTL}${border}${_G_DTR}${_UI_RESET}"
    echo -e "  ${_UI_CYAN}${_G_DV}${_UI_RESET}${_UI_BOLD}${title_line}${_UI_RESET}${_UI_CYAN}${_G_DV}${_UI_RESET}"
    echo -e "  ${_UI_CYAN}${_G_DV}${_UI_RESET}${sub_line}${_UI_CYAN}${_G_DV}${_UI_RESET}"
    echo -e "  ${_UI_CYAN}${_G_DBL}${border}${_G_DBR}${_UI_RESET}"
    echo ""
}

_render_section() {
    echo ""
    # Bare header form: `ui_section "Title"` (one arg) prints just the styled
    # title with no [N/M] counter — for non-sequential sections where a counter
    # would lie about progress. Branch on arg count BEFORE referencing $2/$3.
    if [[ $# -eq 1 ]]; then
        echo -e "  ${_UI_CYAN}${_UI_BOLD}${1}${_UI_RESET}"
        return
    fi
    local step="$1" total="$2" title="$3"
    if [[ "$total" -gt 0 ]]; then
        echo -e "  ${_UI_CYAN}${_UI_BOLD}[$step/$total] $title${_UI_RESET}"
    else
        echo -e "  ${_UI_CYAN}${_UI_BOLD}Step $step: $title${_UI_RESET}"
    fi
}

_render_log() {
    local level="$1"
    shift
    local msg="$*"
    local color icon

    case "$level" in
        ok) color="$_UI_GREEN" ;;
        warn) color="$_UI_YELLOW" ;;
        error) color="$_UI_RED" ;;
        info) color="$_UI_BLUE" ;;
        skip) color="$_UI_GRAY" ;;
        *) color="$_UI_GRAY" ;;
    esac
    # Unified marker: glyph (✓/!/✗/•/→) when the terminal can render it, else the
    # ASCII bracket tag ([OK]/...). Same vocabulary as common.sh log_*, so a single
    # run never mixes glyph and bracket "languages".
    icon=$(_ui_status_token "$level")

    # Write to stderr so log output stays visible when the caller is inside
    # a command substitution (e.g. validators run inside ui_input_validated
    # would otherwise swallow the ui_log warn/info that explains the prompt).
    echo -e "  ${color}${_UI_BOLD}${icon}${_UI_RESET} $msg" >&2
}

_render_spin_demo() {
    # Show spinner animation for demo mode (no command executed).
    # Called by ui.sh's ui_spin/ui_spin_fg when UI_DEMO=1; the delay
    # duration is passed in so the backend stays unaware of UI_DEMO_DELAY.
    local title="$1" delay="${2:-0}"
    local frames=("${_G_SPIN[@]}")
    local frame_count=${#frames[@]}
    local delay_int="${delay%.*}"
    local cycles=$((${delay_int:-0} * 12 + 6))
    local i=0
    while ((i < cycles)); do
        echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
        sleep 0.08 2>/dev/null || sleep 1
        ((i++)) || true
    done
    echo -ne "\r\033[K"
}

_render_spin() {
    local title="$1"
    shift
    local frames=("${_G_SPIN[@]}")
    local frame_count=${#frames[@]}

    # The spinner owns the terminal line, so the wrapped command's stdout/stderr
    # must not print here — a chatty apt/dpkg run would collide with the \r
    # repaint and render as garbled fragments. Capture to a log; surface it only
    # if the command fails (below), where the output is actually useful.
    local _log
    _log=$(mktemp 2>/dev/null) || _log=/dev/null

    "$@" >"$_log" 2>&1 &
    local pid=$!
    local i=0

    # Save the caller's INT/TERM disposition so this transient spinner trap does
    # not permanently clobber it — `trap - INT TERM` resets to bash *default*,
    # which would silently wipe setup.sh's interrupt-reassurance handler for
    # everything after the first spinner. Restore it on the way out instead.
    local _interrupted=0 _prev_int _prev_term
    _prev_int="$(trap -p INT)"
    _prev_term="$(trap -p TERM)"
    # Detect Ctrl-C via a flag set IN the trap, not via the child's exit code:
    # bash runs background jobs with SIGINT ignored (no job control in scripts),
    # so the child never exits 130 on Ctrl-C — it's the trap's kill (SIGTERM=143)
    # that stops it. The flag is the only reliable interrupt signal.
    # $pid must bind now, not at signal time — single-quoting would defer it.
    # shellcheck disable=SC2064
    trap "_interrupted=1; kill $pid 2>/dev/null; echo -ne '\r\033[K'" INT
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; echo -ne '\r\033[K'" TERM

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
        sleep 0.08 2>/dev/null || sleep 1
        ((i++)) || true
    done

    wait "$pid"
    local rc=$?
    trap - INT TERM
    [[ -n "$_prev_int" ]] && eval "$_prev_int"
    [[ -n "$_prev_term" ]] && eval "$_prev_term"
    echo -ne "\r\033[K"
    # Ctrl-C: re-raise so the caller's INT handler (setup.sh's _setup_on_interrupt
    # / the launcher's exit) runs, instead of the caller treating the killed child
    # as a plain failure and "falling back" through the interrupt.
    if ((_interrupted)); then
        [[ "$_log" != /dev/null ]] && rm -f "$_log"
        kill -INT "$$" 2>/dev/null
        return 130
    fi
    # On failure, surface the captured output so the caller's "Failed to..."
    # message has the real error under it.
    if ((rc != 0)) && [[ -s "$_log" ]]; then
        tail -n 20 "$_log" >&2
    fi
    [[ "$_log" != /dev/null ]] && rm -f "$_log"
    return "$rc"
}

_render_spin_fg() {
    local title="$1"
    shift
    local frames=("${_G_SPIN[@]}")
    local frame_count=${#frames[@]}

    (
        trap 'exit 0' TERM INT
        local i=0
        # Self-terminate if the parent shell dies (e.g. Ctrl-C fires the caller's
        # INT trap and it exits before we reach the kill below) so the spinner
        # can never orphan and spam the terminal. $$ is the parent shell PID.
        while kill -0 "$$" 2>/dev/null; do
            echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
            sleep 0.08 2>/dev/null || sleep 1
            ((i++)) || true
        done
    ) &
    local spinner_pid=$!

    "$@"
    local rc=$?

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    echo -ne "\r\033[K"
    return "$rc"
}

_render_input() {
    local prompt="${1:-Input}" default="${2:-}"
    local _hint="$default"
    [[ -n "$default" ]] && _hint="$default - press Enter"
    local result=""
    # Return exit 3 on EOF so the orchestrator (ui.sh) can gate SIGTERM on ! -t 0.
    if ! read -rp "  $prompt [$_hint]: " result; then
        return 3
    fi
    echo "${result:-$default}"
}

_render_password() {
    local prompt="${1:-Password}" default="${2:-}"
    local result=""
    if ! read -rsp "  $prompt: " result; then
        echo "" >&2
        return 3
    fi
    echo "" >&2
    echo "${result:-$default}"
}

_render_confirm() {
    # $1 prompt, $2 default (yes|no), $3 hint (Y/n or y/N)
    local prompt="$1" default="$2" hint="$3"
    local result=""
    if ! read -rp "  $prompt [$hint - press Enter]: " result; then
        return 3 # EOF
    fi
    result="${result:-$default}"
    case "${result,,}" in
        y | yes) return 0 ;;
        n | no) return 1 ;;
        *) return 2 ;; # unrecognised — orchestrator re-prompts or uses default
    esac
}

_render_box() {
    local title="$1"
    shift
    local content=("$@")

    # Auto-size: find longest line (title + 1 for leading space, or content + 2 for indent)
    local inner_width
    inner_width=$(($(_ui_visible_len "$title") + 2))
    for line in "${content[@]}"; do
        local line_width=$(($(_ui_visible_len "$line") + 4))
        ((line_width > inner_width)) && inner_width=$line_width
    done
    # Minimum width and add padding
    ((inner_width < 40)) && inner_width=40
    ((inner_width += 2))

    # NOTE: bash printf "%-Ns" pads to N bytes, not terminal-visible
    # characters. Multi-byte UTF-8 and ANSI styles break alignment. Measure
    # visible text after stripping ANSI, then append ASCII spaces explicitly.
    local _pad border padded_title empty_line padded_line
    border=$(_ui_repeat_char "$inner_width" "$_G_H")
    echo ""
    echo -e "  ${_UI_CYAN}${_G_TL}${border}${_G_TR}${_UI_RESET}"
    _pad=$((inner_width - $(_ui_visible_len " ${title}")))
    padded_title=" ${title}$(_ui_spaces "$_pad")"
    echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${_UI_BOLD}${padded_title}${_UI_RESET}${_UI_CYAN}${_G_V}${_UI_RESET}"
    empty_line=$(_ui_spaces "$inner_width")
    echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${empty_line}${_UI_CYAN}${_G_V}${_UI_RESET}"
    for line in "${content[@]}"; do
        _pad=$((inner_width - $(_ui_visible_len "  ${line}")))
        ((_pad < 0)) && _pad=0
        padded_line="  ${line}$(_ui_spaces "$_pad")"
        echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${padded_line}${_UI_CYAN}${_G_V}${_UI_RESET}"
    done
    echo -e "  ${_UI_CYAN}${_G_BL}${border}${_G_BR}${_UI_RESET}"
}

_render_kv() {
    local key="$1" value="$2"
    local _klen _pad
    _klen=$(_ui_visible_len "$key")
    # Pad keys to the widest one any ui_kv caller renders so every value column
    # aligns. Currently 20: 'Hardware transcoding' / 'Remote streaming cap'. Bump
    # this if a longer key is ever added (no caller passes a variable-length key).
    _pad=$((20 - _klen))
    ((_pad < 0)) && _pad=0
    echo -e "  ${_UI_BOLD}${key}$(_ui_spaces "$_pad")${_UI_RESET} ${value}"
}

_render_divider() {
    local title="${1:-}" width="$_UI_FRAME_WIDTH"
    echo ""
    if [[ -n "$title" ]]; then
        local rest=$((width - 4 - $(_ui_visible_len "$title"))) # "-- title " uses 2 + 1 + len + 1
        ((rest < 0)) && rest=0
        echo -e "  ${_UI_GRAY}$(_ui_repeat_char 2 "$_G_H") ${title} $(_ui_repeat_char "$rest" "$_G_H")${_UI_RESET}"
    else
        echo -e "  ${_UI_GRAY}$(_ui_repeat_char "$width" "$_G_H")${_UI_RESET}"
    fi
}

_render_progress() {
    local current="$1" total="$2" label="${3:-}"
    ((total == 0)) && total=1
    local pct=$((current * 100 / total))
    local bar_width=30
    local filled=$((current * bar_width / total))
    local empty=$((bar_width - filled))

    local bar_fill="" bar_empty=""
    for ((i = 0; i < filled; i++)); do bar_fill+="$_G_BAR_FILL"; done
    for ((i = 0; i < empty; i++)); do bar_empty+="$_G_BAR_EMPTY"; done

    echo -e "  ${_UI_GREEN}${bar_fill}${_UI_GRAY}${bar_empty}${_UI_RESET} ${pct}%  ${label}"
}

_render_status() {
    local msg="$*"
    echo -ne "\r\033[K  ${_UI_GRAY}$msg${_UI_RESET}"
}

_render_status_clear() {
    echo -ne "\r\033[K"
}

_render_choose() {
    # $1 prompt, $2 default_index (0=no default), $3..N items
    # Exit codes: 0=valid (echoes item), 1=invalid (echoes raw input),
    #             2=blank Enter, 3=EOF
    local prompt="$1" default_index="$2"
    shift 2
    local items=("$@")
    local n=${#items[@]}
    local has_default=0
    ((default_index > 0)) && has_default=1

    echo -e "  ${_UI_CYAN}$prompt${_UI_RESET}" >&2
    local i=1 item suffix
    for item in "${items[@]}"; do
        suffix=""
        ((has_default && i == default_index)) && suffix="  ${_UI_GRAY}(default - press Enter)${_UI_RESET}"
        printf '  %s) %s%b\n' "$i" "$item" "$suffix" >&2
        ((i++))
    done

    local label
    ((has_default)) && label="[$default_index]" || label="1-$n"
    local choice=""
    if ! read -rp "  Choice ${label}: " choice; then
        return 3 # EOF
    fi
    if [[ -z "$choice" ]]; then
        return 2 # blank Enter
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= n)); then
        echo "${items[$((choice - 1))]}"
        return 0
    fi
    echo "$choice" # echo the invalid input for the orchestrator's error message
    return 1
}
