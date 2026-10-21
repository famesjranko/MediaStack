# Owns: admin-port filter repair tests (a flushed chain behind an active unit is verified, re-applied and re-verified).
# Sources: the fake host, helpers and af_* functions of tests/unit/hardening/admin-filter.sh, which sources this file.

# Given an installed, active unit whose chain was flushed behind systemd's back
# When setup runs again
# Then it verifies, re-applies without restarting the unit, and succeeds only once the chain is back
af_reset
af_docker_up
setup_admin_filter >/dev/null 2>&1
iptables -F MEDIASTACK-DOCKER-RESTRICT
ip6tables -F MEDIASTACK-DOCKER-RESTRICT
: >"$SYSTEMCTL_LOG"
: >"$AF_STATE/ops.log"
af_out=$(setup_admin_filter 2>&1)
assert_eq "0" "$?" "admin filter repair: a flushed chain is repaired and setup succeeds"
assert_eq "0" "$(sh "$MEDIASTACK_ADMIN_FILTER_SCRIPT" verify >/dev/null 2>&1 && echo 0 || echo 1)" "admin filter repair: the installed script verifies afterwards"
assert_eq "1" "$(af_jumps iptables)" "admin filter repair: still exactly one v4 jump"
assert_not_contains "$(cat "$SYSTEMCTL_LOG")" "restart" "admin filter repair: the unit is never restarted (that would restart Docker)"
assert_not_contains "$af_out" "already installed" "admin filter repair: a flushed chain is not reported as already installed"

# Given an installed, active unit whose chain is flushed and cannot be restored
# When setup runs again
# Then it returns non-zero and does not report success
af_reset
af_docker_up
setup_admin_filter >/dev/null 2>&1
iptables -F MEDIASTACK-DOCKER-RESTRICT
af_out=$(FAKE_RESTORE_SKIP_DROP=1 setup_admin_filter 2>&1)
assert_eq "1" "$?" "admin filter repair failure: setup fails when the chain still does not verify"
assert_not_contains "$af_out" "repaired" "admin filter repair failure: no repair is claimed"
