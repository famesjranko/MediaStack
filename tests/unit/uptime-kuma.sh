#!/usr/bin/env bash
# tests/unit/uptime-kuma.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uptime-kuma"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
CONFIG_FILE=/dev/null

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/services/uptime-kuma/main.sh"

monitors=$(_uptime_kuma_monitors_json "jellyfin sonarr beszel wireguard")

monitor_url() {
    local name="$1"
    printf '%s' "$monitors" | NAME="$name" python3 -c '
import json
import os
import sys

name = os.environ["NAME"]
for monitor in json.load(sys.stdin):
    if monitor.get("name") == name:
        print(monitor.get("url", ""))
        break
'
}

assert_eq "http://jellyfin:8096/health" "$(monitor_url Jellyfin)" \
    "Uptime Kuma monitor URL: Jellyfin health path"
assert_eq "http://sonarr:8989/ping" "$(monitor_url Sonarr)" \
    "Uptime Kuma monitor URL: Sonarr ping path"
assert_eq "http://beszel:8090/api/health" "$(monitor_url Beszel)" \
    "Uptime Kuma monitor URL: Beszel API health path"
assert_eq "http://wireguard:51821" "$(monitor_url WireGuard)" \
    "Uptime Kuma monitor URL: WireGuard optional service"

# --- SEC-5: the KUMA_PW env-file must not survive an interrupted run --------
# configure_uptime_kuma writes the shared admin password to a mktemp env-file
# for the 120s `docker run`. A worker script runs the real configurator with
# docker/mktemp stubbed so the "run" step blocks; the driver interrupts the
# whole process group mid-flight (a real Ctrl-C hits every process in the
# foreground group, not just the immediate child) and asserts the env-file is
# gone rather than sitting in /tmp with the sentinel password still in it.
KUMA_TMP=$(mktemp -d)
trap 'rm -rf "$KUMA_TMP"' EXIT
ENVFILE="$KUMA_TMP/kuma-envfile"
WORKER="$KUMA_TMP/worker.sh"
cat >"$WORKER" <<WORKER_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$REPO_ROOT"
CONFIG_FILE=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/services/uptime-kuma/main.sh"
mktemp() { printf '%s' "$ENVFILE"; }
docker() {
    case "\$1" in
        compose) printf 'jellyfin\n' ;;
        pull) return 0 ;;
        run) sleep 30 ;;
    esac
}
# "timeout 120 docker run ..." would otherwise exec the real docker(1) via
# PATH — a fork+exec loses this shell's docker() function entirely — so
# timeout is stubbed too, dropping the duration and calling straight through.
timeout() {
    shift
    "\$@"
}
JELLYFIN_ADMIN_USER=testuser
JELLYFIN_ADMIN_PASSWORD=SEC5_SENTINEL_PW
configure_uptime_kuma >/dev/null 2>&1
WORKER_EOF
chmod +x "$WORKER"

setsid bash "$WORKER" &
WORKER_PID=$!
for _ in $(seq 1 100); do
    [[ -s "$ENVFILE" ]] && break
    sleep 0.02
done
assert_eq "0" "$([[ -f "$ENVFILE" ]] && echo 0 || echo 1)" "env-file exists once the docker run step starts"
assert_file_contains "$ENVFILE" "SEC5_SENTINEL_PW" "env-file holds the sentinel password mid-flight"
kill -TERM -"$WORKER_PID" 2>/dev/null
# The signal hits every process in the group at once with no ordering
# guarantee, so the top-level worker process can die (letting `wait` return)
# before its command-substitution subshell finishes running the cleanup trap.
# Poll for the whole group to actually be gone rather than trusting `wait`
# alone.
for _ in $(seq 1 100); do
    ps -o pid= -g "$WORKER_PID" >/dev/null 2>&1 || break
    sleep 0.02
done
wait "$WORKER_PID" 2>/dev/null
assert_eq "0" "$([[ -f "$ENVFILE" ]] && echo 1 || echo 0)" "env-file is gone after the run is interrupted mid-flight"
rm -rf "$KUMA_TMP"
trap - EXIT

scenario_end "$CURRENT_SCENARIO"
summary
