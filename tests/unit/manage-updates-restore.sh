#!/usr/bin/env bash
# Unit test - restore points for image updates, the revert that restores them,
# and "Update all" handling of stopped services.
#
# Real files in a temp SCRIPT_DIR (fake config dirs, policy and install-digest
# state) and the real launcher functions; only docker, the UI, the login helpers
# and sleep are stubbed. The docker stub appends every call to $tmp/docker.log and
# rewrites the qBittorrent config on `up -d`, like a newer image would.
#
# Run directly: ./tests/unit/manage-updates-restore.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="manage-updates-restore"
scenario_begin "$CURRENT_SCENARIO"

# Shared setup for each case: launcher sourced, state dirs, an old qBittorrent
# config, an install digest, and stubs. A case body is appended and runs in its
# own bash so stubs and the temp dir never leak between cases.
PROLOGUE='
source "$REPO_ROOT/mediastack" </dev/null
tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir -p "$tmp/config/state" "$tmp/config/qbittorrent"
source "$REPO_ROOT/scripts/setup/override.sh"
source "$REPO_ROOT/scripts/lib/json.sh"
IMAGE_CHANNEL=stable
JELLYFIN_ADMIN_PASSWORD=pw
OLD_CONF="WebUI\\Password_PBKDF2=OLDHASH"
NEW_CONF="WebUI\\Password_PBKDF2=NEWER-FORMAT"
printf "%s\n" "$OLD_CONF" > "$tmp/config/qbittorrent/qBittorrent.conf"
D="sha256:$(printf "a%.0s" {1..64})"
printf "qbittorrent\tlscr.io/linuxserver/qbittorrent:latest\t%s\n" "$D" > "$tmp/config/state/image-install.tsv"
: > "$tmp/docker.log"
UP_FAILS=0
NEWIMG=1   # 1: `up -d` starts a newer image that rewrites the config
_service_profile_flag(){ echo ""; }
_regenerate_override(){ return 0; }
storage_guard_before_start(){ return 0; }
_wait_service_running(){ return 0; }
_service_is_running(){ [[ ! -f "$tmp/stopped" ]]; }   # `docker compose stop` stops it, `up`/`start` runs it
tar(){ echo "tar $*" >> "$tmp/docker.log"; command tar "$@"; }
sleep(){ :; }
ui_log(){ printf "UI_%s:%s\n" "$1" "$2"; }
ui_confirm(){ echo "CONFIRM:$1" >&2; return "${CONFIRM_RC:-0}"; }
_verify_service_up(){ return 0; }
_qbt_login_shared(){ echo "LOGIN_CALLED" >> "$tmp/docker.log"; return "${LOGIN_RC:-0}"; }
docker(){
  echo "docker $*" >> "$tmp/docker.log"
  case "$1 $2" in "compose stop") : > "$tmp/stopped" ;; "compose start") rm -f "$tmp/stopped" ;; esac
  if [[ "$1 $2" == "compose up" ]]; then
    # A failed `up -d` aborts before it touches the container: a stopped one stays stopped.
    if ((UP_FAILS > 0)); then ((UP_FAILS--)); return 1; fi
    rm -f "$tmp/stopped"
    ((NEWIMG)) && printf "%s\n" "$NEW_CONF" > "$tmp/config/qbittorrent/qBittorrent.conf"
  fi
  return 0
}
conf(){ cat "$tmp/config/qbittorrent/qBittorrent.conf"; }
'

run_case() { REPO_ROOT="$REPO_ROOT" MEDIASTACK_NONINTERACTIVE=1 bash -c "$PROLOGUE"$'\n'"$1" 2>&1; }

# --- update creates a restore point -----------------------------------------
# Given qBittorrent on its install image with an old-format config
# When it is updated and the new image rewrites the config
# Then a restore point holding the OLD config exists and is recorded
out=$(run_case '
  _apply_service_update qbittorrent 1; echo "RC=$?"
  echo "POINT=[$(tar -xzOf "$tmp/config/state/restore-points/qbittorrent.tar.gz" qbittorrent/qBittorrent.conf)]"
  echo "INDEX=[$(cut -f1,3 "$tmp/config/state/restore-points.tsv")]"
  echo "MODE=$(stat -c %a "$tmp/config/state/restore-points/qbittorrent.tar.gz")"
  echo "NOW=[$(conf)]"
')
assert_contains "$out" "RC=0" "update: succeeds"
assert_contains "$out" 'POINT=[WebUI\Password_PBKDF2=OLDHASH]' "update: restore point holds the config from before the update"
assert_contains "$out" "INDEX=[qbittorrent	qbittorrent.tar.gz]" "update: restore point is recorded in the index"
assert_contains "$out" "MODE=600" "update: restore point is owner-only (it holds secrets)"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=NEWER-FORMAT]' "update: the live config is the new image's (point is not a no-op)"

# Given a service that already floated (policy latest) with an older restore point
# When it is updated again
# Then the original restore point is kept (it belongs to the install image)
out=$(run_case '
  mkdir -p "$tmp/config/state/restore-points"
  mkdir -p "$tmp/seed/qbittorrent"; echo FIRST > "$tmp/seed/qbittorrent/qBittorrent.conf"
  tar -czf "$tmp/config/state/restore-points/qbittorrent.tar.gz" -C "$tmp/seed" qbittorrent
  printf "qbittorrent\t2026-01-01T00:00:00Z\tqbittorrent.tar.gz\n" > "$tmp/config/state/restore-points.tsv"
  printf "qbittorrent\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _apply_service_update qbittorrent 1
  echo "POINT=[$(tar -xzOf "$tmp/config/state/restore-points/qbittorrent.tar.gz" qbittorrent/qBittorrent.conf)]"
')
assert_contains "$out" "POINT=[FIRST]" "update: an already-floated service keeps its original restore point"

# Given a config dir over the size limit
# When the service is updated
# Then no restore point is made, the user is told, and the update still goes ahead
out=$(run_case '
  _MU_RESTORE_MAX_KB=0
  _apply_service_update qbittorrent 1; echo "RC=$?"
  ls "$tmp/config/state/restore-points" 2>/dev/null | wc -l | sed "s/^/POINTS=/"
')
assert_contains "$out" "RC=0" "update: an oversize config does not block the update"
assert_contains "$out" "POINTS=0" "update: an oversize config gets no restore point"
assert_contains "$out" "UI_warn:qbittorrent: no restore point saved" "update: tells the user no restore point was saved"

# --- the config copy is taken with the service stopped ----------------------
# Given a running qBittorrent
# When it is updated
# Then it is stopped, then its config is archived, then the new image starts
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  grep -nE "compose stop|tar -czf|compose up" "$tmp/docker.log" | sed "s/^[0-9]*://" | sed "s/ -czf.*/ -czf/;s/ -d .*/ -d/"
')
assert_eq "docker compose stop qbittorrent|tar -czf|docker compose up -d" "$(paste -sd'|' <<<"$out")" \
    "snapshot order: update stops the service, archives its config, then starts the new image"

# Given a running qBittorrent
# When a config snapshot is requested without stopping it first
# Then the snapshot is refused and no archive is made
out=$(run_case '
  _snapshot_config qbittorrent; echo "RC=$?"
  ls "$tmp/config/state/restore-points" 2>/dev/null | wc -l | sed "s/^/ARCHIVES=/"
')
assert_contains "$out" "RC=1" "snapshot: refused while the service runs"
assert_contains "$out" "ARCHIVES=0" "snapshot: no archive is made while the service runs"
assert_contains "$out" "UI_warn:qbittorrent: not copying config/qbittorrent while qbittorrent runs" "snapshot: says why it refused"

# Given a running qBittorrent and a restore point
# When a config restore is requested without stopping it first
# Then the restore is refused and the live config is untouched
out=$(run_case '
  : > "$tmp/stopped"; _snapshot_config qbittorrent; rm -f "$tmp/stopped"
  echo CHANGED > "$tmp/config/qbittorrent/qBittorrent.conf"
  _restore_config qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"
')
assert_contains "$out" "RC=1" "restore: refused while the service runs"
assert_contains "$out" "NOW=[CHANGED]" "restore: the live config is untouched while the service runs"

# --- revert restores config and image, then verifies ------------------------
# Given qBittorrent updated (restore point taken, config rewritten by the new image)
# When it is reverted
# Then the service is stopped before the old config is put back, brought up on the
#   install-digest pin, its login is checked, and the restore point is discarded
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  : > "$tmp/docker.log"; NEWIMG=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"
  echo "PIN=[$(grep ^qbittorrent "$tmp/config/state/image-policy.tsv" | cut -f2 | cut -c1-49)]"
  echo "ORDER=$(grep -E "compose stop|tar -czf|tar -xzf|compose up" "$tmp/docker.log" \
    | sed -e "s/^docker compose stop.*/stop/;s/^tar -czf.*/save-newer-config/;s/^tar -xzf.*/restore-old-config/;s/^docker compose up.*/up/" | paste -sd"|")"
  echo "POINT_LEFT=$(ls "$tmp/config/state/restore-points" | wc -l)"
  cat "$tmp/docker.log"
')
assert_contains "$out" "RC=0" "revert: succeeds"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=OLDHASH]' "revert: the config from before the update is back"
assert_contains "$out" "PIN=[lscr.io/linuxserver/qbittorrent:latest@sha256:aaa" "revert: the service is pinned to its install image"
assert_contains "$out" "LOGIN_CALLED" "revert: the qBittorrent login is checked"
assert_contains "$out" "UI_ok:qbittorrent: back up and MediaStack can still log in." "revert: reports the verified login"
assert_contains "$out" "POINT_LEFT=0" "revert: the used restore point (and safety copy) are discarded"
assert_eq "stop|save-newer-config|restore-old-config|up" "$(sed -n 's/^ORDER=//p' <<<"$out")" \
    "revert: the service is stopped, the newer config saved, the old config restored, then started"

# Given a reverted qBittorrent whose login still fails (the F2 symptom)
# When the revert finishes
# Then it reports a clear failure, returns non-zero and keeps the restore point
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  LOGIN_RC=1; NEWIMG=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "POINT_LEFT=$(ls "$tmp/config/state/restore-points" | wc -l)"
')
assert_contains "$out" "RC=1" "revert-login: a failed login makes the revert fail"
assert_contains "$out" "UI_error:qbittorrent: reverted and running, but MediaStack can no longer log in to it." \
    "revert-login: says plainly that the login is broken"
assert_contains "$out" "POINT_LEFT=2" "revert-login: the restore point and the newer-config copy are kept"

# Given an updated qBittorrent whose safety copy cannot be made at revert time
# When the revert runs
# Then its config is not touched, the stopped container is started again, and the revert fails
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  _MU_RESTORE_MAX_KB=0; NEWIMG=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"
  echo "RUNNING=$(_service_is_running qbittorrent && echo yes || echo no)"
  grep -c "compose start qbittorrent" "$tmp/docker.log" | sed "s/^/STARTS=/"
')
assert_contains "$out" "RC=1" "revert-safety: no safety copy fails the revert"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=NEWER-FORMAT]' "revert-safety: the config is left as it was"
assert_contains "$out" "RUNNING=yes" "revert-safety: the service is not left stopped"

# Given a revert whose image cannot start (the first up fails)
# When the revert falls back to the previous image
# Then the newer config that the previous image needs is put back, and the service runs again
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  UP_FAILS=1; NEWIMG=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"
  echo "RUNNING=$(_service_is_running qbittorrent && echo yes || echo no)"
  echo "UPS=$(grep -c "compose up" "$tmp/docker.log")"
')
assert_contains "$out" "RC=1" "revert-fail: a failed start fails the revert"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=NEWER-FORMAT]' "revert-fail: the previous image gets its own (newer) config back"
assert_contains "$out" "RUNNING=yes" "revert-fail: the service is running again after the fallback"
assert_contains "$out" "UPS=3" "revert-fail: the fallback starts the service with up -d (update, failed revert, fallback)"
assert_not_contains "$out" "is stopped - the new image is staged" "revert-fail: a service that ran is not reported as staged"

# Given a running qBittorrent whose update cannot start (up -d fails)
# When it is updated
# Then the update fails and the service it stopped for the restore point runs again
out=$(run_case '
  UP_FAILS=1
  _apply_service_update qbittorrent 1; echo "RC=$?"
  echo "RUNNING=$(_service_is_running qbittorrent && echo yes || echo no)"
  grep -c "compose start qbittorrent" "$tmp/docker.log" | sed "s/^/STARTS=/"
')
assert_contains "$out" "RC=1" "update-fail: a failed start fails the update"
assert_contains "$out" "RUNNING=yes" "update-fail: the service is not left stopped"
assert_contains "$out" "STARTS=1" "update-fail: the stopped container is started again"

# Given a stopped qBittorrent that was updated and whose revert fallback runs
# When the first revert step fails
# Then the fallback does not start a service that the user had stopped
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  : > "$tmp/stopped"; NEWIMG=0; : > "$tmp/docker.log"
  _MU_RESTORE_MAX_KB=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "RUNNING=$(_service_is_running qbittorrent && echo yes || echo no)"
  grep -cE "compose (up|start)" "$tmp/docker.log" | sed "s/^/STARTS=/"
')
assert_contains "$out" "RUNNING=no" "revert-stopped: a service the user stopped stays stopped"
assert_contains "$out" "STARTS=0" "revert-stopped: nothing starts it"

# Given an updated qBittorrent whose live config gained a file the newer version made
# When the revert restores the restore point
# Then the file is gone, the old config is back, and no staging directory is left
out=$(run_case '
  _apply_service_update qbittorrent 1 >/dev/null
  echo wal > "$tmp/config/qbittorrent/qBittorrent.db-wal"
  : > "$tmp/stopped"
  _restore_config qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"
  echo "WAL=$([[ -e "$tmp/config/qbittorrent/qBittorrent.db-wal" ]] && echo kept || echo gone)"
  echo "LEFT=$(ls "$tmp/config" | paste -sd"|")"
')
assert_contains "$out" "RC=0" "restore: succeeds"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=OLDHASH]' "restore: the old config is back"
assert_contains "$out" "WAL=gone" "restore: a file the newer version created does not survive"
assert_eq "qbittorrent|state" "$(sed -n 's/^LEFT=//p' <<<"$out")" "restore: no staging or aside directory is left in config"

# --- no restore point: warn and confirm -------------------------------------
# Given a floated service with no restore point (updated before restore points existed)
# When the user declines the confirmation
# Then nothing changes: no pull, no recreate, the config and policy are untouched
out=$(run_case '
  CONFIRM_RC=1
  printf "qbittorrent\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "POLICY=[$(cut -f2 "$tmp/config/state/image-policy.tsv" | tail -1)]"
  echo "COMPOSE_CALLS=$(grep -c "docker compose" "$tmp/docker.log")"
')
assert_contains "$out" "UI_warn:qbittorrent: no restore point for its config." "no-point: warns before reverting"
assert_contains "$out" "CONFIRM:Revert the qbittorrent image anyway" "no-point: asks for confirmation"
assert_contains "$out" "RC=1" "no-point: declining returns non-zero"
assert_contains "$out" "POLICY=[latest]" "no-point: declining leaves the policy alone"
assert_contains "$out" "COMPOSE_CALLS=0" "no-point: declining touches no container"

# Given the same service
# When the user accepts
# Then the image reverts, the config is left as is, and the login is still verified
out=$(run_case '
  printf "qbittorrent\tlatest\n" > "$tmp/config/state/image-policy.tsv"
  printf "%s\n" "$NEW_CONF" > "$tmp/config/qbittorrent/qBittorrent.conf"; NEWIMG=0
  _reset_service_to_default qbittorrent; echo "RC=$?"
  echo "NOW=[$(conf)]"; cat "$tmp/docker.log"
')
assert_contains "$out" "RC=0" "no-point: accepting reverts the image"
assert_contains "$out" 'NOW=[WebUI\Password_PBKDF2=NEWER-FORMAT]' "no-point: the config is not invented or changed"
assert_contains "$out" "LOGIN_CALLED" "no-point: the login is still verified"

# --- Update all and stopped services ----------------------------------------
# Given two updatable services, one running and one stopped
# When "Update all" is opened
# Then only the running one is counted and listed, and the stopped one is named as skipped
out=$(run_case '
  CONFIRM_RC=1
  _service_is_running(){ [[ "$1" != "autoheal" ]]; }
  tsv=$(printf "sonarr\tstable\tdefault\tUpdate available\ttrue\nautoheal\tstable\tdefault\tUpdate available\ttrue\n")
  launcher_pause_for_menu(){ :; }
  _menu_update_all "$tsv"
')
assert_contains "$out" "UI_warn:About to update 1 service(s)" "update-all: counts only running services"
assert_contains "$out" "UI_info:Services: sonarr" "update-all: lists only running services"
assert_contains "$out" "Skipped (stopped): autoheal" "update-all: names the skipped stopped service"

# Given the only updatable service is stopped
# When "Update all" is opened
# Then it says no running service has an update (not "About to update 1")
out=$(run_case '
  _service_is_running(){ return 1; }
  tsv=$(printf "autoheal\tstable\tdefault\tUpdate available\ttrue\n")
  launcher_pause_for_menu(){ :; }
  _menu_update_all "$tsv"
')
assert_contains "$out" "No running service has an update." "update-all: all-stopped says nothing runs to update"
assert_not_contains "$out" "About to update" "update-all: all-stopped does not announce an update"

# --- login check per service ------------------------------------------------
# Given Sonarr with an API key in its config.xml
# When the login check runs and its API refuses the key, then accepts it
# Then the check fails, then passes, and it sent the key from config.xml
out=$(run_case '
  mkdir -p "$tmp/config/sonarr"
  echo "<Config><ApiKey>KEY123</ApiKey></Config>" > "$tmp/config/sonarr/config.xml"
  curl_header_stdin(){ echo "CURL:$1:$2" >> "$tmp/docker.log"; return "$CURL_RC"; }
  CURL_RC=22; _service_login_check sonarr; echo "BAD_RC=$?"
  CURL_RC=0;  _service_login_check sonarr; echo "GOOD_RC=$?"
  grep -c "CURL:X-Api-Key:KEY123" "$tmp/docker.log" | sed "s/^/KEY_SENT=/"
')
assert_contains "$out" "BAD_RC=1" "login-check: a refused Sonarr API key fails the check"
assert_contains "$out" "GOOD_RC=0" "login-check: an accepted Sonarr API key passes the check"
assert_contains "$out" "KEY_SENT=5" "login-check: the config.xml key is what gets sent (4 failed tries, then 1)"

# Given Jellyfin whose AuthenticateByName refuses the shared admin login, then accepts it
# When the login check runs
# Then it fails, then passes
out=$(run_case '
  wait_for_jellyfin_auth(){ return "$JF_RC"; }
  JF_RC=2; _service_login_check jellyfin; echo "BAD_RC=$?"
  JF_RC=1; _service_login_check jellyfin; echo "UNREADY_RC=$?"
  JF_RC=0; _service_login_check jellyfin; echo "GOOD_RC=$?"
')
assert_contains "$out" "BAD_RC=1" "login-check: a refused Jellyfin login fails the check"
assert_contains "$out" "UNREADY_RC=1" "login-check: a Jellyfin that never answers fails the check"
assert_contains "$out" "GOOD_RC=0" "login-check: an accepted Jellyfin login passes the check"

scenario_end "$CURRENT_SCENARIO"
summary
