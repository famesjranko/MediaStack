#!/usr/bin/env bash
# tests/unit/launcher-access-info.sh
#
# Launcher coverage for the day-2 "View access info" surface.
# Asserts the post-install menu exposes the view as its first item, that the
# handler lazily sources stack.sh and renders print_access_info, and that the
# new WireGuard admin line is gated on WG_INIT_PASSWORD alone (shows even when
# no domain is configured — the LAN-only WireGuard case).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="launcher-access-info"
echo -e "${CYAN}${BOLD}▶ scenario: launcher-access-info${NC}"

# --- (a) menu wiring: the view is present AND is the first post-install item ---
menu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  LABELS=$(mktemp)
  ui_choose(){ shift; printf "%s\n" "$@" > "$LABELS"; echo "Noop"; }
  recovery_menu_remote_available(){ return 1; }
  recovery_menu_transcoding_available(){ return 1; }
  pause_for_menu(){ :; }
  STAGE_1_COMPLETE=1
  menu_post >/dev/null 2>&1
  head -n1 "$LABELS"
  rm -f "$LABELS"
' 2>&1)
assert_eq "View access info (URLs, logins, remote, ports)" "$menu_out" \
    "launcher: access-info is the FIRST post-install menu item"

# --- (b) integration: handler lazily sources stack.sh and renders the summary ---
# Runs action_access_info for real, so it sources scripts/setup/stack.sh and calls
# print_access_info. "MediaStack is running!" / "PORT FORWARDING" are static banner
# lines printed regardless of whether a .env exists, so this is robust on a clean
# checkout (.env is gitignored). print_access_info only reads .env, never writes it.
access_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  action_access_info
' 2>&1)
assert_contains "$access_out" "MediaStack is running!" \
    "launcher: action_access_info lazily sources stack.sh and renders the access summary"
assert_contains "$access_out" "PORT FORWARDING" \
    "launcher: access summary includes the router port-forward block"

# --- (c) WireGuard admin line gated on WG_INIT_PASSWORD alone, not on a domain ---
# Hermetic: SCRIPT_DIR points at a temp fixture dir so the real repo .env is never
# touched. print_access_info greps $SCRIPT_DIR/.env for WG_INIT_PASSWORD.
render_access_info() {
    # $1 = fixture dir containing .env; $2 = optional print_access_info mode (e.g. "mask")
    REPO_ROOT="$REPO_ROOT" FIXTURE_DIR="$1" PAI_MODE="${2:-}" bash -c '
      set -uo pipefail
      SCRIPT_DIR="$FIXTURE_DIR"
      source "$REPO_ROOT/scripts/lib/common.sh"
      source "$REPO_ROOT/scripts/setup/stack.sh"
      print_access_info $PAI_MODE
    ' 2>&1
}

# WG configured WITHOUT a domain → the wg-easy admin URL must still appear.
wg_nodomain_dir=$(mktemp -d)
printf "%s\n" "WG_INIT_PASSWORD='secret'" >"$wg_nodomain_dir/.env"
wg_nodomain_out=$(render_access_info "$wg_nodomain_dir")
rm -rf "$wg_nodomain_dir"
assert_contains "$wg_nodomain_out" ":51821" \
    "access summary: WireGuard admin URL shows for LAN-only WG (no domain)"

# WG configured WITH a domain → also appears.
wg_domain_dir=$(mktemp -d)
printf "%s\n" "WG_INIT_PASSWORD='secret'" "DOMAIN=example.org" >"$wg_domain_dir/.env"
wg_domain_out=$(render_access_info "$wg_domain_dir")
rm -rf "$wg_domain_dir"
assert_contains "$wg_domain_out" ":51821" \
    "access summary: WireGuard admin URL shows when WG + domain are configured"

# No WG password → no wg-easy admin URL (domain set, to prove it's the WG gate,
# not has_domain, that drives the line).
nowg_dir=$(mktemp -d)
printf "%s\n" "DOMAIN=example.org" >"$nowg_dir/.env"
nowg_out=$(render_access_info "$nowg_dir")
rm -rf "$nowg_dir"
case "$nowg_out" in
    *":51821"*) fail "access summary: no WireGuard admin URL when WG is not configured" \
        "':51821' unexpectedly present" ;;
    *) pass "access summary: no WireGuard admin URL when WG is not configured" ;;
esac

# --- (d) admin password: shown once at install, masked in the re-openable day-2 view ---
# Hermetic fixture with a known password. The install summary (no arg) must show the
# value so the user can save it; the day-2 view (mask) must NOT print it.
pw_dir=$(mktemp -d)
printf "%s\n" "JELLYFIN_ADMIN_PASSWORD='S3cr3tPw123'" "DOMAIN=example.org" >"$pw_dir/.env"
install_render=$(render_access_info "$pw_dir")
masked_render=$(render_access_info "$pw_dir" mask)
rm -rf "$pw_dir"

assert_contains "$install_render" "S3cr3tPw123" \
    "access summary: install view (no arg) shows the admin password so it can be saved"
assert_contains "$install_render" "(admin password above)" \
    "access summary: install view points service logins at the admin password shown above"
assert_contains "$masked_render" "(hidden" \
    "access summary: day-2 masked view shows a hidden placeholder for the admin password"
case "$masked_render" in
    *S3cr3tPw123*) fail "AUDIT: day-2 masked view does not leak the admin password value" \
        "cleartext password present under mask" ;;
    *) pass "AUDIT: day-2 masked view does not leak the admin password value" ;;
esac
# The masked view has no value on screen to point "above" at, so its login hint is the
# mode-aware variant. Asserting it proves the rows carry the pointer (not a leaked value).
assert_contains "$masked_render" "(your admin password)" \
    "access summary: day-2 masked view points service logins at the admin password (mode-aware hint)"

# --- (f) localhost LAN-IP fallback caveat ---
# When LAN-IP detection fails (hostname -I empty AND no HOST_ADDRESS), print_access_info
# falls back to http://localhost URLs. Those only work ON the box, so the summary must
# carry a caveat. Force the fallback by stubbing hostname to emit nothing, and prove the
# caveat is present. Then prove it does NOT fire when a real IP resolves.
render_access_info_nohost() {
    # $1 = fixture dir containing .env. Stubs hostname so 'hostname -I' yields nothing,
    # forcing the localhost fallback regardless of the test host's real address.
    REPO_ROOT="$REPO_ROOT" FIXTURE_DIR="$1" bash -c '
      set -uo pipefail
      SCRIPT_DIR="$FIXTURE_DIR"
      hostname(){ return 0; }   # '\''hostname -I'\'' prints nothing -> lan_ip falls back
      source "$REPO_ROOT/scripts/lib/common.sh"
      source "$REPO_ROOT/scripts/setup/stack.sh"
      # Real callers source .env before print_access_info, so HOST_ADDRESS is in scope
      # for the loopback fallback. Mirror that here.
      set -a; source "$FIXTURE_DIR/.env"; set +a
      print_access_info
    ' 2>&1
}

# Fallback case: no HOST_ADDRESS in .env -> localhost -> caveat must appear.
nohost_dir=$(mktemp -d)
printf "%s\n" "DOMAIN=example.org" >"$nohost_dir/.env"
nohost_out=$(render_access_info_nohost "$nohost_dir")
rm -rf "$nohost_dir"
assert_contains "$nohost_out" "LAN IP not detected" \
    "access summary: localhost fallback prints a caveat that the URLs are local-only"
assert_contains "$nohost_out" "http://localhost:8096" \
    "access summary: localhost fallback still renders the service URLs (caveat does not change them)"

# HOST_ADDRESS set in .env -> print_access_info honours it instead of localhost -> no caveat.
hostaddr_dir=$(mktemp -d)
printf "%s\n" "DOMAIN=example.org" "HOST_ADDRESS=192.168.1.50" >"$hostaddr_dir/.env"
hostaddr_out=$(render_access_info_nohost "$hostaddr_dir")
rm -rf "$hostaddr_dir"
assert_contains "$hostaddr_out" "http://192.168.1.50:8096" \
    "access summary: HOST_ADDRESS from .env is used as the LAN-IP fallback before localhost"
case "$hostaddr_out" in
    *"LAN IP not detected"*) fail "access summary: no localhost caveat when HOST_ADDRESS resolves a real IP" \
        "caveat fired despite a routable HOST_ADDRESS" ;;
    *) pass "access summary: no localhost caveat when HOST_ADDRESS resolves a real IP" ;;
esac

# --- (e) launcher reveal gating: value appears only on explicit opt-in ---
# Pre-source stack.sh so the source guard in action_access_info is a no-op and our
# stubs survive; drive the reveal both ways. _access_admin_pw is the single source of
# truth, stubbed here to a sentinel so no real .env is needed.
reveal_yes=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/stack.sh"
  _access_admin_pw(){ echo "REVEALED_TEST_PW"; }
  ui_confirm(){ return 0; }   # user opts in
  action_access_info </dev/null
' 2>&1)
assert_contains "$reveal_yes" "REVEALED_TEST_PW" \
    "launcher reveal: confirming shows the admin password"

reveal_no=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  source "$REPO_ROOT/scripts/setup/stack.sh"
  _access_admin_pw(){ echo "REVEALED_TEST_PW"; }
  ui_confirm(){ return 1; }   # user declines (also the deterministic non-TTY default)
  action_access_info </dev/null
' 2>&1)
case "$reveal_no" in
    *REVEALED_TEST_PW*) fail "AUDIT: launcher reveal stays masked unless explicitly confirmed" \
        "password shown without opt-in" ;;
    *) pass "AUDIT: launcher reveal stays masked unless explicitly confirmed" ;;
esac

echo -e "${CYAN}◀ launcher-access-info done${NC}"
summary
