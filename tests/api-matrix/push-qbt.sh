#!/usr/bin/env bash
# tests/api-matrix/push-qbt.sh — drive the PRODUCT qBittorrent configurators
# against a live qBittorrent, inside DinD. Reuses product code only; this file
# owns no API logic of its own.
#
#   push-qbt.sh apply                  # configure_qbittorrent (config.yml-driven)
#   push-qbt.sh speedlimit <dl_mb> <ul_mb>   # day-2 qbt_set_speed_limits
set -uo pipefail

mode="$1"
shift

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
export SCRIPT_DIR

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

# Throwaway config so we never touch the repo's tracked config.yml. Seeded once
# from it; matrix_qbittorrent reads cfg_field/cfg_qbt_categories against this
# SAME file for its expected values (mirrors push-quality.sh's pattern).
CONFIG_FILE="/tmp/ms-qbt-matrix.yml"
export CONFIG_FILE
[[ -f "$CONFIG_FILE" ]] || cp "$SCRIPT_DIR/config.yml" "$CONFIG_FILE"

if [[ "$mode" == "seed-config" ]]; then
    [[ $# -eq 2 ]] || {
        echo "usage: push-qbt.sh seed-config <download_mb> <upload_mb>" >&2
        exit 2
    }
    python3 - "$CONFIG_FILE" "$1" "$2" <<'PY'
import sys
import yaml

path, download, upload = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    config = yaml.safe_load(handle) or {}
config.setdefault("qbittorrent", {})["dl_speed_limit"] = float(download)
config["qbittorrent"]["ul_speed_limit"] = float(upload)
with open(path, "w", encoding="utf-8") as handle:
    yaml.safe_dump(config, handle, sort_keys=False)
PY
    exit 0
fi

# Same library set configure.sh loads for qBittorrent.
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/services/qbittorrent/main.sh"

case "$mode" in
    apply)
        configure_qbittorrent
        ;;
    speedlimit)
        qbt_set_speed_limits "$1" "$2"
        ;;
    *)
        echo "usage: push-qbt.sh apply|seed-config <dl_mb> <ul_mb>|speedlimit <dl_mb> <ul_mb>" >&2
        exit 2
        ;;
esac
