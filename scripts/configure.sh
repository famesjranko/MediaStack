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
cd "$SCRIPT_DIR"

# Load .env
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a; source "$SCRIPT_DIR/.env"; set +a
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
for svc in qbittorrent jackett sonarr radarr bazarr jellyfin jellyseerr portainer homepage npm ddns-updater wireguard uptime-kuma beszel; do
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
        --only) ONLY_SERVICES="$2"; shift 2 ;;
        --only=*) ONLY_SERVICES="${1#--only=}"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

_should_configure() {
    [[ -z "$ONLY_SERVICES" ]] && return 0
    local svc="$1" list=" ${ONLY_SERVICES//,/ } "
    [[ "$list" == *" $svc "* ]]
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════╗"
    echo "  ║    MediaStack Auto-Configuration         ║"
    echo "  ╚══════════════════════════════════════════╝"
    echo -e "${NC}"
    log_info "Reading config from: config.yml"
    if storage_is_manual; then
        log_warn "Advanced manual app wiring: skipping MediaStack's app-level storage wiring."
    fi
    if [[ -n "$ONLY_SERVICES" ]]; then
        log_info "Targeted run: ${ONLY_SERVICES}"
    fi
    log_info "Waiting for services..."

    _should_configure qbittorrent && wait_for_service "qBittorrent" "http://localhost:8080"
    _should_configure jackett     && wait_for_service "Jackett"     "http://localhost:9117"
    _should_configure sonarr      && wait_for_service "Sonarr"      "http://localhost:8989"
    _should_configure radarr      && wait_for_service "Radarr"      "http://localhost:7878"
    _should_configure jellyfin    && wait_for_service "Jellyfin"    "http://localhost:8096"
    _should_configure jellyseerr  && wait_for_service "Jellyseerr"  "http://localhost:5055"
    _should_configure portainer   && wait_for_service "Portainer"   "http://localhost:9000"
    _should_configure homepage    && wait_for_service "Homepage"    "http://localhost:3000"

    # Portainer first: it has a 5-minute admin creation timeout from first
    # start. Running it before the slower services (indexer adds, Jellyfin
    # library scan) maximises the chance of hitting that window.
    _should_configure portainer   && configure_portainer

    _should_configure qbittorrent && configure_qbittorrent
    _should_configure jackett     && configure_jackett
    _should_configure sonarr      && configure_sonarr
    _should_configure radarr      && configure_radarr

    # Indexer phase — Sonarr and Radarr add the same Jackett-fronted trackers,
    # and on save each *arr synchronously fetches caps through Jackett to the
    # upstream tracker. Cloudflare-protected trackers can stall a single save
    # for tens of seconds. Running both apps' indexer adds concurrently roughly
    # halves wall time compared to the previous serial Sonarr→Radarr flow. The
    # configure_arr_indexers helper itself already streams [OK]/[WARN] lines as
    # workers finish, so the user sees progress instead of a long silence.
    if { _should_configure sonarr && [[ -n "${SONARR_API_KEY:-}" ]]; } \
        || { _should_configure radarr && [[ -n "${RADARR_API_KEY:-}" ]]; }; then
        echo ""
        echo -e "${BOLD}Adding Sonarr + Radarr indexers (in parallel)...${NC}"
        local _ix_pids=()
        if _should_configure sonarr && [[ -n "${SONARR_API_KEY:-}" ]]; then
            local tv_cats; tv_cats=$(cfg_field "categories.tv")
            configure_arr_indexers "sonarr" "http://localhost:8989/api/v3" "${SONARR_API_KEY}" "$tv_cats" &
            _ix_pids+=($!)
        fi
        if _should_configure radarr && [[ -n "${RADARR_API_KEY:-}" ]]; then
            local movie_cats; movie_cats=$(cfg_field "categories.movies")
            configure_arr_indexers "radarr" "http://localhost:7878/api/v3" "${RADARR_API_KEY}" "$movie_cats" &
            _ix_pids+=($!)
        fi
        for _ix_pid in "${_ix_pids[@]}"; do wait "$_ix_pid" 2>/dev/null; done
    fi

    if _should_configure bazarr; then
        if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx bazarr; then
            wait_for_service "Bazarr" "http://localhost:6767"
            configure_bazarr
        fi
    fi

    _should_configure jellyfin && configure_jellyfin

    # Jellyfin connection in Sonarr/Radarr — needs JELLYFIN_API_KEY (exported
    # by configure_jellyfin above) and the *arr API keys (exported earlier).
    if storage_is_manual; then
        log_skip "Sonarr/Radarr Jellyfin notifications skipped (manual app wiring)"
    else
        _should_configure sonarr && \
            configure_arr_jellyfin_connection "sonarr" "http://localhost:8989/api/v3" "${SONARR_API_KEY:-}"
        _should_configure radarr && \
            configure_arr_jellyfin_connection "radarr" "http://localhost:7878/api/v3" "${RADARR_API_KEY:-}"
    fi

    if _should_configure jellyseerr; then
        if storage_is_manual; then
            log_skip "Jellyseerr setup skipped (manual app wiring)"
        else
            sleep 3  # Jellyfin may have just restarted — let auth endpoints stabilise
            configure_jellyseerr
        fi
    fi
    _should_configure homepage && configure_homepage

    if _should_configure npm; then
        if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx npm; then
            wait_for_service "NPM" "http://localhost:81"
            configure_npm
        fi
    fi
    _should_configure ddns-updater && configure_ddns_updater

    if _should_configure wireguard; then
        if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx wireguard; then
            wait_for_healthy "WireGuard" "wireguard" "http://localhost:51821"
            if ! configure_wireguard; then
                log_error "WireGuard access-tier enforcement failed; fix the warnings above and rerun ./scripts/configure.sh --only wireguard"
                return 1
            fi
        fi
    fi

    if _should_configure uptime-kuma; then
        wait_for_healthy "Uptime Kuma" "uptime-kuma" "http://localhost:3001"
        configure_uptime_kuma
    fi

    if _should_configure beszel; then
        wait_for_service "Beszel" "http://localhost:8090"
        configure_beszel
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
        if docker compose ps --format '{{.Names}}' 2>/dev/null | grep -qx fail2ban; then
            docker exec fail2ban fail2ban-client reload >/dev/null 2>&1 && \
                log_ok "fail2ban reloaded (jails watching real log files)" || \
                log_warn "Could not reload fail2ban"
        fi
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Auto-configuration complete!${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "  To change settings later, edit config.yml and re-run:"
    echo "    ./scripts/configure.sh"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
}

main
