# tests/scenarios/wizard-ui-bandwidth.sh — day-2 "Adjust bandwidth limits" PTY flow.
#
# Sources the `mediastack` launcher (guarded main -> sourcing only exposes helpers),
# drives the post-install menu Features -> "Adjust bandwidth limits (qBittorrent)",
# enters new download/upload MB/s values and confirms. The live apply
# (qbt_set_speed_limits) and the Docker/qBittorrent reachability guards are stubbed
# in the fixture so the full interactive ui_input_validated + ui_confirm path runs
# end-to-end over a REAL PTY (type-ahead flush exercised) without a live qBittorrent.
# Complements the hermetic unit coverage in tests/unit/launcher-bandwidth.sh.

run_scenario() {
    local fixture="/tmp/wizard-bandwidth.sh"
    local steps="/tmp/wizard-bandwidth.steps.json"
    local plain_log="/tmp/wizard-bandwidth.plain.log"

    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack
rm -f .env
cp .env.example .env
sed -i \"s#^QBT_DL_LIMIT=.*#QBT_DL_LIMIT=3#\" .env
sed -i \"s#^QBT_UL_LIMIT=.*#QBT_UL_LIMIT=1#\" .env

# The launcher refuses to run as root (EUID guard); DinD runs as root, so source a
# same-directory copy with only that guard stripped. SCRIPT_DIR still resolves to
# the repo. The guard itself is intentional and unchanged.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi\$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh

# Stub the live edges so the guided prompt path runs without a running stack.
recovery_menu_remote_available(){ return 1; }   # fix submenu indices (no remote-add row)
_docker_reachable(){ return 0; }
_service_is_running(){ return 0; }
qbt_set_speed_limits(){ echo \"APPLIED dl=\$1 ul=\$2\"; return 0; }

menu_post
BASH
chmod +x $fixture"

    dind_exec 'cat >/tmp/wizard-bandwidth.steps.json <<"JSON"
[
  {"expect": "What would you like to do\\?"},
  {"send": "6\n"},
  {"expect": "Manage features & settings"},
  {"send": "4\n"},
  {"expect": "Current: download 3 MB/s, upload 1 MB/s"},
  {"expect": "Download limit \\(MB/s"},
  {"send": "5\n"},
  {"expect": "Upload limit \\(MB/s"},
  {"send": "2\n"},
  {"expect": "Apply download 5 MB/s / upload 2 MB/s"},
  {"send": "y\n"},
  {"expect": "APPLIED dl=5 ul=2"},
  {"expect": "completed successfully"},
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
        pass "wizard-ui bandwidth: PTY flow exits 0"
    else
        fail "wizard-ui bandwidth: PTY flow exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Adjust bandwidth limits (qBittorrent)" "wizard-ui bandwidth: option present in Features"
    assert_contains "$transcript" "Download limit (MB/s" "wizard-ui bandwidth: MB/s download prompt shown"
    assert_contains "$transcript" "APPLIED dl=5 ul=2" "wizard-ui bandwidth: applies the entered DL/UL via qbt_set_speed_limits"
    assert_contains "$transcript" "completed successfully" "wizard-ui bandwidth: success reported"

    # .env was persisted only after the (stubbed) successful apply.
    local envline
    envline="$(dind_exec "grep -E '^QBT_DL_LIMIT=' /root/MediaStack/.env")"
    assert_contains "$envline" "QBT_DL_LIMIT='5'" "wizard-ui bandwidth: .env download limit persisted on success"
}
