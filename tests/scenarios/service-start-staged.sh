# tests/scenarios/service-start-staged.sh — Start a service applies what was
# staged while the service was stopped (issue #103).
#
# Real Docker in DinD, a throwaway two-service compose project (one default, one
# optional-profile service) and the real launcher functions. Covers: staging
# keeps a stopped service stopped; Start a service then runs the new image
# (image-ID change) and the new config (config-only change); a failing storage
# guard blocks the start; an optional-profile service starts; a failed recreate
# is reported as a failure. Needs python:3.12-alpine on the host (sideloaded).
#
#   DIND_NAME=ms-test-x ./tests/run.sh --no-preload service-start-staged

run_scenario() {
    if ! docker image inspect --format '{{.Id}}' python:3.12-alpine >/dev/null 2>&1; then
        skip "service-start-staged" "python:3.12-alpine not on host"
        return 0
    fi
    docker save python:3.12-alpine | docker exec -i "$DIND_NAME" docker load >/dev/null 2>&1 \
        || {
            fail "sideload python:3.12-alpine into DinD"
            return 1
        }

    docker exec -i "$DIND_NAME" sh -c 'cat >/tmp/service-start-staged.sh' <<'BASH'
set -uo pipefail
cd /root/MediaStack
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi$/d' mediastack > .ms-launcher-test.sh
export MEDIASTACK_NONINTERACTIVE=1
source ./.ms-launcher-test.sh
ui_log() { echo "LOG|$1|$2"; }
ui_choose() { echo "$CHOICE"; }
launcher_pause_for_menu() { :; }
storage_guard_before_start() { echo GUARD >>/tmp/w103.guard; return "${GUARD_RC:-0}"; }

W=/tmp/w103
rm -rf "$W" && mkdir -p "$W" && cd "$W" || exit 1
docker rm -f svc bazarr >/dev/null 2>&1
cat >docker-compose.yml <<'Y'
name: w103
services:
  svc:
    image: ms-w103/svc:cur
    container_name: svc
    command: sleep 3600
    labels:
      mark: "${MARK:-one}"
  bazarr:
    image: ms-w103/bazarr:cur
    container_name: bazarr
    profiles: [subtitles]
    command: sleep 3600
Y
build() { printf 'FROM python:3.12-alpine\nRUN echo %s >/marker\n' "$2" | docker build -q -t "$1" - >/dev/null; }
img() { docker inspect --format '{{.Image}}' "$1"; }
state() { docker inspect --format '{{.State.Status}}' "$1"; }
imgid() { docker image inspect --format '{{.Id}}' "$1"; }
out() { echo "$1=$2"; }

docker tag python:3.12-alpine ms-w103/svc:cur
docker tag python:3.12-alpine ms-w103/bazarr:cur
docker compose up -d svc >/dev/null 2>&1
docker compose --profile subtitles up -d bazarr >/dev/null 2>&1
out A_ID "$(img svc)"
docker compose stop svc >/dev/null 2>&1
docker compose --profile subtitles stop bazarr >/dev/null 2>&1

# Image change: stage image B while stopped, through the real staging code.
build ms-w103/svc:cur b
out B_ID "$(imgid ms-w103/svc:cur)"
_recreate_service svc "svc updated" >/dev/null 2>&1
out STAGED_STATE "$(state svc)"
out STAGED_ID "$(img svc)"
: >/tmp/w103.guard
CHOICE=svc action_service_start 2>&1 | sed 's/^/IMG_START|/'
out START_STATE "$(state svc)"
out START_ID "$(img svc)"
out GUARD_CALLS "$(wc -l </tmp/w103.guard | tr -d ' ')"

# Config-only change: same image, new label.
docker compose stop svc >/dev/null 2>&1
export MARK=two
CHOICE=svc action_service_start >/dev/null 2>&1
out CFG_STATE "$(state svc)"
out CFG_ID "$(img svc)"
out CFG_MARK "$(docker inspect --format '{{index .Config.Labels "mark"}}' svc)"

# Storage guard failure: nothing may start or be recreated.
docker compose stop svc >/dev/null 2>&1
build ms-w103/svc:cur c
BEFORE_ID=$(img svc)
GUARD_RC=1 CHOICE=svc action_service_start >/dev/null 2>&1
out GUARD_STATE "$(state svc)"
out GUARD_ID_SAME "$([[ "$(img svc)" == "$BEFORE_ID" ]] && echo yes || echo no)"

# Optional-profile service: listed, started with its profile, on the new image.
build ms-w103/bazarr:cur b
out BZ_NEW "$(imgid ms-w103/bazarr:cur)"
CHOICE=bazarr action_service_start >/dev/null 2>&1
out BZ_STATE "$(state bazarr)"
out BZ_ID "$(img bazarr)"

# Failed recreate: unpullable image must be reported as a failure.
docker compose --profile subtitles stop bazarr >/dev/null 2>&1
sed -i 's#ms-w103/bazarr:cur#ms-w103.invalid/nope:1#' docker-compose.yml
CHOICE=bazarr action_service_start 2>&1 | sed 's/^/FAIL_START|/'
out FAIL_STATE "$(state bazarr)"
docker rm -f svc bazarr >/dev/null 2>&1
BASH

    local o
    o=$(docker exec "$DIND_NAME" bash /tmp/service-start-staged.sh 2>&1)
    grep -E '^([A-Z_]+=|IMG_START|FAIL_START)' <<<"$o" >&2
    _v() { grep "^$1=" <<<"$o" | cut -d= -f2-; }
    local a b
    a=$(_v A_ID)
    b=$(_v B_ID)

    if [[ -n "$a" && -n "$b" && "$a" != "$b" ]]; then
        pass "fixture: image B differs from image A"
    else
        fail "fixture: image B differs from image A" "A=$a B=$b"
    fi

    # Given a stopped service whose image was changed, When the update is staged
    # Then it stays stopped on image A.
    assert_eq "exited" "$(_v STAGED_STATE)" "staging keeps a stopped service stopped"
    assert_eq "$a" "$(_v STAGED_ID)" "staging does not recreate the stopped container"

    # Given that staged image, When Start a service runs, Then it runs image B.
    assert_eq "running" "$(_v START_STATE)" "Start a service starts the staged service"
    assert_eq "$b" "$(_v START_ID)" "Start a service runs the staged image (image ID A -> B)"
    assert_eq "1" "$(_v GUARD_CALLS)" "storage guard ran once before the start"

    # Given a config-only change, Then the start recreates with the new config.
    assert_eq "running" "$(_v CFG_STATE)" "config-only change: service running"
    assert_eq "$b" "$(_v CFG_ID)" "config-only change: image unchanged"
    assert_eq "two" "$(_v CFG_MARK)" "config-only change: new config applied"

    # Given a failing storage guard, Then nothing starts or is recreated.
    assert_eq "exited" "$(_v GUARD_STATE)" "failed storage guard leaves the service stopped"
    assert_eq "yes" "$(_v GUARD_ID_SAME)" "failed storage guard does not recreate the container"

    # Given an optional-profile service, Then it starts on its new image.
    assert_eq "running" "$(_v BZ_STATE)" "optional-profile service starts"
    assert_eq "$(_v BZ_NEW)" "$(_v BZ_ID)" "optional-profile service runs its staged image"

    # Given an unpullable image, Then the failure is reported and nothing claims success.
    local failblock
    failblock=$(grep '^FAIL_START|' <<<"$o")
    assert_contains "$failblock" "LOG|error|" "failed recreate is reported as an error"
    assert_not_contains "$failblock" "completed successfully" "failed recreate never says it completed"
    assert_eq "exited" "$(_v FAIL_STATE)" "failed recreate leaves the service stopped"
}
