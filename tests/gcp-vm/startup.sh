#!/bin/bash
# GCP instance startup script — installs the host prerequisites that the
# fresh-test harness assumes are present before it rsyncs the repo.
#
# This is small on purpose: setup.sh installs Docker + everything else
# itself; the only things this script provides are tools needed BEFORE
# setup.sh can run (rsync to copy the repo in, git for any in-place
# clones, curl for /opt bootstrap fetches).
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git ca-certificates curl rsync
mkdir -p /opt/MediaStack
