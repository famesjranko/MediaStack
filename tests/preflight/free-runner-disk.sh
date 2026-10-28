#!/usr/bin/env bash
# Frees disk on a disposable GitHub-hosted runner before an image job starts
# DinD. A cold scenario grows the disk by up to about 13 GB, and the runner has
# only about 14 GB free. These preinstalled toolchains are large, and MediaStack
# never uses them. The job still needs docker, python3, git, curl and apt, and
# none of them is under these paths.
set -euo pipefail

if [[ "${GITHUB_ACTIONS:-}" != true ]]; then
    echo "free-runner-disk: refused; this deletes system directories on a disposable runner only" >&2
    exit 2
fi

# DinD keeps its inner daemon's data in a volume under the host data root.
root=$(docker info --format '{{.DockerRootDir}}')
free_bytes() { df -B1 --output=avail "$root" | tail -n 1 | tr -d ' '; }

before=$(free_bytes)
sudo rm -rf \
    /usr/local/lib/android \
    /usr/share/dotnet \
    /opt/ghc \
    /usr/local/.ghcup \
    /opt/hostedtoolcache/CodeQL \
    /usr/share/swift
docker image prune --all --force >/dev/null
after=$(free_bytes)

printf 'Runner disk on %s: %s bytes free before cleanup, %s bytes after.\n' \
    "$root" "$before" "$after" | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
