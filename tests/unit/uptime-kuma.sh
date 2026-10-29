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

# The cleanup tests drive the REAL configurator in a child shell with docker,
# mktemp and timeout stubbed. They differ in what the `docker run` step
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
mktemp() {
    if ((\$#)); then command mktemp "\$@"; else printf '%s' "$envfile"; fi
}
export TMPDIR="$(dirname "$envfile")"
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
assert_eq 1 "$(compgen -G "$KUMA_TMP/kuma-configure.*" | wc -l)" \
    "stderr file exists before the run is interrupted"
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
assert_eq "" "$(compgen -G "$KUMA_TMP/kuma-configure.*")" \
    "stderr file is gone after the run is interrupted mid-flight"
rm -rf "$KUMA_TMP"
trap - EXIT

# Given a foreground configurator with a real controlling terminal.
INT_TMP=$(mktemp -d)
trap 'rm -rf "$INT_TMP"' EXIT
write_kuma_worker "$INT_TMP/worker.sh" "$INT_TMP/envfile" \
    "touch '$INT_TMP/ready'; sleep 30" 'configure_uptime_kuma >/dev/null 2>&1'
INT_RC=0
# When Ctrl-C interrupts the helper after both temporary files exist.
python3 - "$INT_TMP/worker.sh" "$INT_TMP/ready" <<'PY' || INT_RC=$?
import os
import pathlib
import pty
import signal
import sys
import time

pid, terminal = pty.fork()
if pid == 0:
    os.execlp("bash", "bash", sys.argv[1])
try:
    deadline = time.monotonic() + 5
    while not pathlib.Path(sys.argv[2]).exists():
        if time.monotonic() > deadline:
            raise RuntimeError("helper did not start")
        time.sleep(0.02)
    os.write(terminal, b"\x03")
    while True:
        child, status = os.waitpid(pid, os.WNOHANG)
        if child:
            pid = 0
            assert os.waitstatus_to_exitcode(status) in (-signal.SIGINT, 130), status
            break
        if time.monotonic() > deadline:
            raise RuntimeError("Ctrl-C did not stop configuration")
        time.sleep(0.02)
    # The parent's exit can precede the command substitution's cleanup.
    scratch = pathlib.Path(sys.argv[2]).parent
    deadline = time.monotonic() + 2
    while (scratch / "envfile").exists() or list(scratch.glob("kuma-configure.*")):
        if time.monotonic() > deadline:
            break
        time.sleep(0.02)
finally:
    if pid:
        os.killpg(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
    os.close(terminal)
PY

# Then the interrupted configurator leaves no credentials or stderr file.
assert_eq 0 "$INT_RC" 'Ctrl-C interrupts the real foreground configurator'
assert_file_absent "$INT_TMP/envfile" 'Ctrl-C removes the credentials file'
assert_eq "" "$(compgen -G "$INT_TMP/kuma-configure.*")" 'Ctrl-C removes the stderr file'
rm -rf "$INT_TMP"
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
    ": >\"$NORMAL_TMP/reached\"; printf '{\"created\":[],\"skipped\":[],\"errors\":[]}\\n'" \
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
# The self-disarm above MASKS the original bug: it stops the RETURN trap
# re-firing in the caller's frame, which is the only place the deferred
# expansion read an unset name. Reverting the expansion alone therefore breaks
# nothing observable at runtime, and every assertion above stays green. The
# expand-at-set-time property is now defence-in-depth, and the only honest way
# left to guard it is to read the trap lines themselves.
_kuma_trap_lines=$(grep -E '^[[:space:]]*trap .*(TERM|RETURN)$' \
    "$REPO_ROOT/scripts/services/uptime-kuma/main.sh")
assert_eq "2" "$(grep -c '@Q' <<<"$_kuma_trap_lines")" \
    "both cleanup traps expand the env-file path when the trap is set"
assert_eq "0" "$(grep -c '\$_kuma_' <<<"$_kuma_trap_lines")" \
    "neither cleanup trap defers expansion to a frame where the local is gone"
rm -rf "$NORMAL_TMP"
trap - EXIT

# --- #153: a stale fixed-path error log must not skip the whole step -------
# The error log was once the fixed path /tmp/kuma-configure.err. A stale copy
# owned by another user (one `sudo` run) made the stderr redirect fail, so the
# step returned "no output" and created no monitors. The test runs in a user
# and mount namespace with a private /tmp, so it never touches the host's
# /tmp. A directory at the legacy path blocks the redirect even for the
# namespace's root. The real mktemp runs, so the private /tmp also shows that
# no temp file survives the step.
STALE_TMP=$(mktemp -d)
trap 'rm -rf "$STALE_TMP"' EXIT
STALE_WORKER="$STALE_TMP/worker.sh"
write_kuma_worker "$STALE_WORKER" "$STALE_TMP/unused" \
    "printf 'KUMA_STDERR_SENTINEL\\n' >&2; printf '{\"created\":[\"Jellyfin\"],\"skipped\":[],\"errors\":[]}\\n'" \
    'unset -f mktemp
unset TMPDIR
mkdir /tmp/kuma-configure.err
configure_uptime_kuma
printf "LEFTOVER:%s\n" "$(find /tmp -mindepth 1 ! -path /tmp/kuma-configure.err)"'
if unshare -rm sh -c 'mount -t tmpfs none /tmp' 2>/dev/null; then
    # Open the worker before /tmp is replaced, because it lives under /tmp.
    STALE_OUT=$(unshare -rm bash -c \
        'exec 3<"$1"; mount -t tmpfs none /tmp && bash /dev/fd/3' _ "$STALE_WORKER" 2>&1)
    assert_contains "$STALE_OUT" "Monitors created: Jellyfin" \
        "monitors are created when a stale error log blocks the legacy fixed path"
    assert_not_contains "$STALE_OUT" "returned no output" \
        "the step is not skipped when a stale error log blocks the legacy fixed path"
    assert_contains "$STALE_OUT" "LEFTOVER:" "the worker reached the leftover check"
    assert_not_contains "$STALE_OUT" "LEFTOVER:/" "no temp file survives the step"
else
    skip "stale error log: a private /tmp mount is unavailable on this host"
fi
rm -rf "$STALE_TMP"
trap - EXIT

# Given a private temporary directory and a helper that returns each supported result.
SCRATCH_TMP=$(mktemp -d)
trap 'rm -rf "$SCRATCH_TMP"' EXIT
mkdir "$SCRATCH_TMP/private'logs"
PREVIOUS_STDERR=
for RESULT_KIND in success empty error; do
    (
        docker() {
            case "$1" in
                compose) printf 'jellyfin\n' ;;
                pull) return 0 ;;
                run)
                    readlink /proc/self/fd/2 >"$SCRATCH_TMP/stderr-path"
                    stat -Lc '%a' /proc/self/fd/2 >"$SCRATCH_TMP/stderr-mode"
                    printf 'fixture helper diagnostic\n' >&2
                    case "$RESULT_KIND" in
                        success) printf '{"created":["Jellyfin"],"skipped":[],"errors":[]}' ;;
                        error)
                            printf '{"error":"fixture authentication failure"}'
                            return 1
                            ;;
                    esac
                    ;;
            esac
        }
        timeout() {
            shift
            "$@"
        }

        # When the real configurator runs with real temporary files.
        TMPDIR="$SCRATCH_TMP/private'logs" configure_uptime_kuma
    ) >"$SCRATCH_TMP/output" 2>"$SCRATCH_TMP/errors"

    # Then the helper uses a new private stderr file and leaves no temporary files.
    STDERR_PATH=$(cat "$SCRATCH_TMP/stderr-path" 2>/dev/null)
    assert_contains "$STDERR_PATH" "$SCRATCH_TMP/private'logs/" \
        "$RESULT_KIND: helper stderr is inside the caller's temporary directory"
    assert_eq 600 "$(cat "$SCRATCH_TMP/stderr-mode" 2>/dev/null)" \
        "$RESULT_KIND: helper stderr is readable only by its owner"
    assert_eq true "$([[ "$PREVIOUS_STDERR" != "$STDERR_PATH" ]] && echo true)" \
        "$RESULT_KIND: stderr gets a unique path"
    assert_eq "" "$(ls -A "$SCRATCH_TMP/private'logs")" \
        "$RESULT_KIND: stderr and credentials are removed on return"
    case "$RESULT_KIND" in
        success) assert_file_contains "$SCRATCH_TMP/errors" 'Monitors created: Jellyfin' \
            'success: provisioning result reaches the caller' ;;
        empty) assert_file_contains "$SCRATCH_TMP/errors" 'fixture helper diagnostic' \
            'empty: helper diagnostics remain readable until the warning is logged' ;;
        error) assert_file_contains "$SCRATCH_TMP/errors" 'fixture authentication failure' \
            'error: authentication failure reaches the caller' ;;
    esac
    PREVIOUS_STDERR="$STDERR_PATH"
done

# Given a failure to allocate either temporary file.
for FAILED_FILE in stderr credentials; do
    (
        mktemp() {
            if [[ "$FAILED_FILE" == stderr || $# == 0 ]]; then return 1; fi
            command mktemp "$@"
        }
        docker() {
            case "$1" in
                compose) printf 'jellyfin\n' ;;
                run) touch "$SCRATCH_TMP/unexpected-run" ;;
            esac
        }
        timeout() {
            shift
            "$@"
        }

        # When configuration cannot allocate its scratch files.
        TMPDIR="$SCRATCH_TMP/private'logs" configure_uptime_kuma
    ) >"$SCRATCH_TMP/output" 2>"$SCRATCH_TMP/errors"

    # Then configuration reports the failure without running the helper or leaking files.
    assert_file_contains "$SCRATCH_TMP/errors" 'Could not create Uptime Kuma' \
        "$FAILED_FILE: allocation failure is reported"
    assert_file_absent "$SCRATCH_TMP/unexpected-run" "$FAILED_FILE: helper does not run"
    assert_eq "" "$(ls -A "$SCRATCH_TMP/private'logs")" \
        "$FAILED_FILE: allocation failure leaves no temporary files"
done

scenario_end "$CURRENT_SCENARIO"
summary
