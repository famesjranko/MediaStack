#!/usr/bin/env bash
# Owns: the persisted "the user stopped this service" intent, one service name
# per line in config/state/user-stopped-services.
# Writers: the launcher (Stop/Start a service, Stop/Start all) and the NAS
# watchdog (drops an entry when it finds that service running again).
# Reader: the NAS watchdog, which must not restart what the user stopped.
# Side-effect-free at source time; needs SCRIPT_DIR (the repo root) and
# storage_data_services (scripts/setup/storage.sh) at call time; storage_is_nas,
# when defined, limits the file to NAS installs.
# Only launcher actions are tracked: direct `docker` commands and setup.sh/update.sh
# leave this file alone, so a running service always outranks a stale entry.

[[ -n "${_MS_SERVICE_INTENT_LOADED:-}" ]] && return 0
_MS_SERVICE_INTENT_LOADED=1

service_intent_file() { printf '%s\n' "$SCRIPT_DIR/config/state/user-stopped-services"; }

# Print the valid service names in the file, one per line. Missing or empty
# means "the user stopped nothing" (rc 0). Lines that are not a plain service
# name (blank, spaces, path characters, over 64 characters) are skipped, so a
# damaged file cannot inject anything. An entry that exists but cannot be read
# as a regular file returns rc 1: intent is then unknown, and the caller decides.
service_intent_list() {
    local f line
    f="$(service_intent_file)"
    [[ -e "$f" ]] || return 0
    [[ -f "$f" && -r "$f" ]] || return 1
    # The loop body always ends in success, so only a failed open of $f is rc 1.
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]]; then printf '%s\n' "$line"; fi
    done <"$f"
}

# Read-modify-write under flock. The new content goes to a temp file in the
# same directory and is renamed over the old one, so a concurrent reader sees
# the old file or the new file, never a partial one.
# Usage: _service_intent_update add|remove|clear [name...]
_service_intent_update() {
    local mode="$1" f dir
    shift
    # Only the NAS watchdog reads the file; local installs keep no intent state.
    if declare -F storage_is_nas >/dev/null && ! storage_is_nas; then return 0; fi
    f="$(service_intent_file)"
    dir="${f%/*}"
    (
        local -A keep=()
        local names=() n tmp
        mkdir -p "$dir" || exit 1
        if command -v flock >/dev/null 2>&1; then
            exec 9>"$f.lock" || exit 1
            flock 9 || exit 1
        fi
        mapfile -t names < <(service_intent_list || echo "!unreadable")
        [[ "${names[0]:-}" == "!unreadable" ]] && exit 1
        case "$mode" in
            add) names+=("$@") ;;
            remove)
                for n in "${names[@]}"; do
                    [[ " $* " == *" $n "* ]] || keep[$n]=1
                done
                names=("${!keep[@]}")
                keep=()
                ;;
            clear) names=() ;;
        esac
        for n in "${names[@]}"; do
            [[ "$n" =~ ^[a-z0-9][a-z0-9_.-]{0,63}$ ]] && keep[$n]=1
        done
        tmp="$(mktemp "$dir/.user-stopped-services.XXXXXX")" || exit 1
        trap 'rm -f "$tmp"' EXIT
        if ((${#keep[@]} > 0)); then
            printf '%s\n' "${!keep[@]}" | sort >"$tmp" || exit 1
        fi
        chmod 644 "$tmp" && mv -f "$tmp" "$f"
    ) || {
        printf 'warning: could not update %s; the NAS watchdog may restart a service you stopped.\n' "$f" >&2
        return 1
    }
}

# The user stopped these services.
service_intent_record() { _service_intent_update add "$@"; }

# The user started these services (or they are running again).
service_intent_clear() { _service_intent_update remove "$@"; }

# "Start all": nothing is stopped by the user any more.
service_intent_clear_all() { _service_intent_update clear; }

# "Stop all": the whole NAS-dependent set is stopped by the user.
service_intent_record_data_services() {
    local svcs=()
    mapfile -t svcs < <(storage_data_services)
    service_intent_record "${svcs[@]}"
}
