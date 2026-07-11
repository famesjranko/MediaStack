# =============================================================================
# MediaStack UI — GUM rendering backend
# =============================================================================
# Implements all _render_* primitives using charmbracelet/gum.
# Zero dependency on ui_render_fallback.sh — fully self-contained.
#
# Requirements: gum binary on PATH, interactive TTY (auto-selected by ui.sh
# only when both conditions are met). Install: https://github.com/charmbracelet/gum
#
# Sourced by ui.sh via _ui_select_backend() when UI_BACKEND=gum or when gum
# is present on an interactive TTY. Do not source directly in application code.
# Orchestration (demo mode, retry loops, non-TTY handling) lives in ui.sh.

# Terminal-capability detection — required for _G_* glyph vars (glyph lint
# mandates all structural glyphs come from term_caps.sh, not raw literals).
_GUM_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=term_caps.sh
source "$_GUM_TC_DIR/term_caps.sh"

# --- Render primitives (the backend contract) ---
# Display functions write to stdout (callers use $(ui_kv ...) to compose lines
# into ui_box args). Only _render_log writes to stderr so it stays visible
# inside command substitutions that capture stdout.

_render_banner() {
    local title="${1:-MediaStack}"
    local subtitle="${2:-Turnkey Media Server for Home Networks}"
    echo ""
    gum style \
        --border double --border-foreground 6 \
        --align center --bold --padding "0 2" \
        "$title" "$subtitle"
    echo ""
}

_render_section() {
    echo ""
    if [[ $# -eq 1 ]]; then
        gum style --bold --foreground 14 "  $1"
        return
    fi
    local step="$1" total="$2" title="$3"
    if [[ "$total" -gt 0 ]]; then
        gum style --bold --foreground 14 "  [$step/$total] $title"
    else
        gum style --bold --foreground 14 "  Step $step: $title"
    fi
}

_render_log() {
    local level="$1"; shift
    local msg="$*"
    local icon color
    icon=$(_ui_status_token "$level")
    case "$level" in
        ok)    color=2  ;;
        warn)  color=3  ;;
        error) color=1  ;;
        info)  color=12 ;;
        skip)  color=8  ;;
        *)     color=8  ;;
    esac
    gum style --foreground "$color" "  $icon $msg" >&2
}

_render_spin_demo() {
    # Show spinner animation for demo mode without running a command.
    # ui.sh calls this when UI_DEMO=1; delay duration is passed in so this
    # function stays unaware of UI_DEMO_DELAY.
    local title="$1" delay="${2:-0}"
    local secs; secs=$(printf '%.0f' "${delay:-0}")
    (( secs < 1 )) && secs=1
    gum spin --spinner dot --title "  $title" -- sleep "$secs" 2>/dev/null || true
}

_render_spin() {
    # Deliberately NOT `gum spin`: gum's spin has Ctrl-C bugs (charmbracelet/gum
    # #690 — doesn't kill a child whose stdout is redirected; #588 — non-130 exit
    # on Ctrl-C) and can't wrap shell functions. Use our own bash spinner (same as
    # the fallback backend): the wrapped command runs in the background and gets a
    # real SIGINT (exit 130) from the process group, output is captured to a log,
    # and shell functions work. Version-independent and signal-correct.
    local title="$1"; shift
    local frames=("${_G_SPIN[@]}"); local frame_count=${#frames[@]}
    local _log; _log=$(mktemp 2>/dev/null) || _log=/dev/null

    "$@" >"$_log" 2>&1 &
    local pid=$! i=0
    local _interrupted=0 _prev_int _prev_term
    _prev_int="$(trap -p INT)"
    _prev_term="$(trap -p TERM)"
    # Detect Ctrl-C via a flag set IN the trap, not the child's exit code: bash
    # runs background jobs with SIGINT ignored (no job control in scripts), so the
    # child never exits 130 on Ctrl-C — the trap's kill (SIGTERM=143) stops it.
    # shellcheck disable=SC2064
    trap "_interrupted=1; kill $pid 2>/dev/null; printf '\r\033[K'" INT
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; printf '\r\033[K'" TERM
    while kill -0 "$pid" 2>/dev/null; do
        printf '\r  \033[0;36m%s\033[0m %s' "${frames[$((i % frame_count))]}" "$title"
        sleep 0.08 2>/dev/null || sleep 1
        ((i++)) || true
    done
    wait "$pid"
    local rc=$?
    trap - INT TERM
    [[ -n "$_prev_int" ]] && eval "$_prev_int"
    [[ -n "$_prev_term" ]] && eval "$_prev_term"
    printf '\r\033[K'
    if (( _interrupted )); then
        [[ "$_log" != /dev/null ]] && rm -f "$_log"
        kill -INT "$$" 2>/dev/null
        return 130
    fi
    if (( rc != 0 )) && [[ -s "$_log" ]]; then
        tail -n 20 "$_log" >&2
    fi
    [[ "$_log" != /dev/null ]] && rm -f "$_log"
    return $rc
}

_render_spin_fg() {
    # gum spin can only wrap external commands, not bash functions. Use a
    # background bash spinner instead so globals set by the function survive.
    local title="$1"; shift
    local frames=("${_G_SPIN[@]}"); local frame_count=${#frames[@]}
    (
        trap 'exit 0' TERM INT
        local i=0
        # Self-terminate if the parent shell dies (e.g. Ctrl-C fires the caller's
        # INT trap and it exits before we reach the kill below) so the spinner
        # can never orphan and spam the terminal. $$ is the parent shell PID.
        while kill -0 "$$" 2>/dev/null; do
            printf '\r  \033[0;36m%s\033[0m %s' "${frames[$((i % frame_count))]}" "$title"
            sleep 0.08 2>/dev/null || sleep 1
            ((i++)) || true
        done
    ) &
    local spinner_pid=$!
    "$@"; local rc=$?
    kill "$spinner_pid" 2>/dev/null; wait "$spinner_pid" 2>/dev/null
    printf '\r\033[K'
    return $rc
}

# gum is a Go program that traps SIGINT itself and exits 130 instead of letting
# Ctrl-C reach the shell. Left as a generic non-zero, callers treat it as an
# empty/cancel answer and (for required fields) loop forever — the user "can't
# Ctrl-C out". Re-raise SIGINT to the main shell so setup.sh's _setup_on_interrupt
# runs and aborts cleanly. $$ is the top-level shell PID (unchanged inside the
# command substitutions these widgets run in), so this targets setup.sh/mediastack
# even from nested $()s. Same idea as the _render_spin Ctrl-C fix.
_gum_reraise_on_sigint() {
    (( $1 == 130 )) && kill -INT "$$" 2>/dev/null
}

_render_input() {
    local prompt="$1" default="${2:-}" result rc
    # Return exit 3 on EOF/cancel so the orchestrator (ui.sh) can gate SIGTERM.
    result=$(gum input --placeholder "$default" --prompt "  $prompt: "); rc=$?
    _gum_reraise_on_sigint "$rc"
    (( rc == 130 )) && return 130   # Ctrl-C: distinct abort (see _render_choose)
    (( rc != 0 )) && return 3
    echo "${result:-$default}"
}

_render_password() {
    local prompt="$1" default="${2:-}" result rc
    result=$(gum input --password --placeholder "••••••" --prompt "  $prompt: "); rc=$?
    _gum_reraise_on_sigint "$rc"
    (( rc == 130 )) && return 130   # Ctrl-C: distinct abort (see _render_choose)
    (( rc != 0 )) && return 3
    echo "${result:-$default}"
}

_render_confirm() {
    # $1 prompt, $2 default (yes|no), $3 hint (Y/n or y/N) — hint ignored by gum
    # --default is a boolean presence flag: present = default YES, absent = default NO.
    # gum confirm exits 0=yes, 1=no, 130=Ctrl-C. Ctrl-C re-raises SIGINT (abort);
    # everything else maps to no (return 1). Ctrl-D can't be told apart from "no"
    # in this backend, so ui_confirm's EOF branch is unreachable here.
    local prompt="$1" default="${2:-no}" rc
    if [[ "$default" == "yes" ]]; then
        gum confirm --default "$prompt"; rc=$?
    else
        gum confirm "$prompt"; rc=$?
    fi
    _gum_reraise_on_sigint "$rc"
    (( rc == 0 )) && return 0 || return 1
}

_render_box() {
    local title="$1"; shift
    gum style \
        --border rounded --border-foreground 6 \
        --padding "1 2" --margin "0 2" \
        "$(gum style --bold "$title")" "" "$@"
}

_render_kv() {
    local key="$1" value="$2"
    printf '  %s %s\n' "$(gum style --bold "$(printf '%-20s' "$key")")" "$value"
}

_render_divider() {
    local title="${1:-}" width=46
    echo ""
    if [[ -n "$title" ]]; then
        local rest=$(( width - 4 - ${#title} ))
        (( rest < 0 )) && rest=0
        gum style --foreground 8 "  $(_g_repeat 2 "$_G_H") $title $(_g_repeat "$rest" "$_G_H")"
    else
        gum style --foreground 8 "  $(_g_repeat "$width" "$_G_H")"
    fi
}

_render_progress() {
    # gum has no inline colour for partial-line rendering; use ANSI directly.
    # GUM backend implies colour-capable TTY so hardcoding ANSI codes is safe.
    local current="$1" total="${2:-1}" label="${3:-}"
    (( total == 0 )) && total=1
    local pct=$(( current * 100 / total ))
    local bar_width=30
    local filled=$(( current * bar_width / total ))
    local empty=$(( bar_width - filled ))
    local bar_fill="" bar_empty="" i
    for ((i=0; i<filled; i++)); do bar_fill+="$_G_BAR_FILL"; done
    for ((i=0; i<empty; i++)); do bar_empty+="$_G_BAR_EMPTY"; done
    printf '  \033[0;32m%s\033[0;90m%s\033[0m %d%%  %s\n' "$bar_fill" "$bar_empty" "$pct" "$label"
}

_render_status() {
    printf '\r\033[K  \033[0;90m%s\033[0m' "$*"
}

_render_status_clear() {
    printf '\r\033[K'
}

_render_choose() {
    # $1 prompt, $2 default_index (1-based; 0=no default), $3..N items
    # Exit codes: 0=valid (echoes item), 130=Ctrl-C abort, 3=other cancel/EOF
    # gum choose cannot produce invalid or blank-Enter; exits are 0 or non-0 only.
    # --selected takes the item VALUE string (not a numeric index).
    local prompt="$1" default_index="$2"; shift 2
    local items=("$@")
    local selected_args=()
    if (( default_index > 0 && default_index <= ${#items[@]} )); then
        selected_args=(--selected="${items[$((default_index - 1))]}")
    fi
    # Clamp the list height to the terminal: an unclamped --height on a 40-item
    # list overflows the screen. height = min(item count, max(3, rows - 4)); tput
    # falls back to 24 when there's no TTY / it fails, so the clamp never divides by
    # a bogus row count. Does not touch the exit-code contract below.
    local rows; rows=$(tput lines 2>/dev/null) || rows=24
    [[ "$rows" =~ ^[0-9]+$ ]] || rows=24
    local max=$(( rows - 4 )); (( max < 3 )) && max=3
    local height=${#items[@]}; (( height > max )) && height=$max
    local result rc
    result=$(gum choose --header "  $prompt" --height="$height" "${selected_args[@]}" "${items[@]}"); rc=$?
    _gum_reraise_on_sigint "$rc"
    # Ctrl-C: gum exits 130 and _gum_reraise_on_sigint has re-raised SIGINT to $$.
    # But that signal stays PENDING while ui_choose is blocked in command
    # substitution ($(_render_choose ...)). Return a distinct 130 so ui_choose
    # breaks its reprompt loop and returns; only then does the main shell regain
    # control and run its pending INT trap (clean "Goodbye"). Collapsing this to
    # the generic 3 makes ui_choose reprompt forever, swallowing the signal.
    (( rc == 130 )) && return 130
    (( rc != 0 )) && return 3
    echo "$result"
}
