# =============================================================================
# MediaStack UI — pure bash implementation
# =============================================================================
# Implements all _ui_*_impl functions using ANSI escape codes and unicode.
# Zero external dependencies beyond bash 4+.

# ANSI color codes
_UI_RESET='\033[0m'
_UI_BOLD='\033[1m'
_UI_RED='\033[0;31m'
_UI_GREEN='\033[0;32m'
_UI_YELLOW='\033[1;33m'
_UI_BLUE='\033[0;34m'
_UI_CYAN='\033[0;36m'
_UI_GRAY='\033[0;90m'

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
    local width=46

    local title_line sub_line border
    title_line=$(_ui_center_text "$title" "$width")
    sub_line=$(_ui_center_text "$subtitle" "$width")
    border=$(_ui_repeat_char "$width" "═")

    echo ""
    echo -e "  ${_UI_CYAN}╔${border}╗${_UI_RESET}"
    echo -e "  ${_UI_CYAN}║${_UI_RESET}${_UI_BOLD}${title_line}${_UI_RESET}${_UI_CYAN}║${_UI_RESET}"
    echo -e "  ${_UI_CYAN}║${_UI_RESET}${sub_line}${_UI_CYAN}║${_UI_RESET}"
    echo -e "  ${_UI_CYAN}╚${border}╝${_UI_RESET}"
    echo ""
}

_ui_section_impl() {
    local step="$1" total="$2" title="$3"
    echo ""
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
        ok)    color="$_UI_GREEN";  icon="✓" ;;
        warn)  color="$_UI_YELLOW"; icon="!" ;;
        error) color="$_UI_RED";    icon="✗" ;;
        info)  color="$_UI_BLUE";   icon="•" ;;
        skip)  color="$_UI_YELLOW"; icon="→" ;;
        *)     color="$_UI_GRAY";   icon=" " ;;
    esac

    # Write to stderr so log output stays visible when the caller is inside
    # a command substitution (e.g. validators run inside ui_input_validated
    # would otherwise swallow the ui_log warn/info that explains the prompt).
    echo -e "  ${color}${_UI_BOLD}${icon}${_UI_RESET} $msg" >&2
}

_ui_spin_impl() {
    local title="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
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

    trap "kill $pid 2>/dev/null; echo -ne '\r\033[K'" INT TERM

    while kill -0 "$pid" 2>/dev/null; do
        echo -ne "\r  ${_UI_CYAN}${frames[$((i % frame_count))]}${_UI_RESET} $title"
        sleep 0.08 2>/dev/null || sleep 1
        ((i++)) || true
    done

    wait "$pid"
    local rc=$?
    trap - INT TERM
    echo -ne "\r\033[K"
    return $rc
}

_ui_spin_fg_impl() {
    local title="$1"; shift
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
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
    read -rp "  $prompt [$default]: " result || :
    echo "${result:-$default}"
}

_ui_input_validated_impl() {
    # Prompts via _ui_input_impl, then runs the validator on the returned value.
    # Loops until validator returns 0. The validator emits its own ui_log warn
    # on failure, so this helper does NOT print anything itself.
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

    local result
    while true; do
        result=$(_ui_input_impl "$prompt" "$default")
        # Validator returns 0 on valid; non-zero means it already emitted ui_log warn.
        if "$validator_fn" "$result"; then
            echo "$result"
            return 0
        fi
        # Loop — re-prompt with the same prompt + default. No extra logging here.
    done
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

_ui_confirm_impl() {
    local prompt="${1:-Continue?}"
    local default="${2:-no}"

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        [[ "$default" == "yes" ]]
        return
    fi

    local hint="y/N"
    [[ "$default" == "yes" ]] && hint="Y/n"

    local result=""
    read -rp "  $prompt [$hint]: " result || :
    result="${result:-$default}"

    [[ "${result,,}" == "y" || "${result,,}" == "yes" ]]
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
    border=$(_ui_repeat_char "$inner_width" "─")
    echo ""
    echo -e "  ${_UI_CYAN}╭${border}╮${_UI_RESET}"
    _pad=$(( inner_width - $(_ui_visible_len " ${title}") ))
    padded_title=" ${title}$(_ui_spaces "$_pad")"
    echo -e "  ${_UI_CYAN}│${_UI_RESET}${_UI_BOLD}${padded_title}${_UI_RESET}${_UI_CYAN}│${_UI_RESET}"
    empty_line=$(_ui_spaces "$inner_width")
    echo -e "  ${_UI_CYAN}│${_UI_RESET}${empty_line}${_UI_CYAN}│${_UI_RESET}"
    for line in "${content[@]}"; do
        _pad=$(( inner_width - $(_ui_visible_len "  ${line}") ))
        (( _pad < 0 )) && _pad=0
        padded_line="  ${line}$(_ui_spaces "$_pad")"
        echo -e "  ${_UI_CYAN}│${_UI_RESET}${padded_line}${_UI_CYAN}│${_UI_RESET}"
    done
    echo -e "  ${_UI_CYAN}╰${border}╯${_UI_RESET}"
}

_ui_kv_impl() {
    local key="$1" value="$2"
    local formatted_key
    printf -v formatted_key "%-18s" "$key"
    echo -e "  ${_UI_BOLD}${formatted_key}${_UI_RESET} ${value}"
}

_ui_divider_impl() {
    local title="${1:-}"
    echo ""
    if [[ -n "$title" ]]; then
        echo -e "  ${_UI_GRAY}── $title ──────────────────────────────────────${_UI_RESET}"
    else
        echo -e "  ${_UI_GRAY}─────────────────────────────────────────────────${_UI_RESET}"
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
    for ((i=0; i<filled; i++)); do bar_fill+="█"; done
    for ((i=0; i<empty; i++)); do bar_empty+="░"; done

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
    local default_index="${UI_CHOOSE_DEFAULT_INDEX:-1}"
    if ! [[ "$default_index" =~ ^[0-9]+$ ]] || (( default_index < 1 || default_index > ${#items[@]} )); then
        default_index=1
    fi

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "${items[$((default_index - 1))]}"
        return
    fi

    echo -e "  ${_UI_CYAN}$prompt${_UI_RESET}" >&2
    local i=1
    for item in "${items[@]}"; do
        echo "  $i) $item" >&2
        ((i++))
    done

    local choice=""
    if ! read -rp "  Choice [$default_index]: " choice; then
        # On closed/piped stdin (EOF), looping with the silent default
        # spins the menu forever. ui_choose is called inside `$(...)` so a
        # plain `exit` only kills the subshell — SIGTERM the foreground
        # process group so the parent script (mediastack/setup.sh) dies too.
        # Interactive EOF (Ctrl-D) still falls through to the visible default.
        if [[ ! -t 0 ]]; then
            _ui_log_impl warn "EOF on stdin — exiting."
            kill -TERM 0 2>/dev/null || true
            exit 0
        fi
        choice=""
    fi
    choice="${choice:-$default_index}"
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#items[@]} )); then
        _ui_log_impl warn "Choice '$choice' out of range — defaulting to $default_index"
        choice="$default_index"
    fi
    echo "${items[$((choice - 1))]}"
}
