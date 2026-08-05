#!/usr/bin/env bash
# =============================================================================
# MediaStack Auto-Configuration
# =============================================================================
# Reads settings from config.yml and wires up all services automatically.
# Safe to run multiple times (idempotent - checks before creating).
#
# Usage: ./scripts/configure.sh
#        ./scripts/configure.sh --only jellyfin,sonarr
#
# To change indexers, quality profiles, paths, etc:
#   Edit config.yml, then re-run this script.
#
# Structure: thin entrypoint. Shared helpers live under scripts/lib/,
# per-service installers live under scripts/services/. Cross-service
# orchestration (when it arrives) goes in scripts/flows/.
# =============================================================================
# -e is intentionally OFF: each step handles errors locally via if/fi, log_warn,
# and `if ! var=$(api_get/api_fetch ...); then log_warn; var="[]"; fi` fallbacks.
# A single api_post returning HTTP 4xx (validation error, conflict, etc.) should
# not abort the whole configurator — otherwise steps 4-8 are silently skipped on
# the first transient failure in step 3.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR" || exit 1

# Load .env
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

CONFIG_FILE="$SCRIPT_DIR/config.yml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.yml not found at $CONFIG_FILE"
    exit 1
fi

# Validate config.yml parses correctly
if ! python3 -c "import yaml; yaml.safe_load(open('$CONFIG_FILE'))" 2>/dev/null; then
    echo "ERROR: config.yml has invalid YAML syntax. Fix it and re-run."
    python3 -c "import yaml; yaml.safe_load(open('$CONFIG_FILE'))" 2>&1 || true
    exit 1
fi

# --- Shared libraries ---
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/lib/json.sh"
source "$SCRIPT_DIR/scripts/lib/arr/main.sh"
source "$SCRIPT_DIR/scripts/lib/network.sh"
source "$SCRIPT_DIR/scripts/setup/storage.sh"

# --- Per-service installers ---
# Supports services/<svc>.sh (single file) or services/<svc>/main.sh
# (directory form) — a service can grow from one file to a submodule
# without touching this entrypoint.
for svc in qbittorrent jackett sonarr radarr bazarr jellyfin seerr portainer homepage npm ddns-updater wireguard uptime-kuma beszel; do
    if [[ -f "$SCRIPT_DIR/scripts/services/$svc/main.sh" ]]; then
        source "$SCRIPT_DIR/scripts/services/$svc/main.sh"
    else
        source "$SCRIPT_DIR/scripts/services/$svc.sh"
    fi
done

# --- Cross-service orchestration ---
# flows/*.sh is the escape hatch for features mutating ≥2 services' state.
# Empty today; each file must define a single `flow_<name>` function.
if [[ -d "$SCRIPT_DIR/scripts/flows" ]]; then
    for flow in "$SCRIPT_DIR"/scripts/flows/*.sh; do
        [[ -f "$flow" ]] && source "$flow"
    done
fi

# --- Argument parsing ---
ONLY_SERVICES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)
            ONLY_SERVICES="$2"
            shift 2
            ;;
        --only=*)
            ONLY_SERVICES="${1#--only=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

_should_configure() {
    [[ -z "$ONLY_SERVICES" ]] && return 0
    local svc="$1" list=" ${ONLY_SERVICES//,/ } "
    [[ "$list" == *" $svc "* ]]
}

_CONFIGURE_OK=()
_CONFIGURE_WARN=()

_record_configure_result() {
    local _label="${1%%|*}" _flag="${1##*|}" _w0="$2" _forced_warn="${3:-0}"
    if ((_forced_warn || _LOG_COUNTS_WARN + _LOG_COUNTS_ERROR > _w0)); then
        _CONFIGURE_WARN+=("$_label|$_flag")
    else
        _CONFIGURE_OK+=("$_label")
    fi
}

# Runs a configure_* function and records the service label in _CONFIGURE_OK
# or _CONFIGURE_WARN. WARN when the function emitted any log_warn/log_error
# (many configurators log-and-continue on partial failure, returning 0) OR
# returned non-zero (rc contract: a non-zero return always badges WARN, even
# if nothing was logged). Advisory drift notices use log_drift, which is
# uncounted and never affects the badge.
# Usage: _run_configure "Label|--only-flag" configure_fn [args...]
_run_configure() {
    local _service="$1"
    shift
    local _w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
    local _rc=0
    "$@" || _rc=$?
    _record_configure_result "$_service" "$_w0" "$((_rc != 0))"
    return "$_rc"
}

# =============================================================================
# Main
# =============================================================================

main() {
    rm -f "$SCRIPT_DIR/.configure_issues"
    echo -e "${CYAN}"
    echo "  ${_G_DTL}$(_g_repeat 42 "$_G_DH")${_G_DTR}"
    echo "  ${_G_DV}    MediaStack Auto-Configuration         ${_G_DV}"
    echo "  ${_G_DBL}$(_g_repeat 42 "$_G_DH")${_G_DBR}"
    echo -e "${NC}"
    log_info "Reading your settings"
    if storage_is_manual; then
        log_warn "Advanced manual app wiring: skipping MediaStack's app-level storage wiring."
    fi
    if [[ -n "$ONLY_SERVICES" ]]; then
        log_info "Targeted run: ${ONLY_SERVICES}"
    fi
    _should_configure qbittorrent && wait_for_service "qBittorrent" "$(service_local_url qbittorrent)"
    _should_configure jackett && wait_for_service "Jackett" "$(service_local_url jackett)"
    _should_configure sonarr && wait_for_service "Sonarr" "$(service_local_url sonarr)"
    _should_configure radarr && wait_for_service "Radarr" "$(service_local_url radarr)"
    _should_configure jellyfin && wait_for_service "Jellyfin" "$(service_local_url jellyfin)"
    _should_configure seerr && wait_for_service "Seerr" "$(service_local_url seerr)"
    _should_configure portainer && wait_for_service "Portainer" "$(service_local_url portainer)"
    _should_configure homepage && wait_for_service "Homepage" "$(service_local_url homepage)"

    # Portainer first: it has a 5-minute admin creation timeout from first
    # start. Running it before the slower services (indexer adds, Jellyfin
    # library scan) maximises the chance of hitting that window.
    _should_configure portainer && _run_configure "Portainer|portainer" configure_portainer

    _should_configure qbittorrent && _run_configure "qBittorrent|qbittorrent" configure_qbittorrent
    _should_configure jackett && _run_configure "Jackett|jackett" configure_jackett
    local _sonarr_w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR)) _sonarr_warn=0
    if _should_configure sonarr; then configure_sonarr || _sonarr_warn=1; fi
    ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR > _sonarr_w0)) && _sonarr_warn=1
    local _radarr_w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR)) _radarr_warn=0
    if _should_configure radarr; then configure_radarr || _radarr_warn=1; fi
    ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR > _radarr_w0)) && _radarr_warn=1

    # Indexer phase — Sonarr and Radarr add the same Jackett-fronted trackers,
    # and on save each *arr synchronously fetches caps through Jackett to the
    # upstream tracker. Cloudflare-protected trackers can stall a single save
    # for tens of seconds. Running both apps' indexer adds concurrently roughly
    # halves wall time compared to the previous serial Sonarr→Radarr flow. The
    # configure_arr_indexers helper itself already streams [OK]/[WARN] lines as
    # workers finish, so the user sees progress instead of a long silence.
    local -A _ix_warn=()
    if { _should_configure sonarr && [[ -n "${SONARR_API_KEY:-}" ]]; } \
        || { _should_configure radarr && [[ -n "${RADARR_API_KEY:-}" ]]; }; then
        echo ""
        echo -e "${BOLD}Adding Sonarr + Radarr indexers (in parallel)...${NC}"
        local _ix_pids=() _ix_apps=()
        if _should_configure sonarr && [[ -n "${SONARR_API_KEY:-}" ]]; then
            local tv_cats
            tv_cats=$(cfg_field "categories.tv")
            (
                local _w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
                configure_arr_indexers "sonarr" "$(service_local_url sonarr)/api/v3" "${SONARR_API_KEY}" "$tv_cats"
                ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR == _w0))
            ) &
            _ix_pids+=($!)
            _ix_apps+=(sonarr)
        fi
        if _should_configure radarr && [[ -n "${RADARR_API_KEY:-}" ]]; then
            local movie_cats
            movie_cats=$(cfg_field "categories.movies")
            (
                local _w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
                configure_arr_indexers "radarr" "$(service_local_url radarr)/api/v3" "${RADARR_API_KEY}" "$movie_cats"
                ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR == _w0))
            ) &
            _ix_pids+=($!)
            _ix_apps+=(radarr)
        fi
        local _ix_i
        for _ix_i in "${!_ix_pids[@]}"; do
            wait "${_ix_pids[$_ix_i]}" 2>/dev/null || _ix_warn["${_ix_apps[$_ix_i]}"]=1
        done
    fi

    if _should_configure bazarr; then
        if service_container_running bazarr; then
            wait_for_service "Bazarr" "$(service_local_url bazarr)"
            _run_configure "Bazarr|bazarr" configure_bazarr
        fi
    fi

    _should_configure jellyfin && _run_configure "Jellyfin|jellyfin" configure_jellyfin

    # Jellyfin connection in Sonarr/Radarr — needs JELLYFIN_API_KEY (exported
    # by configure_jellyfin above) and the *arr API keys (exported earlier).
    if storage_is_manual; then
        log_skip "Sonarr/Radarr Jellyfin notifications skipped (manual app wiring)"
    else
        if _should_configure sonarr; then
            local _w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
            configure_arr_jellyfin_connection "sonarr" "$(service_local_url sonarr)/api/v3" "${SONARR_API_KEY:-}"
            ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR > _w0)) && _sonarr_warn=1
        fi
        if _should_configure radarr; then
            local _w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
            configure_arr_jellyfin_connection "radarr" "$(service_local_url radarr)/api/v3" "${RADARR_API_KEY:-}"
            ((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR > _w0)) && _radarr_warn=1
        fi
    fi

    _sonarr_warn=$((_sonarr_warn || ${_ix_warn[sonarr]:-0}))
    _radarr_warn=$((_radarr_warn || ${_ix_warn[radarr]:-0}))
    local _result_w0=$((_LOG_COUNTS_WARN + _LOG_COUNTS_ERROR))
    _should_configure sonarr && _record_configure_result "Sonarr|sonarr" "$_result_w0" "$_sonarr_warn"
    _should_configure radarr && _record_configure_result "Radarr|radarr" "$_result_w0" "$_radarr_warn"

    if _should_configure seerr; then
        if storage_is_manual; then
            log_skip "Seerr setup skipped (manual app wiring)"
        else
            sleep 3 # Jellyfin may have just restarted - let auth endpoints stabilise
            _run_configure "Seerr|seerr" configure_seerr
        fi
    fi
    _should_configure homepage && _run_configure "Homepage|homepage" configure_homepage

    if _should_configure npm; then
        if service_container_running npm; then
            wait_for_service "NPM" "$(service_local_url npm)"
            _run_configure "NPM|npm" configure_npm
        fi
    fi
    _should_configure ddns-updater && _run_configure "DDNS Updater|ddns-updater" configure_ddns_updater

    if _should_configure wireguard; then
        if service_container_running wireguard; then
            wait_for_healthy "WireGuard" "wireguard" "$(service_local_url wireguard)"
            if ! _run_configure "WireGuard|wireguard" configure_wireguard; then
                log_error "WireGuard access-tier enforcement failed; fix the warnings above, then choose Features & settings -> Add remote access from the menu"
                return 1
            fi
        fi
    fi

    if _should_configure uptime-kuma; then
        wait_for_healthy "Uptime Kuma" "uptime-kuma" "$(service_local_url uptime-kuma)"
        _run_configure "Uptime Kuma|uptime-kuma" configure_uptime_kuma
    fi

    if _should_configure beszel; then
        wait_for_service "Beszel" "$(service_local_url beszel)"
        _run_configure "Beszel|beszel" configure_beszel
    fi

    if [[ -z "$ONLY_SERVICES" ]]; then
        # Recreate Unpackerr so it picks up the API keys configure.sh just saved
        # to .env. `docker compose restart` only stops/starts the existing container
        # with its original (empty) env — `up -d` detects the env change and
        # recreates the container with the new values.
        if storage_is_manual; then
            log_skip "Unpackerr recreate skipped (manual app wiring)"
        else
            echo ""
            log_info "Recreating Unpackerr with API keys..."
            docker compose up -d unpackerr >/dev/null 2>&1
            log_ok "Unpackerr restarted"
        fi

        # Reload fail2ban so jails pick up the real (dated) log files that services
        # have created since startup. At boot, fail2ban resolves logpath globs to
        # the placeholder touchfiles from setup.sh — a reload re-resolves them.
        # Note: iptables chains are created at jail start (actionstart_on_demand=false
        # in mediastack.conf) and survive reload, so no chain repair is needed here.
        if service_container_running fail2ban; then
            docker exec fail2ban fail2ban-client reload >/dev/null 2>&1 \
                && log_ok "fail2ban reloaded (jails watching real log files)" \
                || log_warn "Could not reload fail2ban"
        fi
    fi

    echo ""
    echo -e "${CYAN}$(_g_repeat 59 "$_G_DH")${NC}"
    if ((${#_CONFIGURE_WARN[@]} == 0)); then
        echo -e "${GREEN}${BOLD}  Auto-configuration complete!${NC}"
    else
        echo -e "${YELLOW}${BOLD}  Auto-configuration complete (with warnings)${NC}"
    fi
    echo -e "${CYAN}$(_g_repeat 59 "$_G_DH")${NC}"
    echo ""
    local _svc _wlabel
    for _svc in "${_CONFIGURE_OK[@]}"; do
        echo -e "  ${GREEN}$(_ui_status_token ok)${NC}  $_svc"
    done
    for _svc in "${_CONFIGURE_WARN[@]}"; do
        _wlabel="${_svc%%|*}"
        echo -e "  ${YELLOW}$(_ui_status_token warn)${NC}  $_wlabel"
    done
    echo ""
    echo "  To retry these or change settings later, re-run MediaStack setup"
    echo "  (already-configured services are skipped)."
    echo ""
    echo -e "${CYAN}$(_g_repeat 59 "$_G_DH")${NC}"

    # Write issues file so stage1.sh can surface them after the final banner.
    local _issues_file="$SCRIPT_DIR/.configure_issues"
    rm -f "$_issues_file"
    for _svc in "${_CONFIGURE_WARN[@]}"; do
        printf '%s\n' "$_svc" >>"$_issues_file"
    done
}

main
