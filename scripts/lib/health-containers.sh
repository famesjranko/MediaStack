#!/usr/bin/env bash
# Owns: health_containers - one verdict per compose service of the active profiles.
# Sources: scripts/lib/profiles.sh (profiles_build_args). Presentation lives in health.sh.

_HC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F profiles_build_args >/dev/null 2>&1 || source "$_HC_LIB_DIR/profiles.sh"
# shellcheck source=/dev/null
declare -F service_intent_list >/dev/null 2>&1 || source "$_HC_LIB_DIR/service-intent.sh"

# Prints one "STATUS|msg" line per service. `ps -a` keeps exited containers in
# view (plain `ps` hides them, which is how a dead Jellyfin went unreported); a
# service with no container at all is listed too.
health_containers() {
    local -a profiles=()
    profiles_build_args profiles
    if [[ "${STORAGE_MODE:-}" == "nas" && -s "$SCRIPT_DIR/config/state/storage-watchdog-stopped" ]]; then
        echo "fail|NAS storage unreachable - NAS-dependent services stopped by the watchdog"
    fi
    local services rows
    services=$(docker compose "${profiles[@]}" config --services 2>/dev/null) || {
        echo "skip|Containers: cannot list the compose services"
        return 0
    }
    rows=$(docker compose "${profiles[@]}" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.Status}}' 2>/dev/null) || rows=""
    local intents="" graph="" json=""
    if [[ "${STORAGE_MODE:-}" == "nas" ]]; then
        if ! intents=$(service_intent_list 2>/dev/null); then
            echo "warn|Cannot read user-stopped services; stop causes may be missing"
        elif [[ -n "$intents" ]]; then
            json=$(docker compose "${profiles[@]}" config --format json 2>/dev/null) || json=""
            graph=$(python3 -I -c '
import json, sys
try:
    services = json.load(sys.stdin)["services"]
    for name in services:
        found, todo = set(), [name]
        while todo:
            for dep in services.get(todo.pop(), {}).get("depends_on") or []:
                if dep not in found and dep != name:
                    found.add(dep)
                    todo.append(dep)
        print(name, *sorted(found))
except (ValueError, KeyError, TypeError, AttributeError):
    sys.exit(1)
' <<<"$json") || graph=""
        fi
    fi
    local svc line state health status found running dep deps dep_line dep_state
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        found=""
        running=""
        while IFS='|' read -r line state health status; do
            [[ "$line" == "$svc" ]] || continue
            found=1
            case "$state" in
                running)
                    running=1
                    case "$health" in
                        unhealthy) echo "fail|${svc}: ${status} (unhealthy)" ;;
                        starting) echo "warn|${svc}: ${status} (health check still starting)" ;;
                        *) echo "ok|${svc}: ${status}" ;;
                    esac
                    ;;
                exited)
                    # Every service restarts unless-stopped, so an exit Docker did not
                    # restart is a stop: 0 is a clean one, 143 is SIGTERM from `stop`.
                    # Any other code is a crash or a kill and stays a failure.
                    if [[ "$status" =~ ^Exited\ \((0|143)\) ]]; then
                        echo "warn|${svc}: stopped (${status})"
                    else
                        echo "fail|${svc}: ${status:-$state}"
                    fi
                    ;;
                *) echo "fail|${svc}: ${status:-$state}" ;;
            esac
        done <<<"$rows"
        [[ -n "$found" ]] || echo "warn|${svc}: no container (not started)"
        # Running containers outrank stale intent entries.
        if [[ -z "$running" ]]; then
            if grep -Fxq "$svc" <<<"$intents"; then
                echo "warn|${svc}: stopped by you from the launcher; Start a service brings it back"
            else
                while read -r line deps; do
                    [[ "$line" == "$svc" ]] || continue
                    for dep in $deps; do
                        grep -Fxq "$dep" <<<"$intents" || continue
                        dep_state=""
                        while IFS='|' read -r dep_line dep_state _; do
                            [[ "$dep_line" == "$dep" ]] && break
                            dep_state=""
                        done <<<"$rows"
                        [[ "$dep_state" == "running" ]] && continue
                        echo "warn|${svc}: depends on ${dep}, stopped by you from the launcher"
                    done
                done <<<"$graph"
            fi
        fi
    done <<<"$services"
}
