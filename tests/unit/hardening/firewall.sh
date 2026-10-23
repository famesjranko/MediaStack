# Owns: UFW, SSH, and Docker firewall behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/firewall.sh.

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
assert_eq "false" "$found_tee" "setup_ufw: skip path — no after.rules write"
assert_eq "true" "$found_ssh_10" "setup_ufw: skip path — repairs active SSH port allow for 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: skip path — repairs active SSH port allow for 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: skip path — repairs active SSH port allow for 192.168.0.0/16"
assert_eq "true" "$found_active_client" "setup_ufw: skip path — preserves current non-private SSH client IP"
assert_eq "false" "$found_ssh_broad_delete" "setup_ufw: skip path — preserves pre-existing broad SSH allow"
unset -f sudo ufw
unset SSH_CONNECTION

# ===========================================================================
# setup_ufw — never writes the admin-port filter into after.rules/after6.rules
# (the filter is admin-filter.sh's, UFW on or off)
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
DOCKER6_RULES=""
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
        if [[ "$*" == *after6.rules* ]]; then
            DOCKER6_RULES="$(cat)"
        elif [[ "$*" == *after.rules* ]]; then
            DOCKER_RULES="$(cat)"
        fi
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
# Given UFW is active and neither after file carries a MediaStack block
# When setup_ufw runs
# Then it writes neither file: the admin-port filter is not UFW's
assert_eq "" "$DOCKER_RULES" "setup_ufw: writes no admin-port block to after.rules"
assert_eq "" "$DOCKER6_RULES" "setup_ufw: writes no admin-port block to after6.rules"
unset -f sudo ufw

# ===========================================================================
# setup_ufw — does not reload UFW or look at DOCKER-USER
# ===========================================================================

# Given UFW is configured and Docker's chain has no MediaStack jump
# When setup_ufw runs
# Then it neither reloads UFW (a reload appends jumps behind Docker's RETURN) nor touches iptables
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
    [[ "${1:-}" == "grep" ]] && return 1
    [[ "${1:-}" == "iptables" && "${2:-}" == "-C" ]] && return 1
    [[ "${1:-}" == "tee" ]] && cat >/dev/null
    return 0
}
ufw() { :; }
setup_ufw >/dev/null 2>&1
ufw_trace_text=$(cat "$UFW_TRACE")
assert_not_contains "$ufw_trace_text" "ufw reload" "setup_ufw: never reloads UFW for the admin-port filter"
assert_not_contains "$ufw_trace_text" "iptables" "setup_ufw: never reads or edits DOCKER-USER"
assert_not_contains "$ufw_trace_text" "after.rules" "setup_ufw: never writes after.rules"
assert_not_contains "$ufw_trace_text" "after6.rules" "setup_ufw: never writes after6.rules"
rm -f "$UFW_TRACE"
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
# shellcheck disable=SC2034
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
# setup_ufw — re-run on a host MediaStack already configured
# ===========================================================================

# Given UFW is active with MediaStack's HTTP rule and the deny/allow defaults
# When setup_ufw runs again
# Then it reports the firewall as configured and adds no rule
UFW_CALLS=()
_ufw_defaults() { echo "deny allow"; }
sudo() {
    if [[ "${1:-}" == "ufw" ]]; then
        UFW_CALLS+=("$*")
        if [[ "${2:-}" == "status" ]]; then
            echo "Status: active"
            echo "80/tcp                     ALLOW       Anywhere                   # MediaStack:HTTP-ACME"
        fi
        return 0
    fi
    return 0
}
ufw() { UFW_CALLS+=("ufw $*"); }
log_skip() { echo "SKIP $*"; }
rerun_out=$(setup_ufw 2>&1)
rerun_adds=0
for c in "${UFW_CALLS[@]}"; do [[ "$c" == *" allow "* ]] && rerun_adds=$((rerun_adds + 1)); done
assert_contains "$rerun_out" "UFW already configured" "setup_ufw: re-run — MediaStack's own HTTP rule marks the firewall as configured"
assert_eq "0" "$rerun_adds" "setup_ufw: re-run — no rule is added again"
log_skip() { :; }
unset -f sudo ufw _ufw_defaults

# ===========================================================================
# setup_ufw — fresh path (verify correct ufw commands called)
# ===========================================================================

UFW_CALLS=()
DOCKER_RULES=""
DOCKER6_RULES=""
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
        if [[ "$*" == *after6.rules* ]]; then
            DOCKER6_RULES="$(cat)"
        elif [[ "$*" == *after.rules* ]]; then
            DOCKER_RULES="$(cat)"
        fi
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
assert_eq "false" "$found_45876" "setup_ufw: fresh path — no UFW rule for the Beszel agent (it listens on a unix socket)"
assert_eq "false" "$found_ssh_broad" "setup_ufw: fresh path — SSH is not open to all sources"
assert_eq "true" "$found_ssh_10" "setup_ufw: fresh path — SSH allows 10.0.0.0/8"
assert_eq "true" "$found_ssh_172" "setup_ufw: fresh path — SSH allows 172.16.0.0/12"
assert_eq "true" "$found_ssh_192" "setup_ufw: fresh path — SSH allows 192.168.0.0/16"
assert_eq "" "$DOCKER_RULES$DOCKER6_RULES" "setup_ufw: fresh path — no admin-port rules written to the after files"

# ===========================================================================
# ufw_remove_legacy_beszel_rule — drop MediaStack's unused Beszel agent rule
# ===========================================================================

# Stub: UFW_STATUS_TEXT is what `ufw status numbered` prints; deletes are recorded.
UFW_DELETES=()
UFW_STATUS_TEXT=""
UFW_STATUS_RC=0
sudo() {
    if [[ "${1:-}" == "ufw" && "${2:-}" == "status" ]]; then
        printf '%s\n' "$UFW_STATUS_TEXT"
        return "$UFW_STATUS_RC"
    fi
    if [[ "${1:-}" == "ufw" && "${2:-}" == "--force" && "${3:-}" == "delete" ]]; then
        UFW_DELETES+=("$4")
        return 0
    fi
    return 0
}

ufw() { :; }
ACTIVE_HEAD=$'Status: active\n\n     To                         Action      From\n     --                         ------      ----'

# Given UFW is active with the exact MediaStack:Beszel-agent rule among other rules
# When the legacy rule cleanup runs
# Then only that rule is deleted
UFW_DELETES=()
UFW_STATUS_TEXT="$ACTIVE_HEAD
[ 1] 22/tcp                     ALLOW IN    Anywhere
[ 2] 45876/tcp                  ALLOW IN    172.16.0.0/12              # MediaStack:Beszel-agent
[ 3] 443/tcp                    ALLOW IN    Anywhere                   # MediaStack:HTTPS"
ufw_remove_legacy_beszel_rule
assert_eq "2" "${UFW_DELETES[*]}" "legacy beszel rule: the exact MediaStack comment is deleted, nothing else"

# Given another rule on port 45876 that lacks that comment, and one with a similar comment
# When the legacy rule cleanup runs
# Then neither rule is touched
UFW_DELETES=()
UFW_STATUS_TEXT="$ACTIVE_HEAD
[ 1] 45876/tcp                  ALLOW IN    192.168.1.0/24
[ 2] 45876/tcp                  ALLOW IN    10.0.0.0/8                 # my own beszel rule
[ 3] 45876/tcp                  ALLOW IN    10.0.0.0/8                 # MediaStack:Beszel-agent-extra"
ufw_remove_legacy_beszel_rule
assert_eq "0" "${#UFW_DELETES[@]}" "legacy beszel rule: other rules on 45876 are untouched"

# Given UFW is inactive
# When the legacy rule cleanup runs
# Then no delete call is made
UFW_DELETES=()
UFW_STATUS_TEXT="Status: inactive"
ufw_remove_legacy_beszel_rule
assert_eq "0" "${#UFW_DELETES[@]}" "legacy beszel rule: inactive UFW means no delete"

# Given UFW is installed but `ufw status numbered` fails, for example when sudo is refused
# When the legacy rule cleanup runs
# Then it warns, makes no delete call and returns failure
UFW_DELETES=()
UFW_STATUS_TEXT=""
UFW_STATUS_RC=1
log_warn() { echo "WARN $*"; }
_warn_out=$(ufw_remove_legacy_beszel_rule 2>&1)
rc=$?
log_warn() { :; }
UFW_STATUS_RC=0
assert_eq "1" "$rc" "legacy beszel rule: unreadable UFW rules return failure"
assert_eq "0" "${#UFW_DELETES[@]}" "legacy beszel rule: unreadable UFW rules mean no delete"
assert_contains "$_warn_out" "Could not read the UFW rules" "legacy beszel rule: unreadable UFW rules warn"

# Given UFW is active and the rule is already gone
# When the legacy rule cleanup runs twice
# Then no delete call is made and it returns success
UFW_DELETES=()
UFW_STATUS_TEXT="$ACTIVE_HEAD
[ 1] 22/tcp                     ALLOW IN    Anywhere"
ufw_remove_legacy_beszel_rule
rc=$?
ufw_remove_legacy_beszel_rule
assert_eq "0" "$rc" "legacy beszel rule: absent rule returns success"
assert_eq "0" "${#UFW_DELETES[@]}" "legacy beszel rule: absent rule means no delete"

# Given a ledger holding a Beszel-agent rule between two other MediaStack rules
# When the legacy rule cleanup runs on a host where that rule is already gone
# Then the stale entry is dropped and the others are renumbered
# And the ledger key above the new count is deleted
LEDGER=("allow 80/tcp comment MediaStack:HTTP" "allow 45876/tcp comment MediaStack:Beszel-agent" "allow 443/tcp comment MediaStack:HTTPS")
LEDGER_COUNT=3
_ms_state_get() {
    case "$1" in
        UFW_RULE_COUNT) echo "$LEDGER_COUNT" ;;
        UFW_RULE_[0-9]*) echo "${LEDGER[${1#UFW_RULE_} - 1]}" ;;
    esac
}
_ms_state_set() {
    case "$1" in
        UFW_RULE_COUNT) LEDGER_COUNT="$2" ;;
        UFW_RULE_[0-9]*) LEDGER[${1#UFW_RULE_} - 1]="$2" ;;
    esac
}
LEDGER_UNSET=()
_ms_state_unset() { LEDGER_UNSET+=("$1"); }
UFW_DELETES=()
UFW_STATUS_TEXT="$ACTIVE_HEAD
[ 1] 22/tcp                     ALLOW IN    Anywhere"
ufw_remove_legacy_beszel_rule
assert_eq "UFW_RULE_3" "${LEDGER_UNSET[*]}" "legacy beszel rule: ledger key above the new count is deleted"
assert_eq "2" "$LEDGER_COUNT" "legacy beszel rule: ledger count drops by the stale entry"
assert_eq "allow 80/tcp comment MediaStack:HTTP|allow 443/tcp comment MediaStack:HTTPS" "$(IFS='|' && echo "${LEDGER[*]:0:2}")" "legacy beszel rule: other ledger entries kept in order"
_ms_state_set() { :; }
_ms_state_get() { echo false; }

# Given a Debian-like host: ufw exists only at the sbin path, not on PATH
# When the legacy rule cleanup runs
# Then the stale rule is still deleted
UFW_DELETES=()
UFW_STATUS_TEXT="$ACTIVE_HEAD
[ 1] 45876/tcp                  ALLOW IN    172.16.0.0/12              # MediaStack:Beszel-agent"
_sbin_dir=$(mktemp -d)
printf '#!/bin/sh\n' >"$_sbin_dir/ufw"
chmod +x "$_sbin_dir/ufw"
unset -f ufw
_saved_path=$PATH
PATH=/usr/bin:/bin
MS_UFW_SBIN_PATH="$_sbin_dir/ufw" ufw_remove_legacy_beszel_rule
PATH=$_saved_path
rm -rf "$_sbin_dir"
assert_eq "1" "${UFW_DELETES[*]:-}" "legacy beszel rule: found when ufw is only in the sbin directory"
unset -f sudo ufw
unset SSH_CONNECTION

# ===========================================================================

# The admin-port filter (rule source, systemd path, apply script, handover).
source "$HARDENING_TEST_DIR/hardening/admin-filter.sh"
