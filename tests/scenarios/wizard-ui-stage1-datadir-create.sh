# tests/scenarios/wizard-ui-stage1-datadir-create.sh — Stage 1 data-dir create branch.
#
# When the chosen local data directory does not yet exist, validate_data_dir
# (scripts/lib/validators.sh) prompts "Path <p> does not exist. Create it?" and
# creates it on yes. The all-defaults and options runs pre-create the directory,
# so this is the only scenario that drives the create-it confirmation. Asserts
# the directory is created, validation continues, and DATA_DIR persists.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-datadir-create.sh"
    local steps="/tmp/wizard-stage1-datadir-create.steps.json"
    local plain_log="/tmp/wizard-stage1-datadir-create.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-datadir-key"
    # Start from a guaranteed-absent path so validate_data_dir takes the
    # create-it branch (idempotent across re-runs).
    dind_exec "cat >>$fixture <<'BASH'
rm -rf /tmp/ms-wizard-newdir
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-datadir-create.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "1\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@stage1-datadir.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "1\n"},
  {"expect": "Data directory"},
  {"send": "/tmp/ms-wizard-newdir\n"},
  {"expect": "does not exist. Create it\\?"},
  {"send": "y\n"},
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

    wizard_stage1_run_pty "wizard-ui stage1 datadir create" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "does not exist. Create it?" "wizard-ui stage1 datadir create: create-it prompt shown"
    assert_eq "/tmp/ms-wizard-newdir" "$(env_get DATA_DIR)" "wizard-ui stage1 datadir create: DATA_DIR persisted"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "wizard-ui stage1 datadir create: Stage 1 completed"
    if dind_exec "test -d /tmp/ms-wizard-newdir"; then
        pass "wizard-ui stage1 datadir create: directory created on confirm"
    else
        fail "wizard-ui stage1 datadir create: directory created on confirm"
    fi
}
