#!/usr/bin/env bash
set -uo pipefail
UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="health-user-stopped"
scenario_begin "$CURRENT_SCENARIO"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
source "$REPO_ROOT/scripts/lib/health-containers.sh"
profiles_build_args() { :; }
docker() {
    case " $* " in
        *" config --services "*) printf '%s\n' qbittorrent sonarr jellyfin ;;
        *" config --format json "*) printf '%s\n' '{"services":{"qbittorrent":{},"sonarr":{"depends_on":{"qbittorrent":{}}},"jellyfin":{}}}' ;;
        *" ps -a --format "*) printf '%s\n' 'qbittorrent|exited||Exited (0)' 'sonarr|exited||Exited (0)' 'jellyfin|running|healthy|Up' ;;
    esac
}
mkdir -p "$TMP_DIR/config/state"
export SCRIPT_DIR="$TMP_DIR" STORAGE_MODE=nas

# Given a stopped service and a stopped service that depends on it.
printf '%s\n' qbittorrent jellyfin >"$TMP_DIR/config/state/user-stopped-services"
# When container health runs.
output=$(health_containers)
# Then it identifies the user's stop and the blocked dependency.
assert_contains "$output" 'qbittorrent: stopped by you from the launcher' 'user stop has a cause'
assert_contains "$output" 'sonarr: depends on qbittorrent, stopped by you' 'blocked service identifies its dependency'
assert_not_contains "$output" 'jellyfin: stopped by you' 'running service has no stop cause'

# Given an unreadable intent file.
rm "$TMP_DIR/config/state/user-stopped-services"
ln -s missing "$TMP_DIR/config/state/user-stopped-services"
# When container health runs.
output=$(health_containers)
# Then it warns that the intent is unknown.
assert_contains "$output" 'warn|Cannot read user-stopped services' 'unreadable intent warns'
scenario_end "$CURRENT_SCENARIO"
summary
