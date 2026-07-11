# tests/scenarios/wizard-ui-uninstall.sh — real launcher uninstall PTY flow.

run_scenario() {
    local fixture_dir="/tmp/wizard-uninstall-fixture"
    local fixture="$fixture_dir/mediastack"
    local steps="/tmp/wizard-uninstall.steps.json"
    local plain_log="/tmp/wizard-uninstall.plain.log"

    dind_exec "rm -rf $fixture_dir && mkdir -p $fixture_dir/state
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi$/d' mediastack > $fixture
chmod +x $fixture
ln -s /root/MediaStack/scripts $fixture_dir/scripts
cp .env.example $fixture_dir/.env
sed -i 's#^STAGE_1_COMPLETE=.*#STAGE_1_COMPLETE=1#' $fixture_dir/.env
cat >$fixture_dir/setup.sh <<'BASH'
#!/usr/bin/env bash
source /root/MediaStack/setup.sh
SCRIPT_DIR=/tmp/wizard-uninstall-fixture
MEDIASTACK_STATE_DIR=\$SCRIPT_DIR/state
MEDIASTACK_STATE_FILE=\$MEDIASTACK_STATE_DIR/install-state
check_not_root() { :; }
check_debian() { :; }
prompt_sudo_cache() { :; }
validate_install_state() { return 0; }
storage_pause_watchdog_for_install() { return 0; }
uninstall_system_cleanup() { log_ok 'MediaStack system artefacts removed'; }
sudo() {
    if [[ \$1 == systemctl ]]; then return 1; fi
    "\$@" 2>/dev/null || true
}
docker() {
    echo DOCKER_STUB >&2
    return 0
}
main "\$@"
BASH
chmod +x $fixture_dir/setup.sh"

    dind_exec 'cat >/tmp/wizard-uninstall.steps.json <<"JSON"
[
  {"expect": "What would you like to do\\?"},
  {"send": "11\n"},
  {"expect": "This will DELETE"},
  {"expect": "Type DESTROY to confirm"},
  {"send": "DESTROY\n"},
  {"expect": "Uninstall completed successfully"},
  {"expect": "Press Enter"},
  {"send": "\n"},
  {"expect": "What would you like to do\\?"},
  {"send": "6\n"}
]
JSON'

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui uninstall: real launcher action exits 0"
    else
        fail "wizard-ui uninstall: real launcher action exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "This will DELETE" "wizard-ui uninstall: DELETE preview shown"
    assert_contains "$transcript" "Type DESTROY to confirm" "wizard-ui uninstall: DESTROY prompt shown"
    assert_contains "$transcript" "Uninstall completed successfully" "wizard-ui uninstall: real result plumbing reports success"
    assert_contains "$transcript" "MediaStack-owned UFW rules" "wizard-ui uninstall: selective UFW cleanup previewed"

    if dind_exec "test -f $fixture_dir/.env"; then
        fail "wizard-ui uninstall: .env removed after completed cleanup"
    else
        pass "wizard-ui uninstall: .env removed after completed cleanup"
    fi
}
