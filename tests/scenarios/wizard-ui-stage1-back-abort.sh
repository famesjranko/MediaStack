# tests/scenarios/wizard-ui-stage1-back-abort.sh — install confirmation back/abort safety.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-back-abort.sh"
    local steps="/tmp/wizard-stage1-back-abort.steps.json"
    local plain_log="/tmp/wizard-stage1-back-abort.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-back-abort-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-back-one /tmp/ms-wizard-back-two
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-back-abort.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@back-abort.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "1\n"},
  {"expect": "Data directory"},
  {"send": "/tmp/ms-wizard-back-one\n"},
  {"expect": "Enable automatic subtitle downloads with Bazarr\\?"},
  {"send": "\n"},
  {"expect": "Enable SMB file share for LAN file access\\?"},
  {"send": "\n"},
  {"expect": "Choose how much storage to spend per movie/show:"},
  {"send": "1\n"},
  {"expect": "Subtitle languages"},
  {"send": "\n"},
  {"expect": "Enable the example public-tracker indexer preset\\?"},
  {"send": "\n"},
  {"expect": "Choose how MediaStack should update container images:"},
  {"send": "1\n"},
  {"expect": "qBittorrent download limit"},
  {"send": "\n"},
  {"expect": "qBittorrent upload limit"},
  {"send": "\n"},
  {"expect": "qBittorrent peer port"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 1 installation\\?"},
  {"send": "2\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@back-abort.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "1\n"},
  {"expect": "Data directory"},
  {"send": "/tmp/ms-wizard-back-two\n"},
  {"expect": "Enable automatic subtitle downloads with Bazarr\\?"},
  {"send": "\n"},
  {"expect": "Enable SMB file share for LAN file access\\?"},
  {"send": "\n"},
  {"expect": "Choose how much storage to spend per movie/show:"},
  {"send": "1\n"},
  {"expect": "Subtitle languages"},
  {"send": "\n"},
  {"expect": "Enable the example public-tracker indexer preset\\?"},
  {"send": "\n"},
  {"expect": "Choose how MediaStack should update container images:"},
  {"send": "1\n"},
  {"expect": "qBittorrent download limit"},
  {"send": "\n"},
  {"expect": "qBittorrent upload limit"},
  {"send": "\n"},
  {"expect": "qBittorrent peer port"},
  {"send": "\n"},
  {"expect": "Proceed with Stage 1 installation\\?"},
  {"send": "3\n"}
]
JSON'

    wizard_stage1_run_pty "wizard-ui stage1 back abort" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Stage 1: Install Plan" "wizard-ui stage1 back abort: install plan shown"
    assert_contains "$transcript" "Setup aborted" "wizard-ui stage1 back abort: abort message shown"
    if dind_exec "test ! -f .env"; then
        pass "wizard-ui stage1 back abort: abort leaves no .env"
    else
        fail "wizard-ui stage1 back abort: abort leaves no .env"
    fi
}
