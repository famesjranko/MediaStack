# tests/scenarios/wizard-ui-stage2-wireguard-containers.sh — WireGuard "Containers only" tier.
#
# Same drive as the server-tier scenario but selects the Containers-only access
# tier (MediaStack apps reachable, host services blocked). Asserts the tier is
# recorded.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-wg-containers.sh"
    local steps="/tmp/wizard-stage2-wg-containers.steps.json"
    local plain_log="/tmp/wizard-stage2-wg-containers.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    wizard_stage2_steps "$steps" \
        remote_offer 1 \
        stage2_have_domain 1 \
        stage2_hostname demo.mywire.org \
        stage2_static_ip 2 \
        stage2_wg_enable y \
        stage2_wg_port ENTER \
        stage2_vpn_level 3 \
        stage2_upload_bw ENTER \
        stage2_viewer_cap ENTER \
        stage2_proceed 3

    wizard_stage2_run_pty "wizard-ui stage2 wg containers" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Access level: Containers" "wizard-ui stage2 wg containers: containers access-level message shown"
    assert_eq "containers" "$(env_get WG_ACCESS_TIER)"  "wizard-ui stage2 wg containers: WG_ACCESS_TIER=containers"
    assert_eq "skipped"    "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 wg containers: Skip Stage 2 -> REMOTE_WEB_STATE=skipped"
}
