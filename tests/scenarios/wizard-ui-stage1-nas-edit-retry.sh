# tests/scenarios/wizard-ui-stage1-nas-edit-retry.sh — edit NAS settings after mount failure.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-nas-edit-retry.sh"
    local steps="/tmp/wizard-stage1-nas-edit-retry.steps.json"
    local plain_log="/tmp/wizard-stage1-nas-edit-retry.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-nas-edit-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-nas-edit
storage_mount_nfs() {
    local attempts=0
    [[ -f /tmp/wizard-nas-edit-attempts ]] && attempts=\$(cat /tmp/wizard-nas-edit-attempts)
    attempts=\$((attempts + 1))
    printf '%s\n' "\$attempts" > /tmp/wizard-nas-edit-attempts
    [[ "\${STORAGE_NFS_HOST:-}" == "127.0.0.2" ]]
}
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-nas-edit-retry.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@edit-retry.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "2\n"},
  {"expect": "Local mountpoint for NAS storage"},
  {"send": "/tmp/ms-wizard-nas-edit\n"},
  {"expect": "NAS host/IP"},
  {"send": "127.0.0.1\n"},
  {"expect": "NFS export path"},
  {"send": "/exports/bad\n"},
  {"expect": "NFS mount options"},
  {"send": "\n"},
  {"expect": "NAS sentinel file"},
  {"send": "\n"},
  {"expect": "NAS mount failed\\. What should setup do\\?"},
  {"send": "1\n"},
  {"expect": "Local mountpoint for NAS storage"},
  {"send": "/tmp/ms-wizard-nas-edit\n"},
  {"expect": "NAS host/IP"},
  {"send": "127.0.0.2\n"},
  {"expect": "NFS export path"},
  {"send": "/exports/good\n"},
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
  {"send": "1\n"}
]
JSON'

    wizard_stage1_run_pty "wizard-ui stage1 NAS edit retry" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Edit NAS settings and retry" "wizard-ui stage1 NAS edit retry: edit option shown"
    assert_contains "$transcript" "nas at /tmp/ms-wizard-nas-edit" "wizard-ui stage1 NAS edit retry: plan summarizes NAS storage"

    assert_eq "2" "$(dind_exec "cat /tmp/wizard-nas-edit-attempts")" "wizard-ui stage1 NAS edit retry: mount attempted before and after edit"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS edit retry: STORAGE_MODE=nas"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS edit retry: app wiring managed"
    assert_eq "127.0.0.2" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS edit retry: corrected host persisted"
    assert_eq "/exports/good" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS edit retry: corrected export persisted"
    assert_eq "/tmp/ms-wizard-nas-edit/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS edit retry: sentinel follows mountpoint"
}
