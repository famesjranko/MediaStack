#!/usr/bin/env bash
# tests/unit/packages.sh
#
# Pure-bash unit tests for scripts/setup/packages.sh. System-mutating commands
# are shimmed, so these tests do not touch apt, Docker, groups, or keyrings.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="packages"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/packages.sh"

set +e
set +u

log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# packages.sh wraps apt calls in ui_spin (defined in ui.sh, not sourced here).
# Run the wrapped command in-process so the sudo shim records the apt install.
ui_spin() {
    shift
    "$@"
}

PACKAGE_CALLS=()

reset_package_shims() {
    PACKAGE_CALLS=()
    unset -f command docker sudo curl dpkg groups || true
}

install_call_seen() {
    local needle="$1"
    local call
    for call in "${PACKAGE_CALLS[@]}"; do
        [[ "$call" == *"apt-get install"* && "$call" == *"$needle"* ]] && return 0
    done
    return 1
}

# Docker Engine exists, but Compose v2 is missing. --full should repair this
# by installing the official Compose plugin instead of returning early.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "docker" ]]; then
        return 0
    fi
    builtin command "$@"
}
docker() {
    if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
        return 1
    fi
    return 0
}
sudo() {
    PACKAGE_CALLS+=("sudo $*")
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            ;;
    esac
    return 0
}
curl() { printf '%s\n' "fake-docker-gpg-key"; }
dpkg() {
    if [[ "${1:-}" == "--print-architecture" ]]; then
        printf '%s\n' "amd64"
        return 0
    fi
    return 1
}
groups() { printf '%s\n' "${USER:-tester} docker"; }

install_docker
if install_call_seen "docker-compose-plugin"; then
    pass "install_docker: Docker present + Compose missing installs Compose plugin"
else
    fail "install_docker: Docker present + Compose missing installs Compose plugin" \
        "calls: ${PACKAGE_CALLS[*]:-(none)}"
fi
reset_package_shims

# Fully installed Docker + Compose should remain a no-op.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "docker" ]]; then
        return 0
    fi
    builtin command "$@"
}
docker() {
    if [[ "${1:-}" == "compose" && "${2:-}" == "version" ]]; then
        return 0
    fi
    return 0
}
sudo() {
    PACKAGE_CALLS+=("sudo $*")
    return 0
}

install_docker
if install_call_seen "docker-compose-plugin"; then
    fail "install_docker: Docker + Compose present skips apt install" \
        "calls: ${PACKAGE_CALLS[*]}"
else
    pass "install_docker: Docker + Compose present skips apt install"
fi
reset_package_shims

# ---------------------------------------------------------------------------
# Docker apt source lifecycle, in a fake root. sudo runs the real file tools;
# curl, gpg, apt-get and dpkg are stubs. Nothing here reaches the real /etc/apt.
# ---------------------------------------------------------------------------
unset -f command docker sudo curl dpkg groups
FAKE=$(mktemp -d)
trap 'rm -rf "$FAKE"' EXIT
export TMPDIR="$FAKE/tmp"
LOG="$FAKE/log"
log_ok() { echo "OK $*" >>"$LOG"; }
log_info() { echo "INFO $*" >>"$LOG"; }
log_warn() { echo "WARN $*" >>"$LOG"; }
log_error() { echo "ERROR $*" >>"$LOG"; }
sudo() { "$@"; }
# `sudo env VAR=x cmd` must not reach the real env binary and the host's apt-get:
# record the assignments and run the stubbed command in-process.
ENV_SEEN=""
env() {
    ENV_SEEN=""
    while [[ "${1:-}" == *=* ]]; do
        ENV_SEEN+="$1 "
        shift
    done
    "$@"
}
dpkg() { [[ "$1" == "--print-architecture" ]] && echo amd64; }
CURL_MODE=ok GPG_MODE=ok APT_MODE=ok
curl() {
    local out
    case "$CURL_MODE" in
        fail) return 22 ;;
        term) kill -s TERM "$BASHPID" ;;
    esac
    while [[ $# -gt 0 ]]; do
        [[ "$1" == -o ]] && out=$2
        shift
    done
    echo armored >"$out"
}
gpg() {
    if [[ "$1" == "--show-keys" ]]; then
        [[ "$GPG_MODE" == nokey ]] || echo "pub:u:255:22:ABCD:1:::"
        return 0
    fi
    local out
    while [[ $# -gt 0 ]]; do
        [[ "$1" == -o ]] && out=$2
        shift
    done
    case "$GPG_MODE" in
        fail) return 2 ;;
        empty) : >"$out" ;;
        *) echo binary-key >"$out" ;;
    esac
}
apt-get() {
    echo "$*" >>"$FAKE/apt-calls"
    [[ "$APT_MODE" == ok ]] && return 0
    echo "Err:1 https://download.docker.com/linux/debian noble InRelease"
    return 100
}

# $1 = os-release ID, $2 = VERSION_CODENAME
new_root() {
    rm -rf "$FAKE/root" "$FAKE/tmp" "$FAKE/apt-calls" "$LOG"
    mkdir -p "$FAKE/root/sources" "$FAKE/root/keyrings" "$FAKE/tmp"
    MEDIASTACK_DOCKER_APT_LIST="$FAKE/root/sources/docker.list"
    MEDIASTACK_DOCKER_APT_KEY="$FAKE/root/keyrings/docker.gpg"
    MEDIASTACK_OS_RELEASE="$FAKE/root/os-release"
    MEDIASTACK_APT_SOURCES_DIR="$FAKE/root/sources"
    MEDIASTACK_APT_SOURCES_LIST="$FAKE/root/sources.list"
    printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "$2" >"$MEDIASTACK_OS_RELEASE"
    CURL_MODE=ok GPG_MODE=ok APT_MODE=ok
    : >"$LOG"
}
LINE_BOOKWORM='deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable'
# The shape the pre-fix writer produced (a run of spaces before the codename).
OLD_NOBLE='deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian       noble stable'

check() { # $1 = label; rest = test command
    local label="$1"
    shift
    if "$@"; then pass "$label"; else fail "$label"; fi
}
nothing_left() {
    [[ ! -e "$MEDIASTACK_DOCKER_APT_LIST" && ! -e "$MEDIASTACK_DOCKER_APT_KEY" && -z "$(ls -A "$FAKE/tmp")" ]]
}
removed() { [[ ! -e "$MEDIASTACK_DOCKER_APT_LIST" && ! -e "$MEDIASTACK_DOCKER_APT_KEY" ]]; }
kept() { [[ -e "$MEDIASTACK_DOCKER_APT_LIST" && -e "$MEDIASTACK_DOCKER_APT_KEY" ]]; }
put_list() {
    echo "$1" >"$MEDIASTACK_DOCKER_APT_LIST"
    echo key >"$MEDIASTACK_DOCKER_APT_KEY"
}

# Given a failed key download, When the repo is configured, Then it fails and writes nothing.
new_root debian bookworm
CURL_MODE=fail
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: failed download returns non-zero"
check "docker apt: failed download leaves no list, no key, no temp" nothing_left

# Given gpg fails, When configured, Then no 0-byte key or list remains.
new_root debian bookworm
GPG_MODE=fail
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: gpg failure returns non-zero"
check "docker apt: gpg failure leaves no list, no key, no temp" nothing_left

# Given gpg writes an empty key, When configured, Then the key is rejected.
new_root debian bookworm
GPG_MODE=empty
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: empty key returns non-zero"
check "docker apt: empty key leaves nothing" nothing_left

# Given a key that holds no public key, When configured, Then it is rejected.
new_root debian bookworm
GPG_MODE=nokey
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: invalid key returns non-zero"
check "docker apt: invalid key leaves nothing" nothing_left

# Given the isolated apt update fails, When configured, Then no list is left behind.
new_root ubuntu noble
APT_MODE=fail
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: failed apt update returns non-zero"
check "docker apt: failed apt update leaves no list, no key, no temp" nothing_left
assert_contains "$(cat "$FAKE/apt-calls")" "Dir::Etc::sourceparts=/dev/null" "docker apt: proof update is isolated from system sources"
assert_contains "$(cat "$LOG")" "ERROR Docker apt source failed verification" "docker apt: failure is explained"

# Given a stop signal during the download, When configured, Then the temp dir is removed.
new_root debian bookworm
CURL_MODE=term
(configure_docker_apt_repo)
check "docker apt: interrupted run cleans its temp dir" nothing_left

# Given the final move fails, When configured, Then what this run wrote is undone.
new_root debian bookworm
sudo() {
    [[ "$1" == mv && "${*: -1}" == "$MEDIASTACK_DOCKER_APT_LIST" ]] && return 1
    "$@"
}
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: failed install returns non-zero"
check "docker apt: failed install is rolled back" nothing_left
sudo() { "$@"; }

# Given everything works, When configured, Then both files exist with the expected content and mode.
new_root debian bookworm
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: success returns zero"
assert_eq "$LINE_BOOKWORM" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "docker apt: list content"
assert_eq "binary-key" "$(cat "$MEDIASTACK_DOCKER_APT_KEY")" "docker apt: key content"
assert_eq "644 644" "$(stat -c '%a' "$MEDIASTACK_DOCKER_APT_LIST" "$MEDIASTACK_DOCKER_APT_KEY" | paste -sd' ')" "docker apt: modes are 0644"
assert_eq "" "$(ls -A "$FAKE/tmp")" "docker apt: success removes its temp dir"

# Given a deb822 docker.sources for download.docker.com, When configured, Then nothing is written, no key is fetched, and it succeeds.
new_root debian bookworm
printf 'Types: deb\nURIs: https://download.docker.com/linux/debian\nSuites: bookworm\nComponents: stable\nSigned-By: /etc/apt/keyrings/docker.asc\n' >"$FAKE/root/sources/docker.sources"
CURL_MODE=fail
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: existing deb822 source returns zero"
check "docker apt: existing deb822 source gets no docker.list and no key" removed
assert_contains "$(cat "$LOG")" "INFO Docker apt source already present in $FAKE/root/sources/docker.sources" "docker apt: existing deb822 source is reported"
assert_eq "update" "$(cat "$FAKE/apt-calls")" "docker apt: existing source is verified with a normal apt-get update"

# Given a foreign one-line docker-ce.list, When configured, Then the same holds.
new_root debian bookworm
echo 'deb [signed-by=/usr/share/keyrings/d.gpg] https://download.docker.com/linux/debian bookworm stable' >"$FAKE/root/sources/docker-ce.list"
CURL_MODE=fail
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: foreign docker-ce.list returns zero"
check "docker apt: foreign docker-ce.list gets no docker.list and no key" removed
assert_contains "$(cat "$LOG")" "INFO Docker apt source already present" "docker apt: foreign docker-ce.list is reported"

# Given a Docker source in the main sources.list, When configured, Then it is used.
new_root debian bookworm
echo 'deb https://download.docker.com/linux/debian bookworm stable' >"$FAKE/root/sources.list"
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: Docker source in sources.list returns zero"
check "docker apt: Docker source in sources.list gets no docker.list" removed

# Given only a commented-out Docker line elsewhere, When configured, Then MediaStack adds its own source.
new_root debian bookworm
echo '# deb https://download.docker.com/linux/debian bookworm stable' >"$FAKE/root/sources.list"
configure_docker_apt_repo
assert_eq "$LINE_BOOKWORM" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "docker apt: commented Docker line is not a source"

# Given an existing Docker source while apt is broken, When configured, Then it fails with a clear message and writes nothing.
new_root debian bookworm
echo 'deb https://download.docker.com/linux/debian bookworm stable' >"$FAKE/root/sources/docker-ce.list"
APT_MODE=fail
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: broken apt with existing source fails"
check "docker apt: broken apt with existing source writes nothing" removed
assert_contains "$(cat "$LOG")" "ERROR apt-get update fails with the existing Docker source" "docker apt: broken apt is explained"

# Given only MediaStack's own docker.list, When configured, Then it is not treated as foreign and stays.
new_root debian bookworm
put_list "$LINE_BOOKWORM"
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: own list returns zero"
check "docker apt: own list triggers no apt-get" test ! -e "$FAKE/apt-calls"

# Given a docker.list MediaStack did not write, When configured, Then it is kept and a warning is logged.
new_root debian bookworm
echo 'deb https://mirror.example/docker bookworm stable' >"$MEDIASTACK_DOCKER_APT_LIST"
configure_docker_apt_repo
assert_eq "0" "$?" "docker apt: foreign list does not fail the run"
assert_eq "deb https://mirror.example/docker bookworm stable" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "docker apt: foreign list is not overwritten"
assert_contains "$(cat "$LOG")" "WARN" "docker apt: foreign list is warned about"
check "docker apt: foreign list triggers no fetch" test ! -e "$FAKE/apt-calls"

# Given the old writer's broken Ubuntu source, When configured on Ubuntu, Then the run fails closed and keeps the file.
new_root ubuntu noble
echo "$OLD_NOBLE" >"$MEDIASTACK_DOCKER_APT_LIST"
APT_MODE=fail
configure_docker_apt_repo
assert_eq "1" "$?" "docker apt: broken old source on Ubuntu fails closed"
assert_eq "$OLD_NOBLE" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "docker apt: pre-existing source is not deleted by a failed run"

# Given a stale MediaStack source for another codename on Debian, When configured, Then it is replaced.
new_root debian bookworm
echo "$OLD_NOBLE" >"$MEDIASTACK_DOCKER_APT_LIST"
: >"$MEDIASTACK_DOCKER_APT_KEY"
configure_docker_apt_repo
assert_eq "$LINE_BOOKWORM" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "docker apt: stale MediaStack source is repaired"
check "docker apt: 0-byte key is replaced" test -s "$MEDIASTACK_DOCKER_APT_KEY"

# Given Docker without Compose, When --full repair runs, Then the source is added and the plugin installed.
new_root debian bookworm
command() {
    [[ "${1:-}" == "-v" && "${2:-}" == "docker" ]] && return 0
    builtin command "$@"
}
docker() { return 1; }
groups() { echo "x docker"; }
install_docker
# And the install ran under DEBIAN_FRONTEND=noninteractive with conffile defaults, so no debconf dialog hides behind the spinner.
assert_contains "$ENV_SEEN" "DEBIAN_FRONTEND=noninteractive" "install_docker: apt install runs with DEBIAN_FRONTEND=noninteractive"
assert_contains "$(cat "$FAKE/apt-calls")" "install -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold docker-compose-plugin" "install_docker: Compose-missing repair installs the plugin with conffile defaults"
check "install_docker: repair wrote the Docker apt source" test -s "$MEDIASTACK_DOCKER_APT_LIST"

# Given the source cannot be proven, When Docker is installed, Then it stops before installing anything.
new_root ubuntu noble
APT_MODE=fail
install_docker
assert_eq "1" "$?" "install_docker: unprovable source fails the install"
assert_not_contains "$(cat "$FAKE/apt-calls")" "docker-compose-plugin" "install_docker: nothing is installed from an unproven source"
unset -f command docker groups

# Given the old writer's debian/noble source on Ubuntu, When the broken source is removed, Then list and key go.
new_root ubuntu noble
put_list "$OLD_NOBLE"
remove_broken_docker_apt_source
assert_eq "0" "$?" "broken source: Ubuntu repair returns zero"
check "broken source: debian repo on Ubuntu is removed with its key" removed

# Given a MediaStack source for another codename on Debian, Then it is removed.
new_root debian bookworm
put_list "$OLD_NOBLE"
remove_broken_docker_apt_source
check "broken source: codename mismatch on Debian is removed" removed

# Given a working source, Then it stays and the keep is logged.
new_root debian bookworm
put_list "$LINE_BOOKWORM"
remove_broken_docker_apt_source
assert_eq "0" "$?" "working source: returns zero"
check "working source: list stays" test -e "$MEDIASTACK_DOCKER_APT_LIST"
check "working source: key stays" test -e "$MEDIASTACK_DOCKER_APT_KEY"
assert_contains "$(cat "$LOG")" "INFO Docker apt source kept" "working source: the keep is logged"

# Given Linux Mint (wilma) with Docker's documented linux/ubuntu noble line, Then it stays.
new_root linuxmint wilma
put_list 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable'
remove_broken_docker_apt_source
check "derivative: Mint with a valid ubuntu noble repo keeps list and key" kept
assert_contains "$(cat "$LOG")" "INFO Docker apt source kept" "derivative: Mint keep is logged"

# Given Raspbian (bookworm) with Docker's documented linux/debian bookworm line, Then it stays.
new_root raspbian bookworm
put_list 'deb [arch=armhf signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable'
remove_broken_docker_apt_source
check "derivative: Raspbian with a valid debian bookworm repo keeps list and key" kept

# Given Debian trixie with an older but valid bookworm line, Then it stays.
new_root debian trixie
put_list "$LINE_BOOKWORM"
remove_broken_docker_apt_source
check "older codename: bookworm source on trixie keeps list and key" kept

# Given a foreign list, Then it is untouched and warned about; near-miss content is foreign too.
new_root debian bookworm
put_list "deb https://mirror.example/docker bookworm stable"
remove_broken_docker_apt_source
assert_eq "deb https://mirror.example/docker bookworm stable" "$(cat "$MEDIASTACK_DOCKER_APT_LIST")" "foreign source: untouched"
assert_contains "$(cat "$LOG")" "WARN" "foreign source: warned about"
printf '%s\ndeb-src https://x y z\n' "$OLD_NOBLE" >"$MEDIASTACK_DOCKER_APT_LIST"
remove_broken_docker_apt_source
check "foreign source: near-miss content is not treated as ours" test -e "$MEDIASTACK_DOCKER_APT_LIST"

# Given only a 0-byte key, Then it is removed.
new_root ubuntu noble
: >"$MEDIASTACK_DOCKER_APT_KEY"
remove_broken_docker_apt_source
check "empty key: removed when no source exists" removed

# Given a removal that fails, Then the function returns non-zero.
new_root ubuntu noble
put_list "$OLD_NOBLE"
sudo() {
    [[ "$1" == rm ]] && return 1
    "$@"
}
remove_broken_docker_apt_source
assert_eq "1" "$?" "broken source: removal failure returns non-zero"
sudo() { "$@"; }

scenario_end "$CURRENT_SCENARIO"
summary
