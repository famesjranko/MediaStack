# tests/scenarios/wizard-ui-stage2-no-domain.sh — Stage 2 "No, I don't have a
# domain" branch.
#
# The "[1/5] Domain" step is provider-agnostic: the has-domain "No" answer
# prints provider-neutral free-hostname guidance and routes straight into the
# 6-provider picker (skipping the static/dynamic question), replacing the old
# Dynu-only walkthrough. install-ready drives the "Yes" answer; tell-me-more
# drives the offer's "Tell me more" loop; NEITHER drives this "No" branch, so its
# intro copy + the "Ready to pick a provider" confirm + the No->picker routing
# were unguarded against SSOT drift. This scenario closes that gap: it drives the
# "No" answer, asserts the free-options intro copy, answers the confirm, picks a
# provider, and lands the same install-ready terminal state.
#
# Mirrors wizard-ui-stage2-install-ready.sh from the picker onward (Dynu, verify
# stubbed OK, LE stubbed ready); the only divergence is the top of Stage 2:
# have_domain "No" -> confirm -> hostname -> picker (NO static-IP step, since "no
# domain" implies DDNS).

source tests/lib/wizard_stage2_common.sh

run_scenario() {
    local fixture="/tmp/wizard-stage2-no-domain.sh"
    local steps="/tmp/wizard-stage2-no-domain.steps.json"
    local plain_log="/tmp/wizard-stage2-no-domain.plain.log"

    wizard_stage2_write_base_fixture "$fixture"
    wizard_stage2_append_runner "$fixture"

    # No static-IP step: the "No" branch forces the DDNS picker directly
    # (skip_static_q=true, pick_mode=pick in _stage2_collect_domain).
    wizard_stage2_steps "$steps" \
        remote_offer 1 \
        stage2_have_domain 2 \
        stage2_freehost_confirm y \
        stage2_hostname demo.mywire.org \
        stage2_ddns_provider 2 \
        stage2_dynu_password dynupass123 \
        stage2_wg_enable y \
        stage2_wg_port ENTER \
        stage2_vpn_level 1 \
        stage2_lan_cidr ENTER \
        stage2_upload_bw ENTER \
        stage2_viewer_cap ENTER \
        stage2_proceed 1

    wizard_stage2_run_pty "wizard-ui stage2 no domain" "$fixture" "$steps" "$plain_log" || return 1

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    # The No-branch free-options intro copy (distinct from tell-me-more's
    # "Free-hostname providers" line): guards stage2.sh:633 against drift.
    assert_contains "$transcript" "Free hostname, nothing to buy" "wizard-ui stage2 no domain: free-options intro copy shown"
    assert_contains "$transcript" "accepted the update" "wizard-ui stage2 no domain: ephemeral verify accepted (dyndns2 tier message)"
    assert_contains "$transcript" "Remote access is ready" "wizard-ui stage2 no domain: LE-ready success message"

    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "wizard-ui stage2 no domain: REMOTE_WEB_STATE=ready"
    assert_eq "demo.mywire.org" "$(env_get DOMAIN)" "wizard-ui stage2 no domain: DOMAIN persisted"
    assert_eq "dynu" "$(env_get DDNS_PROVIDER)" "wizard-ui stage2 no domain: DDNS provider persisted to .env"
}
