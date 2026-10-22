#!/usr/bin/env bash
# tests/unit/apt-noninteractive.sh
#
# Repo-wide guard: every `apt-get install` in the shipped scripts runs through
# MS_APT_INSTALL, and every remove or purge through MS_APT_REMOVE/MS_APT_PURGE
# (scripts/lib/apt.sh). A bare call lets a debconf dialog open
# behind ui_spin, which makes the install look hung.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="apt-noninteractive"
scenario_begin "$CURRENT_SCENARIO"

# Executable lines only: skip comments and message strings (log_*, ui_log).
_bare_calls() {
    local files
    cd "$REPO_ROOT" || return 1
    mapfile -t files < <(find scripts -name '*.sh' ! -path scripts/lib/apt.sh)
    grep -nE 'apt(-get)?[[:space:]]+(install|remove|purge|upgrade|dist-upgrade|full-upgrade)' mediastack setup.sh "${files[@]}" \
        | grep -Ev ':[0-9]+:[[:space:]]*#|log_|ui_log|MS_APT_' || true
}

# Given every script that changes packages,
# When searched for an apt-get install, remove, or purge outside the shared prefixes,
# Then none exists.
_found=$(_bare_calls)
assert_eq "" "$_found" "no script runs apt-get install/remove/purge without the MS_APT_* prefixes"

# Given the shared prefixes,
# When their words are read,
# Then each is non-interactive, and install adds conffile defaults.
source "$REPO_ROOT/scripts/lib/apt.sh"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold" \
    "${MS_APT_INSTALL[*]}" "MS_APT_INSTALL: non-interactive with conffile defaults"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq" "${MS_APT_REMOVE[*]}" "MS_APT_REMOVE: non-interactive"
assert_eq "sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq" "${MS_APT_PURGE[*]}" "MS_APT_PURGE: non-interactive"

scenario_end "$CURRENT_SCENARIO"
summary
