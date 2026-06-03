# tests/scenarios/wizard-ui-stage1-smb-retry.sh — SMB port retry UX.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-smb-retry.sh"
    local steps="/tmp/wizard-stage1-smb-retry.steps.json"
    local plain_log="/tmp/wizard-stage1-smb-retry.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-smb-retry-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-smb-retry
validate_smb_port() {
    local attempts=0
    [[ -f /tmp/wizard-smb-port-attempts ]] && attempts=\$(cat /tmp/wizard-smb-port-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' "\$attempts" > /tmp/wizard-smb-port-attempts
    (( attempts >= 2 ))
}
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-smb-retry.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@smb-retry.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "1\n"},
  {"expect": "Data directory"},
  {"send": "/tmp/ms-wizard-smb-retry\n"},
  {"expect": "Enable automatic subtitle downloads with Bazarr\\?"},
  {"send": "\n"},
  {"expect": "Enable SMB file share for LAN file access\\?"},
  {"send": "y\n"},
  {"expect": "SMB needs TCP port 445\\. What should setup do\\?"},
  {"send": "1\n"},
  {"expect": "Choose SMB share scope:"},
  {"send": "1\n"},
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
  {"send": "1\n"}
]
JSON'

    wizard_stage1_run_pty "wizard-ui stage1 SMB retry" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "SMB needs TCP port 445. What should setup do?" "wizard-ui stage1 SMB retry: retry menu shown"
    assert_contains "$transcript" "Retry port check" "wizard-ui stage1 SMB retry: retry option shown"
    assert_contains "$transcript" "Disable SMB" "wizard-ui stage1 SMB retry: disable option shown"
    assert_eq "2" "$(dind_exec "cat /tmp/wizard-smb-port-attempts")" "wizard-ui stage1 SMB retry: port check retried"
    assert_eq "true" "$(env_get SMB_ENABLED)" "wizard-ui stage1 SMB retry: SMB enabled after successful retry"
    assert_eq "data" "$(env_get SMB_SHARE_SCOPE)" "wizard-ui stage1 SMB retry: data scope selected"
}
