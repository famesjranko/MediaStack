#!/usr/bin/env bash
# tests/unit/hardening.sh
#
# Pure-bash unit test for the OS hardening + SMB helpers in hardening.sh.
# No DinD, no Docker, no network. Shims override external commands.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="hardening"
echo -e "${CYAN}${BOLD}▶ scenario: hardening${NC}"

# Source setup.sh for the helper functions (guard prevents main() from running).
# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

# Relax strict mode for test assertions.
set +e
set +u

# Silence log_* output — tests drive their own assertions.
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_skip() { :; }
_ms_state_set() { :; }
_ms_state_get() { echo false; }

# ===========================================================================
# setup_ufw — skip path repairs SSH policy when service + Docker markers exist
# ===========================================================================

UFW_CALLS=()
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "2222/tcp                   ALLOW       Anywhere"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        if [[ "$*" == *"# MEDIASTACK-DOCKER-RULES"* ]]; then
            return 0
        fi
        return 1
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "tee" ]]; then
        UFW_CALLS+=("$*")
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}

UFW_CALLS=()
SSH_CONNECTION="198.51.100.10 55123 192.0.2.20 2222"
setup_ufw
found_reset=false
found_tee=false
found_ssh_10=false
found_ssh_172=false
found_ssh_192=false
found_ssh_broad_delete=false
found_active_client=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"reset"* ]] && found_reset=true
    [[ "$c" == *"tee"* ]] && found_tee=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 2222 proto tcp"* ]] && found_ssh_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 2222 proto tcp"* ]] && found_ssh_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 2222 proto tcp"* ]] && found_ssh_192=true
    [[ "$c" == *"allow from 198.51.100.10 to any port 2222 proto tcp"* ]] && found_active_client=true
    [[ "$c" == *"delete allow 2222/tcp"* ]] && found_ssh_broad_delete=true
done
assert_eq "false" "$found_reset" "setup_ufw: skip path — no reset when active + service/Docker markers"
assert_eq "false" "$found_tee" "setup_ufw: skip path — no Docker rule rewrite when persisted and live"
assert_eq "true" "$found_ssh_10" "setup_ufw: skip path — repairs active SSH port allow for 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: skip path — repairs active SSH port allow for 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: skip path — repairs active SSH port allow for 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: skip path — preserves current non-private SSH client IP"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: skip path — preserves pre-existing broad SSH allow"
unset -f sudo ufw
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — active service marker repairs missing Docker after.rules block
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "22/tcp                     ALLOW       Anywhere"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        UFW_CALLS+=("$*")
        DOCKER_RULES="$(cat)"
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}

UFW_CALLS=()
setup_ufw

found_reset=false
found_ssh_broad_delete=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"reset"* ]] && found_reset=true
    [[ "$c" == *"delete allow 22/tcp"* ]] && found_ssh_broad_delete=true
done
assert_eq "false" "$found_reset" "setup_ufw: active marker repair — no firewall reset"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: active marker repair — preserves broad SSH allow"
assert_contains "$DOCKER_RULES" "# MEDIASTACK-DOCKER-RULES" "setup_ufw: active marker repair — writes missing Docker rules block"
assert_contains "$DOCKER_RULES" "-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" "setup_ufw: active marker repair — writes DOCKER-USER jump"
unset -f sudo ufw

# ===========================================================================
# setup_ufw_docker_dedup_hook — injects the dedup block into a stock after.init,
# makes it executable, and is idempotent on re-run. Guards the defect: the jump
# duplicates on every ufw reload unless after.init trims it back to one.
# ===========================================================================

DEDUP_TMP=$(mktemp -d)
MEDIASTACK_UFW_AFTER_INIT="$DEDUP_TMP/after.init"

# Seed the stock Canonical after.init sample (mode 640, not executable).
cat >"$MEDIASTACK_UFW_AFTER_INIT" <<'STOCK'
#!/bin/sh
set -e
case "$1" in
start)
    # typically required
    ;;
stop)
    # typically required
    ;;
*)
    echo "'$1' not supported"
    ;;
esac
STOCK
chmod 640 "$MEDIASTACK_UFW_AFTER_INIT"

# Passthrough sudo for file ops; no-op the iptables calls and the after.init
# self-invocation ("sudo $after_init start", whose $1 is a path, not a command).
sudo() {
    case "${1:-}" in
        test | grep | awk | tee | chmod | sed | rm | cat | mktemp) command "$@" ;;
        iptables) return 0 ;;
        *) return 0 ;;
    esac
}

# Capture state writes: the inject path must record CREATED=false so a later
# uninstall strips only our block instead of rm-ing the (pre-existing) file.
DEDUP_STATE=()
_ms_state_set() { DEDUP_STATE+=("$1=$2"); }

setup_ufw_docker_dedup_hook

# Block injected inside the start) arm (before its ;;), file now executable.
if grep -q 'MEDIASTACK-DOCKER-DEDUP' "$MEDIASTACK_UFW_AFTER_INIT"; then
    pass "dedup hook: injects MEDIASTACK-DOCKER-DEDUP block into after.init"
else
    fail "dedup hook: injects MEDIASTACK-DOCKER-DEDUP block into after.init" \
        "$(cat "$MEDIASTACK_UFW_AFTER_INIT")"
fi
assert_contains "$(cat "$MEDIASTACK_UFW_AFTER_INIT")" \
    "iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" \
    "dedup hook: block carries the trim command"
[[ -x "$MEDIASTACK_UFW_AFTER_INIT" ]] \
    && pass "dedup hook: makes after.init executable" \
    || fail "dedup hook: makes after.init executable" "not executable"
# Emitted after.init must stay valid POSIX sh.
sh -n "$MEDIASTACK_UFW_AFTER_INIT" \
    && pass "dedup hook: emitted after.init is valid POSIX sh" \
    || fail "dedup hook: emitted after.init is valid POSIX sh" "$(cat "$MEDIASTACK_UFW_AFTER_INIT")"
# The block sits inside the start) arm, not appended after esac.
if awk '/^[[:space:]]*start\)/{s=1} /MEDIASTACK-DOCKER-DEDUP/{if(s&&!e)ok=1} /^esac/{e=1} END{exit !ok}' \
    "$MEDIASTACK_UFW_AFTER_INIT"; then
    pass "dedup hook: block lives inside the start) arm (before esac)"
else
    fail "dedup hook: block lives inside the start) arm (before esac)" \
        "$(cat "$MEDIASTACK_UFW_AFTER_INIT")"
fi
# Inject path recorded CREATED=false — otherwise a stale =true from an earlier
# created-install would make uninstall rm an admin-owned after.init.
if printf '%s\n' "${DEDUP_STATE[@]}" | grep -qx 'UFW_AFTER_INIT_CREATED=false'; then
    pass "dedup hook: inject path records CREATED=false (uninstall strips, never rm's admin file)"
else
    fail "dedup hook: inject path records CREATED=false (uninstall strips, never rm's admin file)" \
        "state writes: ${DEDUP_STATE[*]:-<none>}"
fi

# Idempotent re-run: marker present -> no second copy.
setup_ufw_docker_dedup_hook
occ=$(grep -c '^# >>> MEDIASTACK-DOCKER-DEDUP' "$MEDIASTACK_UFW_AFTER_INIT")
assert_eq "1" "$occ" "dedup hook: idempotent re-run does not duplicate the block"

# Custom after.init without a stock start) arm -> warn + skip, never edit.
cat >"$MEDIASTACK_UFW_AFTER_INIT" <<'CUSTOM'
#!/bin/sh
# admin's own hook, no start) case
iptables -N MY-CHAIN 2>/dev/null || true
CUSTOM
chmod 640 "$MEDIASTACK_UFW_AFTER_INIT"
setup_ufw_docker_dedup_hook
if grep -q 'MEDIASTACK-DOCKER-DEDUP' "$MEDIASTACK_UFW_AFTER_INIT"; then
    fail "dedup hook: leaves a custom after.init untouched" "$(cat "$MEDIASTACK_UFW_AFTER_INIT")"
else
    pass "dedup hook: leaves a custom after.init untouched"
fi

unset -f sudo
_ms_state_set() { :; }
unset DEDUP_STATE
rm -rf "$DEDUP_TMP"
unset MEDIASTACK_UFW_AFTER_INIT
MEDIASTACK_UFW_AFTER_INIT=/etc/ufw/after.init

# ===========================================================================
# setup_ufw — active service marker reloads persisted rules when live jump is missing
# ===========================================================================

UFW_TRACE=$(mktemp)
UFW_RELOADED="$UFW_TRACE.reloaded"
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        elif [[ "${2:-}" == "reload" ]]; then
            touch "$UFW_RELOADED"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        if [[ "${2:-}" == "-L" ]]; then
            return 0
        fi
        if [[ "${2:-}" == "-C" ]]; then
            [[ -f "$UFW_RELOADED" ]]
            return $?
        fi
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() { :; }

setup_ufw
ufw_trace_text=$(cat "$UFW_TRACE")

if echo "$ufw_trace_text" | grep -Fq "ufw --force reset"; then
    fail "setup_ufw: live jump repair — no firewall reset" "$ufw_trace_text"
else
    pass "setup_ufw: live jump repair — no firewall reset"
fi
if echo "$ufw_trace_text" | grep -Fq "tee -a /etc/ufw/after.rules"; then
    fail "setup_ufw: live jump repair — reuses persisted Docker rules" "$ufw_trace_text"
else
    pass "setup_ufw: live jump repair — reuses persisted Docker rules"
fi
if echo "$ufw_trace_text" | grep -Fq "ufw reload"; then
    pass "setup_ufw: live jump repair — reloads UFW to restore DOCKER-USER jump"
else
    fail "setup_ufw: live jump repair — reloads UFW to restore DOCKER-USER jump" "$ufw_trace_text"
fi
rm -f "$UFW_TRACE" "$UFW_RELOADED"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — active service marker surfaces UFW reload errors
# ===========================================================================

UFW_TRACE=$(mktemp)
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        elif [[ "${2:-}" == "reload" ]]; then
            echo "ERROR: problem running ufw-init" >&2
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        return 0
    fi
    return 0
}
ufw() { :; }

ufw_output=$(setup_ufw 2>&1)
ufw_rc=$?
assert_eq "1" "$ufw_rc" "setup_ufw: reload error repair — surfaces failure"
assert_contains "$ufw_output" "ERROR: problem running ufw-init" "setup_ufw: reload error repair — reports ufw-init failure"
if grep -Fq "ufw --force reset" "$UFW_TRACE"; then
    fail "setup_ufw: reload error repair — no firewall reset" "$(cat "$UFW_TRACE")"
else
    pass "setup_ufw: reload error repair — no firewall reset"
fi
rm -f "$UFW_TRACE"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — active service marker surfaces a missing live jump after reload
# ===========================================================================

UFW_TRACE=$(mktemp)
sudo() {
    printf '%s\n' "$*" >>"$UFW_TRACE"
    if [[ "${1:-}" == "ufw" ]]; then
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "45876/tcp                  ALLOW       172.16.0.0/12"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 0
    fi
    if [[ "${1:-}" == "iptables" ]]; then
        if [[ "${2:-}" == "-L" ]]; then
            return 0
        fi
        if [[ "${2:-}" == "-C" ]]; then
            return 1
        fi
    fi
    if [[ "${1:-}" == "tee" ]]; then
        cat >/dev/null
        return 0
    fi
    return 0
}
ufw() { :; }
log_warn() { echo "$*"; }

ufw_output=$(setup_ufw 2>&1)
ufw_rc=$?
assert_eq "1" "$ufw_rc" "setup_ufw: missing jump after reload — surfaces failure"
assert_contains "$ufw_output" "Docker LAN-only restriction jump is still missing" "setup_ufw: missing jump after reload — reports missing jump"
if grep -Fq "ufw reload" "$UFW_TRACE"; then
    pass "setup_ufw: missing jump after reload — attempted UFW reload"
else
    fail "setup_ufw: missing jump after reload — attempted UFW reload" "$(cat "$UFW_TRACE")"
fi
rm -f "$UFW_TRACE"
log_warn() { :; }
unset -f sudo ufw

# ===========================================================================
# setup_ufw — reentrancy (day-2 OFF -> ON): the mediastack UFW toggle resets
# UFW_DEFAULTS_APPLIED on the OFF path precisely so a later ON reconfigures.
# A stale "true" latch + non-'deny allow' defaults (what a full _uninstall_ufw
# leaves behind) trips the early-return guard and the firewall never comes back.
# ===========================================================================

# Case A: post-reset ledger (UFW_DEFAULTS_APPLIED=false) -> setup_ufw proceeds.
UFW_CALLS=()
_ms_state_get() { echo false; } # reset latch
_ufw_defaults() { echo ""; }    # inactive UFW reports no defaults
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        [[ "${2:-}" == "status" ]] && echo "Status: inactive"
        return 0
    fi
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}
SSH_CONNECTION=""
setup_ufw
found_configure=false
for c in "${UFW_CALLS[@]}"; do [[ "$c" == *"default deny incoming"* ]] && found_configure=true; done
assert_eq "true" "$found_configure" "setup_ufw: reentrancy — reset latch (DEFAULTS_APPLIED=false) lets a re-enable reconfigure"
unset -f sudo ufw _ms_state_get _ufw_defaults

# Case B: stale latch (UFW_DEFAULTS_APPLIED=true) + non-'deny allow' defaults
# -> early return, no reconfigure (this is the bug the OFF-path reset avoids).
UFW_CALLS=()
_ms_state_get() { [[ "$1" == "UFW_DEFAULTS_APPLIED" ]] && echo true || echo false; }
_ufw_defaults() { echo "allow allow"; }
sudo() {
    [[ "${1:-}" == "ufw" ]] && UFW_CALLS+=("$*")
    return 0
}
ufw() {
    UFW_CALLS+=("ufw $*")
    return 0
}
setup_ufw
ufw_rc=$?
found_configure=false
for c in "${UFW_CALLS[@]}"; do [[ "$c" == *"default deny incoming"* ]] && found_configure=true; done
assert_eq "0" "$ufw_rc" "setup_ufw: reentrancy — stale latch returns cleanly (leaves UFW unchanged)"
assert_eq "false" "$found_configure" "setup_ufw: reentrancy — stale latch (DEFAULTS_APPLIED=true) blocks reconfigure (why OFF must reset it)"
unset -f sudo ufw _ms_state_get _ufw_defaults
# Restore the module-level ledger stubs for the tests below.
_ms_state_set() { :; }
_ms_state_get() { echo false; }

# ===========================================================================
# setup_ufw — fresh path (verify correct ufw commands called)
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: inactive"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        DOCKER_RULES="$(cat)"
        return 0
    fi
    return 0
}

UFW_CALLS=()
setup_ufw

found_reset=false
found_enable=false
found_8096=false
found_3000=false
found_45876=false
found_ssh_broad=false
found_ssh_10=false
found_ssh_172=false
found_ssh_192=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"--force reset"* ]] && found_reset=true
    [[ "$c" == *"--force enable"* ]] && found_enable=true
    [[ "$c" == *"8096/tcp"* ]] && found_8096=true
    [[ "$c" == *"3000/tcp"* ]] && found_3000=true
    [[ "$c" == *"45876"* ]] && found_45876=true
    [[ "$c" == "ufw allow 22/tcp"* ]] && found_ssh_broad=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 22 proto tcp"* ]] && found_ssh_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 22 proto tcp"* ]] && found_ssh_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 22 proto tcp"* ]] && found_ssh_192=true
done
assert_eq "false" "$found_reset" "setup_ufw: fresh path — preserves pre-existing UFW rules"
assert_eq "true" "$found_enable" "setup_ufw: fresh path — ufw enable called"
assert_eq "false" "$found_8096" "setup_ufw: fresh path — Jellyfin 8096 not directly allowed"
assert_eq "false" "$found_3000" "setup_ufw: fresh path — Homepage 3000 not directly allowed"
assert_eq "true" "$found_45876" "setup_ufw: fresh path — Beszel bridge marker allowed"
assert_eq "false" "$found_ssh_broad" "setup_ufw: fresh path — SSH is not open to all sources"
assert_eq "true" "$found_ssh_10" "setup_ufw: fresh path — SSH allows 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: fresh path — SSH allows 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: fresh path — SSH allows 192.168.0.0/16"
assert_contains "$DOCKER_RULES" "8096,3000 -j DROP" "setup_ufw: Docker rules block Jellyfin and Homepage from WAN"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — fresh path preserves the active public SSH client
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: inactive"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        DOCKER_RULES="$(cat)"
        return 0
    fi
    return 0
}

SSH_CONNECTION="198.51.100.10 55123 192.0.2.20 2222"
UFW_CALLS=()
setup_ufw

found_2222_broad=false
found_2222_10=false
found_2222_172=false
found_2222_192=false
found_active_client=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == "ufw allow 2222/tcp"* ]] && found_2222_broad=true
    [[ "$c" == *"allow from 10.0.0.0/8 to any port 2222 proto tcp"* ]] && found_2222_10=true
    [[ "$c" == *"allow from 172.16.0.0/12 to any port 2222 proto tcp"* ]] && found_2222_172=true
    [[ "$c" == *"allow from 192.168.0.0/16 to any port 2222 proto tcp"* ]] && found_2222_192=true
    [[ "$c" == *"allow from 198.51.100.10 to any port 2222 proto tcp"* ]] && found_active_client=true
done
assert_eq "false" "$found_2222_broad" "setup_ufw: active public SSH — server port is not open to all sources"
assert_eq "true" "$found_2222_10" "setup_ufw: active public SSH — non-standard port allows 10.0.0.0/8"
assert_eq "true" "$found_2222_172" "setup_ufw: active public SSH — non-standard port allows 172.16.0.0/12"
assert_eq "true" "$found_2222_192" "setup_ufw: active public SSH — non-standard port allows 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: active public SSH — preserves current non-private client IP"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — fresh path does not add redundant exact rules for LAN SSH clients
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: inactive"
        fi
        return 0
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        DOCKER_RULES="$(cat)"
        return 0
    fi
    return 0
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SSH_CONNECTION="192.168.1.50 55123 192.168.1.20 2222"
UFW_CALLS=()
setup_ufw

found_lan_exact=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"allow from 192.168.1.50 to any port 2222 proto tcp"* ]] && found_lan_exact=true
done
assert_eq "false" "$found_lan_exact" "setup_ufw: active LAN SSH — RFC1918 rule covers client without exact host allow"
unset -f sudo
unset SSH_CONNECTION

# ===========================================================================
# setup_unattended_upgrades — skip path (marker present)
# ===========================================================================

sudo() {
    if [[ "${1:-}" == "grep" ]]; then
        shift
        if [[ "$*" == *"MediaStack"* ]]; then
            return 0
        fi
        return 1
    fi
    return 0
}

UPGRADES_WRITTEN=false
setup_unattended_upgrades
assert_eq "false" "$UPGRADES_WRITTEN" "setup_unattended_upgrades: skip when marker present"
unset -f sudo

# ===========================================================================
# setup_unattended_upgrades — fresh path
# ===========================================================================

WRITTEN_FILES=()
sudo() {
    if [[ "${1:-}" == "test" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "grep" ]]; then
        return 1
    fi
    if [[ "${1:-}" == "tee" ]]; then
        WRITTEN_FILES+=("$2")
        cat >/dev/null
        return 0
    fi
    return 0
}

WRITTEN_FILES=()
setup_unattended_upgrades

found_auto=false
found_policy=false
for f in "${WRITTEN_FILES[@]}"; do
    [[ "$f" == *"21mediastack-auto-upgrades"* ]] && found_auto=true
    [[ "$f" == *"51mediastack-unattended-upgrades"* ]] && found_policy=true
done
assert_eq "true" "$found_auto" "setup_unattended_upgrades: fresh — writes owned periodic drop-in"
assert_eq "true" "$found_policy" "setup_unattended_upgrades: fresh — writes owned policy drop-in"
unset -f sudo

# ===========================================================================
# setup_sysctl_hardening — skip path (conf exists)
# ===========================================================================

# Simulate conf file exists by overriding the [[ -f ]] test through a temp file
SYSCTL_TMPDIR=$(mktemp -d)
SYSCTL_CONF="$SYSCTL_TMPDIR/90-mediastack-hardening.conf"
touch "$SYSCTL_CONF"

# We need to test the function's own [[ -f ]] check.
# Patch the conf path by redefining the function with the temp path.
_orig_setup_sysctl_hardening=$(declare -f setup_sysctl_hardening)
eval "setup_sysctl_hardening_skip_test() {
    local conf=\"$SYSCTL_CONF\"
    if [[ -f \"\$conf\" ]]; then
        log_skip \"Sysctl hardening already applied\"
        return
    fi
    # Should not reach here in skip test
    SYSCTL_FRESH_RAN=true
}"

SYSCTL_FRESH_RAN=false
setup_sysctl_hardening_skip_test
assert_eq "false" "$SYSCTL_FRESH_RAN" "setup_sysctl_hardening: skip when conf exists"

rm -rf "$SYSCTL_TMPDIR"

# ===========================================================================
# setup_sysctl_hardening — fresh path
# ===========================================================================

SYSCTL_TMPDIR=$(mktemp -d)
SYSCTL_CONF="$SYSCTL_TMPDIR/90-mediastack-hardening.conf"
# Don't create the file — simulate fresh

SYSCTL_CALLS=()
sudo() {
    if [[ "${1:-}" == "tee" ]]; then
        cat >"$2" 2>/dev/null || cat >/dev/null
        SYSCTL_CALLS+=("tee $2")
        return 0
    fi
    if [[ "${1:-}" == "sysctl" ]]; then
        SYSCTL_CALLS+=("sysctl $2")
        return 0
    fi
    return 0
}

eval "setup_sysctl_hardening_fresh_test() {
    local conf=\"$SYSCTL_CONF\"
    if [[ -f \"\$conf\" ]]; then
        log_skip \"Sysctl hardening already applied\"
        return
    fi
    log_info \"Applying kernel hardening (sysctl)...\"
    sudo tee \"\$conf\" >/dev/null <<'SYSEOF'
net.ipv4.tcp_syncookies = 1
SYSEOF
    sudo sysctl --system >/dev/null 2>&1
    log_ok \"Kernel hardening applied\"
}"

setup_sysctl_hardening_fresh_test

found_tee=false
found_sysctl=false
for c in "${SYSCTL_CALLS[@]}"; do
    [[ "$c" == *"tee"* ]] && found_tee=true
    [[ "$c" == *"sysctl"* ]] && found_sysctl=true
done
assert_eq "true" "$found_tee" "setup_sysctl_hardening: fresh — writes conf file"
assert_eq "true" "$found_sysctl" "setup_sysctl_hardening: fresh — calls sysctl --system"

rm -rf "$SYSCTL_TMPDIR"
unset -f sudo

# ===========================================================================
# verify_gpu_runtime — GPU_TYPE=none (immediate return)
# ===========================================================================

NVIDIA_CTK_CALLED=false
sudo() {
    if [[ "${1:-}" == "nvidia-ctk" ]]; then
        NVIDIA_CTK_CALLED=true
    fi
    return 0
}

GPU_TYPE="none"
verify_gpu_runtime
assert_eq "false" "$NVIDIA_CTK_CALLED" "verify_gpu_runtime: GPU_TYPE=none — no action"
unset -f sudo

# ===========================================================================
# verify_gpu_runtime — GPU_TYPE=nvidia + valid daemon.json
# ===========================================================================

DAEMON_JSON_TMP=$(mktemp)
cat >"$DAEMON_JSON_TMP" <<'JSON'
{
    "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
JSON

# Override the function to use our temp path
eval "verify_gpu_runtime_valid_test() {
    [[ \"\${GPU_TYPE:-none}\" != \"nvidia\" ]] && return
    local daemon_json=\"$DAEMON_JSON_TMP\"
    if [[ ! -f \"\$daemon_json\" ]]; then
        return
    fi
    local has_nvidia
    has_nvidia=\$(python3 -c \"
import json, sys
with open('\$daemon_json') as f:
    d = json.load(f)
runtimes = d.get('runtimes', {})
if 'nvidia' in runtimes:
    sys.exit(0)
sys.exit(1)
\" 2>/dev/null && echo \"yes\" || echo \"no\")
    GPU_RUNTIME_RESULT=\"\$has_nvidia\"
}"

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
GPU_TYPE="nvidia"
GPU_RUNTIME_RESULT=""
verify_gpu_runtime_valid_test
assert_eq "yes" "$GPU_RUNTIME_RESULT" "verify_gpu_runtime: nvidia + valid daemon.json"

rm -f "$DAEMON_JSON_TMP"

# ===========================================================================
# setup_samba — point the file paths at writable tmpfs locations so the tests
# can drive the cleanup/idempotency branches that depend on file existence.
# ===========================================================================
SAMBA_TMP=$(mktemp -d)
SAMBA_INCLUDE_FILE="$SAMBA_TMP/mediastack.conf"
SAMBA_MAIN_CONF="$SAMBA_TMP/smb.conf"

# ===========================================================================
# setup_samba — SMB_ENABLED=false, no prior install (immediate return)
# ===========================================================================

SAMBA_CALLS=()
sudo() {
    SAMBA_CALLS+=("$*")
    return 0
}
systemctl() {
    SAMBA_CALLS+=("systemctl $*")
    return 0
}

rm -f "$SAMBA_INCLUDE_FILE"
SMB_ENABLED="false"
SAMBA_CALLS=()
setup_samba
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: SMB_ENABLED=false + no include file — no action"
unset -f sudo systemctl

# ===========================================================================
# setup_samba — SMB_ENABLED=false WITH a prior install present (cleanup path)
# Bug we're guarding against: the early-return historically left orphaned
# MediaStack stanzas in /etc/samba/smb.conf on reinstall with SMB=no. New
# behavior: rm the include file. The dangling `include = …` line in main
# smb.conf is intentionally left in place — samba tolerates a missing include
# with just a warning, and a future SMB_ENABLED=true install reuses the path.
# ===========================================================================

mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
cat >"$SAMBA_INCLUDE_FILE" <<'EOF'
[Media]
   path = /
EOF
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP
   security = user

# Pre-existing user share — must NOT be touched by cleanup
[UserShare]
   path = /home/user/share
   read only = no

# MEDIASTACK include — managed by setup.sh
include = $SAMBA_INCLUDE_FILE
EOF

sudo() {
    case "${1:-}" in
        rm)
            shift
            command rm "$@"
            return 0
            ;;
        systemctl) return 0 ;;
        *) return 0 ;;
    esac
}

SMB_ENABLED="false"
setup_samba

[[ ! -f "$SAMBA_INCLUDE_FILE" ]] \
    && pass "setup_samba: cleanup removes mediastack.conf include file" \
    || fail "setup_samba: cleanup removes mediastack.conf include file" "still present"

if grep -Fq '[UserShare]' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'path = /home/user/share' "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: cleanup preserves pre-existing user [UserShare] section"
else
    fail "setup_samba: cleanup preserves pre-existing user [UserShare] section" \
        "lost user content:\n$(cat "$SAMBA_MAIN_CONF")"
fi

unset -f sudo

# ===========================================================================
# setup_samba — skip path (include file present + include line in main conf)
# Idempotency: re-running on an already-configured host must do no work.
# ===========================================================================

mkdir -p "$(dirname "$SAMBA_INCLUDE_FILE")"
cat >"$SAMBA_INCLUDE_FILE" <<'EOF'
[Media]
   path = /data
EOF
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP

# MEDIASTACK include — managed by setup.sh
include = $SAMBA_INCLUDE_FILE
EOF

SAMBA_CALLS=()
sudo() {
    if [[ "${1:-}" == "grep" ]]; then
        shift
        command grep "$@"
        return $?
    fi
    SAMBA_CALLS+=("$*")
    return 0
}
# Stub smbd so `command -v smbd` short-circuits the install-samba branch
# that otherwise pollutes SAMBA_CALLS with an apt-get call on hosts where
# samba isn't installed. See note in the fresh-path test.
smbd() { :; }

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="true"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DATA_DIR="/data"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
PGID="1000"
setup_samba
# Skip path runs ONLY the grep idempotency check, then returns. No useradd,
# no tee, no systemctl, no ufw — which means SAMBA_CALLS stays empty.
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: skip when include file + include line both present"
unset -f sudo smbd

# Regression: idempotency keys on the functional `include = <path>` line, NOT a
# decorative comment marker. An existing install whose main smb.conf has the
# include line but no (or a differently-punctuated) comment must still be
# detected as already-configured — a prose marker's em-dash was once a fragile
# byte-exact grep target that silently broke this.
cat >"$SAMBA_MAIN_CONF" <<EOF
[global]
   workgroup = WORKGROUP

include = $SAMBA_INCLUDE_FILE
EOF
SAMBA_CALLS=()
sudo() {
    if [[ "${1:-}" == "grep" ]]; then
        shift
        command grep "$@"
        return $?
    fi
    SAMBA_CALLS+=("$*")
    return 0
}
smbd() { :; }
SMB_ENABLED="true"
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
DATA_DIR="/data"
PGID="1000"
setup_samba
assert_eq "0" "${#SAMBA_CALLS[@]}" "setup_samba: skip is comment-independent (detects bare include line, no marker)"
unset -f sudo smbd

# A matching include from an interrupted run must resume the remaining
# idempotent work instead of taking the completed-install fast path forever.
PENDING_HASH=$(sha256sum "$SAMBA_INCLUDE_FILE" | awk '{print $1}')
PENDING_CALLS=()
PENDING_STATE=()
_ms_state_get() {
    case "$1" in
        SAMBA_SETUP_PENDING | SAMBA_OWNERSHIP_RECORDED | SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK) echo true ;;
        SAMBA_USER) echo testadmin ;;
        SAMBA_PASSDB_PREEXISTED | SAMBA_GROUP_PREEXISTED) echo false ;;
        SAMBA_GROUP) echo media ;;
        SAMBA_INCLUDE_SHA256) echo "$PENDING_HASH" ;;
    esac
}
_ms_state_set() { PENDING_STATE+=("$1=$2"); }
sudo() {
    case "${1:-}" in
        grep | install | tee | sha256sum) command "$@" ;;
        pdbedit) return 0 ;;
        testparm) echo effective ;;
        systemctl | ufw)
            PENDING_CALLS+=("$*")
            return 0
            ;;
        *) return 0 ;;
    esac
}
smbd() { :; }
id() {
    [[ "${1:-}" == -nG ]] && echo media
    return 0
}
getent() { echo 'media:x:1000:'; }
SMB_ENABLED=true
JELLYFIN_ADMIN_USER=testadmin
JELLYFIN_ADMIN_PASSWORD=testpass
DATA_DIR=/data
PGID=1000
setup_samba
assert_contains "${PENDING_CALLS[*]}" "systemctl enable --now smbd" \
    "setup_samba: interrupted matching config resumes remaining work"
assert_contains "${PENDING_STATE[*]}" "SAMBA_SETUP_PENDING=false" \
    "setup_samba: successful resume clears the pending ledger state"
unset -f sudo smbd id getent
_ms_state_get() { echo false; }
_ms_state_set() { :; }

# ===========================================================================
# setup_samba — fresh path: writes include file (NOT main smb.conf) + appends
# the include line to main conf without overwriting it.
# Bug we're guarding against: the prior implementation `sudo tee smb.conf`
# (no -a) overwrote the entire file, destroying any pre-existing user samba
# config. New behavior must write to the include file and append-only.
# ===========================================================================

# Seed main smb.conf with pre-existing user content that must survive.
rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
   security = user

[UserShare]
   path = /home/user/share
   read only = no
EOF
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SAMBA_MAIN_BEFORE_BYTES=$(wc -c <"$SAMBA_MAIN_CONF")

SAMBA_CALLS=()
sudo() {
    case "${1:-}" in
        grep)
            shift
            command grep "$@"
            return $?
            ;;
        useradd)
            SAMBA_CALLS+=("useradd")
            return 0
            ;;
        usermod)
            SAMBA_CALLS+=("usermod")
            return 0
            ;;
        install)
            shift
            command install "$@"
            return 0
            ;;
        # `sudo tee` here also runs from inside the right side of a pipe
        # (`printf … | sudo tee -a $main`). Pipe RHS executes in a subshell,
        # so any `SAMBA_CALLS+=(…)` we'd add inside the function would be
        # invisible to the parent. We rely on the file-content assertions
        # below to verify the include-line append, instead of capturing the
        # call into the array.
        tee)
            shift
            command tee "$@" >/dev/null
            return 0
            ;;
        smbpasswd)
            shift
            smbpasswd "$@"
            return $?
            ;;
        pdbedit) return 1 ;;
        systemctl)
            SAMBA_CALLS+=("systemctl $2")
            return 0
            ;;
        ufw)
            SAMBA_CALLS+=("ufw $*")
            return 0
            ;;
        *) return 0 ;;
    esac
}
# `command -v smbd` is consulted before the install path; on hosts without
# samba installed (e.g. the dev box running this test) it returns 1 and
# triggers a `sudo apt-get install`. Stubbing smbd as a function makes
# `command -v smbd` succeed (functions are visible to `command -v`) so the
# install-path check stays a no-op and doesn't pollute SAMBA_CALLS.
smbd() { :; }
smbpasswd() {
    SAMBA_CALLS+=("smbpasswd")
    return 0
}
id() {
    if [[ "${1:-}" == "-u" || "${1:-}" == "-g" ]]; then
        echo "1000"
        return 0
    fi
    return 1
}
getent() {
    if [[ "${1:-}" == "group" ]]; then
        echo "mediaadmin:x:1000:"
        return 0
    fi
    return 1
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_ENABLED="true"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
JELLYFIN_ADMIN_USER="testadmin"
JELLYFIN_ADMIN_PASSWORD="testpass"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DATA_DIR="/data"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
PGID="1000"

SAMBA_CALLS=()
setup_samba

# Ergonomic checks via captured calls — these all happen in the function's
# own process so SAMBA_CALLS sees them. The two tee invocations are NOT
# captured (one runs via heredoc, one runs in a pipe subshell — neither
# can write back to the parent's array). File-content assertions below
# cover the actual write behavior.
found_useradd=false
found_systemctl=false
found_ufw=false
for c in "${SAMBA_CALLS[@]}"; do
    [[ "$c" == "useradd" ]] && found_useradd=true
    [[ "$c" == *"systemctl enable"* ]] && found_systemctl=true
    [[ "$c" == *"ufw"*"445"* ]] && found_ufw=true
done
assert_eq "true" "$found_useradd" "setup_samba: fresh — creates system user"
assert_eq "true" "$found_systemctl" "setup_samba: fresh — enables smbd"
assert_eq "true" "$found_ufw" "setup_samba: fresh — adds UFW rules for port 445"

# Belt-and-braces: explicitly verify the user's pre-existing content survived.
if grep -Fq '[UserShare]' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'path = /home/user/share' "$SAMBA_MAIN_CONF" \
    && grep -Fq 'workgroup = HOMEUSER' "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: fresh — user's pre-existing smb.conf content survived"
else
    fail "setup_samba: fresh — user's pre-existing smb.conf content survived" \
        "main conf after install:\n$(cat "$SAMBA_MAIN_CONF")"
fi

# And the include line was actually appended.
if grep -Fxq "include = $SAMBA_INCLUDE_FILE" "$SAMBA_MAIN_CONF"; then
    pass "setup_samba: fresh — include line present in main smb.conf"
else
    fail "setup_samba: fresh — include line present in main smb.conf" \
        "no match in:\n$(cat "$SAMBA_MAIN_CONF")"
fi

if grep -Fxq "   path = /data" "$SAMBA_INCLUDE_FILE"; then
    pass "setup_samba: fresh — default SMB scope shares DATA_DIR"
else
    fail "setup_samba: fresh — default SMB scope shares DATA_DIR" \
        "include file:\n$(cat "$SAMBA_INCLUDE_FILE")"
fi

# Backslash escapes in the shared admin password must pass through to
# smbpasswd literally. `smbpasswd -s` reads two newline-delimited password
# entries from stdin; interpreting `\n`, `\t`, `\c`, or `\\` changes the
# password before Samba receives it.
rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
EOF
SMB_SHARE_SCOPE="data"
JELLYFIN_ADMIN_PASSWORD='alpha\nbravo\tcharlie\cdelta\\end'
SMB_PASS_STDIN="$SAMBA_TMP/smbpasswd.stdin"
SMB_PASS_EXPECTED="$SAMBA_TMP/smbpasswd.expected"
smbpasswd() {
    cat >"$SMB_PASS_STDIN"
    return 0
}

setup_samba
printf '%s\n%s\n' "$JELLYFIN_ADMIN_PASSWORD" "$JELLYFIN_ADMIN_PASSWORD" >"$SMB_PASS_EXPECTED"
if cmp -s "$SMB_PASS_EXPECTED" "$SMB_PASS_STDIN"; then
    pass "setup_samba: fresh — smbpasswd receives passwords with backslashes literally"
else
    fail "setup_samba: fresh — smbpasswd receives passwords with backslashes literally" \
        "expected:\n$(od -An -tx1 -c "$SMB_PASS_EXPECTED")\nactual:\n$(od -An -tx1 -c "$SMB_PASS_STDIN")"
fi
unset SMB_SHARE_SCOPE

rm -f "$SAMBA_INCLUDE_FILE"
cat >"$SAMBA_MAIN_CONF" <<'EOF'
[global]
   workgroup = HOMEUSER
EOF
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
SMB_SHARE_SCOPE="system"
setup_samba
if grep -Fxq "[MediaStackSystem]" "$SAMBA_INCLUDE_FILE" \
    && grep -Fxq "   path = /" "$SAMBA_INCLUDE_FILE"; then
    pass "setup_samba: system SMB scope keeps full filesystem access explicit"
else
    fail "setup_samba: system SMB scope keeps full filesystem access explicit" \
        "include file:\n$(cat "$SAMBA_INCLUDE_FILE")"
fi
unset SMB_SHARE_SCOPE

unset -f sudo smbpasswd id getent
rm -rf "$SAMBA_TMP"

# ===========================================================================
# setup_ufw_service_ports — opens torrent + VPN ports from .env
# ===========================================================================

UFW_CALLS=()
ufw() { :; }
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        return 0
    fi
    return 0
}

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
TORRENT_PORT="50000"
DOMAIN="media.example.com"
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
WG_PORT="51999"

UFW_CALLS=()
setup_ufw_service_ports

found_torrent_tcp=false
found_torrent_udp=false
found_wg=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"50000/tcp"* ]] && found_torrent_tcp=true
    [[ "$c" == *"50000/udp"* ]] && found_torrent_udp=true
    [[ "$c" == *"51999/udp"* ]] && found_wg=true
done
assert_eq "true" "$found_torrent_tcp" "setup_ufw_service_ports: opens custom torrent TCP port"
assert_eq "true" "$found_torrent_udp" "setup_ufw_service_ports: opens custom torrent UDP port"
assert_eq "true" "$found_wg" "setup_ufw_service_ports: opens custom WireGuard port when domain set"

# Without domain — WireGuard port should not be opened
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
DOMAIN="example.com"
UFW_CALLS=()
setup_ufw_service_ports

found_wg_nodomain=false
for c in "${UFW_CALLS[@]}"; do
    [[ "$c" == *"51999/udp"* ]] && found_wg_nodomain=true
done
assert_eq "false" "$found_wg_nodomain" "setup_ufw_service_ports: skips WireGuard port without domain"
unset -f sudo ufw

echo -e "${CYAN}◀ hardening done${NC}"
summary
