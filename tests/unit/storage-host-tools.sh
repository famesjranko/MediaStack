#!/usr/bin/env bash
# tests/unit/storage-host-tools.sh
#
# Root-only tools (visudo, mount.nfs, ufw) live in /usr/sbin, which a normal
# user's PATH omits on Debian; and the NAS status probes must give up when a
# hard NFS mount stalls. Verifies:
#   1. host_tool_path / host_tool_installed / ufw_installed look in the sbin dirs.
#   2. storage_ensure_nfs_common sees mount.nfs there and does not reinstall it.
#   3. storage_bounded cuts off a command (or shell function) that hangs.
#   4. The storage view answers promptly and says "unreachable" when the mount hangs.
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

# ---------------------------------------------------------------------------
# 3. storage_bounded cuts off hangs.
# ---------------------------------------------------------------------------
# Given an external command and a shell function that both hang
# When they run under storage_bounded with a 1 s deadline
# Then each returns 124 within a few seconds, even inside a command substitution
hang_fn() { sleep 30; }
start=$SECONDS
out="$(storage_bounded 1 sleep 30)"
rc_ext=$?
out_fn="$(storage_bounded 1 hang_fn)"
rc_fn=$?
assert_eq "" "$out$out_fn" "storage_bounded: a hung command leaves no output behind"
assert_eq "124" "$rc_ext" "storage_bounded: a hanging command returns 124"
assert_eq "124" "$rc_fn" "storage_bounded: a hanging shell function returns 124"
((SECONDS - start < 6)) && pass "storage_bounded: both hangs were cut off promptly" || fail "storage_bounded: both hangs were cut off promptly"

# Given a command that finishes in time
# When it runs under storage_bounded
# Then its output and exit code come through
ok_out="$(storage_bounded 5 bash -c 'echo hello; exit 3')"
assert_eq "3" "$?" "storage_bounded: the command's own exit code is kept"
assert_eq "hello" "$ok_out" "storage_bounded: the command's output is kept"

# ---------------------------------------------------------------------------
# 4. The storage view does not wait on a stalled mount.
# ---------------------------------------------------------------------------
# Given a NAS mount where every stat, findmnt and df hangs
# When the storage view renders
# Then it answers within a few seconds and says the NAS is unreachable
mkdir -p "$TMP_DIR/hang-bin" "$TMP_DIR/data"
for tool in test findmnt df; do
    printf '#!/bin/sh\nsleep 30\n' >"$TMP_DIR/hang-bin/$tool"
    chmod +x "$TMP_DIR/hang-bin/$tool"
done
view_out=$(
    PATH="$TMP_DIR/hang-bin:$PATH" STORAGE_PROBE_TIMEOUT=1 REPO_ROOT="$REPO_ROOT" DATA_DIR="$TMP_DIR/data" \
        STORAGE_MODE=nas STORAGE_EXPECTED_SOURCE=192.0.2.10:/exports/m bash -c '
  MEDIASTACK_NONINTERACTIVE=1
  source "$REPO_ROOT/mediastack" </dev/null
  ui_box() { shift; printf "%s\n" "$@"; }
  docker() { :; }
  start=$SECONDS
  _storage_info
  echo "ELAPSED=$((SECONDS - start))"
' 2>&1
)
assert_contains "$view_out" "NAS unreachable" "storage view: a stalled mount is reported as unreachable"
elapsed="$(sed -n 's/^ELAPSED=//p' <<<"$view_out")"
((${elapsed:-99} < 5)) && pass "storage view: answered in ${elapsed}s with every probe hanging" || fail "storage view: answered in ${elapsed:-?}s with every probe hanging"

scenario_end "$CURRENT_SCENARIO"
summary
