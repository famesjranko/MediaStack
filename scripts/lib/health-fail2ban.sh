#!/usr/bin/env bash
# Owns: _health_f2b_running _health_f2b_installed _health_f2b_down_reason - why fail2ban is not running.
# Sources: scripts/lib/profiles.sh (profiles_build_args). Needs _HEALTH_REPO_ROOT from health.sh.

_HF2B_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
declare -F profiles_build_args >/dev/null 2>&1 || source "$_HF2B_LIB_DIR/profiles.sh"

# fail2ban container present + running. Works in every consumer (no reliance on
# mediastack's _service_is_running). Capture-then-grep: piping docker into grep
# would SIGPIPE under pipefail.
_health_f2b_running() {
    local names
    names=$(docker ps --format '{{.Names}}' 2>/dev/null) || return 1
    grep -qx fail2ban <<<"$names"
}

# fail2ban belongs to the proxy profile, which a real DOMAIN in .env switches on.
# "Installed" therefore means configured, not "a container exists": a stopped,
# crashed or removed fail2ban on a remote-access host is still installed and
# still needs starting, while a LAN-only host never had one.
_health_f2b_installed() {
    local -a _hf2b_profiles=()
    profiles_build_args _hf2b_profiles "$_HEALTH_REPO_ROOT/.env"
    [[ " ${_hf2b_profiles[*]} " == *" proxy "* ]]
}

# Why fail2ban is not running, in one clause. The two causes need different
# next steps, so callers must not collapse them into "LAN-only".
_health_f2b_down_reason() {
    if _health_f2b_installed; then
        printf 'fail2ban is installed but not running - start it from Manage stack > Start a service'
    else
        printf 'fail2ban not installed (LAN-only install)'
    fi
}
