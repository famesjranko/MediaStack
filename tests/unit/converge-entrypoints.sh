#!/usr/bin/env bash
# tests/unit/converge-entrypoints.sh
#
# The real entry points of converge_mediastack_state - scripts/update.sh and the
# launcher (source ./mediastack) - with NOTHING pre-sourced. tests/unit/launcher-converge.sh
# pre-sources hardening.sh, which hid that these two paths never loaded it (and
# never loaded json.sh), so every converge from them died on unbound variables
# and missing commands. Here the host binaries (sudo, docker, systemctl, ufw,
# curl) are recorders on PATH; a copy of the tree is run so nothing is written
# into the checkout and no host file is touched.
set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="converge-entrypoints"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TREE="$TMP_DIR/tree"
BIN="$TMP_DIR/bin"
export STUBLOG="$TMP_DIR/stub.log"
mkdir -p "$TREE" "$BIN"
(cd "$REPO_ROOT" && git ls-files -z | xargs -0 cp --parents -t "$TREE")
cp "$TREE/config/examples/config.yml" "$TREE/config.yml"
# MEDIASTACK_NETWORK_PREFIX is left out on purpose: compose falls back to 172.28.0.
cat >"$TREE/.env" <<ENV
DATA_DIR=$TMP_DIR/data
STAGE_1_COMPLETE=1
IMAGE_CHANNEL=stable
NPM_ADMIN_EMAIL=admin@example.test
JELLYFIN_ADMIN_PASSWORD=test-password
ENV
mkdir -p "$TMP_DIR/data"

stub() { # $1 name; the body comes from stdin
    {
        printf '#!/bin/sh\n'
        cat
    } >"$BIN/$1"
    chmod +x "$BIN/$1"
}

# sudo never runs a command that writes: files "do not exist" (so the filter is
# installed from scratch) and every write is only recorded. ufw and systemctl
# are the recorders below.
stub sudo <<'STUB'
echo "sudo $*" >>"$STUBLOG"
[ "$1" = -n ] && shift
case "$1" in
    test | grep | cmp | awk) exit 1 ;;
    ufw | systemctl) exec "$@" ;;
    *) exit 0 ;;
esac
STUB
stub systemctl <<'STUB'
echo "systemctl $*" >>"$STUBLOG"
case "$1" in is-active | is-failed) exit 1 ;; esac
exit 0
STUB
stub sleep <<'STUB'
exit 0
STUB
stub docker <<'STUB'
echo "docker $*" >>"$STUBLOG"
case "$*" in
    *State.Running*) echo true ;;
    *State.Health*) echo healthy ;;
esac
exit 0
STUB
# A UFW with MediaStack's old Beszel rule (number 2) and an unrelated rule.
stub ufw <<'STUB'
echo "ufw $*" >>"$STUBLOG"
if [ "$1 $2" = "status numbered" ]; then
    printf '%s\n' 'Status: active' '' '     To                         Action      From' \
        '[ 1] 22/tcp                     ALLOW IN    Anywhere' \
        '[ 2] 45876/tcp                  ALLOW IN    172.18.0.0/16              # MediaStack:Beszel-agent'
fi
exit 0
STUB
# qBittorrent still holds the legacy /12; Beszel still holds the old TCP entry.
stub curl <<'STUB'
body=""
[ -t 0 ] || body=$(cat)
printf 'curl %s <<%s>>\n' "$*" "$body" | tr '\n' ' ' >>"$STUBLOG"
echo >>"$STUBLOG"
case "$*" in
    *"-X PATCH"*) printf '\n200' ;;
    *systems/records*) printf '{"items":[{"id":"s1","name":"MediaStack","host":"host.docker.internal","port":45876}]}' ;;
    *users/auth-with-password*) printf '{"token":"tok","record":{"id":"u1"}}\n200' ;;
    *auth/login*) printf 'Ok.\n200' ;;
    *app/preferences*) printf '{"bypass_auth_subnet_whitelist":"172.16.0.0/12","bypass_auth_subnet_whitelist_enabled":true}' ;;
esac
exit 0
STUB

# Given an installed host, a pending code update and all four converge steps due
# When $1 (update | launcher) runs converge, with nothing sourced beforehand
# Then it exits 0 and each step reaches its work
run_entry() {
    local entry="$1" out rc=0
    : >"$STUBLOG"
    if [[ "$entry" == "update" ]]; then
        out=$(cd "$TREE" && PATH="$BIN:$PATH" bash scripts/update.sh </dev/null 2>&1) || rc=$?
    else
        out=$(cd "$TREE" && PATH="$BIN:$PATH" MEDIASTACK_NONINTERACTIVE=1 bash -c '
            source ./mediastack
            converge_mediastack_state' </dev/null 2>&1) || rc=$?
    fi
    local log
    log=$(<"$STUBLOG")
    assert_eq "0" "$rc" "$entry: converge exits 0"
    assert_not_contains "$out" "unbound variable" "$entry: no unbound variable"
    assert_not_contains "$out" "command not found" "$entry: no missing command"
    assert_contains "$log" "sudo install -D -m 0644 " "$entry: the filter files are installed"
    assert_contains "$log" "/etc/systemd/system/docker.service.d/mediastack-admin-filter.conf" "$entry: the docker.service drop-in is installed"
    assert_contains "$log" "sudo /usr/local/sbin/mediastack-admin-filter apply" "$entry: the filter is applied"
    assert_contains "$log" '172.28.0.22/32, 172.28.0.23/32, 172.28.0.40/32' "$entry: qBittorrent's whitelist is narrowed to compose's default addresses"
    assert_contains "$log" "-X PATCH http://localhost:" "$entry: Beszel's old entry is moved"
    assert_contains "$log" "ufw --force delete 2" "$entry: the unused Beszel UFW rule is deleted"
}

run_entry update
run_entry launcher

scenario_end "$CURRENT_SCENARIO"
summary
