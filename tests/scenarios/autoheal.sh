# tests/scenarios/autoheal.sh — Autoheal unhealthy-container self-heal oracle.
#
# `fresh-install` starts Autoheal but only checks that it is running, never
# that it actually heals anything. This scenario proves the behavior that
# broader scenario cannot: induce a deliberately-unhealthy container and
# confirm Autoheal restarts it.
#
# AUTOHEAL_CONTAINER_LABEL=all (docker-compose.yml) means Autoheal watches every
# container visible on the socket with no label required — confirmed against
# willfarrell/docker-autoheal's docker-entrypoint, which drops its label filter
# entirely when that var is "all". So the fixture below needs no autoheal label.
#
# The fixture is a disposable, immutable BusyBox image launched via plain
# `docker run` (no compose, no MediaStack network) with a healthcheck that
# always fails fast (2s interval, 1 retry) — isolated from every real
# MediaStack service so the oracle is fast and deterministic.
#
# Two fixture-correlated pass signals, not one: the fixture's State.StartedAt
# changing AND Autoheal's own log line, including this fixture's name and short
# ID. The fixture is launched with no --restart policy, so StartedAt can only
# move if something external restarts it.

AUTOHEAL_FIXTURE=autoheal-fixture
# BusyBox 1.37.0 OCI index digest. Pinning avoids an unrelated fixture-image
# drift changing this candidate-image oracle between runs.
AUTOHEAL_FIXTURE_IMAGE=busybox@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028

autoheal_cleanup() {
    dind_exec "docker rm -f $AUTOHEAL_FIXTURE autoheal" >/dev/null 2>&1 || true
}

autoheal_finish() {
    # Keep the scenario's signal cleanup active until this label=all watcher
    # is gone; KEEP_ALWAYS can otherwise preserve it after an interrupt.
    autoheal_cleanup
    trap 'on_exit 130' INT
    trap 'on_exit 143' TERM
}

autoheal_interrupted() {
    # KEEP_ALWAYS/--keep can preserve DinD after the runner exits. Remove this
    # label=all watcher before delegating to the runner's normal signal path.
    autoheal_cleanup
    on_exit "$1"
}

run_scenario() {
    # ------------------------------------------------------------------
    # 0. Defensive cleanup first: a stale autoheal/fixture container from
    #    a prior manual (non --reset-between) run would otherwise watch
    #    with label=all while this scenario's own containers come up,
    #    racing their startup health-check grace windows.
    # ------------------------------------------------------------------
    autoheal_cleanup
    trap 'autoheal_interrupted 130' INT
    trap 'autoheal_interrupted 143' TERM

    # ------------------------------------------------------------------
    # 1. Minimal .env — compose interpolates the whole file (every
    #    service's variables) before profile filtering even when we only
    #    ask for `autoheal`, so a missing/blank DATA_DIR etc. breaks
    #    parsing for unrelated services' volume specs. .env.example's
    #    defaults are enough; no config dirs or override needed since
    #    Autoheal itself only mounts the docker socket.
    # ------------------------------------------------------------------
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set DATA_DIR /tmp/ms-data
    dind_exec "mkdir -p /tmp/ms-data"

    # ------------------------------------------------------------------
    # 2. Bring up Autoheal alone.
    # ------------------------------------------------------------------
    if ! dind_exec "docker compose --profile autoheal up -d autoheal" >/dev/null 2>&1; then
        fail "autoheal: compose up -d autoheal"
        dind_exec "docker compose ps"
        autoheal_finish
        return 1
    fi
    if ! wait_healthy autoheal 60; then
        fail "autoheal: container running"
        autoheal_finish
        return 1
    fi
    pass "autoheal: container running"

    # ------------------------------------------------------------------
    # 3. Launch the disposable fixture with an always-failing healthcheck.
    # ------------------------------------------------------------------
    if ! dind_exec "docker run -d --name $AUTOHEAL_FIXTURE \
        --health-cmd='exit 1' --health-interval=2s --health-retries=1 \
        --health-timeout=2s --health-start-period=0s \
        $AUTOHEAL_FIXTURE_IMAGE sleep 600" >/dev/null 2>&1; then
        fail "autoheal: fixture container started"
        autoheal_finish
        return 1
    fi
    pass "autoheal: fixture container started"

    # State.StartedAt, not RestartCount: RestartCount only tracks restarts
    # driven by the container's own --restart policy, not an externally
    # triggered `docker restart` (which is exactly what Autoheal's REST
    # POST .../restart does) — confirmed empirically, RestartCount stayed 0
    # across multiple observed Autoheal-driven restarts. The fixture is
    # launched with no --restart policy at all, so StartedAt can only move
    # if something external restarts it — here, only Autoheal can.
    local baseline_started fixture_id fixture_short_id
    baseline_started=$(dind_exec "docker inspect --format '{{.State.StartedAt}}' $AUTOHEAL_FIXTURE" | tr -d '\r\n')
    fixture_id=$(dind_exec "docker inspect --format '{{.Id}}' $AUTOHEAL_FIXTURE" | tr -d '\r\n')
    if [[ ! "$fixture_id" =~ ^[[:xdigit:]]{12,}$ ]]; then
        fail "autoheal: fixture ID available" "inspect returned '$fixture_id'"
        autoheal_finish
        return 1
    fi
    fixture_short_id=${fixture_id:0:12}

    # ------------------------------------------------------------------
    # 4. Wait for the fixture to actually go unhealthy — without this
    #    checkpoint, a misconfigured fixture that never flips would make
    #    the restart check below meaningless.
    # ------------------------------------------------------------------
    local status="" waited=0
    while (( waited < 30 )); do
        status=$(dind_exec "docker inspect --format '{{.State.Health.Status}}' $AUTOHEAL_FIXTURE 2>/dev/null" | tr -d '\r\n')
        [[ "$status" == "unhealthy" ]] && break
        sleep 2; waited=$((waited + 2))
    done
    if [[ "$status" == "unhealthy" ]]; then
        pass "autoheal: fixture reached unhealthy (${waited}s)"
    else
        fail "autoheal: fixture reached unhealthy" "status=$status after ${waited}s"
        autoheal_finish
        return 1
    fi

    # ------------------------------------------------------------------
    # 5. Wait for Autoheal to act. AUTOHEAL_INTERVAL=10s in compose, so
    #    give real margin over one poll cycle.
    # ------------------------------------------------------------------
    local started="$baseline_started"
    waited=0
    while (( waited < 90 )); do
        started=$(dind_exec "docker inspect --format '{{.State.StartedAt}}' $AUTOHEAL_FIXTURE 2>/dev/null" | tr -d '\r\n')
        [[ -n "$started" && "$started" != "$baseline_started" ]] && break
        sleep 3; waited=$((waited + 3))
    done
    if [[ -n "$started" && "$started" != "$baseline_started" ]]; then
        pass "autoheal: fixture restarted (StartedAt $baseline_started -> $started, ${waited}s)"
    else
        fail "autoheal: fixture restarted (StartedAt changed)" "stayed at $baseline_started after ${waited}s"
        dind_exec "docker logs --tail 30 autoheal" 2>&1 || true
        autoheal_finish
        return 1
    fi

    # ------------------------------------------------------------------
    # 6. Second, fixture-correlated signal: the Autoheal action line names
    #    this fixture and its short ID, then records a restart. A heal log for
    #    any other unhealthy container cannot satisfy this assertion. Keep the
    #    action match resilient to non-semantic upstream wording changes.
    # ------------------------------------------------------------------
    local logs fixture_action
    logs=$(dind_exec "docker logs autoheal 2>&1" || true)
    fixture_action=$(grep -F "Container /$AUTOHEAL_FIXTURE ($fixture_short_id)" <<<"$logs" | grep -i 'restart' || true)
    if [[ -n "$fixture_action" ]]; then
        pass "autoheal: log shows the heal action for the fixture"
    else
        fail "autoheal: log shows the heal action for the fixture" "$(echo "$logs" | tail -5)"
        autoheal_finish
        return 1
    fi

    if echo "$logs" | grep -qiE "panic|fatal"; then
        fail "autoheal: log clean of panic/fatal" "$(echo "$logs" | grep -iE "panic|fatal" | head -3)"
        autoheal_finish
        return 1
    else
        pass "autoheal: log clean of panic/fatal"
    fi

    # ------------------------------------------------------------------
    # 7. Cleanup so downstream scenarios in the same DinD don't inherit
    #    a live label=all watcher.
    # ------------------------------------------------------------------
    autoheal_finish
    pass "autoheal: cleanup (fixture + autoheal removed)"
}
