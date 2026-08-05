#!/usr/bin/env bash
# tests/api-matrix/push-seerr.sh — drive the PRODUCT Seerr configurator and the
# Sonarr/Radarr->Seerr connection helper against a live Seerr, inside DinD.
# Reuses product code only; this file owns no API logic of its own.
#
#   push-seerr.sh apply                    # configure_seerr (assumes the
#                                           # jellyfin module already created
#                                           # the SSO admin this needs)
#   push-seerr.sh connect <sonarr|radarr> <cookiejar>  # connect_arr_to_seerr
#                                           # (day-2 reuse path, same session)
set -uo pipefail

mode="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
export SCRIPT_DIR

# Reads the tracked config.yml directly - this module doesn't seed a
# throwaway file, it only reads quality_profile.name/root_folder (cfg_field
# requires CONFIG_FILE exported, same as configure.sh itself sets it).
CONFIG_FILE="$SCRIPT_DIR/config.yml"
export CONFIG_FILE

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

# Same library set configure.sh loads for Jellyfin / Seerr.
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/lib/json.sh"
source "$SCRIPT_DIR/scripts/setup/storage.sh"
source "$SCRIPT_DIR/scripts/services/jellyfin/main.sh"
source "$SCRIPT_DIR/scripts/services/seerr/main.sh"

case "$mode" in
    apply)
        configure_seerr
        ;;
    connect)
        [[ $# -eq 2 ]] || {
            echo "usage: push-seerr.sh connect <sonarr|radarr> <cookiejar>" >&2
            exit 2
        }
        app="$1"
        cookiejar="$2"
        case "$app" in
            sonarr) connect_arr_to_seerr sonarr 8989 "http://localhost:5055" "$cookiejar" ;;
            radarr) connect_arr_to_seerr radarr 7878 "http://localhost:5055" "$cookiejar" ;;
            *)
                echo "usage: push-seerr.sh connect <sonarr|radarr> <cookiejar>" >&2
                exit 2
                ;;
        esac
        ;;
    *)
        echo "usage: push-seerr.sh apply|connect <sonarr|radarr> <cookiejar>" >&2
        exit 2
        ;;
esac
