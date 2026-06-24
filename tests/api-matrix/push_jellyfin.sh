#!/usr/bin/env bash
# tests/api-matrix/push_jellyfin.sh — drive the PRODUCT Jellyfin configurator
# and the Sonarr/Radarr->Jellyfin notification connector against a live
# Jellyfin, inside DinD. Reuses product code only; this file owns no API
# logic of its own.
#
#   push_jellyfin.sh seed-config <name:type:path> [name:type:path ...]
#   push_jellyfin.sh apply                                  # configure_jellyfin
#   push_jellyfin.sh connect <sonarr|radarr> <api-base> <api-key>
set -uo pipefail

mode="$1"; shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
export SCRIPT_DIR

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

# Throwaway config so we never touch the repo's tracked config.yml.
CONFIG_FILE="/tmp/ms-jellyfin-matrix.yml"
export CONFIG_FILE
[[ -f "$CONFIG_FILE" ]] || cp "$SCRIPT_DIR/config.yml" "$CONFIG_FILE"

if [[ "$mode" == "seed-config" ]]; then
    (( $# >= 1 )) || {
        echo "usage: push_jellyfin.sh seed-config <name:type:path> [name:type:path ...]" >&2
        exit 2
    }
    # Pass each spec as its own argv entry, not space-joined - library names
    # (e.g. "TV Shows") can contain spaces, which a space-split would mangle.
    python3 - "$CONFIG_FILE" "$@" <<'PY'
import sys

import yaml

path = sys.argv[1]
libraries = []
for entry in sys.argv[2:]:
    name, lib_type, lib_path = entry.split(":", 2)
    libraries.append({"name": name, "type": lib_type, "path": lib_path})

with open(path, encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}
config.setdefault("jellyfin", {})["libraries"] = libraries
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
    exit 0
fi

# Same library set configure.sh loads for Jellyfin / the Jellyfin connection.
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/lib/json.sh"
source "$SCRIPT_DIR/scripts/setup/storage.sh"
source "$SCRIPT_DIR/scripts/services/jellyfin/main.sh"
source "$SCRIPT_DIR/scripts/lib/arr/main.sh"

case "$mode" in
    apply)
        configure_jellyfin
        ;;
    connect)
        [[ $# -eq 3 ]] || {
            echo "usage: push_jellyfin.sh connect <sonarr|radarr> <api-base> <api-key>" >&2
            exit 2
        }
        configure_arr_jellyfin_connection "$1" "$2" "$3"
        ;;
    *)
        echo "usage: push_jellyfin.sh seed-config <name:type:path>...|apply|connect <sonarr|radarr> <api-base> <api-key>" >&2
        exit 2
        ;;
esac
