# tests/scenarios/wizard-ui-stage2-wireguard-containers.sh — WireGuard "Containers only" tier.
#
# Same drive as the server-tier scenario but selects the Containers-only access
# tier (MediaStack apps reachable, host services blocked). Asserts the tier is
# recorded.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-wg-containers.sh"
    local steps="/tmp/wizard-stage2-wg-containers.steps.json"
    local plain_log="/tmp/wizard-stage2-wg-containers.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage2-wg-containers.steps.json <<"JSON"
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
  {"send": "3\n"},
  {"expect": "Your upload bandwidth in Mbps"},
  {"send": "\n"},
  {"expect": "Per-viewer cap in Mbps"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 2 installation\\?"},
  {"send": "3\n"}
]
JSON'

    wizard_stage2_run_pty "wizard-ui stage2 wg containers" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Access level: Containers" "wizard-ui stage2 wg containers: containers access-level message shown"
    assert_eq "containers" "$(env_get WG_ACCESS_TIER)"  "wizard-ui stage2 wg containers: WG_ACCESS_TIER=containers"
    assert_eq "skipped"    "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 wg containers: Skip Stage 2 -> REMOTE_WEB_STATE=skipped"
}
