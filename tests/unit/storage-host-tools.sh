#!/usr/bin/env bash
# tests/unit/storage-host-tools.sh
#
# Root-only tools (visudo, mount.nfs, ufw) live in /usr/sbin, which a normal
# user's PATH omits on Debian. Verifies:
#   1. host_tool_path / host_tool_installed / ufw_installed look in the sbin dirs.
#   2. storage_ensure_nfs_common sees mount.nfs there and does not reinstall it.
# The visudo/watchdog-install case lives in tests/unit/storage/watchdog.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="storage-host-tools"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
# shellcheck source=../../scripts/setup/storage.sh
source "$REPO_ROOT/scripts/setup/storage.sh"

mkdir -p "$TMP_DIR/user-bin" "$TMP_DIR/fake-sbin" "$TMP_DIR/empty-sbin"
for tool in visudo mount.nfs ufw; do
    printf '#!/bin/sh\nexit 0\n' >"$TMP_DIR/fake-sbin/$tool"
    chmod +x "$TMP_DIR/fake-sbin/$tool"
done

# ---------------------------------------------------------------------------
# 1. Lookup falls back to the sbin dirs.
# ---------------------------------------------------------------------------
# Given a user PATH without sbin and mount.nfs only under the sbin dir
# When the tool is looked up
# Then its sbin path is returned
found="$(PATH="$TMP_DIR/user-bin" MS_SBIN_DIRS="$TMP_DIR/fake-sbin" host_tool_path mount.nfs)"
assert_eq "$TMP_DIR/fake-sbin/mount.nfs" "$found" "host_tool_path: finds a tool that only the sbin dir has"

# Given the tool is in neither PATH nor the sbin dirs
# When it is looked up
# Then the lookup fails
PATH="$TMP_DIR/user-bin" MS_SBIN_DIRS="$TMP_DIR/empty-sbin" host_tool_installed mount.nfs
assert_eq "1" "$?" "host_tool_installed: a tool in neither PATH nor sbin is reported missing"

# Given a user PATH without sbin and ufw only under the sbin dir
# When ufw_installed runs
# Then ufw counts as installed
PATH="$TMP_DIR/user-bin" MS_SBIN_DIRS="$TMP_DIR/fake-sbin" ufw_installed
assert_eq "0" "$?" "ufw_installed: ufw under sbin is detected"

# Given ufw is nowhere and only the legacy single-path override names a file
# When ufw_installed runs
# Then the override still counts (the UFW tests rely on it)
PATH="$TMP_DIR/user-bin" MS_SBIN_DIRS="$TMP_DIR/empty-sbin" MS_UFW_SBIN_PATH="$TMP_DIR/fake-sbin/ufw" ufw_installed
assert_eq "0" "$?" "ufw_installed: legacy MS_UFW_SBIN_PATH override still works"
PATH="$TMP_DIR/user-bin" MS_SBIN_DIRS="$TMP_DIR/empty-sbin" ufw_installed
assert_eq "1" "$?" "ufw_installed: absent ufw is reported missing"

# ---------------------------------------------------------------------------
# 2. nfs-common is not reinstalled when mount.nfs sits under sbin.
# ---------------------------------------------------------------------------
APT_CALLS="$TMP_DIR/apt.calls"
sudo() { echo "sudo $*" >>"$APT_CALLS"; }
ui_spin() {
    shift
    "$@"
}
storage_log_info() { :; }

# Given a user PATH without sbin and mount.nfs only under the sbin dir
# When the NFS client check runs
# Then it does not try to install nfs-common
: >"$APT_CALLS"
PATH="$TMP_DIR/user-bin:$PATH" MS_SBIN_DIRS="$TMP_DIR/fake-sbin" storage_ensure_nfs_common
assert_eq "" "$(cat "$APT_CALLS")" "storage_ensure_nfs_common: mount.nfs under sbin counts as installed"

# Given mount.nfs is genuinely absent
# When the NFS client check runs
# Then it installs nfs-common
: >"$APT_CALLS"
mkdir -p "$TMP_DIR/path-without-nfs"
PATH="$TMP_DIR/path-without-nfs" MS_SBIN_DIRS="$TMP_DIR/empty-sbin" storage_ensure_nfs_common
assert_contains "$(cat "$APT_CALLS")" "apt-get install" "storage_ensure_nfs_common: a missing mount.nfs triggers the install"
unset -f sudo ui_spin storage_log_info

scenario_end "$CURRENT_SCENARIO"
summary
