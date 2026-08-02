# tests/scenarios/wizard-ui-stage2-wireguard-server.sh — WireGuard "Server only" tier.
#
# Drives to the WireGuard step, selects the Server-only access tier (no LAN CIDR
# prompt for non-full-lan tiers), then chooses "Skip Stage 2" at the confirm
# screen. Asserts the server tier is recorded and the skip path preserves it.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-wg-server.sh"
    local steps="/tmp/wizard-stage2-wg-server.steps.json"
    local plain_log="/tmp/wizard-stage2-wg-server.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    wizard_stage2_steps "$steps" \
        remote_offer 1 \
        stage2_have_domain 1 \
        stage2_hostname demo.mywire.org \
        stage2_static_ip 2 \
        stage2_wg_enable y \
        stage2_wg_port ENTER \
        stage2_vpn_level 2 \
        stage2_upload_bw ENTER \
        stage2_viewer_cap ENTER \
        stage2_proceed 3

    wizard_stage2_run_pty "wizard-ui stage2 wg server" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Access level: Server" "wizard-ui stage2 wg server: server access-level message shown"
    assert_eq "server" "$(env_get WG_ACCESS_TIER)" "wizard-ui stage2 wg server: WG_ACCESS_TIER=server"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 wg server: Skip Stage 2 -> REMOTE_WEB_STATE=skipped"
    # Regression guard: configuring WireGuard then choosing "Skip remote access"
    # at the confirm must NOT leave WG_INIT_PASSWORD set (which would silently
    # activate the wg-easy profile). The password is committed only on the install
    # path, so a skip leaves it empty.
    assert_eq "" "$(env_get WG_INIT_PASSWORD)" "wizard-ui stage2 wg server: skip leaves WG init password empty"
}
