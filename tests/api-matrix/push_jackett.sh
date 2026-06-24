#!/usr/bin/env bash
# tests/api-matrix/push_jackett.sh — drive the PRODUCT Jackett configurator
# against a live Jackett, inside DinD. Reuses product code only; this file
# owns no API logic of its own.
#
#   push_jackett.sh seed-config <id[:type]> [id[:type] ...]  # write indexers: list
#   push_jackett.sh apply                                    # configure_jackett
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
CONFIG_FILE="/tmp/ms-jackett-matrix.yml"
export CONFIG_FILE
[[ -f "$CONFIG_FILE" ]] || cp "$SCRIPT_DIR/config.yml" "$CONFIG_FILE"

if [[ "$mode" == "seed-config" ]]; then
    (( $# >= 1 )) || {
        echo "usage: push_jackett.sh seed-config <id[:type]> [id[:type] ...]" >&2
        exit 2
    }
    JKM_PAIRS="$*" python3 - "$CONFIG_FILE" <<'PY'
import os
import sys

import yaml

path = sys.argv[1]
indexers = []
for pair in os.environ["JKM_PAIRS"].split():
    idx_id, _, idx_type = pair.partition(":")
    indexers.append({"id": idx_id, "type": idx_type or "general"})

with open(path, encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}
config["indexers"] = indexers
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
    exit 0
fi

# Same library set configure.sh loads for Jackett.
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/services/jackett/main.sh"

case "$mode" in
    apply)
        configure_jackett
        ;;
    *)
        echo "usage: push_jackett.sh seed-config <id[:type]> ...|apply" >&2
        exit 2
        ;;
esac
