# tests/scenarios/nas-storage.sh — managed NAS/NFS storage fixture.
#
# This is an in-VM DinD proof. It starts a disposable NFS server inside the
# privileged DinD container, mounts it through scripts/setup/storage.sh, and
# verifies the mount identity + sentinel guard that protects Jellyfin and
# download clients from local fallback writes.

nas_storage_start_nfs_fixture() {
    dind_exec "bash -lc '
set -euo pipefail
mkdir -p /exports
mountpoint -q /exports || mount -t tmpfs -o size=64m tmpfs /exports
mkdir -p /exports/mediastack
printf fixture > /exports/mediastack/remote-only.txt

mkdir -p /run/rpcbind /proc/fs/nfsd
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd
rpcbind -w 2>/dev/null || true

cat >/etc/exports <<EOF
/exports 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,fsid=0,insecure)
/exports/mediastack 127.0.0.1(rw,sync,no_subtree_check,no_root_squash,fsid=1,insecure)
EOF
exportfs -ra
rpc.nfsd 8
rpc.mountd --manage-gids
'"
}

nas_storage_stop_nfs_fixture() {
    dind_exec "bash -lc '
exportfs -ua 2>/dev/null || true
killall rpc.mountd 2>/dev/null || true
rpc.nfsd 0 2>/dev/null || true
umount /proc/fs/nfsd 2>/dev/null || true
umount /exports 2>/dev/null || true
'"
}

nas_storage_preflight() {
    local log_path="/tmp/nas-storage-preflight.out"
    if dind_exec "timeout 45 bash -lc '
set -euo pipefail
SCRIPT_DIR=/root/MediaStack
sudo() { \"\$@\"; }
set -a
source .env
set +a
source scripts/lib/common.sh
source scripts/setup/storage.sh
storage_preflight_nas
storage_guard_before_start
source scripts/setup/stack.sh
create_data_dirs
'" >"$log_path" 2>&1; then
        pass "NAS: storage preflight, guard, and directory creation exit 0"
    else
        fail "NAS: storage preflight, guard, and directory creation exit 0"
        tail -80 "$log_path"
        return 1
    fi
}

nas_storage_assert_watchdog_recovers_pending_state() {
    local log_path="/tmp/nas-storage-watchdog-restart.out"
    local docker_log="/tmp/nas-storage-watchdog-docker.log"

    if dind_exec "bash -lc '
set -euo pipefail
mkdir -p /tmp/fakebin config/state
cat >/tmp/fakebin/docker <<DOCKER
#!/usr/bin/env bash
printf \"%s\\n\" \"docker \\\$*\" >> $docker_log
exit 0
DOCKER
chmod +x /tmp/fakebin/docker
printf \"%s\\n\" stopped > config/state/storage-watchdog-stopped
rm -f $docker_log $log_path
PATH=/tmp/fakebin:\$PATH STORAGE_CHECK_INTERVAL=1 STORAGE_OK_STABLE=0 timeout 3 ./scripts/storage-watchdog.sh >$log_path 2>&1 || true
test ! -e config/state/storage-watchdog-stopped
grep -q \"docker compose up -d jellyfin\" $docker_log
grep -q \"docker compose up -d qbittorrent\" $docker_log
'"; then
        pass "NAS: watchdog recovers pending state using known service set"
    else
        fail "NAS: watchdog recovers pending state using known service set"
        dind_exec "cat $log_path 2>/dev/null || true; cat $docker_log 2>/dev/null || true"
        return 1
    fi
}

nas_storage_assert_watchdog_recovers_clean_boot() {
    local log_path="/tmp/nas-storage-watchdog-exact.out"
    local docker_log="/tmp/nas-storage-watchdog-exact-docker.log"

    if dind_exec "bash -lc '
set -euo pipefail
mkdir -p /tmp/fakebin config/state
cat >/tmp/fakebin/docker <<DOCKER
#!/usr/bin/env bash
printf \"%s\\n\" \"docker \\\$*\" >> $docker_log
exit 0
DOCKER
chmod +x /tmp/fakebin/docker
rm -f config/state/storage-watchdog-stopped
rm -f $docker_log $log_path
PATH=/tmp/fakebin:\$PATH STORAGE_CHECK_INTERVAL=1 STORAGE_OK_STABLE=0 timeout 3 ./scripts/storage-watchdog.sh >$log_path 2>&1 || true
grep -q \"no NAS-dependent services are running after boot\" $log_path
grep -q \"docker compose up -d jellyfin\" $docker_log
grep -q \"docker compose up -d jellyseerr\" $docker_log
! grep -q \"docker compose up -d bazarr\" $docker_log
'"; then
        pass "NAS: watchdog starts known service set after clean reboot"
    else
        fail "NAS: watchdog starts known service set after clean reboot"
        dind_exec "cat $log_path 2>/dev/null || true; cat $docker_log 2>/dev/null || true"
        return 1
    fi
}

run_scenario() {
    local mountpoint="/tmp/ms-nas-data"
    local export_path="/exports/mediastack"

    dind_exec "bash -lc 'umount -l $mountpoint 2>/dev/null || true; rm -rf $mountpoint /exports/mediastack; mkdir -p $mountpoint'"
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR "$mountpoint"
    env_set HOST_ADDRESS 127.0.0.1
    env_set STORAGE_MODE nas
    env_set STORAGE_PROTOCOL nfs
    env_set STORAGE_MOUNTPOINT "$mountpoint"
    env_set STORAGE_NFS_HOST 127.0.0.1
    env_set STORAGE_NFS_EXPORT "$export_path"
    env_set STORAGE_NFS_OPTS "vers=3,proto=tcp,rw,soft,timeo=10,retrans=1,nolock,nosuid,nodev,noexec"
    env_set STORAGE_SENTINEL "$mountpoint/.mediastack-storage-ready"
    env_set STORAGE_EXPECTED_SOURCE ""
    env_set STORAGE_EXPECTED_FSTYPE ""

    if nas_storage_start_nfs_fixture; then
        pass "NAS: disposable NFS fixture starts"
    else
        skip "NAS: disposable NFS fixture starts" "kernel NFS server unavailable inside DinD"
        return 0
    fi

    nas_storage_preflight || return 1

    if dind_exec "findmnt -rn -M $mountpoint -o SOURCE,FSTYPE | grep -Eq '^127\\.0\\.0\\.1:$export_path +(nfs|nfs4)$'"; then
        pass "NAS: mounted source and fstype match fixture"
    else
        fail "NAS: mounted source and fstype match fixture" "$(dind_exec "findmnt -rn -M $mountpoint -o SOURCE,FSTYPE || true")"
    fi

    if dind_exec "test -e $mountpoint/.mediastack-storage-ready && test -f $mountpoint/remote-only.txt"; then
        pass "NAS: sentinel and remote fixture file are visible through mount"
    else
        fail "NAS: sentinel and remote fixture file are visible through mount"
    fi

    if dind_exec "test -d /exports/mediastack/media/movies && test -d /exports/mediastack/torrents/incomplete"; then
        pass "NAS: MediaStack directories were created on the exported storage"
    else
        fail "NAS: MediaStack directories were created on the exported storage"
    fi

    dind_exec "umount $mountpoint"
    if dind_exec "bash -lc '
set -a
source .env
set +a
source scripts/setup/storage.sh
storage_guard_before_start
'" >/tmp/nas-storage-guard.out 2>&1; then
        fail "NAS: guard rejects unmounted local fallback"
    else
        pass "NAS: guard rejects unmounted local fallback"
    fi

    if dind_exec "test ! -e $mountpoint/.mediastack-storage-ready && test ! -e $mountpoint/media && test ! -e $mountpoint/torrents"; then
        pass "NAS: unmounted local mountpoint remains empty"
    else
        fail "NAS: unmounted local mountpoint remains empty" "$(dind_exec "find $mountpoint -maxdepth 2 -mindepth 1 -print 2>/dev/null | sort")"
    fi

    if dind_exec "mount -t tmpfs -o size=4m tmpfs $mountpoint && touch $mountpoint/wrong-live-mount"; then
        pass "NAS: wrong live mount fixture created"
    else
        fail "NAS: wrong live mount fixture created"
        return 1
    fi

    if dind_exec "timeout 30 bash -lc '
set -euo pipefail
sudo() { \"\$@\"; }
set -a
source .env
set +a
source scripts/setup/storage.sh
storage_mount_nfs
storage_guard_before_start
'"; then
        pass "NAS: storage repairs wrong live mount and passes guard"
    else
        fail "NAS: storage repairs wrong live mount and passes guard"
    fi

    if dind_exec "findmnt -rn -M $mountpoint -o SOURCE,FSTYPE | grep -Eq '^127\\.0\\.0\\.1:$export_path +(nfs|nfs4)$' && test ! -e $mountpoint/wrong-live-mount"; then
        pass "NAS: repaired mountpoint is selected NFS export"
    else
        fail "NAS: repaired mountpoint is selected NFS export" "$(dind_exec "findmnt -rn -M $mountpoint -o SOURCE,FSTYPE || true; ls -la $mountpoint 2>/dev/null || true")"
    fi

    nas_storage_assert_watchdog_recovers_pending_state || return 1
    nas_storage_assert_watchdog_recovers_clean_boot || return 1

    dind_exec "umount $mountpoint 2>/dev/null || true"
    nas_storage_stop_nfs_fixture || true
}
