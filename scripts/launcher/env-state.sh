#!/usr/bin/env bash
# Owns: The launcher's durable .env writes and the in-shell reload that follows them.
# Sources: launcher globals ($SCRIPT_DIR/.env) and scripts/lib/env-update.sh.
#
# Every day-2 action that changes a persisted setting goes through here, so the
# rule "persist, then reload, then report" has one implementation. Sourced ahead
# of its consumers (bandwidth, ddns, features, manage-updates) by ./mediastack.

# Write one or more KEY VALUE pairs to .env in a single atomic call, so a
# multi-key setting can never be half-persisted. Returns non-zero — after
# warning once per key — when the write fails; callers must not report success.
_set_env_vars() {
    local file="$SCRIPT_DIR/.env" status
    local -a pairs=("$@")
    [[ -f "$file" && ${#pairs[@]} -ge 2 && $((${#pairs[@]} % 2)) -eq 0 ]] || return 1
    if ! status=$(_env_write_kv "$file" "${pairs[@]}"); then
        local i
        for ((i = 0; i < ${#pairs[@]}; i += 2)); do
            _env_write_kv_warn "${pairs[i]}" "$status"
        done
        return 1
    fi
}

_reload_env() {
    [[ -f "$SCRIPT_DIR/.env" ]] || return 0
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
}
