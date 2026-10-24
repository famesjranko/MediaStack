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
assert_contains "$AF_OUT" "rule out of place" "apply script: reports the missing rule"

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

verify_rejects_rule_order() {
    local ipt change="$1" rules first_drop
    for ipt in iptables ip6tables; do
        af_reset
        af_write_script
        af_docker_up
        af_run apply
        rules="$AF_STATE/v$([[ "$ipt" == iptables ]] && echo 4 || echo 6).rules"
        case "$change" in
            extra-return) "$ipt" -I MEDIASTACK-DOCKER-RESTRICT 1 -j RETURN ;;
            first-drop)
                first_drop=$(grep -m1 -- '|.*DROP' "$rules")
                grep -vxF "$first_drop" "$rules" >"$rules.n"
                {
                    printf '%s\n' "$first_drop"
                    cat "$rules.n"
                } >"$rules"
                ;;
            extra-rule) "$ipt" -A MEDIASTACK-DOCKER-RESTRICT -j RETURN ;;
        esac
        af_run verify
        assert_eq "1" "$AF_RC" "verify mode: $ipt rejects $change in the generated rule order"
        assert_contains "$AF_OUT" "$ipt: first MEDIASTACK-DOCKER-RESTRICT rule out of place" "verify mode: $ipt names the first displaced rule"
    done
}

# Given an extra RETURN at position one
# When the script verifies both IP families
# Then it rejects the first displaced payload rule
verify_rejects_rule_order extra-return

# Given a DROP moved ahead of the source RETURN rules
# When the script verifies both IP families
# Then it rejects the first displaced payload rule
verify_rejects_rule_order first-drop

# Given an appended extra rule
# When the script verifies both IP families
# Then it rejects the first extra payload rule
verify_rejects_rule_order extra-rule

# Given two or more displaced filter rules
# When the script verifies the chain
# Then it reports only the first expected and found rule pair
af_reset
af_write_script
af_docker_up
af_run apply
iptables -I MEDIASTACK-DOCKER-RESTRICT 1 -j RETURN
iptables -A MEDIASTACK-DOCKER-RESTRICT -j RETURN
af_run verify
assert_eq "1" "$AF_RC" "verify mode: exits non-zero for multiple displaced rules"
assert_eq "1" "$(grep -o 'expected ' <<<"$AF_OUT" | wc -l)" "verify mode: reports one expected rule for multiple displaced rules"
assert_eq "1" "$(grep -o 'found ' <<<"$AF_OUT" | wc -l)" "verify mode: reports one found rule for multiple displaced rules"
assert_contains "$AF_OUT" "expected -s 127.0.0.0/8 -j RETURN, found -j RETURN" "verify mode: reports the first displaced rule pair"

# Given a chain that disappears after apply
# When the script verifies
# Then it fails closed instead of accepting unreadable output
af_reset
af_write_script
af_docker_up
af_run apply
grep -vx MEDIASTACK-DOCKER-RESTRICT "$AF_STATE/v4.chains" >"$AF_STATE/v4.chains.n"
mv "$AF_STATE/v4.chains.n" "$AF_STATE/v4.chains"
af_run verify
assert_eq "1" "$AF_RC" "verify mode: exits non-zero when the filter chain cannot be listed"
assert_contains "$AF_OUT" "cannot read MEDIASTACK-DOCKER-RESTRICT rules" "verify mode: names unreadable filter output"

# Fail only the comparison awk program. jump_ok has a different program and
# still executes the real awk, so this models a comparison failure after its
# preceding jump check has passed.
cat >"$AF_BIN/awk" <<'FAKE'
#!/usr/bin/env bash
if [[ "${FAKE_FAIL_RULE_COMPARE:-}" == 1 && "$*" == *"expected["* ]]; then exit 1; fi
exec /usr/bin/awk "$@"
FAKE
chmod +x "$AF_BIN/awk"

# Given matching filter chains
# When the script verifies them
# Then the comparison succeeds with no mismatch text
af_reset
af_write_script
af_docker_up
af_run apply
af_run verify
assert_eq "0" "$AF_RC" "verify mode: matching chains pass the rule comparison"

# Given the comparison utility fails before it can emit a mismatch
# When the script verifies otherwise matching chains
# Then it fails closed and names the comparison error
af_reset
af_write_script
af_docker_up
af_run apply
FAKE_FAIL_RULE_COMPARE=1 af_run verify
assert_eq "1" "$AF_RC" "verify mode: exits non-zero when rule comparison fails"
assert_contains "$AF_OUT" "cannot compare MEDIASTACK-DOCKER-RESTRICT rules" "verify mode: names a rule comparison failure"

# Given the comparison utility fails during apply's post-load verification
# When the script applies otherwise matching chains
# Then apply fails closed and names the comparison error
af_reset
af_write_script
af_docker_up
FAKE_FAIL_RULE_COMPARE=1 af_run apply
assert_eq "1" "$AF_RC" "apply script: exits non-zero when rule comparison fails"
assert_contains "$AF_OUT" "cannot compare MEDIASTACK-DOCKER-RESTRICT rules" "apply script: names a rule comparison failure"

# Given an extra RETURN that apply must replace
# When the script applies again, then verifies
# Then the generated sequence is restored
af_reset
af_write_script
af_docker_up
af_run apply
iptables -I MEDIASTACK-DOCKER-RESTRICT 1 -j RETURN
af_run apply
af_run verify
assert_eq "0" "$AF_RC" "apply script: replaces an unexpected RETURN with its generated chain"

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
if unshare -rn true 2>/dev/null; then
    for backend in legacy nft; do
        real_bin=$(mktemp -d)
        for t in iptables ip6tables iptables-restore ip6tables-restore; do
            ln -s "/usr/sbin/xtables-${backend}-multi" "$real_bin/$t"
        done
        real_out=$(PATH="$real_bin:/usr/sbin:/usr/bin:/sbin:/bin" XTABLES_LOCKFILE="$AF_TMP/xtables-${backend}.lock" unshare -rn sh -c '
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
        rm -rf "$real_bin"
        if [[ "$backend" == legacy && "$real_out" == *"can't initialize ip6tables table"* ]]; then
            skip "real legacy iptables: IPv6 legacy table unavailable in this unprivileged namespace"
            continue
        fi
        assert_contains "$real_out" "rc=000" "real $backend iptables: apply, re-apply and verify all succeed"
        assert_eq "1" "$(grep -c -- '-j MEDIASTACK-DOCKER-RESTRICT$' <<<"$real_out")" "real $backend iptables: one jump after a re-apply"
        assert_eq "$(_admin_filter_rule_lines v4)" "$(sed -n '/^-A MEDIASTACK-DOCKER-RESTRICT /p' <<<"$real_out")" "real $backend iptables: -S chain exactly matches the generated sequence"
        assert_contains "$real_out" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT
-A DOCKER-USER -j RETURN" "real iptables: the jump sits ahead of Docker's RETURN"
    done
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
