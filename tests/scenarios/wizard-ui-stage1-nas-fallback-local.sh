# tests/scenarios/wizard-ui-stage1-nas-fallback-local.sh — NAS failure to local storage.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-nas-fallback-local.sh"
    local steps="/tmp/wizard-stage1-nas-fallback-local.steps.json"
    local plain_log="/tmp/wizard-stage1-nas-fallback-local.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-nas-local-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-nas-local
storage_mount_nfs() { return 1; }
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-nas-fallback-local.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@fallback-local.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "2\n"},
  {"expect": "Local mountpoint for NAS storage"},
  {"send": "/tmp/ms-wizard-nas-local\n"},
  {"expect": "NAS host/IP"},
  {"send": "127.0.0.1\n"},
  {"expect": "NFS export path"},
  {"send": "/exports/bad\n"},
  {"expect": "NFS mount options"},
  {"send": "\n"},
  {"expect": "NAS sentinel file"},
  {"send": "\n"},
  {"expect": "NAS mount failed\\. What should setup do\\?"},
  {"send": "3\n"},
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

    wizard_stage1_run_pty "wizard-ui stage1 NAS fallback local" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "NAS mount failed. What should setup do?" "wizard-ui stage1 NAS fallback local: failure menu shown"
    assert_contains "$transcript" "Use local storage instead" "wizard-ui stage1 NAS fallback local: local fallback option shown"
    assert_contains "$transcript" "local at /data" "wizard-ui stage1 NAS fallback local: plan summarizes local fallback"

    assert_eq "local" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS fallback local: STORAGE_MODE=local"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS fallback local: app wiring managed"
    assert_eq "/data" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS fallback local: DATA_DIR reset to local default"
    assert_eq "" "$(env_get STORAGE_NFS_HOST)" "wizard-ui stage1 NAS fallback local: NFS host cleared"
    assert_eq "" "$(env_get STORAGE_NFS_EXPORT)" "wizard-ui stage1 NAS fallback local: NFS export cleared"
    assert_eq "/data/.mediastack-storage-ready" "$(env_get STORAGE_SENTINEL)" "wizard-ui stage1 NAS fallback local: local sentinel set"
}
