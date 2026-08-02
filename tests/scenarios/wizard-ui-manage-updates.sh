# tests/scenarios/wizard-ui-manage-updates.sh — day-2 Manage-Updates menu smoke.
#
# Sources the `mediastack` launcher (guarded main → sourcing only exposes
# helpers), stubs the registry scan + docker reachability, drives the
# manage-updates menu through a re-check and out via Back. Asserts the
# channel-agnostic 2-state table renders (Pinned / Tracking tag, Up to date /
# Update available) and that the collapsed menu no longer offers the removed
# "Switch default channel" / "Pull tested Stable updates" items. This is the only
# end-to-end coverage of submenu_manage_updates — it also exercises the
# launcher-scope `source override.sh` the apply/flip helpers depend on. (The
# underlying policy/apply/flip logic is unit-tested in tests/unit/manage-updates.sh.)

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
# copy's path, so it still resolves to the repo (and the in-menu
# 'source override.sh' backend load). The guard itself is intentional and
# unchanged in the repo.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh

_docker_reachable() { return 0; }
# Rows exercise both status colours, the manual-override footnote, and a
# digest-pinned (reverted) service — POLICY token 'pinned' → 'Pinned (install)'.
_update_status_scan() {
  printf 'jellyfin\tstable\tdefault\tUp to date\tfalse\nsonarr\tlatest\tmanual\tUpdate available\ttrue\nradarr\tpinned\tmanual\tUpdate available\ttrue\n'
}
IMAGE_CHANNEL=stable

submenu_manage_updates
BASH
chmod +x $fixture"

    dind_exec 'cat >/tmp/wizard-manage-updates.steps.json <<"JSON"
[
  {"expect": "Manage updates:"},
  {"send": "4\n"},
  {"expect": "Manage updates:"},
  {"send": "5\n"}
]
JSON'

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui manage updates: PTY flow exits 0"
    else
        fail "wizard-ui manage updates: PTY flow exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Manage updates:" "wizard-ui manage updates: menu shown"
    assert_contains "$transcript" "Install channel" "wizard-ui manage updates: banner uses install-channel framing"
    assert_contains "$transcript" "Pinned" "wizard-ui manage updates: Pinned policy label rendered"
    assert_contains "$transcript" "Tracking tag" "wizard-ui manage updates: Tracking-tag policy label rendered"
    assert_contains "$transcript" "Update available" "wizard-ui manage updates: 2-state status rendered"
    assert_contains "$transcript" "Revert a service to its installed image" "wizard-ui manage updates: revert item present"
    assert_contains "$transcript" "Pinned (install)" "wizard-ui manage updates: a reverted (pinned) service reads 'Pinned (install)'"
    if grep -q "Switch default channel\|Pull tested Stable" <<<"$transcript"; then
        fail "wizard-ui manage updates: removed channel/pull-tested items absent"
    else
        pass "wizard-ui manage updates: removed channel/pull-tested items absent"
    fi
}
