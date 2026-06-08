# =============================================================================
# MediaStack UI — pure bash implementation
# =============================================================================
# Implements all _ui_*_impl functions using ANSI escape codes and unicode.
# Zero external dependencies beyond bash 4+ (term_caps.sh is an internal sibling).

# Terminal-capability detection — colour gating lives in one place (term_caps.sh).
# Resolve via BASH_SOURCE (not $SCRIPT_DIR): ui_fallback.sh is also sourced
# standalone by tests/unit/ui-box-alignment.sh where $SCRIPT_DIR is the test dir.
_UI_TC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=term_caps.sh
source "$_UI_TC_DIR/term_caps.sh"

# ANSI color codes
_UI_RESET='\033[0m'
_UI_BOLD='\033[1m'
_UI_RED='\033[0;31m'
_UI_GREEN='\033[0;32m'
_UI_YELLOW='\033[1;33m'
_UI_BLUE='\033[0;94m'   # bright blue: info is the highest-volume level, and 0;34 is unreadably dark on dark terminals
_UI_CYAN='\033[0;36m'
_UI_GRAY='\033[0;90m'

_UI_FRAME_WIDTH=46

# Distinct exit code a piped/non-interactive parent uses to signal "ui_choose
# ran out of stdin" (input exhausted), as opposed to a generic SIGTERM (143) or
# a real failure. _ui_choose_impl's EOF branch SIGTERMs the whole process group
# to take the looping parent (mediastack / setup.sh) down from inside $(...);
# those parents install a non-interactive TERM trap that maps the group-kill to
# this code (see mediastack:main and setup.sh:main). Sourced via ui.sh, so both
# parents share one definition. Exported so it survives the trap subshell.
export UI_EXIT_INPUT_EXHAUSTED=3

# Blank the whole palette when colour is disabled so escape codes never leak
# into piped/redirected logs. Frozen here at source time (when the installer's
# stdout/stderr are still the real TTY); UI_FORCE_COLOR overrides for demos.
if ! _color_enabled; then
    _UI_RESET='' _UI_BOLD='' _UI_RED='' _UI_GREEN='' _UI_YELLOW='' _UI_BLUE='' _UI_CYAN='' _UI_GRAY=''
fi

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
    if (( len >= width )); then
        printf '%s' "$text"
        return
    fi
    left=$(( (width - len) / 2 ))
    right=$(( width - len - left ))
    printf '%s%s%s' "$(_ui_spaces "$left")" "$text" "$(_ui_spaces "$right")"
}

_ui_banner_impl() {
    local title="${1:-MediaStack}"
    local subtitle="${2:-Turnkey Media Server for Home Networks}"
    local width="$_UI_FRAME_WIDTH"
    local _tlen _slen
    _tlen=$(_ui_visible_len "$title"); _slen=$(_ui_visible_len "$subtitle")
    (( _tlen > width )) && width=$_tlen
    (( _slen > width )) && width=$_slen

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

_ui_section_impl() {
    echo ""
    # Bare header form: `ui_section "Title"` (one arg) prints just the styled
    # title with no [N/M] counter — for non-sequential sections (network
    # discovery, the single hardware-transcoding offer) where a counter would lie
    # about progress (#99). Branch on arg count BEFORE referencing $2/$3, so the
    # 1-arg call is safe under the wizard's `set -u`.
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

_ui_log_impl() {
    local level="$1"; shift
    local msg="$*"
    local color icon

    case "$level" in
        ok)    color="$_UI_GREEN"  ;;
        warn)  color="$_UI_YELLOW" ;;
        error) color="$_UI_RED"    ;;
        info)  color="$_UI_BLUE"   ;;
        skip)  color="$_UI_GRAY"   ;;
        *)     color="$_UI_GRAY"   ;;
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

_ui_spin_impl() {
    local title="$1"; shift
    local frames=("${_G_SPIN[@]}")
    local frame_count=${#frames[@]}

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        local delay_int="${UI_DEMO_DELAY:-0}"
        delay_int="${delay_int%.*}"
        local cycles=$(( ${delay_int:-0} * 12 + 6 ))
        local i=0
        while (( i < cycles )); do
            echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
            sleep 0.08 2>/dev/null || sleep 1
            ((i++)) || true
        done
        echo -ne "\r\033[K"
        return 0
    fi

    "$@" &
    local pid=$!
    local i=0

    # Save the caller's INT/TERM disposition so this transient spinner trap does
    # not permanently clobber it — `trap - INT TERM` resets to bash *default*,
    # which would silently wipe setup.sh's interrupt-reassurance handler for
    # everything after the first spinner. Restore it on the way out instead.
    local _prev_int _prev_term
    _prev_int="$(trap -p INT)"
    _prev_term="$(trap -p TERM)"
    # $pid must bind now (the spinner's background pid), not at signal time —
    # single-quoting would defer expansion past its scope. Intentional.
    # shellcheck disable=SC2064
    trap "kill $pid 2>/dev/null; echo -ne '\r\033[K'" INT TERM

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
    return $rc
}

_ui_spin_fg_impl() {
    local title="$1"; shift
    local frames=("${_G_SPIN[@]}")
    local frame_count=${#frames[@]}

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        local delay_int="${UI_DEMO_DELAY:-0}"
        delay_int="${delay_int%.*}"
        local cycles=$(( ${delay_int:-0} * 12 + 6 ))
        local i=0
        while (( i < cycles )); do
            echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
            sleep 0.08 2>/dev/null || sleep 1
            ((i++)) || true
        done
        echo -ne "\r\033[K"
        "$@"
        return $?
    fi

    (
        trap 'exit 0' TERM
        local i=0
        while true; do
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
    return $rc
}

_ui_input_impl() {
    local prompt="${1:-Input}"
    local default="${2:-}"

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "$default"
        return
    fi

    local result=""
    # `|| :` so an EOF on piped stdin falls through to the default rather
    # than aborting under `set -e`. Without this, a non-interactive run
    # whose input file is one line short of expected silently exits the
    # whole installer at the next `read` — no error message, no log line.
    # Match ui_choose's "press Enter" affordance: when a default exists, tell the
    # user that Enter accepts it. Display-only — does not touch the read/default
    # logic, so non-interactive behaviour is unchanged.
    local _hint="$default"
    [[ -n "$default" ]] && _hint="$default - press Enter"
    read -rp "  $prompt [$_hint]: " result || :
    echo "${result:-$default}"
}

# Shared validator-driven re-prompt loop for ui_input_validated / ui_password_validated.
# Calls "$prompt_fn" "$prompt" "$default" (the masked variant passes the PUBLIC
# ui_password by name, so test stubs that replace it keep working) and loops until
# the validator returns 0. The validator emits its own ui_log warn on failure, so
# this loop prints nothing on a normal re-prompt.
#
# Non-TTY safety (issue #93): on a piped/closed stdin the prompt returns the default
# every iteration (read hits EOF -> "${result:-$default}"). If that default fails the
# validator, an unguarded loop spins forever. So, off a TTY, once the value EOF keeps
# producing (the default) is rejected a SECOND consecutive time, stdin is exhausted -> emit the
# breadcrumb and SIGTERM the process group, exactly like _ui_choose_impl's EOF branch.
# These run inside $(...), so a plain exit only kills the subshell; setup.sh /
# mediastack install a TERM trap that maps the group-kill to UI_EXIT_INPUT_EXHAUSTED.
# The second strike is the one probe needed to confirm exhaustion across the $(...)
# boundary (a flag set inside the prompt subshell can't reach us). Distinct invalid
# inputs, and any interactive TTY, never trip the latch and re-prompt as before.
_ui_validated_loop() {
    local prompt_fn="$1"
    local prompt="$2"
    local default="$3"
    local validator_fn="$4"

    local result interactive=0 seen_default_invalid=0
    [[ -t 0 ]] && interactive=1
    while true; do
        result=$("$prompt_fn" "$prompt" "$default")
        # Validator returns 0 on valid; non-zero means it already emitted ui_log warn.
        if "$validator_fn" "$result"; then
            echo "$result"
            return 0
        fi
        if (( ! interactive )) && [[ "$result" == "$default" ]]; then
            if (( seen_default_invalid )); then
                _ui_log_impl warn "No more usable input on stdin - exiting non-interactive session (exit ${UI_EXIT_INPUT_EXHAUSTED}: input exhausted)."
                kill -TERM 0 2>/dev/null || true
                exit 0
            fi
            seen_default_invalid=1
        else
            # A distinct value (or any TTY re-prompt) breaks the streak: the latch is
            # CONSECUTIVE, not sticky, so a non-TTY driver that interleaves the default
            # with other lines keeps consuming its queued input instead of being killed
            # on a later, non-adjacent default. (Reachable only if a caller's default is
            # itself invalid - today every non-empty validated default is pre-clamped -
            # but this is the shared primitive #94 and later children build on.)
            seen_default_invalid=0
        fi
    done
}

_ui_input_validated_impl() {
    # Prompts via _ui_input_impl, then runs the validator on the returned value via
    # _ui_validated_loop (which carries the non-TTY input-exhaustion guard, issue #93).
    # The validator emits its own ui_log warn on failure, so this helper does NOT
    # print anything itself.
    #
    # Args:
    #   $1 prompt          (required)
    #   $2 default         (required; may be empty string for required-no-default fields)
    #   $3 validator_fn    (required; function name, called as: "$validator_fn" "$value")
    #   $4 demo_default    (optional; falls back to $2 if unset)
    local prompt="${1:-Input}"
    local default="${2:-}"
    local validator_fn="${3:?ui_input_validated: validator function name required}"
    local demo_default="${4:-$default}"

    # DEMO short-circuit: BOTH UI_DEMO=1 (simulation) and DEMO=1 (full non-interactive).
    # No validation in demo — caller is responsible for ensuring demo defaults are valid.
    if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
        echo "$demo_default"
        return 0
    fi

    _ui_validated_loop _ui_input_impl "$prompt" "$default" "$validator_fn"
}

_ui_password_impl() {
    local prompt="${1:-Password}"
    local default="${2:-}"

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "$default"
        return
    fi

    local result=""
    read -rsp "  $prompt: " result || :
    echo "" >&2
    echo "${result:-$default}"
}

_ui_password_validated_impl() {
    # MASKED sibling of _ui_input_validated_impl: prompts via ui_password (read -rsp,
    # no echo) and loops until the validator returns 0. The validator emits its own
    # ui_log warn on failure, so this helper prints nothing itself. Calls the public
    # ui_password (not _ui_password_impl directly) — same as the _stage2_password_
    # validated helper it replaces, so callers/tests that stub ui_password keep working.
    #
    # Args:
    #   $1 prompt          (required)
    #   $2 default         (required; may be empty for required-no-default fields)
    #   $3 validator_fn    (required; called as: "$validator_fn" "$value")
    #   $4 demo_default    (optional; falls back to $2 if unset)
    local prompt="${1:-Password}"
    local default="${2:-}"
    local validator_fn="${3:?ui_password_validated: validator function name required}"
    local demo_default="${4:-$default}"

    # DEMO short-circuit: BOTH UI_DEMO=1 (simulation) and DEMO=1 (full non-interactive).
    # No validation in demo — caller is responsible for ensuring demo defaults are valid.
    # (The previous _stage2_password_validated lacked the DEMO=1 guard; this is stricter.)
    if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
        echo "$demo_default"
        return 0
    fi

    _ui_validated_loop ui_password "$prompt" "$default" "$validator_fn"
}

_ui_confirm_impl() {
    local prompt="${1:-Continue?}"
    local default="${2:-no}"

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        [[ "$default" == "yes" ]]
        return
    fi

    local hint="y/N"
    [[ "$default" == "yes" ]] && hint="Y/n"

    # Interactive TTY: accept only y/yes/n/no (blank = default) and re-prompt on
    # anything else — never guess from an unrecognised answer. Non-interactive:
    # keep the historical deterministic rule (blank = default; anything not
    # y/yes = no) so piped callers/tests stay stable.
    local interactive=0; [[ -t 0 ]] && interactive=1
    local result=""
    while true; do
        read -rp "  $prompt [$hint - press Enter]: " result || :
        result="${result:-$default}"
        case "${result,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
        if (( interactive )); then
            _ui_log_impl warn "Please answer y or n."
            result=""
            continue
        fi
        [[ "${result,,}" == "y" || "${result,,}" == "yes" ]]
        return
    done
}

_ui_box_impl() {
    local title="$1"; shift
    local content=("$@")

    # Auto-size: find longest line (title + 1 for leading space, or content + 2 for indent)
    local inner_width
    inner_width=$(( $(_ui_visible_len "$title") + 2 ))
    for line in "${content[@]}"; do
        local line_width=$(( $(_ui_visible_len "$line") + 4 ))
        (( line_width > inner_width )) && inner_width=$line_width
    done
    # Minimum width and add padding
    (( inner_width < 40 )) && inner_width=40
    (( inner_width += 2 ))

    # NOTE: bash printf "%-Ns" pads to N bytes, not terminal-visible
    # characters. Multi-byte UTF-8 and ANSI styles break alignment. Measure
    # visible text after stripping ANSI, then append ASCII spaces explicitly.
    local _pad border padded_title empty_line padded_line
    border=$(_ui_repeat_char "$inner_width" "$_G_H")
    echo ""
    echo -e "  ${_UI_CYAN}${_G_TL}${border}${_G_TR}${_UI_RESET}"
    _pad=$(( inner_width - $(_ui_visible_len " ${title}") ))
    padded_title=" ${title}$(_ui_spaces "$_pad")"
    echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${_UI_BOLD}${padded_title}${_UI_RESET}${_UI_CYAN}${_G_V}${_UI_RESET}"
    empty_line=$(_ui_spaces "$inner_width")
    echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${empty_line}${_UI_CYAN}${_G_V}${_UI_RESET}"
    for line in "${content[@]}"; do
        _pad=$(( inner_width - $(_ui_visible_len "  ${line}") ))
        (( _pad < 0 )) && _pad=0
        padded_line="  ${line}$(_ui_spaces "$_pad")"
        echo -e "  ${_UI_CYAN}${_G_V}${_UI_RESET}${padded_line}${_UI_CYAN}${_G_V}${_UI_RESET}"
    done
    echo -e "  ${_UI_CYAN}${_G_BL}${border}${_G_BR}${_UI_RESET}"
}

_ui_kv_impl() {
    local key="$1" value="$2"
    local _klen _pad
    _klen=$(_ui_visible_len "$key")
    # Pad keys to the widest one any ui_kv caller renders so every value column
    # aligns. Currently 20: 'Hardware transcoding' / 'Remote streaming cap'. Bump
    # this if a longer key is ever added (no caller passes a variable-length key).
    _pad=$(( 20 - _klen )); (( _pad < 0 )) && _pad=0
    echo -e "  ${_UI_BOLD}${key}$(_ui_spaces "$_pad")${_UI_RESET} ${value}"
}

_ui_divider_impl() {
    local title="${1:-}" width="$_UI_FRAME_WIDTH"
    echo ""
    if [[ -n "$title" ]]; then
        local rest=$(( width - 4 - $(_ui_visible_len "$title") ))   # "-- title " uses 2 + 1 + len + 1
        (( rest < 0 )) && rest=0
        echo -e "  ${_UI_GRAY}$(_ui_repeat_char 2 "$_G_H") ${title} $(_ui_repeat_char "$rest" "$_G_H")${_UI_RESET}"
    else
        echo -e "  ${_UI_GRAY}$(_ui_repeat_char "$width" "$_G_H")${_UI_RESET}"
    fi
}

_ui_progress_impl() {
    local current="$1" total="$2" label="${3:-}"
    (( total == 0 )) && total=1
    local pct=$(( current * 100 / total ))
    local bar_width=30
    local filled=$(( current * bar_width / total ))
    local empty=$(( bar_width - filled ))

    local bar_fill="" bar_empty=""
    for ((i=0; i<filled; i++)); do bar_fill+="$_G_BAR_FILL"; done
    for ((i=0; i<empty; i++)); do bar_empty+="$_G_BAR_EMPTY"; done

    echo -e "  ${_UI_GREEN}${bar_fill}${_UI_GRAY}${bar_empty}${_UI_RESET} ${pct}%  ${label}"
}

_ui_status_impl() {
    local msg="$*"
    echo -ne "\r\033[K  ${_UI_GRAY}$msg${_UI_RESET}"
}

_ui_status_clear_impl() {
    echo -ne "\r\033[K"
}

_ui_choose_impl() {
    local prompt="$1"; shift
    local items=("$@")
    local n=${#items[@]}

    # An explicit UI_CHOOSE_DEFAULT_INDEX means the caller WANTS Enter to accept a
    # default (the wizard's "recommended" prompts). When it is UNSET there is no
    # default: an interactive user must make a real choice — a menu must never
    # silently fall back to item 1 on a stray Enter. Distinguish set-vs-unset with
    # ${VAR+x} so "" and "unset" don't collapse to the same default.
    local has_default=0 default_index=1
    if [[ -n "${UI_CHOOSE_DEFAULT_INDEX+x}" ]]; then
        has_default=1
        default_index="$UI_CHOOSE_DEFAULT_INDEX"
        if ! [[ "$default_index" =~ ^[0-9]+$ ]] || (( default_index < 1 || default_index > n )); then
            default_index=1
        fi
    fi

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "${items[$((default_index - 1))]}"
        return
    fi

    echo -e "  ${_UI_CYAN}$prompt${_UI_RESET}" >&2
    local i=1 item suffix
    for item in "${items[@]}"; do
        suffix=""
        (( has_default && i == default_index )) && suffix="  ${_UI_GRAY}(default - press Enter)${_UI_RESET}"
        printf '  %s) %s%b\n' "$i" "$item" "$suffix" >&2
        ((i++))
    done

    # Interactive TTY: re-prompt until the entry is a valid in-range number (or
    # blank to accept an explicit default) — never silently pick on empty/garbage.
    # Non-interactive (piped/CI/harness): keep the historical deterministic
    # default-fallback so automation can't hang in a re-prompt loop.
    local interactive=0; [[ -t 0 ]] && interactive=1
    local label; (( has_default )) && label="[$default_index]" || label="1-$n"
    local choice=""
    while true; do
        if ! read -rp "  Choice ${label}: " choice; then
            # EOF. On a pipe a re-prompt loop would spin forever; ui_choose runs
            # inside $(...) so a plain exit only kills the subshell — SIGTERM the
            # process group to take the parent (mediastack/setup.sh) down too.
            # The non-interactive parents install a TERM trap that maps this
            # group-kill to exit ${UI_EXIT_INPUT_EXHAUSTED} ("input exhausted"),
            # so a piped driver can tell "ran out of input" from a generic kill
            # (143) or a real failure. The warn below is the matching breadcrumb.
            if (( ! interactive )); then
                _ui_log_impl warn "No more input on stdin - exiting non-interactive session (exit ${UI_EXIT_INPUT_EXHAUSTED}: input exhausted)."
                kill -TERM 0 2>/dev/null || true
                exit 0
            fi
            choice=""
        fi
        if [[ -z "$choice" ]]; then
            if (( has_default )); then choice="$default_index"
            elif (( ! interactive )); then choice=1                  # deterministic for automation
            else _ui_log_impl warn "Enter a number between 1 and $n."; continue
            fi
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            break
        fi
        if (( interactive )); then
            _ui_log_impl warn "'$choice' is not a valid choice - enter a number between 1 and $n."
            continue
        fi
        # Non-interactive invalid input: historical deterministic fallback.
        _ui_log_impl warn "Choice '$choice' out of range - defaulting to $default_index"
        choice="$default_index"
        break
    done
    echo "${items[$((choice - 1))]}"
}
