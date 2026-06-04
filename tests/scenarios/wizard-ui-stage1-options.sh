# tests/scenarios/wizard-ui-stage1-options.sh — Stage 1 non-default toggle coverage.
#
# Drives a local-storage Stage 1 run that flips every Stage-1 toggle to its
# non-default branch in a single PTY flow: Bazarr enabled, SMB enabled with
# the "Full system" scope, the Quality (largest) preset, custom subtitle
# languages, the public-indexer preset enabled, and the Latest image channel.
# Asserts each choice lands in .env. Complements wizard-ui-stage1-local.sh,
# which exercises the all-defaults path. The timezone-override and data-dir
# create-it branches are covered by their own scenarios
# (wizard-ui-stage1-timezone.sh, wizard-ui-stage1-datadir-create.sh).

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-options.sh"
    local steps="/tmp/wizard-stage1-options.steps.json"
    local plain_log="/tmp/wizard-stage1-options.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-options-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-options
BASH"
    wizard_stage1_append_runner "$fixture"

    wizard_stage1_steps "$steps" \
        stage1_continue_detected 1 \
        stage1_admin_username ENTER \
        stage1_admin_email owner@stage1-options.test \
        stage1_admin_password ENTER \
        stage1_storage_location 1 \
        stage1_data_directory /tmp/ms-wizard-options \
        stage1_bazarr y \
        stage1_smb y \
        stage1_smb_scope 2 \
        stage1_quality 3 \
        stage1_subtitle_langs english,spanish,french \
        stage1_indexers y \
        stage1_image_channel 2 \
        stage1_qbt_download ENTER \
        stage1_qbt_upload ENTER \
        stage1_qbt_port ENTER \
        stage1_proceed 1

    wizard_stage1_run_pty "wizard-ui stage1 options" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Choose SMB share scope:" "wizard-ui stage1 options: SMB scope menu shown"
    assert_contains "$transcript" "Full system" "wizard-ui stage1 options: full-system scope option shown"
    assert_contains "$transcript" "Choose how MediaStack should update container images:" "wizard-ui stage1 options: image channel menu shown"

    assert_eq "true"   "$(env_get BAZARR_ENABLED)"          "wizard-ui stage1 options: Bazarr enabled"
    assert_eq "true"   "$(env_get SMB_ENABLED)"             "wizard-ui stage1 options: SMB enabled"
    assert_eq "system" "$(env_get SMB_SHARE_SCOPE)"         "wizard-ui stage1 options: SMB system scope"
    assert_eq "latest" "$(env_get IMAGE_CHANNEL)"           "wizard-ui stage1 options: Latest image channel"
    assert_eq "true"   "$(env_get PUBLIC_INDEXERS_ENABLED)" "wizard-ui stage1 options: public indexers enabled"
    assert_eq "local"  "$(env_get STORAGE_MODE)"            "wizard-ui stage1 options: local storage mode"
    assert_eq "/tmp/ms-wizard-options" "$(env_get DATA_DIR)" "wizard-ui stage1 options: data dir from prompt"
    assert_eq "1"      "$(env_get STAGE_1_COMPLETE)"        "wizard-ui stage1 options: Stage 1 completed"

    # Quality-tier propagation: selecting the Quality preset (option 3) must
    # rewrite config.yml's quality_profile via wizard_apply.py. HQ-1080p is the
    # Quality tier's profile_name (presets.yml), distinct from the repo default
    # HD-720p/1080p, so this proves the write happened rather than matching the
    # shipped value.
    local quality_section
    quality_section="$(dind_exec "grep -A2 '^quality_profile:' config.yml")"
    assert_contains "$quality_section" "HQ-1080p" "wizard-ui stage1 options: Quality preset propagated to config.yml"
}
