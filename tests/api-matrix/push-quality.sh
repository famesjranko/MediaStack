#!/usr/bin/env bash
# tests/api-matrix/push-quality.sh — drive the PRODUCT quality configurators for
# one (resolution x size) cell against a live Sonarr/Radarr, inside DinD.
#
# Composes the cell into a throwaway config.yml via `wizard_apply.py
# --quality-only`, then runs the REAL configure_quality_profile (+ definitions,
# custom formats, format scores) — the exact sequence the launcher's day-2
# "Change quality profile" action triggers through configure.sh. With
# QP_RENAME_FROM set it exercises the in-place rename branch. Reuses product code
# only; this file owns no API logic of its own.
#
#   push-quality.sh <app> <base_url> <api_key> <resolution> <size> [rename_from]
set -uo pipefail

app="$1"
base="$2"
key="$3"
res="$4"
size="$5"
rename_from="${6:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$SCRIPT_DIR" || exit 1
export SCRIPT_DIR

# Throwaway config so we never touch the repo's tracked config.yml. Seeded once
# from it, then re-composed in place across cells (mirrors the day-2 flow, which
# rewrites the live config.yml each change).
CONFIG_FILE="/tmp/ms-quality-rename.yml"
export CONFIG_FILE
[[ -f "$CONFIG_FILE" ]] || cp "$SCRIPT_DIR/config.yml" "$CONFIG_FILE"
python3 "$SCRIPT_DIR/scripts/setup/wizard_apply.py" --quality-only \
    --resolution "$res" --size "$size" --config "$CONFIG_FILE" >/dev/null

# Same library set configure.sh loads (minus the unrelated per-service ones).
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/lib/http.sh"
source "$SCRIPT_DIR/scripts/lib/json.sh"
source "$SCRIPT_DIR/scripts/lib/arr/main.sh"

export QP_RENAME_FROM="$rename_from"
qids=$(cfg_quality_ids "$app")
configure_quality_profile "$app" "$base" "$key" "$qids"
configure_quality_definitions "$app" "$base" "$key"
configure_arr_custom_formats "$app" "$base" "$key"
configure_arr_format_scores "$app" "$base" "$key"
