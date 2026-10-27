#!/usr/bin/env bash
# tests/unit/launcher-features-wireguard.sh
#
# Launcher coverage for the Features & settings "Add WireGuard VPN" action:
# it shows only when HTTPS remote access is ready and WireGuard is absent, and
# it hands off to `setup.sh --wireguard`. The existing "Add remote access" row
# keeps its own rule.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="launcher-features-wireguard"
scenario_begin "$CURRENT_SCENARIO"

# Prints the Features & settings labels, "|"-joined, for the given state.
# The real recovery predicates run; only the menu chrome is stubbed.
features_labels() {
    local remote_state="$1" wg_password="$2"
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" REMOTE_STATE="$remote_state" WG_PW="$wg_password" bash -c '
      source "$REPO_ROOT/mediastack" </dev/null
      LABELS=$(mktemp)
      render_banner(){ :; }
      ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Back"; }
      recovery_menu_transcoding_available(){ return 1; }
      REMOTE_WEB_STATE=$REMOTE_STATE; WG_INIT_PASSWORD=$WG_PW
      submenu_features >/dev/null 2>&1
      tr "\n" "|" < "$LABELS"; rm -f "$LABELS"
    ' 2>&1
}

# Given HTTPS is ready and WireGuard is not configured
# When the Features & settings menu renders
# Then it offers Add WireGuard VPN and no Add remote access
out=$(features_labels ready "")
assert_contains "$out" "Add WireGuard VPN|" "ready, no WireGuard: Add WireGuard VPN is offered"
assert_not_contains "$out" "Add remote access" "ready, no WireGuard: Add remote access stays hidden"

# Given HTTPS is ready and WireGuard is configured
# When the Features & settings menu renders
# Then Add WireGuard VPN is hidden
out=$(features_labels ready "S3cret")
assert_not_contains "$out" "Add WireGuard" "ready with WireGuard: Add WireGuard VPN is hidden"

# Given remote access is not ready, in each state the menu treats as not ready
# When the Features & settings menu renders
# Then Add WireGuard VPN is hidden and Add remote access is offered as before
for state in unchecked skipped failed; do
    out=$(features_labels "$state" "")
    assert_not_contains "$out" "Add WireGuard" "remote $state: Add WireGuard VPN is hidden"
    assert_contains "$out" "Add remote access (HTTPS, domain, WireGuard)|" "remote $state: Add remote access keeps its row"
done

# Given the menu offers Add WireGuard VPN
# When the user picks it
# Then the launcher runs setup.sh --wireguard through the shared setup runner
dispatch_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  picked=$(mktemp -u)
  render_banner(){ :; }
  # ui_choose runs in a command substitution, so the "already picked" flag lives in a file.
  ui_choose(){ if [[ -e "$picked" ]]; then echo "Back"; else : > "$picked"; echo "Add WireGuard VPN"; fi; }
  _run_setup_return(){ echo "RUN_SETUP:$*"; }
  recovery_menu_transcoding_available(){ return 1; }
  REMOTE_WEB_STATE=ready; WG_INIT_PASSWORD=""
  submenu_features 2>&1 | grep RUN_SETUP; rm -f "$picked"
')
assert_eq "RUN_SETUP:0 Add WireGuard VPN --wireguard" "$dispatch_out" "choosing Add WireGuard VPN runs setup.sh --wireguard"

scenario_end "$CURRENT_SCENARIO"
summary
