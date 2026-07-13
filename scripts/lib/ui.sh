# =============================================================================
# MediaStack UI library — public API and orchestration
# =============================================================================
# Selects and loads a rendering backend (ui_render_*.sh), then provides the
# full public ui_* API with all orchestration logic: demo mode, non-TTY
# handling, validation retry loops, and input exhaustion signalling.
#
# Usage: source this file from setup.sh or mediastack. All UI functions are
# prefixed with ui_ to avoid collisions with other helpers.
#
# Demo mode: set UI_DEMO=1 to use simulated inputs and short delays.
# Backend:   set UI_BACKEND=fallback|gum to override auto-detection.

UI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Distinct exit code for "stdin exhausted in a non-interactive session."
# Backends return exit 3 from input primitives on EOF; ui_choose/ui_confirm/
# ui_input/ui_password map that to a SIGTERM of the process group when ! -t 0.
# Parents install a TERM trap that maps the group-kill to this code so a piped
# driver can tell "ran out of input" from a generic kill (143) or a real failure.
# Exported so it survives the trap subshell at call sites.
export UI_EXIT_INPUT_EXHAUSTED=3

# Backend selection — sources ui_render_<backend>.sh which provides all
# _render_* and _render_spin_demo primitives.
#   auto      (default) gum if binary present + stdin is a TTY + not demo mode,
#             else fallback.
#   fallback  pure bash ANSI — always works, non-TTY safe.
#   gum       charmbracelet/gum — interactive TTY only, requires gum binary.
#             NOTE: UI_BACKEND=gum bypasses the TTY guard. On a non-TTY all
#             gum commands exit non-zero, which maps to EOF/default returns or
#             SIGTERM — no warning is emitted. Only set this explicitly on a TTY.
_ui_select_backend() {
    local backend="${UI_BACKEND:-auto}"
    if [[ "$backend" == "auto" ]]; then
        # Pin to fallback in demo/non-interactive mode so demo output is
        # deterministic regardless of whether gum is installed on the host.
        if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
            backend="fallback"
        elif command -v gum &>/dev/null && [[ -t 0 ]]; then
            backend="gum"
        else
            backend="fallback"
        fi
    fi
    source "$UI_LIB_DIR/ui_render_${backend}.sh"
}
_ui_select_backend
unset -f _ui_select_backend

# --- Shared orchestration helpers ---

# Validation retry loop shared by ui_input_validated and ui_password_validated.
# Calls the PUBLIC prompt_fn (ui_input or ui_password) so test stubs that
# replace those public wrappers continue to work.
#
# On a non-TTY (piped) session, ui_input silently returns the default when
# stdin is exhausted (EOF). If the validator rejects the default, the loop
# would spin forever. The two-strike latch detects this: two consecutive
# results equal to the default that both fail validation = stdin exhausted →
# SIGTERM the process group. A distinct (non-default) invalid result resets
# the strike counter so a non-TTY driver that sends blank-then-valid input
# still reaches the valid value without tripping the latch.
_ui_validated_loop() {
    local prompt_fn="$1" prompt="$2" default="$3" validator_fn="$4"
    local result consecutive_default=0
    local interactive=0; [[ -t 0 ]] && interactive=1
    while true; do
        local rc
        result=$("$prompt_fn" "$prompt" "$default"); rc=$?
        if (( rc == 130 )); then
            # Ctrl-C during a validated prompt: the backend re-raised SIGINT (now
            # pending on the main shell). Break the loop and return so the caller's
            # command substitution completes and the pending trap fires. Reprompting
            # would swallow the signal (needs ~5 presses to hit the safety valve).
            return 130
        fi
        if "$validator_fn" "$result"; then
            echo "$result"; return 0
        fi
        if [[ "$result" == "$default" ]]; then
            (( ++consecutive_default ))
            if (( ! interactive && consecutive_default >= 2 )); then
                _render_log warn "No more usable input on stdin - exiting non-interactive session (exit ${UI_EXIT_INPUT_EXHAUSTED}: input exhausted)."
                kill -TERM 0 2>/dev/null || true; exit 0
            fi
            # Interactive safety valve: a required field (empty default) that keeps
            # coming back empty means the input was cancelled (Ctrl-C/Esc) or the
            # terminal is broken — e.g. gum exiting non-zero immediately, which
            # would otherwise spin this loop forever. Re-raise SIGINT so setup.sh's
            # interrupt handler aborts cleanly instead of looping.
            if (( interactive && consecutive_default >= 5 )); then
                _render_log warn "No input received after several attempts - aborting (Ctrl-C or cancelled input)."
                kill -INT "$$" 2>/dev/null
                exit "${UI_EXIT_INPUT_EXHAUSTED}"
            fi
        else
            consecutive_default=0
        fi
    done
}

# --- Public API ---

ui_banner() { _render_banner "$@"; }

ui_section() { _render_section "$@"; }

ui_log() { _render_log "$@"; }

ui_spin() {
    local label="$1"; shift
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        # Animate for a fake duration without running the command.
        # _render_spin_demo is a backend primitive that shows the spinner
        # animation for the given delay; it does not know about UI_DEMO itself.
        _render_spin_demo "$label" "${UI_DEMO_DELAY:-0}"
        return 0
    fi
    # A backgrounded sudo's password prompt lands on /dev/tty but is instantly
    # overwritten by the spinner's \r repaint, so a cold credential cache would
    # hang invisibly. Warm the timestamp in the FOREGROUND first: no-op on a warm
    # cache or NOPASSWD; a visible prompt on a cold cache; fails fast (the wrapped
    # command then surfaces the error as before) when there is no tty. Covers every
    # site that wraps `sudo` directly — install and day-2. The two sites that instead
    # wrap a *function* / `bash -c` calling sudo internally (configure_docker_apt_repo
    # in packages.sh, the NPM/DDNS configure.sh in stage2.sh) can't be reached by this
    # `$1` check, so they prime in the foreground at their own call site.
    [[ "${1:-}" == "sudo" ]] && { sudo -v 2>/dev/null || true; }
    _render_spin "$label" "$@"
}

ui_spin_fg() {
    local label="$1"; shift
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        # Animate, then still run the function (spin_fg callers set globals).
        _render_spin_demo "$label" "${UI_DEMO_DELAY:-0}"
        "$@"; return $?
    fi
    _render_spin_fg "$label" "$@"
}

ui_input() {
    local prompt="${1:-Input}" default="${2:-}"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "$default"; return
    fi
    local result rc
    result=$(_render_input "$prompt" "$default"); rc=$?
    if [[ $rc -eq 130 ]]; then
        # Ctrl-C: propagate abort so _ui_validated_loop breaks and the pending
        # SIGINT (re-raised by the backend) fires the caller's trap. Plain
        # callers do x=$(ui_input) and ignore rc, but the pending signal still
        # aborts them cleanly once this returns.
        return 130
    fi
    if [[ $rc -eq 3 ]]; then
        # EOF (interactive Ctrl-D or non-interactive closed stdin): return the
        # default silently. Callers terminate naturally; ui_choose is the only
        # primitive that SIGTERM-kills on EOF (menus have no sensible default).
        echo "$default"; return
    fi
    echo "$result"
}

ui_input_validated() {
    # Prompts via ui_input, then runs the validator, looping until it passes.
    # The validator emits its own ui_log warn on failure; this function is silent.
    #
    # Args:
    #   $1 prompt          (required)
    #   $2 default         (required; may be empty for required-no-default fields)
    #   $3 validator_fn    (required; function name called as: "$fn" "$value")
    #   $4 demo_default    (optional; falls back to $2 if unset)
    local prompt="${1:-Input}"
    local default="${2:-}"
    local validator_fn="${3:?ui_input_validated: validator function name required}"
    local demo_default="${4:-$default}"
    # DEMO short-circuit: BOTH UI_DEMO=1 (simulation) and DEMO=1 (full non-interactive).
    # No validation in demo — caller is responsible for ensuring demo defaults are valid.
    if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
        echo "$demo_default"; return 0
    fi
    _ui_validated_loop ui_input "$prompt" "$default" "$validator_fn"
}

ui_password() {
    local prompt="${1:-Password}" default="${2:-}"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        echo "$default"; return
    fi
    local result rc
    result=$(_render_password "$prompt" "$default"); rc=$?
    if [[ $rc -eq 130 ]]; then
        return 130   # Ctrl-C: propagate abort (see ui_input)
    fi
    if [[ $rc -eq 3 ]]; then
        echo "$default"; return
    fi
    echo "$result"
}

ui_password_validated() {
    # MASKED sibling of ui_input_validated. Calls the public ui_password wrapper
    # (not _render_password directly) so test stubs that replace ui_password work.
    #
    # Args:
    #   $1 prompt          (required)
    #   $2 default         (required; may be empty for required-no-default fields)
    #   $3 validator_fn    (required; called as: "$fn" "$value")
    #   $4 demo_default    (optional; falls back to $2 if unset)
    local prompt="${1:-Password}"
    local default="${2:-}"
    local validator_fn="${3:?ui_password_validated: validator function name required}"
    local demo_default="${4:-$default}"
    if [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]]; then
        echo "$demo_default"; return 0
    fi
    _ui_validated_loop ui_password "$prompt" "$default" "$validator_fn"
}

ui_confirm() {
    local prompt="${1:-Continue?}" default="${2:-no}"
    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        [[ "$default" == "yes" ]]; return
    fi
    local hint; [[ "$default" == "yes" ]] && hint="Y/n" || hint="y/N"
    local interactive=0; [[ -t 0 ]] && interactive=1
    while true; do
        local rc
        _render_confirm "$prompt" "$default" "$hint"; rc=$?
        case $rc in
            0) return 0 ;;
            1) return 1 ;;
            2) # unrecognised input
               if (( interactive )); then
                   _render_log warn "Please answer y or n."
               else
                   [[ "$default" == "yes" ]]; return
               fi
               ;;
            3) # EOF — return the default silently (no SIGTERM; caller exits naturally)
               [[ "$default" == "yes" ]]; return
               ;;
        esac
    done
}

ui_box() { _render_box "$@"; }

ui_kv() { _render_kv "$@"; }

ui_divider() { _render_divider "$@"; }

ui_progress() { _render_progress "$@"; }

ui_status() { _render_status "$@"; }

ui_status_clear() { _render_status_clear; }

ui_choose() {
    local prompt="$1"; shift
    local items=("$@")
    local n=${#items[@]}

    # An explicit UI_CHOOSE_DEFAULT_INDEX means the caller WANTS Enter to accept a
    # default (the wizard's "recommended" prompts). When UNSET there is no default:
    # an interactive user must make a real choice. Distinguish set-vs-unset with
    # ${VAR+x} so "" and "unset" don't collapse to the same value.
    local has_default=0 default_index=0
    if [[ -n "${UI_CHOOSE_DEFAULT_INDEX+x}" ]]; then
        has_default=1
        default_index="$UI_CHOOSE_DEFAULT_INDEX"
        if ! [[ "$default_index" =~ ^[0-9]+$ ]] || (( default_index < 1 || default_index > n )); then
            default_index=1
        fi
    fi

    if [[ "${UI_DEMO:-0}" == "1" ]]; then
        local di=$(( default_index > 0 ? default_index : 1 ))
        echo "${items[$((di - 1))]}"; return
    fi

    local interactive=0; [[ -t 0 ]] && interactive=1

    while true; do
        local result="" rc
        # Pass default_index=0 when there is no default so the backend shows
        # the "1-N" label instead of "[N]" and omits the "(default)" hint.
        result=$(_render_choose "$prompt" "$default_index" "${items[@]}"); rc=$?
        case $rc in
            0) echo "$result"; return 0 ;;
            130) # gum Ctrl-C abort. The backend already re-raised SIGINT to the
                 # main shell, but it stays pending while we block in the command
                 # substitution above. Return so the caller's $() completes and the
                 # pending INT trap fires (clean exit). Reprompting here would loop
                 # forever and swallow the signal.
                 return 130 ;;
            1) # invalid — $result contains the raw invalid input for the message
               if (( interactive )); then
                   _render_log warn "'$result' is not a valid choice - enter a number between 1 and $n."
               else
                   local fallback=$(( default_index > 0 ? default_index : 1 ))
                   _render_log warn "Choice '$result' out of range - defaulting to $fallback"
                   echo "${items[$((fallback - 1))]}"; return 0
               fi
               ;;
            2) # blank Enter
               if (( has_default )); then
                   echo "${items[$((default_index - 1))]}"; return 0
               elif (( interactive )); then
                   _render_log warn "Enter a number between 1 and $n."
               else
                   echo "${items[0]}"; return 0  # deterministic for automation
               fi
               ;;
            3) # EOF
               if (( ! interactive )); then
                   _render_log warn "No more input on stdin - exiting non-interactive session (exit ${UI_EXIT_INPUT_EXHAUSTED}: input exhausted)."
                   kill -TERM 0 2>/dev/null || true; exit 0
               fi
               # Interactive EOF (Ctrl-D): treat as blank Enter.
               if (( has_default )); then
                   echo "${items[$((default_index - 1))]}"; return 0
               fi
               _render_log warn "Enter a number between 1 and $n."
               ;;
        esac
    done
}
