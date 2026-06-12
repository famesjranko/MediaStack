#!/usr/bin/env bash
# tests/unit/stage1-confirm.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-confirm"
scenario_begin "$CURRENT_SCENARIO"

SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

set +e
set +u

_WIZ_BAZARR_ENABLED="false"
_WIZ_IMAGE_CHANNEL="stable"

docker() {
    if [[ "${1:-}" == "compose" ]]; then
        case " $* " in
            *" config --services "*) printf '%s\n' jellyfin sonarr radarr jackett qbittorrent seerr homepage portainer uptime-kuma beszel; return 0 ;;
            *" config --images "*) printf '%s\n' image{1..10}; return 0 ;;
        esac
    fi
    command docker "$@"
}

CONFIRM_CAPTURE=""
CONFIRM_FILE=$(mktemp)
trap 'rm -f "$CONFIRM_FILE"' EXIT
ui_section() { :; }
ui_box() {
    printf '%s\n' "$@" > "$CONFIRM_FILE"
}

ui_choose() { echo "Install"; }

_stage1_confirm
CONFIRM_CAPTURE=$(cat "$CONFIRM_FILE")

assert_eq "Install" "$_STAGE1_CONFIRM_ACTION" "stage1-confirm: UI_DEMO chooses Install"
assert_contains "$CONFIRM_CAPTURE" "Stage 1: Install Plan" "stage1-confirm: title"
assert_contains "$CONFIRM_CAPTURE" "Image channel" "stage1-confirm: image channel shown"
assert_contains "$CONFIRM_CAPTURE" "stable" "stage1-confirm: image channel value"
assert_contains "$CONFIRM_CAPTURE" "5-7 minutes on first run" "stage1-confirm: time estimate"
assert_contains "$CONFIRM_CAPTURE" "no public access - LAN only" "stage1-confirm: LAN-only copy"

# WR-07: when 'docker compose config --services' returns nothing, the wizard
# must fail loudly with log_error + exit 1 rather than fall back to a
# hardcoded service list (the old fallback omitted unpackerr/flaresolverr
# and would have shown the user an inaccurate commitment).
docker() {
    if [[ "${1:-}" == "compose" ]]; then
        case " $* " in
            *" config --services "*) return 1 ;;
            *" config --images "*) return 1 ;;
        esac
    fi
    command docker "$@"
}
ERR_CAPTURE=""
# Recording hook for debugging; not asserted.
# shellcheck disable=SC2034
log_error() { ERR_CAPTURE="$*"; }
( _stage1_confirm ) ; rc=$?
assert_eq "1" "$rc" "stage1-confirm (WR-07): empty service enumeration exits 1"

scenario_end "$CURRENT_SCENARIO"
summary
