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
    if [[ ! -d /sys/fs/cgroup/init ]]; then
        mkdir -p /sys/fs/cgroup/init
        # Move every process in the root cgroup into /init so the root can
        # switch to domain-invalid mode cleanly.
        xargs -rn1 < /sys/fs/cgroup/cgroup.procs > /sys/fs/cgroup/init/cgroup.procs || :
        # Enable controllers in subtree_control so child cgroups (dockerd's
        # containers) can use cpu/memory/io/pids etc.
        sed -e 's/ / +/g' -e 's/^/+/' \
            < /sys/fs/cgroup/cgroup.controllers \
            > /sys/fs/cgroup/cgroup.subtree_control || :
    fi
fi

if [[ $# -gt 0 && "${1:0:1}" == "-" ]]; then
    set -- dockerd "$@"
elif [[ $# -eq 0 ]]; then
    set -- dockerd
fi

exec "$@"
