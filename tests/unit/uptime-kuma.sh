#!/usr/bin/env bash
# tests/unit/uptime-kuma.sh

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uptime-kuma"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
CONFIG_FILE=/dev/null

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/services/uptime-kuma/main.sh"

monitors=$(_uptime_kuma_monitors_json "jellyfin sonarr beszel wireguard")

monitor_url() {
    local name="$1"
    printf '%s' "$monitors" | NAME="$name" python3 -c '
import json
import os
import sys

name = os.environ["NAME"]
for monitor in json.load(sys.stdin):
    if monitor.get("name") == name:
        print(monitor.get("url", ""))
        break
'
}

assert_eq "http://jellyfin:8096/health" "$(monitor_url Jellyfin)" \
    "Uptime Kuma monitor URL: Jellyfin health path"
assert_eq "http://sonarr:8989/ping" "$(monitor_url Sonarr)" \
    "Uptime Kuma monitor URL: Sonarr ping path"
assert_eq "http://beszel:8090/api/health" "$(monitor_url Beszel)" \
    "Uptime Kuma monitor URL: Beszel API health path"
assert_eq "http://wireguard:51821" "$(monitor_url WireGuard)" \
    "Uptime Kuma monitor URL: WireGuard optional service"

scenario_end "$CURRENT_SCENARIO"
summary
