# tests/scenarios/wizard-ui-stage2-port-gate-skip.sh — router-port gate failure -> skip.
#
# Forces the TCP 80/443 reachability probe to fail (closed) so the port gate
# exhausts its auto-retries, classifies the failure, and presents the manual
# menu. The user picks "Skip HTTPS for now"; we assert the LAN-safe skip state.
# stage2_classify_port_failure is stubbed to a fixed class so the warning copy
# is deterministic and no external probe service is contacted.

source tests/lib/wizard-stage2-common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-port-gate-skip.sh"
    local steps="/tmp/wizard-stage2-port-gate-skip.steps.json"
    local plain_log="/tmp/wizard-stage2-port-gate-skip.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'BASH'
stage2_check_http_ports() { printf 'closed:80,443\n'; }
stage2_classify_port_failure() { printf 'carrier-block\n'; }
BASH"
    wizard_stage2_append_runner "$fixture"

    wizard_stage2_steps "$steps" \
        remote_offer 1 \
        stage2_have_domain 1 \
        stage2_hostname demo.mywire.org \
        stage2_static_ip 2 \
        stage2_router_forwarding@30 3

    wizard_stage2_run_pty "wizard-ui stage2 port gate skip" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Fix the router forwarding, then choose:" "wizard-ui stage2 port gate skip: failure menu shown"
    assert_contains "$transcript" "blocking TCP 80 or 443" "wizard-ui stage2 port gate skip: carrier-block warning shown"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 port gate skip: REMOTE_WEB_STATE=skipped"
}
