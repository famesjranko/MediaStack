#!/usr/bin/env bash
# Owns: health_containers - one verdict per compose service of the active profiles.
# Sources: scripts/lib/profiles.sh (profiles_build_args). Presentation lives in health.sh.

_HC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F profiles_build_args >/dev/null 2>&1 || source "$_HC_LIB_DIR/profiles.sh"

# Prints one "STATUS|msg" line per service. `ps -a` keeps exited containers in
# view (plain `ps` hides them, which is how a dead Jellyfin went unreported); a
# service with no container at all is listed too.
health_containers() {
    local -a profiles=()
    profiles_build_args profiles
    local services rows
    services=$(docker compose "${profiles[@]}" config --services 2>/dev/null) || {
        echo "skip|Containers: cannot list the compose services"
        return 0
    }
    rows=$(docker compose "${profiles[@]}" ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.Status}}' 2>/dev/null) || rows=""
    local svc line state health status found
    while IFS= read -r svc; do
        [[ -n "$svc" ]] || continue
        found=""
        while IFS='|' read -r line state health status; do
            [[ "$line" == "$svc" ]] || continue
            found=1
            case "$state" in
                running)
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
    done <<<"$services"
}
