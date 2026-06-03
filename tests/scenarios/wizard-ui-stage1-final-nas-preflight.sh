# tests/scenarios/wizard-ui-stage1-final-nas-preflight.sh — final NAS preflight retry gate.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-final-nas-preflight.sh"
    local steps="/tmp/wizard-stage1-final-nas-preflight.steps.json"
    local plain_log="/tmp/wizard-stage1-final-nas-preflight.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-final-nas-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-final-nas
storage_preflight_nas() {
    local attempts=0
    [[ -f /tmp/wizard-final-nas-attempts ]] && attempts=\$(cat /tmp/wizard-final-nas-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' "\$attempts" > /tmp/wizard-final-nas-attempts
    (( attempts >= 2 ))
}
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-final-nas-preflight.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@final-nas.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "2\n"},
  {"expect": "Local mountpoint for NAS storage"},
  {"send": "/tmp/ms-wizard-final-nas\n"},
  {"expect": "NAS host/IP"},
  {"send": "127.0.0.1\n"},
  {"expect": "NFS export path"},
  {"send": "/exports/final\n"},
  {"expect": "NFS mount options"},
  {"send": "\n"},
  {"expect": "NAS sentinel file"},
  {"send": "\n"},
  {"expect": "NAS share is empty and ready for MediaStack\\."},
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
  {"send": "1\n"},
  {"expect": "NAS storage check failed\\. What should setup do\\?"},
  {"send": "1\n"}
]
JSON'

    wizard_stage1_run_pty "wizard-ui stage1 final NAS preflight" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS storage check failed. What should setup do?" "wizard-ui stage1 final NAS preflight: final gate shown"
    assert_contains "$transcript" "Retry NAS check" "wizard-ui stage1 final NAS preflight: retry option shown"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 final NAS preflight: edit option shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 final NAS preflight: local fallback shown"
    assert_contains "$transcript" "Advanced manual storage" "wizard-ui stage1 final NAS preflight: manual fallback shown"
    assert_contains "$transcript" "Quit installer" "wizard-ui stage1 final NAS preflight: quit option shown"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-final-nas-attempts")" "wizard-ui stage1 final NAS preflight: preflight retried once"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 final NAS preflight: NAS state preserved after retry"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 final NAS preflight: app wiring managed"
    assert_eq "/tmp/ms-wizard-final-nas" "$(env_get DATA_DIR)" "wizard-ui stage1 final NAS preflight: DATA_DIR preserved"
    assert_eq "127.0.0.1" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 final NAS preflight: NFS host preserved"
}
