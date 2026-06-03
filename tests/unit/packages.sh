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

log_ok()    { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }

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
        gpg|tee)
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

scenario_end "$CURRENT_SCENARIO"
summary
