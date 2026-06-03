# tests/scenarios/wizard-ui-stage1-timezone.sh — Stage 1 timezone-override branch.
#
# The system screen offers Continue / Override timezone / Abort. This drives the
# middle branch: pick "Override timezone", enter a valid zone that differs from
# the detected default, and confirm it lands in .env as TZ. Closes matrix cell
# S1.0's override path (the all-defaults runs take "Continue"). The DinD image
# ships a full tzdata tree, so America/New_York validates against
# /usr/share/zoneinfo without extra setup.

source tests/lib/wizard_stage1_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage1-timezone.sh"
    local steps="/tmp/wizard-stage1-timezone.steps.json"
    local plain_log="/tmp/wizard-stage1-timezone.plain.log"

    wizard_stage1_write_base_fixture "$fixture" "wizard-tz-key"
    dind_exec "cat >>$fixture <<'BASH'
mkdir -p /tmp/ms-wizard-tz
BASH"
    wizard_stage1_append_runner "$fixture"

    dind_exec 'cat >/tmp/wizard-stage1-timezone.steps.json <<"JSON"
[
  {"expect": "Continue with these detected values\\?"},
  {"send": "2\n"},
  {"expect": "Timezone"},
  {"send": "America/New_York\n"},
  {"expect": "Admin username"},
  {"send": "\n"},
  {"expect": "Admin email"},
  {"send": "owner@stage1-tz.test\n"},
  {"expect": "Admin password"},
  {"send": "\n"},
  {"expect": "Where should MediaStack store media and downloads\\?"},
  {"send": "1\n"},
  {"expect": "Data directory"},
  {"send": "/tmp/ms-wizard-tz\n"},
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

    wizard_stage1_run_pty "wizard-ui stage1 timezone" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Override timezone" "wizard-ui stage1 timezone: override option shown"
    assert_contains "$transcript" "Timezone" "wizard-ui stage1 timezone: timezone input prompt shown"
    assert_eq "America/New_York" "$(env_get TZ)" "wizard-ui stage1 timezone: TZ override persisted to .env"
    assert_eq "1" "$(env_get STAGE_1_COMPLETE)" "wizard-ui stage1 timezone: Stage 1 completed"
}
