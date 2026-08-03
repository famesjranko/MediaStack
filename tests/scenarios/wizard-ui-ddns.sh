# tests/scenarios/wizard-ui-ddns.sh — day-2 "Update DDNS provider / credentials" PTY flow.
#
# Sources the `mediastack` launcher (guard stripped -> sourcing only exposes
# helpers), drives Features -> "Update DDNS provider / credentials", and exercises
# the three apply paths over a REAL PTY without a live ddns-updater:
#   - apply-success  : verify OK + restart OK -> config.json switched, .env persisted
#   - verify-reject  : verify KO -> re-prompt loop, live config + .env UNTOUCHED
#   - restore-failure: verify OK but the container fails to come up -> config.json
#                      rolled back to the previous provider, .env NOT persisted
# plus the route path:
#   - route          : a domain-changing switch (free-hostname provider) is detected
#                      by registry category BEFORE collect/verify and hands off to
#                      "Add remote access" instead of dead-ending at the verify.
#
# The three apply paths switch cloudflare -> porkbun: both are bring-your-own-domain
# providers, so the switch KEEPS the current domain and is allowed through to the
# real collect+verify (a free-hostname target would be intercepted by the route
# branch instead — that's what the route path proves). The provider picker, field
# loop, JSON renderer and config write are the REAL shared functions (the point
# being that the day-2 surface reuses the wizard's ddns_provider_pick /
# ddns_render_config_json / ddns_provider_category and the env_gen write helpers).
# Only the two live edges are stubbed: ddns_verify_via_container (the ephemeral
# verify) and _ddns_restart_and_check (the docker restart + up-check), each returning
# a code read from a file so one fixture drives all three apply paths. The route
# path's ACCEPT ("y") branch is intentionally NOT driven: it execs the real Stage-2
# wizard (setup.sh --remote) which is out of scope here. Complements the mechanism
# coverage in tests/scenarios/ddns-verify.sh.

# Re-seed a post-install DDNS state: DDNS_PROVIDER=<provider> (default dynu), a
# concrete DOMAIN, and a chmod-600 config.json for that provider. Called before EACH
# path so a mutated run never leaks into the next. The config.json content only feeds
# the rollback snapshot, so a minimal single-setting block is enough.
_ddns_seed_state() {
    local prov="${1:-dynu}"
    dind_exec "cd /root/MediaStack
rm -f .env
cp .env.example .env
sed -i 's#^DDNS_PROVIDER=.*#DDNS_PROVIDER=${prov}#' .env
sed -i 's#^DOMAIN=.*#DOMAIN=mybox.example.com#' .env
mkdir -p config/ddns-updater
cat > config/ddns-updater/config.json <<JSON
{\"settings\":[{\"provider\":\"${prov}\",\"domain\":\"mybox.example.com\",\"ip_version\":\"ipv4\"}]}
JSON"
}

# Write the per-path steps file and drive the PTY. Returns non-zero on PTY failure.
_ddns_pty_run() {
    local name="$1" steps_json="$2"
    local fixture="/tmp/wizard-ddns.sh"
    local steps="/tmp/wizard-ddns.steps.json"
    local plain_log="/tmp/wizard-ddns.plain.log"

    dind_exec "cat >$steps <<'JSON'
$steps_json
JSON"

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui ddns [$name]: PTY flow exits 0"
        return 0
    else
        fail "wizard-ui ddns [$name]: PTY flow exits 0"
        dind_exec "tail -200 $plain_log 2>/dev/null || true"
        return 1
    fi
}

run_scenario() {
    local fixture="/tmp/wizard-ddns.sh"

    # One fixture for all paths. The two live edges read their return codes from
    # files so each apply path drives a different outcome; remote is stubbed READY
    # (so the DDNS row's remote-gate passes) and non-NAS (to pin the row index).
    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack

# The launcher refuses to run as root (EUID guard); DinD runs as root, so source a
# same-directory copy with only that guard stripped. SCRIPT_DIR still resolves to
# the repo. The guard itself is intentional and unchanged.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi\$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh

# Stub the live edges. remote READY makes the DDNS row's remote-gate pass; not NAS
# pins the row index; docker/service up pass the guards. The verify + restart read
# their return codes from files so one fixture drives all three apply paths.
recovery_menu_remote_available(){ return 1; }
_docker_reachable(){ return 0; }
_service_is_running(){ return 0; }
storage_is_nas(){ return 1; }
ddns_verify_via_container(){ return \$(cat /tmp/ddns_verify_rc); }
# Record whether the NEW (porkbun) config had already been written to the live file
# at the moment the up-check runs, so the restore path can prove the forward write
# actually landed (and was then rolled back) rather than never happening.
_ddns_restart_and_check(){ grep -q porkbun config/ddns-updater/config.json 2>/dev/null && echo yes > /tmp/ddns_wrote_new || echo no > /tmp/ddns_wrote_new; return \$(cat /tmp/ddns_restart_rc); }

submenu_features
BASH
chmod +x $fixture"

    local plain_log="/tmp/wizard-ddns.plain.log"
    local cfg env_line transcript

    # ---- Path 1: apply-success (verify OK, restart OK) -----------------------
    _ddns_seed_state cloudflare
    dind_exec "echo 0 > /tmp/ddns_verify_rc; echo 0 > /tmp/ddns_restart_rc"
    _ddns_pty_run "success" '[
  {"expect": "Manage features & settings"},
  {"send": "8\n"},
  {"expect": "Current DDNS provider: cloudflare"},
  {"expect": "Choose your DDNS provider:"},
  {"send": "6\n"},
  {"expect": "Enter api key"},
  {"send": "pk1_testkey123\n"},
  {"expect": "Enter secret api key"},
  {"send": "sk1_testsecret456\n"},
  {"expect": "Switch DDNS to"},
  {"send": "y\n"},
  {"expect": "completed successfully"},
  {"expect": "Press Enter to return to menu"},
  {"send": "\n"},
  {"expect": "Manage features & settings"},
  {"send": "9\n"}
]' || return 1
    cfg="$(dind_exec "cat /root/MediaStack/config/ddns-updater/config.json")"
    assert_contains "$cfg" "porkbun" "wizard-ui ddns [success]: config.json switched to porkbun"
    assert_contains "$cfg" "pk1_testkey123" "wizard-ui ddns [success]: new api_key written to config.json"
    assert_contains "$cfg" "sk1_testsecret456" "wizard-ui ddns [success]: new secret_api_key written to config.json"
    env_line="$(dind_exec "grep -E '^DDNS_PROVIDER=' /root/MediaStack/.env")"
    assert_contains "$env_line" "DDNS_PROVIDER='porkbun'" "wizard-ui ddns [success]: DDNS_PROVIDER persisted on success"
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "completed successfully" "wizard-ui ddns [success]: success reported"

    # ---- Path 2: verify-reject (verify KO -> re-prompt -> bail) ---------------
    _ddns_seed_state cloudflare
    dind_exec "echo 1 > /tmp/ddns_verify_rc; echo 0 > /tmp/ddns_restart_rc"
    _ddns_pty_run "reject" '[
  {"expect": "Manage features & settings"},
  {"send": "8\n"},
  {"expect": "Choose your DDNS provider:"},
  {"send": "6\n"},
  {"expect": "Enter api key"},
  {"send": "pk1_testkey123\n"},
  {"expect": "Enter secret api key"},
  {"send": "sk1_testsecret456\n"},
  {"expect": "Those credentials were rejected"},
  {"send": "y\n"},
  {"expect": "Enter api key"},
  {"send": "pk1_testkey789\n"},
  {"expect": "Enter secret api key"},
  {"send": "sk1_testsecretABC\n"},
  {"expect": "Those credentials were rejected"},
  {"send": "n\n"},
  {"expect": "No change"},
  {"expect": "Press Enter to return to menu"},
  {"send": "\n"},
  {"expect": "Manage features & settings"},
  {"send": "9\n"}
]' || return 1
    cfg="$(dind_exec "cat /root/MediaStack/config/ddns-updater/config.json")"
    assert_contains "$cfg" "cloudflare" "wizard-ui ddns [reject]: live config still cloudflare"
    if grep -q porkbun <<<"$cfg"; then
        fail "wizard-ui ddns [reject]: live config left UNTOUCHED (no porkbun)"
    else
        pass "wizard-ui ddns [reject]: live config left UNTOUCHED (no porkbun)"
    fi
    env_line="$(dind_exec "grep -E '^DDNS_PROVIDER=' /root/MediaStack/.env")"
    assert_contains "$env_line" "DDNS_PROVIDER=cloudflare" "wizard-ui ddns [reject]: DDNS_PROVIDER unchanged"
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "Those credentials were rejected" "wizard-ui ddns [reject]: rejection surfaced + re-prompted"
    assert_contains "$transcript" "No change" "wizard-ui ddns [reject]: bailed without applying"

    # ---- Path 3: restore-on-startup-failure (verify OK, restart KO) -----------
    _ddns_seed_state cloudflare
    dind_exec "echo 0 > /tmp/ddns_verify_rc; echo 1 > /tmp/ddns_restart_rc; echo pending > /tmp/ddns_wrote_new"
    _ddns_pty_run "restore" '[
  {"expect": "Manage features & settings"},
  {"send": "8\n"},
  {"expect": "Choose your DDNS provider:"},
  {"send": "6\n"},
  {"expect": "Enter api key"},
  {"send": "pk1_testkey123\n"},
  {"expect": "Enter secret api key"},
  {"send": "sk1_testsecret456\n"},
  {"expect": "Switch DDNS to"},
  {"send": "y\n"},
  {"expect": "restoring your previous DDNS config"},
  {"expect": "exited with code"},
  {"expect": "Press Enter to return to menu"},
  {"send": "\n"},
  {"expect": "Manage features & settings"},
  {"send": "9\n"}
]' || return 1
    # Prove the forward write LANDED (config held porkbun when the up-check ran),
    # so the cloudflare end-state is a real rollback, not a write that never happened.
    assert_contains "$(dind_exec "cat /tmp/ddns_wrote_new")" "yes" "wizard-ui ddns [restore]: new config was written before the failed startup"
    cfg="$(dind_exec "cat /root/MediaStack/config/ddns-updater/config.json")"
    assert_contains "$cfg" "cloudflare" "wizard-ui ddns [restore]: config.json rolled back to cloudflare"
    if grep -q porkbun <<<"$cfg"; then
        fail "wizard-ui ddns [restore]: config.json rolled back (no porkbun left)"
    else
        pass "wizard-ui ddns [restore]: config.json rolled back (no porkbun left)"
    fi
    env_line="$(dind_exec "grep -E '^DDNS_PROVIDER=' /root/MediaStack/.env")"
    assert_contains "$env_line" "DDNS_PROVIDER=cloudflare" "wizard-ui ddns [restore]: DDNS_PROVIDER NOT persisted on failed startup"
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "restoring your previous DDNS config" "wizard-ui ddns [restore]: rollback path taken"

    # ---- Path 4: domain-changing switch is routed to Add remote access --------
    # dynu (free) -> duckdns (free) needs a NEW hostname, so it is intercepted by the
    # category route BEFORE collect/verify. Decline the hand-off ('n') to stay
    # hermetic (accepting execs the real Stage-2 wizard). Live config + .env untouched.
    _ddns_seed_state dynu
    _ddns_pty_run "route" '[
  {"expect": "Manage features & settings"},
  {"send": "8\n"},
  {"expect": "Current DDNS provider: dynu"},
  {"expect": "Choose your DDNS provider:"},
  {"send": "1\n"},
  {"expect": "needs a new hostname"},
  {"expect": "set the new hostname"},
  {"send": "n\n"},
  {"expect": "No change to DDNS"},
  {"expect": "Press Enter to return to menu"},
  {"send": "\n"},
  {"expect": "Manage features & settings"},
  {"send": "9\n"}
]' || return 1
    cfg="$(dind_exec "cat /root/MediaStack/config/ddns-updater/config.json")"
    assert_contains "$cfg" "dynu" "wizard-ui ddns [route]: live config still dynu (not touched)"
    if grep -q duckdns <<<"$cfg"; then
        fail "wizard-ui ddns [route]: live config left UNTOUCHED (no duckdns)"
    else
        pass "wizard-ui ddns [route]: live config left UNTOUCHED (no duckdns)"
    fi
    env_line="$(dind_exec "grep -E '^DDNS_PROVIDER=' /root/MediaStack/.env")"
    assert_contains "$env_line" "DDNS_PROVIDER=dynu" "wizard-ui ddns [route]: DDNS_PROVIDER unchanged"
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "needs a new hostname" "wizard-ui ddns [route]: domain-change guidance shown"
    assert_contains "$transcript" "No change to DDNS" "wizard-ui ddns [route]: declined hand-off, no change"
}
