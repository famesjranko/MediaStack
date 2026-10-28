#!/usr/bin/env bash
# Installed as /usr/local/bin/curl inside DinD, ahead of /usr/bin in PATH and in
# sudo's secure_path. With MS_CONTRACT_TRACE set to a directory, each product
# curl writes a hex --trace there for tests/contracts/observe.py; hex, because
# --trace-ascii rewrites bytes and corrupts JSON. The file name carries the
# start time in epoch nanoseconds, which binds the requests to the container
# start events. exec keeps stdin, stdout and the exit code unchanged.
if [[ -z "${MS_CONTRACT_TRACE:-}" ]]; then
    exec /usr/bin/curl "$@"
fi
exec /usr/bin/curl --trace "$MS_CONTRACT_TRACE/$(date +%s%N)-$$.trace" "$@"
