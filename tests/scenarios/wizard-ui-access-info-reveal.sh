# tests/scenarios/wizard-ui-access-info-reveal.sh — day-2 "View access info" + masked reveal.
#
# Sources the `mediastack` launcher (guarded main → sourcing only exposes helpers),
# drives the post-install menu, selects the first item "View access info", and
# verifies the single shared admin password is MASKED by default and only shown
# after an explicit interactive reveal (real PTY, so the type-ahead flush + ui_confirm
# path is exercised end-to-end). Complements the hermetic unit coverage in
# tests/unit/launcher-access-info.sh.

run_scenario() {
    local fixture="/tmp/wizard-access-info.sh"
    local steps="/tmp/wizard-access-info.steps.json"
    local plain_log="/tmp/wizard-access-info.plain.log"

    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
sed -i \"s#^JELLYFIN_ADMIN_PASSWORD=.*#JELLYFIN_ADMIN_PASSWORD='REVEALME123'#\" .env

# The launcher refuses to run as root (EUID guard at mediastack:24); DinD runs as
# root and the repo lives under /root, so we source a same-directory copy with only
# that guard stripped to drive the menu. SCRIPT_DIR derives from the copy's path, so
# it still resolves to the repo. The guard itself is intentional and unchanged.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi\$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh

menu_post
BASH
chmod +x $fixture"

    dind_exec 'cat >/tmp/wizard-access-info.steps.json <<"JSON"
[
  {"expect": "What would you like to do\\?"},
  {"send": "1\n"},
  {"expect": "hidden"},
  {"expect": "Reveal the admin password\\?"},
  {"send": "y\n"},
  {"expect": "REVEALME123"},
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
        pass "wizard-ui access-info reveal: PTY flow exits 0"
    else
        fail "wizard-ui access-info reveal: PTY flow exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "View access info" "wizard-ui access-info reveal: view is the first post-install menu item"
    assert_contains "$transcript" "hidden" "wizard-ui access-info reveal: admin password masked by default"
    assert_contains "$transcript" "REVEALME123" "wizard-ui access-info reveal: password shown after explicit reveal"
}
