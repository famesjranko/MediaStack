# tests/scenarios/wizard-ui-stage2-le-skip.sh — Let's Encrypt gate failure -> skip.
#
# Drives the full install path but forces the post-install LE classification to
# "config-dns" (a non-ready outcome). The gate then offers the manual menu; the
# user picks "Skip HTTPS for now". Asserts the gate copy and the LAN-safe skip
# state. Exercises stage2_le_gate's failure branch without any real NPM/LE.

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-le-skip.sh"
    local steps="/tmp/wizard-stage2-le-skip.steps.json"
    local plain_log="/tmp/wizard-stage2-le-skip.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    dind_exec "cat >>$fixture <<'BASH'
stage2_le_classify() {
    STAGE2_LE_CLASSIFICATION=config-dns
    STAGE2_LE_READY_HOSTS=\"\"
    STAGE2_LE_FAILED_HOSTS=\"jellyfin.\$1, jellyseerr.\$1\"
    printf 'config-dns\n'
    return 1
}
BASH"
    wizard_stage2_append_runner "$fixture"

    wizard_stage2_steps "$steps" \
        remote_offer 1 \
        stage2_have_domain 1 \
        stage2_hostname demo.mywire.org \
        stage2_use_dynu n \
        stage2_wg_port ENTER \
        stage2_vpn_level 1 \
        stage2_lan_cidr ENTER \
        stage2_upload_bw ENTER \
        stage2_viewer_cap ENTER \
        stage2_proceed 1 \
        stage2_https_not_ready@30 1

    wizard_stage2_run_pty "wizard-ui stage2 le skip" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "HTTPS is not ready. Choose how to continue:" "wizard-ui stage2 le skip: LE gate menu shown"
    assert_contains "$transcript" "DNS does not point both Jellyfin and Jellyseerr" "wizard-ui stage2 le skip: config-dns failure copy shown"
    assert_eq "skipped" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 le skip: REMOTE_WEB_STATE=skipped after gate skip"
}
