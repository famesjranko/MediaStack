# tests/scenarios/wizard-ui-manage-updates-channel.sh — day-2 manage-updates channel switch.
#
# Sources the `mediastack` launcher (guarded main → sourcing only exposes
# helpers), stubs the registry scan + override regen, drives the manage-updates
# menu, and switches the default image channel Stable -> Upstream. Asserts the
# new channel persists to .env. (The underlying policy/scan logic is also unit-
# tested in tests/unit/manage-updates.sh; this covers the interactive menu path.)

run_scenario() {
    local fixture="/tmp/wizard-manage-updates.sh"
    local steps="/tmp/wizard-manage-updates.steps.json"
    local plain_log="/tmp/wizard-manage-updates.plain.log"

    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
sed -i 's#^IMAGE_CHANNEL=.*#IMAGE_CHANNEL=stable#' .env

# The launcher refuses to run as root (EUID guard at mediastack:24); DinD runs
# as root and the repo lives under /root, so we source a same-directory copy
# with only that guard stripped to drive the menu. SCRIPT_DIR derives from the
# copy's path, so it still resolves to the repo. The guard itself is intentional
# and unchanged in the repo.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh

_docker_reachable() { return 0; }
_update_status_scan() { printf 'jellyfin\tstable\t-\tOn tested Stable\tno\n'; }
_regenerate_override() { return 0; }
IMAGE_CHANNEL=stable

submenu_manage_updates
BASH
chmod +x $fixture"

    dind_exec 'cat >/tmp/wizard-manage-updates.steps.json <<"JSON"
[
  {"expect": "Manage updates:"},
  {"send": "5\n"},
  {"expect": "Switch default channel to Upstream tags\\?"},
  {"send": "y\n"},
  {"expect": "Press Enter to return to menu"},
  {"send": "\n"}
]
JSON'

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui manage updates channel: PTY flow exits 0"
    else
        fail "wizard-ui manage updates channel: PTY flow exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Manage updates:" "wizard-ui manage updates channel: menu shown"
    assert_contains "$transcript" "Default channel set to Upstream tags" "wizard-ui manage updates channel: switch confirmation"
    assert_eq "latest" "$(env_get IMAGE_CHANNEL)" "wizard-ui manage updates channel: IMAGE_CHANNEL flipped to latest"
}
