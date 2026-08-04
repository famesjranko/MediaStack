# Owns: Escapable Stage 2 input collection for domains and DDNS credentials.
# Sources: Stage 2 interactive UI and validators.

# Collect a required input (a domain, a DDNS credential) WITH a graceful escape
# hatch. On a TTY, an empty submission on a no-default field OR three consecutive
# validation failures (the natural "I can't do this, get me out" gestures) offers
# a small menu — try again, or <skip_label> — instead of the shared
# ui_input_validated 5x-empty valve, which kills the whole installer, and instead
# of a Ctrl-C-only trap when a bad recalled default keeps re-appearing. Prints the
# trimmed value; returns 0 = collected · 2 = user chose skip · 130 = Ctrl-C.
_stage2_escapable_input() {
    local prompt="$1" def="$2" validator="$3" skip_label="${4:-Skip}"
    # Non-interactive (CI / PTY-less / DEMO): delegate to ui_input_validated for
    # the existing deterministic fallback. Only a real interactive TTY gets the
    # escape menu (an empty submission there is a deliberate "get me out").
    if ! _stage2_is_interactive || [[ "${UI_DEMO:-0}" == "1" ]]; then
        local v rc
        v=$(ui_input_validated "$prompt" "$def" "$validator")
        rc=$?
        ((rc == 0)) && printf '%s' "$(_stage2_trim_ws "$v")"
        return "$rc"
    fi
    local val rejects=0
    while true; do
        val=$(ui_input "$prompt" "$def")
        (($? == 130)) && return 130
        # Trim first so a stray leading/trailing space from a paste is auto-fixed
        # (a trailing space silently fails auth on every provider) rather than
        # rejected — the validator still catches internal spaces and empties.
        val=$(_stage2_trim_ws "$val")
        # Empty with NO default is the escape gesture (a field with a default
        # returns that default on Enter, so it never lands here).
        if [[ -z "$val" && -z "$def" ]]; then
            [[ "$(ui_choose "Nothing entered — what would you like to do?" "Try again" "$skip_label")" == "$skip_label" ]] && return 2
            continue
        fi
        if "$validator" "$val"; then
            printf '%s' "$val"
            return 0
        fi
        # Validator rejected (it warned). After a few tries — a recalled or
        # hand-edited value that can't pass — offer the escape and drop the bad
        # default, so the loop is never a Ctrl-C-only trap.
        rejects=$((rejects + 1))
        if ((rejects >= 3)); then
            [[ "$(ui_choose "That value still isn't valid — what would you like to do?" "Try again" "$skip_label")" == "$skip_label" ]] && return 2
            rejects=0
            def=""
        fi
    done
}
