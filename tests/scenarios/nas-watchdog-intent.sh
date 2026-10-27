# tests/scenarios/nas-watchdog-intent.sh - NAS watchdog and a user's stop across a host reboot.
#
# In-DinD proof, on top of the NFS fixture of nas-storage.sh, with real Docker
# containers (alpine stand-ins named like the data services). A "host reboot" is
# `docker restart` of the DinD container: the inner Docker daemon, the watchdog,
# the NFS server and the NFS mount all go away and come back, and Docker applies
# each container's restart policy exactly as after a power cycle.
#
# Kernels that cannot run an NFS server inside DinD (nfsd mount denied) fall back
# to a tmpfs mount with its own expected source and fstype. The watchdog gate is
# the same mount identity and sentinel check, but NFS itself is then not proven.
#
# seerr's stand-in depends on jellyfin's, as in docker-compose.yml: `docker compose
# up -d seerr` would also start a jellyfin the user stopped, so the watchdog must
# leave seerr stopped as well.
#
# The restart policy of the data services is taken from the override MediaStack
# generates for a NAS install (restart: "no"); a `probe` container without that
# override keeps the default `unless-stopped`, so a daemon restart that does not
# restore containers cannot make the proof pass by accident.

# shellcheck source=tests/scenarios/nas-storage.sh
source tests/scenarios/nas-storage.sh

NAS_INTENT_DIR=/root/ms-intent
NAS_INTENT_MOUNT_MODE=nfs # nfs | tmpfs
NAS_INTENT_MOUNTPOINT=/tmp/ms-nas-data
NAS_INTENT_SERVICES="unpackerr qbittorrent sonarr radarr seerr jellyfin"

# Runs stdin as a bash script inside the DinD, in the stand-in project directory.
nas_intent_sh() { docker exec -i -w "$NAS_INTENT_DIR" "$DIND_NAME" bash -s; }

# Polls a condition inside the DinD for up to $2 seconds (default 40).
nas_intent_wait() {
    nas_intent_sh <<EOF
for _ in \$(seq 1 ${2:-40}); do
    if $1; then exit 0; fi
    sleep 1
done
exit 1
EOF
}

nas_intent_running() { nas_intent_sh <<<"docker compose ps --filter status=running --format '{{.Name}}' | sort | paste -sd' '"; }

nas_intent_expect_running() { # $1 = expected sorted list, $2 = test name
    local got
    got="$(nas_intent_running)"
    if [[ "$got" == "$1" ]]; then pass "$2"; else fail "$2" "expected '$1' got '$got'"; fi
}

# Sorted, space-separated: every data service plus the probe, minus the arguments.
nas_intent_all_but() {
    local list
    list="$(tr ' ' '\n' <<<"$NAS_INTENT_SERVICES probe")"
    for svc in "$@"; do list="$(grep -vx "$svc" <<<"$list")"; done
    sort <<<"$list" | paste -sd' '
}

# Wait until $1 containers run.
nas_intent_wait_count() {
    nas_intent_wait "[ \"\$(docker compose ps --filter status=running --format '{{.Name}}' | wc -l)\" -ge $1 ]" 40
}

nas_intent_watchdog_start() {
    docker exec -d -w "$NAS_INTENT_DIR" "$DIND_NAME" bash -c \
        'echo $$ >/tmp/ms-intent-watchdog.pid; exec env STORAGE_CHECK_INTERVAL=1 STORAGE_FAIL_GRACE=2 STORAGE_OK_STABLE=2 ./scripts/storage-watchdog.sh >>/tmp/ms-intent-watchdog.log 2>&1'
    nas_intent_wait '[ -s /tmp/ms-intent-watchdog.pid ] && kill -0 "$(cat /tmp/ms-intent-watchdog.pid)"' 10
}

nas_intent_watchdog_stop() {
    nas_intent_sh <<<'[ -s /tmp/ms-intent-watchdog.pid ] && kill "$(cat /tmp/ms-intent-watchdog.pid)" 2>/dev/null; rm -f /tmp/ms-intent-watchdog.pid; true'
}

# Mount the storage the way a boot would: the NFS preflight, or the tmpfs stand-in.
nas_intent_mount() {
    if [[ "$NAS_INTENT_MOUNT_MODE" == nfs ]]; then
        nas_storage_preflight
    else
        dind_exec "mountpoint -q $NAS_INTENT_MOUNTPOINT || mount -t tmpfs -o size=8m msintent-nas $NAS_INTENT_MOUNTPOINT
touch $NAS_INTENT_MOUNTPOINT/.mediastack-storage-ready"
    fi
}

# Restart the DinD container and wait for its inner daemon.
nas_intent_reboot() {
    local waited=0
    nas_intent_watchdog_stop
    docker restart -t 30 "$DIND_NAME" >/dev/null || return 1
    while ! docker exec "$DIND_NAME" docker info >/dev/null 2>&1; do
        sleep 1
        waited=$((waited + 1))
        if ((waited > 90)); then return 1; fi
    done
    if [[ "$NAS_INTENT_MOUNT_MODE" == nfs ]]; then nas_storage_start_nfs_fixture || return 1; fi
    nas_intent_wait 'docker ps --filter name=probe --filter status=running -q | grep -q .' 60
}

# What "Stop a service" and "Start a service" do to the intent, as the launcher calls them.
nas_intent_user_stop() {
    nas_intent_sh <<EOF
SCRIPT_DIR=$NAS_INTENT_DIR
source scripts/lib/service-intent.sh
docker compose stop $1 >/dev/null && service_intent_record $1
EOF
}

nas_intent_user_start() {
    nas_intent_sh <<EOF
SCRIPT_DIR=$NAS_INTENT_DIR
source scripts/lib/service-intent.sh
docker compose up -d $1 >/dev/null && service_intent_clear $1
EOF
}

# The stand-in project: real watchdog and scripts, six data containers plus a probe; seerr depends on jellyfin.
nas_intent_build_project() {
    docker save alpine:latest | docker exec -i "$DIND_NAME" docker load >/dev/null || return 1
    docker exec -i -w /root/MediaStack "$DIND_NAME" bash -s <<EOF || return 1
set -euo pipefail
# The restart policy comes from the generator, not from this scenario.
set -a; source .env; set +a
SCRIPT_DIR=/root/MediaStack HOST_MEMORY_MB=8192 IMAGE_CHANNEL=latest STORAGE_MODE=nas
log_warn() { :; }; log_ok() { :; }; log_error() { echo "ERR \$*" >&2; }
source scripts/setup/override.sh
generate_override none
rm -rf $NAS_INTENT_DIR
mkdir -p $NAS_INTENT_DIR/config/state
cp -r scripts $NAS_INTENT_DIR/scripts
cp .env $NAS_INTENT_DIR/.env
{
    echo "name: msintent"
    echo "services:"
    for svc in $NAS_INTENT_SERVICES probe; do
        printf '  %s:\n    image: alpine:latest\n    command: ["sleep", "86400"]\n    stop_grace_period: 1s\n    container_name: %s\n    restart: unless-stopped\n' "\$svc" "\$svc"
        if [ "\$svc" = seerr ]; then printf '    depends_on:\n      - jellyfin\n'; fi
    done
} >$NAS_INTENT_DIR/docker-compose.yml
{
    echo "services:"
    awk -v want=" $NAS_INTENT_SERVICES " '/^  [a-z0-9-]+:\$/ {svc=\$1; sub(/:\$/, "", svc)} /^    restart: "no"\$/ && index(want, " " svc " ") {print "  " svc ":"; print \$0}' docker-compose.override.yml
} >$NAS_INTENT_DIR/docker-compose.override.yml
EOF
    nas_intent_sh <<<'docker compose up -d >/dev/null 2>&1 && docker ps --filter name=probe --filter status=running -q | grep -q .'
}

run_scenario() {
    local mountpoint="$NAS_INTENT_MOUNTPOINT" export_path="/exports/mediastack"

    if [[ -z "$(docker images -q alpine:latest)" ]]; then
        skip "NAS intent: reboot proof" "alpine:latest is not on the host to sideload"
        return 0
    fi
    dind_exec "bash -lc 'umount -l $mountpoint 2>/dev/null || true; rm -rf $mountpoint /exports/mediastack; mkdir -p $mountpoint'"
    nas_storage_configure_env "$mountpoint" "$export_path"
    if ! nas_storage_start_nfs_fixture; then
        NAS_INTENT_MOUNT_MODE=tmpfs
        env_set STORAGE_EXPECTED_SOURCE msintent-nas
        env_set STORAGE_EXPECTED_FSTYPE tmpfs
        skip "NAS intent: NFS server in DinD" "kernel NFS server unavailable; using a tmpfs mount with the same identity gate"
    fi
    nas_intent_mount || return 1

    if nas_intent_build_project; then
        pass "NAS intent: stand-in stack starts from the generated NAS override"
    else
        fail "NAS intent: stand-in stack starts from the generated NAS override"
        return 1
    fi
    if nas_intent_sh <<<'grep -c "restart: \"no\"" docker-compose.override.yml | grep -qx 6'; then
        pass "NAS intent: generated override keeps restart \"no\" for every NAS data service"
    else
        fail "NAS intent: generated override keeps restart \"no\" for every NAS data service" "$(nas_intent_sh <<<'cat docker-compose.override.yml')"
        return 1
    fi

    # Given the user stopped jellyfin from the launcher, then the host reboots
    nas_intent_user_stop jellyfin || return 1
    if ! nas_intent_reboot; then
        fail "NAS intent: the DinD host restarts and Docker restores the probe container (control)"
        return 1
    fi
    pass "NAS intent: the DinD host restarts and Docker restores the probe container (control)"

    # Then Docker alone starts none of the NAS data services
    nas_intent_expect_running "probe" "NAS intent: after reboot Docker starts no NAS data service by itself"

    # When storage is mounted again and the watchdog starts
    nas_intent_mount || return 1
    nas_intent_watchdog_start || return 1

    # Then it starts every data service except the one the user stopped and the one that depends on it
    nas_intent_wait_count 5 || true
    nas_intent_expect_running "$(nas_intent_all_but jellyfin seerr)" "NAS intent: after reboot the watchdog starts all data services but the user-stopped one and its dependent"
    if nas_intent_sh <<<'grep -q "leaving jellyfin stopped" /tmp/ms-intent-watchdog.log'; then
        pass "NAS intent: the watchdog log says it left jellyfin stopped"
    else
        fail "NAS intent: the watchdog log says it left jellyfin stopped"
    fi
    if nas_intent_sh <<<'grep -q "leaving seerr stopped: it depends on jellyfin, which you stopped" /tmp/ms-intent-watchdog.log'; then
        pass "NAS intent: the watchdog log says it left seerr stopped because it depends on jellyfin"
    else
        fail "NAS intent: the watchdog log says it left seerr stopped because it depends on jellyfin" "$(nas_intent_sh <<<'tail -n 20 /tmp/ms-intent-watchdog.log')"
    fi

    # And after more polls the dependent is still stopped and jellyfin is still recorded as the user's stop
    sleep 5
    nas_intent_expect_running "$(nas_intent_all_but jellyfin seerr)" "NAS intent: later polls leave the dependent stopped"
    if nas_intent_sh <<<'grep -qx jellyfin config/state/user-stopped-services'; then
        pass "NAS intent: the user's stop of jellyfin survives later polls"
    else
        fail "NAS intent: the user's stop of jellyfin survives later polls" "$(nas_intent_sh <<<'cat config/state/user-stopped-services')"
    fi

    # Given a storage outage while jellyfin is still stopped by the user
    nas_intent_sh <<<"umount -l $mountpoint"
    nas_intent_wait '[ "$(docker compose ps --filter status=running --format "{{.Name}}" | paste -sd" ")" = "probe" ]' 40 || true
    nas_intent_expect_running "probe" "NAS intent: an outage stops the running data services"

    # When storage returns
    nas_intent_mount || return 1
    nas_intent_wait_count 5 || true

    # Then the watchdog restarts what it stopped except the user's stop and its dependent
    nas_intent_expect_running "$(nas_intent_all_but jellyfin seerr)" "NAS intent: after the outage only the services the watchdog stopped come back, minus the user's stop and its dependent"

    # Given the user starts jellyfin again, then the host reboots
    nas_intent_user_start jellyfin || return 1
    if ! nas_intent_reboot; then
        fail "NAS intent: the DinD host restarts a second time"
        return 1
    fi
    nas_intent_mount || return 1
    nas_intent_watchdog_start || return 1

    # Then every data service comes back
    nas_intent_wait_count 7 || true
    nas_intent_expect_running "$(nas_intent_all_but)" "NAS intent: Start a service clears the intent, so the next reboot brings it back"

    nas_intent_watchdog_stop
    nas_intent_sh <<<'docker compose down -v >/dev/null 2>&1; true'
    dind_exec "umount $mountpoint 2>/dev/null || true"
    if [[ "$NAS_INTENT_MOUNT_MODE" == nfs ]]; then nas_storage_stop_nfs_fixture || true; fi
}
