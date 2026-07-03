# tests/scenarios/wizard-ui-stage1-nas-existing-share.sh — NAS share classification UX.

source tests/lib/wizard_stage1_common.sh

wizard_share_case_steps() {
    local path="$1"
    local mountpoint="$2"
    local extra_choice="${3:-}"

    dind_exec "cat >$path <<JSON
[
  {\"expect\": \"Continue with these detected values[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Admin username\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Admin email\"},
  {\"send\": \"owner@share.test\\n\"},
  {\"expect\": \"Admin password\"},
  {\"send\": \"WizardAdminPw123\\n\"},
  {\"expect\": \"Use these admin details\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Where should MediaStack store media and downloads[?]\"},
  {\"send\": \"2\\n\"},
  {\"expect\": \"Local mountpoint for NAS storage\"},
  {\"send\": \"$mountpoint\\n\"},
  {\"expect\": \"NAS host/IP\"},
  {\"send\": \"127.0.0.1\\n\"},
  {\"expect\": \"NFS export path\"},
  {\"send\": \"/exports/share\\n\"}$extra_choice,
  {\"expect\": \"Use the recommended NFS mount options[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Enable the NAS mount watchdog[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Lock in these storage choices[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Enable automatic subtitle downloads with Bazarr[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Use these subtitle choices[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Enable SMB file share for LAN file access[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Use these file-sharing choices[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Choose the maximum video resolution:\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Choose how much storage to spend per movie/show:\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Use these library choices[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Enable the example public-tracker indexers[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Use this indexer choice[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Which image versions should MediaStack install[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"qBittorrent download limit\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"qBittorrent upload limit\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"qBittorrent peer port\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Use these qBittorrent settings[?]\"},
  {\"send\": \"1\\n\"},
  {\"expect\": \"Set up the UFW firewall[?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Apply system hardening [(]auto security updates [+] kernel hardening[)][?]\"},
  {\"send\": \"\\n\"},
  {\"expect\": \"Proceed with Stage 1 installation[?]\"},
  {\"send\": \"1\\n\"}
]
JSON"
}

wizard_share_run_case() {
    local case_name="$1"
    local classification="$2"
    local mountpoint="$3"
    local expected_message="$4"
    local expected_data_dir="$5"
    local extra_choice="${6:-}"
    local fixture="/tmp/wizard-stage1-share-${case_name}.sh"
    local steps="/tmp/wizard-stage1-share-${case_name}.steps.json"
    local plain_log="/tmp/wizard-stage1-share-${case_name}.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-share-${case_name}-key"
    dind_exec "cat >>$fixture <<BASH
mkdir -p '$mountpoint'
storage_classify_data_root() { printf '%s\\n' '$classification'; }
BASH"
    wizard_stage1_append_runner "$fixture"
    wizard_share_case_steps "$steps" "$mountpoint" "$extra_choice"

    wizard_stage1_run_pty "wizard-ui stage1 NAS existing share ${case_name}" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "$expected_message" "wizard-ui stage1 NAS existing share ${case_name}: classification message shown"
    assert_eq "nas" "$(env_get STORAGE_MODE)" "wizard-ui stage1 NAS existing share ${case_name}: STORAGE_MODE=nas"
    assert_eq "managed" "$(env_get STORAGE_APP_WIRING)" "wizard-ui stage1 NAS existing share ${case_name}: app wiring managed"
    assert_eq "$expected_data_dir" "$(env_get DATA_DIR)" "wizard-ui stage1 NAS existing share ${case_name}: DATA_DIR"
}

run_scenario() {
    wizard_share_run_case \
        "empty" \
        "empty" \
        "/tmp/ms-wizard-share-empty" \
        "NAS share is empty and ready for MediaStack." \
        "/tmp/ms-wizard-share-empty" || return 1

    wizard_share_run_case \
        "mediastack" \
        "mediastack" \
        "/tmp/ms-wizard-share-mediastack" \
        "NAS share already has a MediaStack-style media/torrents layout." \
        "/tmp/ms-wizard-share-mediastack" || return 1

    wizard_share_run_case \
        "conflict" \
        "conflict:media" \
        "/tmp/ms-wizard-share-conflict" \
        "NAS share has a blocking conflict at media." \
        "/tmp/ms-wizard-share-conflict/mediastack" \
        ',
  {"expect": "How should MediaStack handle this NAS share[?]"},
  {"send": "1\n"},
  {"expect": "MediaStack will use NAS subfolder: /tmp/ms-wizard-share-conflict/mediastack"}' || return 1

    assert_eq "/tmp/ms-wizard-share-conflict/mediastack/.mediastack-storage-ready" \
        "$(env_get STORAGE_SENTINEL)" \
        "wizard-ui stage1 NAS existing share conflict: sentinel follows safe subfolder"
}
