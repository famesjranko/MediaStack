# tests/scenarios/wizard-ui-stage2-install-ready.sh — Stage 2 full happy path.
#
# Drives the complete remote-access flow: offer -> have-a-domain -> Dynu DDNS
# (preflight stubbed OK) -> DNS OK -> ports OK -> WireGuard (Full LAN tier) ->
# Jellyfin remote bitrate -> Install, with the Let's Encrypt classification
# stubbed to "ready". Asserts the collected remote state lands in .env and the
# gate reports success. All network/NPM/LE/stack operations are stubbed.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-install-ready.sh"
    local steps="/tmp/wizard-stage2-install-ready.steps.json"
    local plain_log="/tmp/wizard-stage2-install-ready.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage2-install-ready.steps.json <<"JSON"
[
  {"expect": "Set up remote access now\\?"},
  {"send": "1\n"},
  {"expect": "Do you already have a domain name"},
  {"send": "1\n"},
  {"expect": "Your hostname \\(e.g. yourname.mywire.org\\)"},
  {"send": "demo.mywire.org\n"},
  {"expect": "Use Dynu DDNS for this domain\\?"},
  {"send": "y\n"},
  {"expect": "Dynu account username"},
  {"send": "dynuuser\n"},
  {"expect": "Dynu account password"},
  {"send": "dynupass123\n"},
  {"expect": "WireGuard UDP port"},
  {"send": "\n"},
  {"expect": "VPN access level for your admin device"},
  {"send": "1\n"},
  {"expect": "Home LAN CIDR"},
  {"send": "\n"},
  {"expect": "Your upload bandwidth in Mbps"},
  {"send": "\n"},
  {"expect": "Per-viewer cap in Mbps"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 2 installation\\?"},
  {"send": "1\n"}
]
JSON'

    wizard_stage2_run_pty "wizard-ui stage2 install ready" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Verified against Dynu's API" "wizard-ui stage2 install ready: Dynu preflight ok message"
    assert_contains "$transcript" "Stage 2: Install Plan" "wizard-ui stage2 install ready: install plan box shown"
    assert_contains "$transcript" "Remote access is ready" "wizard-ui stage2 install ready: LE-ready success message"

    assert_eq "ready"   "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 install ready: REMOTE_WEB_STATE=ready"
    assert_eq "demo.mywire.org" "$(env_get DOMAIN)"   "wizard-ui stage2 install ready: DOMAIN persisted"
    assert_eq "demo.mywire.org" "$(env_get WG_HOST)"  "wizard-ui stage2 install ready: WG_HOST follows domain"
    assert_eq "dynuuser" "$(env_get DDNS_USERNAME)"         "wizard-ui stage2 install ready: Dynu username persisted"
    assert_eq "full-lan" "$(env_get WG_ACCESS_TIER)"        "wizard-ui stage2 install ready: WG full-lan tier"
    assert_eq "51820"    "$(env_get WG_PORT)"               "wizard-ui stage2 install ready: WG port default"
}
