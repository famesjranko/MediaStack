# =============================================================================
# MediaStack — docker-compose profile-arg builder (shared)
# =============================================================================
# Single source of truth for which optional compose profiles a stack runs,
# derived from the on-disk .env. Both the installer (scripts/setup/stack.sh)
# and the front-door launcher (./mediastack) source this file and call the one
# function, so the day-2 menu's stop/start/status always targets the same
# profile set the installer used.
#
# The values are read fresh from disk (not an in-memory snapshot) so a domain
# or WireGuard password added mid-session is reflected immediately, and they are
# read quote-agnostically so a single- or double-quoted .env entry agree.
#
# Side-effect-free: sourcing only defines the function. Safe under both
# `set -euo pipefail` (installer) and `set -uo pipefail` (launcher).
# =============================================================================

# Idempotent include guard. Multiple callers may source this; redefining the
# function would be harmless, but the guard skips the redundant work. The guard
# precedes the function definition so the file's final command (the def) returns
# 0 on first source under `set -e`.
[[ -n "${_MS_PROFILES_SH_LOADED:-}" ]] && return 0
_MS_PROFILES_SH_LOADED=1

# Populate ARRAY_NAME with the `--profile X` flags the .env-declared stack needs.
#
#   Usage: _build_profile_args ARRAY_NAME [ENV_FILE]
#     ARRAY_NAME  caller-provided array variable to fill (reset to () first)
#     ENV_FILE    .env to read; defaults to ${SCRIPT_DIR:-$PWD}/.env
#
# Profiles:
#   subtitles  Bazarr            when BAZARR_ENABLED=true
#   autoheal   autoheal sidecar  unless AUTOHEAL_ENABLED=false (on by default)
#   proxy      NPM/DDNS/fail2ban  when a real DOMAIN is set (not the LAN sentinel)
#   remote     WireGuard          when an init password is set
_build_profile_args() {
    local -n _bpa_out=$1
    local _bpa_env="${2:-${SCRIPT_DIR:-$PWD}/.env}"
    _bpa_out=()

    local _bazarr="false" _autoheal="true" _domain="" _wg=""
    if [[ -f "$_bpa_env" ]]; then
        local _line _key _val
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            # Skip blanks, comments, and any line without a key=value shape.
            case "$_line" in
                '' | '#'*) continue ;;
                *=*) ;;
                *) continue ;;
            esac
            _key=${_line%%=*}
            _val=${_line#*=}
            # Strip one layer of matching surrounding quotes so single- and
            # double-quoted values are read identically.
            if ((${#_val} >= 2)); then
                if { [[ ${_val:0:1} == "'" && ${_val: -1} == "'" ]]; } \
                    || { [[ ${_val:0:1} == '"' && ${_val: -1} == '"' ]]; }; then
                    _val=${_val:1:${#_val}-2}
                fi
            fi
            case "$_key" in
                BAZARR_ENABLED) _bazarr=$_val ;;
                AUTOHEAL_ENABLED) _autoheal=$_val ;;
                DOMAIN) _domain=$_val ;;
                WG_INIT_PASSWORD) _wg=$_val ;;
            esac
        done <"$_bpa_env"
    fi

    if [[ "$_bazarr" == "true" ]]; then
        _bpa_out+=(--profile subtitles)
    fi
    if [[ "$_autoheal" != "false" ]]; then
        _bpa_out+=(--profile autoheal)
    fi
    if [[ -n "$_domain" && "$_domain" != "example.com" ]]; then
        _bpa_out+=(--profile proxy)
    fi
    if [[ -n "$_wg" ]]; then
        _bpa_out+=(--profile remote)
    fi
}
