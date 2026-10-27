#!/usr/bin/env bash
# tests/unit/launcher-service-start.sh
#
# Start a service must apply an image or config staged while the service was
# stopped (issue #103), so it reconciles with `docker compose up -d` and not
# `docker compose start`. A docker shim records every call. Contract:
#   - the storage guard runs before any docker start/recreate, and a failing
#     guard runs none;
#   - an optional-profile service (bazarr, npm, wireguard, autoheal) gets its
#     --profile flag, a default-profile service gets none;
#   - dependencies are not skipped (no --no-deps), so stopped ones start too;
#   - a failed up -d is an error with no success line;
#   - staging an update for a stopped service runs neither up nor start.
# The real image/config change is proven in DinD: tests/scenarios/service-start-staged.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-service-start"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-service-start${NC}"

# Run one scenario in a fresh shell. $1=service chosen, $2=guard rc, $3=up rc.
# Prints the ordered call log (GUARD / docker args) then the ui_log lines.
run_start() {
    CALLS=$(mktemp) MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" CHOICE="$1" GUARD_RC="$2" UP_RC="$3" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "LOG|%s|%s\n" "$1" "$2"; }
  ui_choose(){ echo "$CHOICE"; }
  launcher_pause_for_menu(){ :; }
  storage_guard_before_start(){ echo GUARD; return "$GUARD_RC"; }
  docker(){
    case "$*" in
      *" ps "*) echo "docker $*" >>"$CALLS"; echo "$CHOICE" ;;
      *" up "*) echo "docker $*"; return "$UP_RC" ;;
      *) echo "docker $*" ;;
    esac
  }
  action_service_start
  cat "$CALLS"; rm -f "$CALLS"
' 2>&1
}

for pair in "bazarr:--profile subtitles" "npm:--profile proxy" "wireguard:--profile remote" \
    "autoheal:--profile autoheal" "sonarr:"; do
    svc="${pair%%:*}"
    flag="${pair#*:}"
    # Given a stopped service, When Start a service is chosen,
    # Then the guard runs first and compose reconciles it with its profile flag.
    out=$(run_start "$svc" 0 0)
    expected="docker compose ${flag:+$flag }up -d $svc"
    assert_contains "$out" "$expected" "$svc: started with '$expected'"
    assert_not_contains "$out" "--no-deps" "$svc: dependencies are not skipped"
    assert_not_contains "$out" "compose start" "$svc: plain 'compose start' is not used"
    guard_line=$(grep -n '^GUARD$' <<<"$out" | head -1 | cut -d: -f1)
    up_line=$(grep -n ' up -d ' <<<"$out" | head -1 | cut -d: -f1)
    if [[ -n "$guard_line" && -n "$up_line" ]] && ((guard_line < up_line)); then
        pass "$svc: storage guard runs before the recreate"
    else
        fail "$svc: storage guard runs before the recreate" "guard=$guard_line up=$up_line"
    fi
done

# Given a failing storage guard, When Start a service is chosen,
# Then no docker start or recreate runs.
out=$(run_start bazarr 1 0)
assert_not_contains "$out" " up " "failed guard: no recreate"
assert_not_contains "$out" " start " "failed guard: no start"

# Given the listing, Then it names services, not container names.
out=$(run_start sonarr 0 0)
assert_contains "$out" "--format {{.Service}}" "stopped list uses the compose service name"

# Given a failed up -d, Then it is reported as an error and never as success.
out=$(run_start sonarr 0 1)
assert_contains "$out" "LOG|error|Start sonarr exited with code 1." "failed recreate: error reported"
assert_not_contains "$out" "completed successfully" "failed recreate: no success message"

# Given a stopped service, When its update is staged, Then it stays stopped
# (no up, no start) and the message points at Start a service.
out=$(REPO_ROOT="$REPO_ROOT" MEDIASTACK_NONINTERACTIVE=1 bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  ui_log(){ printf "LOG|%s|%s\n" "$1" "$2"; }
  _service_is_running(){ return 1; }
  docker(){ echo "docker $*"; }
  _recreate_service sonarr "sonarr updated"
' 2>&1)
assert_contains "$out" "pull sonarr" "staging pulls the image"
assert_not_contains "$out" " up " "staging a stopped service does not recreate it"
assert_not_contains "$out" " start " "staging a stopped service does not start it"
assert_contains "$out" "use Start a service" "staging message names the apply step"

summary
