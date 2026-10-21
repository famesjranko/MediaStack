# Owns: admin-port apply-script tests (fail-closed, idempotent, verify mode), the exact-false opt-out and their real-iptables runs.
# Sources: tests/unit/hardening/admin-filter.sh, which defines the fake root, the stateful fake iptables and the af_* helpers.

# ===========================================================================
# The apply script: fail closed, loud, idempotent
# ===========================================================================

# Given Docker's DOCKER-USER ends in RETURN
# When the script applies, then applies again
# Then both runs succeed and one jump sits ahead of Docker's RETURN
af_reset
af_write_script
af_docker_up
af_run apply
assert_eq "0" "$AF_RC" "apply script: succeeds on a Docker host ($AF_OUT)"
af_run apply
assert_eq "0" "$AF_RC" "apply script: a second run succeeds"
assert_eq "1" "$(af_jumps iptables)" "apply script: re-run leaves one v4 jump"
assert_eq "1" "$(af_jumps ip6tables)" "apply script: re-run leaves one v6 jump"
assert_eq "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "$(iptables -S DOCKER-USER | sed -n 2p)" "apply script: the jump sits ahead of Docker's RETURN"

# Given a jump that a ufw reload appended behind Docker's RETURN
# When the script applies
# Then the dead jump is replaced by one live jump
af_reset
af_write_script
af_docker_up
iptables -A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT
iptables -N MEDIASTACK-DOCKER-RESTRICT
af_run apply
assert_eq "0" "$AF_RC" "apply script: repairs a jump stuck behind RETURN"
assert_eq "1" "$(af_jumps iptables)" "apply script: stale jump replaced, not doubled"
assert_eq "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "$(iptables -S DOCKER-USER | sed -n 2p)" "apply script: repaired jump is the first rule"

# Given iptables-restore fails
# When the script applies
# Then it exits non-zero and says why
af_reset
af_write_script
af_docker_up
FAKE_FAIL_RESTORE=1 af_run apply
assert_eq "1" "$AF_RC" "apply script: exits non-zero when iptables-restore fails"
assert_contains "$AF_OUT" "failed to load" "apply script: names the failed load"

# Given a restore that silently drops the DROP rules
# When the script applies
# Then the post-apply check finds them missing and exits non-zero
af_reset
af_write_script
af_docker_up
FAKE_RESTORE_SKIP_DROP=1 af_run apply
assert_eq "1" "$AF_RC" "apply script: exits non-zero when a DROP rule is missing after apply"
assert_contains "$AF_OUT" "rule missing" "apply script: reports the missing rule"

# Given an insert that silently does nothing
# When the script applies
# Then the post-apply check finds the jump missing and exits non-zero
af_reset
af_write_script
af_docker_up
FAKE_NOOP_INSERT=1 af_run apply
assert_eq "1" "$AF_RC" "apply script: exits non-zero when the jump is missing after apply"
assert_contains "$AF_OUT" "does not jump" "apply script: reports the missing jump"

# Given iptables uses nf_tables and ip6tables uses legacy
# When the script applies
# Then it exits non-zero on the backend mismatch and touches no rule
af_reset
af_write_script
af_docker_up
FAKE_BACKEND_V4=nf_tables FAKE_BACKEND_V6=legacy af_run apply
assert_eq "1" "$AF_RC" "apply script: exits non-zero on an nft/legacy backend mismatch"
assert_contains "$AF_OUT" "backend mismatch" "apply script: names the backend mismatch"
assert_eq "0" "$(af_jumps iptables)" "apply script: a backend mismatch changes no rule"

# Given the kernel has no IPv6
# When the script applies
# Then it filters IPv4 and does not call ip6tables
af_reset
af_write_script
iptables -N DOCKER-USER
iptables -A DOCKER-USER -j RETURN
MEDIASTACK_IF_INET6="$AF_TMP/no-such-file" af_run apply
assert_eq "0" "$AF_RC" "apply script: succeeds on a host without IPv6 ($AF_OUT)"
assert_not_contains "$(cat "$AF_STATE/ops.log")" "ip6tables" "apply script: skips ip6tables when IPv6 is off"

# Given Docker is up and FORWARD reaches DOCKER-USER
# When the script verifies, and again with FORWARD detached
# Then it passes, then fails because Docker uses another firewall backend
af_reset
af_write_script
af_docker_up
af_run apply
af_run verify
assert_eq "0" "$AF_RC" "verify mode: passes when FORWARD reaches the filter ($AF_OUT)"
iptables -D FORWARD -j DOCKER-USER
af_run verify
assert_eq "1" "$AF_RC" "verify mode: exits non-zero when FORWARD does not reach DOCKER-USER"
assert_contains "$AF_OUT" "different firewall backend" "verify mode: explains the likely cause"

# Given the chain is flushed after apply
# When the script verifies
# Then it exits non-zero
af_reset
af_write_script
af_docker_up
af_run apply
: >"$AF_STATE/v4.rules"
iptables -A FORWARD -j DOCKER-USER
af_run verify
assert_eq "1" "$AF_RC" "verify mode: exits non-zero when the filter chain was flushed"

# ===========================================================================
# Install failure surfaces and stops
# ===========================================================================

# Given the apply script cannot load its rules
# When the unit path is installed
# Then setup fails loudly instead of reporting success
af_reset
af_docker_up
FAKE_FAIL_RESTORE=1 setup_admin_filter_unit >"$AF_TMP/out" 2>&1
assert_eq "1" "$?" "admin filter install: a failed apply returns non-zero"

# Given the same failure during hardening
# When setup_hardening runs
# Then it returns non-zero, so a set -e caller stops before the stack starts
af_reset
af_docker_up
UFW_ENABLED=false HARDENING_ENABLED=false FAKE_FAIL_RESTORE=1 setup_hardening >/dev/null 2>&1
assert_eq "1" "$?" "admin filter install: setup_hardening fails closed when the filter cannot be applied"

# ===========================================================================
# Integration: the generated script against the real iptables in a throwaway namespace
# ===========================================================================

af_reset
af_write_script
if unshare -rn true 2>/dev/null && command -v /usr/sbin/iptables >/dev/null 2>&1; then
    # The fake binaries must not shadow the real ones inside the namespace.
    real_out=$(PATH="/usr/sbin:/usr/bin:/sbin:/bin" unshare -rn sh -c '
        ip link set lo up 2>/dev/null
        for t in iptables ip6tables; do $t -N DOCKER-USER; $t -A DOCKER-USER -j RETURN; done
        iptables -A FORWARD -j DOCKER-USER
        sh "$1" apply >/dev/null 2>&1; a=$?
        sh "$1" apply >/dev/null 2>&1; b=$?
        sh "$1" verify >/dev/null 2>&1; c=$?
        echo "rc=$a$b$c"
        iptables -S DOCKER-USER
        iptables -S MEDIASTACK-DOCKER-RESTRICT
    ' _ "$MEDIASTACK_ADMIN_FILTER_SCRIPT" 2>&1)
    assert_contains "$real_out" "rc=000" "real iptables: apply, re-apply and verify all succeed"
    assert_eq "1" "$(grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT$' <<<"$real_out")" "real iptables: one jump after a re-apply"
    assert_contains "$real_out" "-A MEDIASTACK-DOCKER-RESTRICT -s 100.64.0.0/10 -j RETURN" "real iptables: Tailscale range RETURNs"
    assert_contains "$real_out" "--dports 8000,8090,3001,8191,6767,8096,3000 -j DROP" "real iptables: admin ports DROP"
    assert_contains "$real_out" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT
-A DOCKER-USER -j RETURN" "real iptables: the jump sits ahead of Docker's RETURN"
else
    skip "real iptables: user+net namespaces unavailable on this host"
fi

# Given hardening ran with UFW on and its after files are loaded the way ufw
# loads them, with Docker's RETURN already in DOCKER-USER (the sequence that
# parked the old jump behind RETURN)
# When ufw reloads, enables, disables and reloads
# Then real iptables shows one jump at position 1 and a populated chain
af_reset
af_write_script
UFW_ENABLED=true HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
af_write_script
if unshare -rn true 2>/dev/null && command -v /usr/sbin/iptables >/dev/null 2>&1; then
    real_out=$(PATH="/usr/sbin:/usr/bin:/sbin:/bin" unshare -rn sh -c '
        ip link set lo up 2>/dev/null
        for t in iptables ip6tables; do $t -N DOCKER-USER; $t -A DOCKER-USER -j RETURN; done
        iptables -A FORWARD -j DOCKER-USER
        sh "$1" apply >/dev/null 2>&1
        load() { # a real ufw load: the *filter sections of after.rules / after6.rules
            awk "/^\*filter/ { p = 1 } p { print } /^COMMIT/ { p = 0 }" "$2" | iptables-restore --noflush
            awk "/^\*filter/ { p = 1 } p { print } /^COMMIT/ { p = 0 }" "$3" | ip6tables-restore --noflush
        }
        load x "$2" "$3"; load x "$2" "$3"; load x "$2" "$3"
        echo "restore-rc=$?"
        iptables -S DOCKER-USER
        ip6tables -S DOCKER-USER
        iptables -S MEDIASTACK-DOCKER-RESTRICT
    ' _ "$MEDIASTACK_ADMIN_FILTER_SCRIPT" "$MEDIASTACK_UFW_AFTER_RULES" "$MEDIASTACK_UFW_AFTER6_RULES" 2>&1)
    assert_contains "$real_out" "restore-rc=0" "real iptables ufw loads: every load succeeds"
    assert_eq "2" "$(grep -c -- '-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT$' <<<"$real_out")" "real iptables ufw loads: one jump per family after three ufw loads"
    assert_contains "$real_out" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT
-A DOCKER-USER -j RETURN" "real iptables ufw loads: the jump stays ahead of Docker's RETURN"
    assert_contains "$real_out" "--dports 8000,8090,3001,8191,6767,8096,3000 -j DROP" "real iptables ufw loads: the chain keeps its DROP rules"
else
    skip "real iptables ufw loads: user+net namespaces unavailable on this host"
fi

# ===========================================================================
# Only the exact value "false" opts out
# ===========================================================================

# Given ADMIN_PORT_FILTER is FALSE or False, which are not the exact opt-out value
# When hardening runs
# Then the filter is still installed
for v in FALSE False; do
    af_reset && af_docker_up
    ADMIN_PORT_FILTER="$v" UFW_ENABLED=false HARDENING_ENABLED=false setup_hardening >/dev/null 2>&1
    assert_file_contains "$MEDIASTACK_ADMIN_FILTER_UNIT" "ExecStart=" "admin filter value [$v]: not an opt-out, unit written"
done
