#!/usr/bin/env bash
# DinD entrypoint for the Debian-based tests/Dockerfile.dind image.
#
# Two jobs:
# 1. cgroup v2 fixup — on hosts using cgroup v2, our own process lands in
#    `/sys/fs/cgroup` which gets switched to "domain threaded" mode as soon
#    as we try to launch a container. Nested containers then fail with
#    "cannot enter cgroupv2 ... it is in threaded mode". Fix: move self to a
#    nested `/sys/fs/cgroup/init`, then enable the subtree controllers so
#    dockerd's children can use them. Ported from docker-library/docker's
#    upstream dockerd-entrypoint.sh.
# 2. Argument massaging — mirror docker:dind's behaviour of prepending
#    `dockerd` when the first arg looks like a flag, so tests/lib/dind.sh can
#    pass positional dockerd flags (`--registry-mirror=...`) unchanged.
set -eu

if [[ "$(stat -f -c '%T' /sys/fs/cgroup 2>/dev/null || echo '')" == "cgroup2fs" ]] \
    && [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    mkdir -p /sys/fs/cgroup/init
    # Enabling controllers in subtree_control fails EBUSY ("Device or resource
    # busy") while ANY process sits directly in the cgroup-v2 namespace root
    # (the "no internal process" rule). tests/lib/dind.sh polls
    # `docker exec <dind> docker info` for readiness immediately after launch,
    # and every `docker exec` lands a transient process in that root cgroup —
    # racing this write. A single swallowed failure here lets dockerd start with
    # NO delegated controllers, so any mem-limited container dies with the cryptic
    # "memory.max: no such file or directory". So: re-move root procs into /init
    # and retry the enable until it sticks, then fail loudly if it never does.
    ok=
    for _ in $(seq 1 50); do
        # Move every process in the root cgroup into /init so the root can
        # switch to domain-invalid mode cleanly.
        xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs 2>/dev/null || :
        # Enable controllers in subtree_control so child cgroups (dockerd's
        # containers) can use cpu/memory/io/pids etc.
        if sed -e 's/ / +/g' -e 's/^/+/' \
            < /sys/fs/cgroup/cgroup.controllers \
            > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
            ok=1
            break
        fi
        sleep 0.1
    done
    if [[ -z "$ok" ]] || ! grep -qw memory /sys/fs/cgroup/cgroup.subtree_control; then
        echo "dind-entrypoint: failed to delegate cgroup v2 controllers" \
             "(subtree_control=[$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null)])" >&2
        exit 1
    fi
fi

if [[ $# -gt 0 && "${1:0:1}" == "-" ]]; then
    set -- dockerd "$@"
elif [[ $# -eq 0 ]]; then
    set -- dockerd
fi

exec "$@"
