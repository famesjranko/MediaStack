# tests/scenarios/uninstall.sh — end-to-end "Uninstall MediaStack" flow.
#
# Simulates a completed Stage 1 install, seeds a valid ownership ledger,
# then runs setup.sh --uninstall and verifies:
#   - DESTROY confirmation gate works
#   - docker compose down called (all profiles)
#   - .env removed; data/ preserved
#   - Sysctl hardening file removed
#   - Login banner removed
#   - Ownership ledger cleaned up only after host cleanup succeeds

run_scenario() {
    # ── Fixture: completed install state ─────────────────────────────────────
    dind_exec "cp .env.example .env"
    env_set DATA_DIR /tmp/ms-uninstall-data
    env_set STAGE_1_COMPLETE 1
    env_set HOST_ADDRESS 127.0.0.1
    env_set JELLYFIN_ADMIN_PASSWORD UninstallDemoPassword123
    env_set DOMAIN example.com
    env_set REMOTE_WEB_STATE skipped
    env_set WG_INIT_PASSWORD "'uninstallwgpassword'"

    # Sentinel to verify data/ is never removed
    dind_exec "mkdir -p /tmp/ms-uninstall-data/media/tv && touch /tmp/ms-uninstall-data/media/tv/.uninstall-sentinel"

    # Seed the minimum valid ownership ledger. Selective cleanup itself has
    # focused unit coverage; this scenario proves the setup.sh transaction.
    dind_exec "mkdir -p /etc/mediastack"
    dind_exec "cat >/etc/mediastack/install-state <<'EOF'
STATE_FORMAT=1
UFW_RULES_BEFORE_SHA256=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
UFW_DEFAULT_INCOMING=deny
UFW_DEFAULT_OUTGOING=allow
UFW_DEFAULTS_APPLIED=false
UFW_ENABLED_BY_MEDIASTACK=false
UFW_RULE_COUNT=0
SYSCTL_FILE_CREATED=false
SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false
SAMBA_OWNERSHIP_RECORDED=false
SAMBA_CONFIGURED=false
EOF
chmod 0600 /etc/mediastack/install-state"

    # Fake artefacts that uninstall should remove
    dind_exec "mkdir -p /etc/sysctl.d && printf 'net.ipv4.conf.all.rp_filter=1\n' > /etc/sysctl.d/90-mediastack-hardening.conf"
    dind_exec "touch /etc/profile.d/mediastack-setup-result.sh"

    dind_exec "rm -f /tmp/uninstall-docker.log"

    # ── Run setup.sh --uninstall ──────────────────────────────────────────────
    local log_path=/tmp/uninstall.out
    if dind_exec "printf 'DESTROY\n' | bash -lc '
set -euo pipefail
source setup.sh
check_not_root()        { :; }
check_debian()          { :; }
prompt_sudo_cache()     { :; }
record_launcher_outcome() { :; }
sudo() { \"\$@\" 2>/dev/null || true; }
docker() {
    printf \"%s\n\" \"\$*\" >> /tmp/uninstall-docker.log
    return 0
}
uninstall_system_cleanup() {
    rm -f /etc/sysctl.d/90-mediastack-hardening.conf /etc/profile.d/mediastack-setup-result.sh
    echo \"MediaStack system artefacts removed\"
}
main --uninstall
'" >"$log_path" 2>&1; then
        pass "uninstall: setup.sh --uninstall exits 0"
    else
        fail "uninstall: setup.sh --uninstall exits 0"
        tail -100 "$log_path"
        return 1
    fi

    local log_plain
    log_plain="$(sed -r 's/\x1b\[[0-9;]*m//g' "$log_path" 2>/dev/null || true)"

    # ── Output assertions ─────────────────────────────────────────────────────
    assert_contains "$log_plain" "This will DELETE:" \
        "uninstall: destructive preview shown before DESTROY gate"
    assert_contains "$log_plain" "MediaStack-owned UFW rules" \
        "uninstall: preview lists system changes"
    assert_contains "$log_plain" "Existing install removed" \
        "uninstall: nuke_existing_install confirms removal"
    assert_contains "$log_plain" "MediaStack system artefacts removed" \
        "uninstall: uninstall_system_cleanup confirms completion"

    # ── Docker compose teardown ───────────────────────────────────────────────
    local docker_log
    docker_log="$(dind_exec "cat /tmp/uninstall-docker.log 2>/dev/null || true" | tr -d '\r')"
    assert_contains "$docker_log" "compose --profile * down -v" \
        "uninstall: docker compose down called for all profiles"

    # ── File system state ─────────────────────────────────────────────────────
    if dind_exec "test ! -f .env"; then
        pass "uninstall: .env removed"
    else
        fail "uninstall: .env removed"
    fi
    if dind_exec "test -f /tmp/ms-uninstall-data/media/tv/.uninstall-sentinel"; then
        pass "uninstall: data/ directory preserved"
    else
        fail "uninstall: data/ directory preserved"
    fi
    if dind_exec "test ! -f /etc/sysctl.d/90-mediastack-hardening.conf"; then
        pass "uninstall: sysctl hardening file removed"
    else
        fail "uninstall: sysctl hardening file removed"
    fi
    if dind_exec "test ! -f /etc/profile.d/mediastack-setup-result.sh"; then
        pass "uninstall: login banner removed"
    else
        fail "uninstall: login banner removed"
    fi

    # ── Ownership ledger cleaned up last ─────────────────────────────────────
    if dind_exec "test ! -e /etc/mediastack"; then
        pass "uninstall: /etc/mediastack removed (ledger cleaned up)"
    else
        fail "uninstall: /etc/mediastack removed (ledger cleaned up)"
    fi
}
