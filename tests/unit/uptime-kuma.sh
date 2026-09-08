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

# Both tests below drive the REAL configurator in a child shell with docker,
# mktemp and timeout stubbed. They differ only in what the `docker run` step
# does and what the worker does after the call returns, so the scaffolding is
# written once here.
#   $1 worker path  $2 env-file path  $3 `docker run` stub body  $4 epilogue
# "timeout 120 docker run ..." would otherwise exec the real docker(1) via
# PATH — a fork+exec loses this shell's docker() function entirely — so
# timeout is stubbed too, dropping the duration and calling straight through.
write_kuma_worker() {
    local worker="$1" envfile="$2" run_body="$3" epilogue="$4"
    cat >"$worker" <<WORKER_EOF
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$REPO_ROOT"
CONFIG_FILE=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/services/uptime-kuma/main.sh"
mktemp() { printf '%s' "$envfile"; }
docker() {
    case "\$1" in
        compose) printf 'jellyfin\n' ;;
        pull) return 0 ;;
        run) $run_body ;;
    esac
}
timeout() {
    shift
    "\$@"
}
JELLYFIN_ADMIN_USER=testuser
JELLYFIN_ADMIN_PASSWORD=SEC5_SENTINEL_PW
$epilogue
WORKER_EOF
    chmod +x "$worker"
}

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
write_kuma_worker "$WORKER" "$ENVFILE" 'sleep 30' \
    'configure_uptime_kuma >/dev/null 2>&1'

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

# --- the cleanup traps must survive a NORMAL return, not just an interrupt ---
# A bash RETURN trap fires after the function's locals have gone out of scope,
# so a single-quoted trap body that defers "$_kuma_envfile" expands an unset
# name in the caller's frame. Under `set -u` that aborts the whole configure
# run at the caller's line — Beszel never gets configured, Stage 1 exits 1, and
# `setup.sh --remote` then refuses with "Stage 1 is not complete yet". The
# interrupt test above kills the worker mid-flight and never reaches this path.
NORMAL_TMP=$(mktemp -d)
trap 'rm -rf "$NORMAL_TMP"' EXIT
NORMAL_ENVFILE="$NORMAL_TMP/kuma-envfile"
NORMAL_WORKER="$NORMAL_TMP/worker.sh"
# The epilogue calls through a wrapper so the RETURN trap fires into a caller
# frame, exactly as _run_configure does in scripts/configure.sh. It then dumps
# the surviving trap state: a RETURN trap left armed re-fires on every later
# `source` in the same shell and would disarm any TERM handler installed after
# it.
write_kuma_worker "$NORMAL_WORKER" "$NORMAL_ENVFILE" \
    ": >\"$NORMAL_TMP/reached\"; printf '{\"created\":0,\"skipped\":0,\"errors\":[]}\\n'" \
    'caller_frame() { configure_uptime_kuma >/dev/null; }
caller_frame
trap -p RETURN >"'"$NORMAL_TMP"'/return-trap"
trap -p TERM >"'"$NORMAL_TMP"'/term-trap"'
NORMAL_ERR="$NORMAL_TMP/stderr.log"
NORMAL_RC=0
bash "$NORMAL_WORKER" >/dev/null 2>"$NORMAL_ERR" || NORMAL_RC=$?
assert_eq "0" "$NORMAL_RC" "configure_uptime_kuma returns 0 on the normal path under set -u"
assert_eq "0" "$(grep -c 'unbound variable' "$NORMAL_ERR")" \
    "cleanup traps reference no out-of-scope local on the normal return path"
assert_eq "0" "$([[ -f "$NORMAL_ENVFILE" ]] && echo 1 || echo 0)" \
    "env-file is removed after a normal return"
assert_eq "1" "$([[ -f "$NORMAL_TMP/reached" ]] && echo 1 || echo 0)" \
    "the configurator reached the trapped path (assertions above are not vacuous)"
assert_eq "" "$(cat "$NORMAL_TMP/return-trap" 2>/dev/null)" \
    "the RETURN trap disarms itself, so it cannot re-fire on a later source"
assert_eq "" "$(cat "$NORMAL_TMP/term-trap" 2>/dev/null)" \
    "the RETURN trap clears the TERM trap it installed"
rm -rf "$NORMAL_TMP"
trap - EXIT

scenario_end "$CURRENT_SCENARIO"
summary
