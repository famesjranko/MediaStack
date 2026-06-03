# tests/scenarios/wizard-ui-stage2-wireguard-server.sh — WireGuard "Server only" tier.
#
# Drives to the WireGuard step, selects the Server-only access tier (no LAN CIDR
# prompt for non-full-lan tiers), then chooses "Skip Stage 2" at the confirm
# screen. Asserts the server tier is recorded and the skip path preserves it.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-wg-server.sh"
    local steps="/tmp/wizard-stage2-wg-server.steps.json"
    local plain_log="/tmp/wizard-stage2-wg-server.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage2-wg-server.steps.json <<"JSON"
[
  {"expect": "Set up remote access now\\?"},
  {"send": "1\n"},
  {"expect": "Do you already have a domain name"},
  {"send": "1\n"},
  {"expect": "Your hostname \\(e.g. yourname.mywire.org\\)"},
  {"send": "demo.mywire.org\n"},
  {"expect": "Use Dynu DDNS for this domain\\?"},
  {"send": "n\n"},
  {"expect": "WireGuard UDP port"},
  {"send": "\n"},
  {"expect": "VPN access level for your admin device"},
  {"send": "2\n"},
  {"expect": "Your upload bandwidth in Mbps"},
  {"send": "\n"},
  {"expect": "Per-viewer cap in Mbps"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 2 installation\\?"},
  {"send": "3\n"}
]
JSON'

    wizard_stage2_run_pty "wizard-ui stage2 wg server" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Access level: Server" "wizard-ui stage2 wg server: server access-level message shown"
    assert_eq "server"  "$(env_get WG_ACCESS_TIER)"  "wizard-ui stage2 wg server: WG_ACCESS_TIER=server"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 wg server: Skip Stage 2 -> REMOTE_WEB_STATE=skipped"
}
