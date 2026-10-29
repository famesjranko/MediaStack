# tests/scenarios/remote-route-user.sh — reused remote-setup account permissions.
# Runs the real fixture helpers and sudo policy in DinD; no service images.

source tests/scenarios/remote-ready-idempotent.sh
source tests/scenarios/remote-after-skip.sh

run_scenario() {
    local helper uid
    for helper in remote_ready_idempotent_prepare_public_route_user remote_after_skip_prepare_public_route_user; do
        # Given an existing account with another group and no fixture sudo rule.
        dind_exec "id -u mstest >/dev/null 2>&1 || useradd -m -s /bin/bash mstest" || return 1
        dind_exec "usermod -G users mstest && rm -f /etc/sudoers.d/90-mediastack-e2e /etc/sudoers.d/90-mediastack-mstest && mkdir -p /tmp/ms-data" || return 1
        uid=$(dind_exec "id -u mstest") || return 1
        if dind_exec "su -s /bin/bash mstest -c 'sudo -n true'" >/dev/null 2>&1; then
            fail "$helper: precondition denies sudo"
            return 1
        fi
        pass "$helper: precondition denies sudo"

        # When the helper prepares that account.
        run_cmd "$helper"
        assert_rc 0 "$helper: prepares the reused account"

        # Then the same account can use sudo and Docker and keeps its other group.
        assert_eq "$uid" "$(dind_exec "id -u mstest")" "$helper: preserves the account UID"
        run_cmd dind_exec "su -s /bin/bash mstest -c 'sudo -n true'"
        assert_rc 0 "$helper: restores non-interactive sudo"
        run_cmd dind_exec "su -s /bin/bash mstest -c 'docker info >/dev/null'"
        assert_rc 0 "$helper: restores Docker access"
        assert_contains " $(dind_exec "id -nG mstest") " " users " "$helper: preserves other groups"
        assert_eq "440 root root" "$(dind_exec "stat -c '%a %U %G' /etc/sudoers.d/90-mediastack-mstest")" "$helper: installs a protected sudo rule"

        # Given the account is now prepared.
        # When the same helper runs again.
        run_cmd "$helper"

        # Then preparation still succeeds and sudo remains usable.
        assert_rc 0 "$helper: preparation is safe to repeat"
        run_cmd dind_exec "su -s /bin/bash mstest -c 'sudo -n true'"
        assert_rc 0 "$helper: repeated preparation preserves sudo"
    done
}
