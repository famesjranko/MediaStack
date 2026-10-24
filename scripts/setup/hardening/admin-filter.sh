# Owns: the admin-port filter chain (rule source of truth), its single systemd install path, the opt-out and uninstall teardown, and the migration off the legacy UFW after.rules blocks and after.init hook.
# Sources: hardening.sh globals (MEDIASTACK_ADMIN_FILTER_*, MEDIASTACK_UFW_AFTER*_RULES) and common.sh logging helpers.
#
# The MEDIASTACK-DOCKER-RESTRICT chain filters traffic that Docker forwards into
# containers, so it cannot lock a host's own SSH out. It does not depend on UFW:
# a systemd oneshot that docker.service Requires= installs it whether UFW is on
# or off. Earlier versions wrote the chain into /etc/ufw/after.rules and
# after6.rules when UFW was on. That path was dropped because of three defects
# proved with real iptables (docs/decisions/admin-port-exposure.md):
#   1. `ufw reload` appends the DOCKER-USER jump behind Docker's `-j RETURN`, so
#      on a running Docker the chain never ran.
#   2. The v4 block did not declare DOCKER-USER, so iptables-restore failed when
#      ufw loaded before Docker.
#   3. Declaring an existing chain under --noflush flushes it.
# setup_admin_filter migrates a host that still has such a block. It also removes
# the after.init hook that trimmed those duplicate jumps: `iptables -D` deletes
# the first match, which is this unit's position-1 jump.
#
# Fail closed. The drop-in gives docker.service Requires= and After= on the
# oneshot. systemd.unit(5), Requires=: "If one of the other units fails to
# activate, and an ordering dependency After= on the failing unit is set, this
# unit will not be started." The oneshot carries no Condition*/Assert* line,
# because the same section says failing condition checks "do not cause the start
# job of a unit with a Requires= dependency on it to fail". It also says an
# explicit stop or restart of the required unit stops or restarts the dependent,
# so setup re-applies by running the script, never by restarting the unit.
#
# Docker never flushes DOCKER-USER (moby libnetwork/firewall_linux.go, v26 to
# v28: "The daemon does not delete or modify any pre-existing rules from the
# DOCKER-USER filter chain"). The ExecStartPost re-check in the drop-in is for a
# different loss: Docker 28 and later can use an nftables backend with no
# DOCKER-USER chain, or a legacy/nft backend split can hide the chain.

MEDIASTACK_ADMIN_FILTER_MARKER="MEDIASTACK-ADMIN-FILTER"

ADMIN_FILTER_CHAIN="MEDIASTACK-DOCKER-RESTRICT"
# iptables -m multiport takes at most 15 ports per match (kernel limit), so the
# TCP list is split in two. Going over fails iptables-restore with "too many
# ports specified" and the apply script fails.
ADMIN_FILTER_TCP_GROUPS=("8989,7878,9117,8080,5055,9000,81,51821" "8000,8090,3001,8191,6767,8096,3000")
# 7359 is Jellyfin's LAN auto-discovery responder: it answers unauthenticated and
# leaks the server URL. The torrent and WireGuard UDP ports stay public.
ADMIN_FILTER_UDP_PORTS="7359"
# Loopback, RFC1918, and Tailscale CGNAT. fd7a:115c:a1e0::/48 sits inside
# fc00::/7; it is listed so the Tailscale scope is visible rather than implied.
ADMIN_FILTER_RETURN_V4=(127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10)
ADMIN_FILTER_RETURN_V6=(::1/128 fc00::/7 fe80::/10 fd7a:115c:a1e0::/48)

# The one opt-out rule, read by setup, the health check, the main-menu warning
# and the day-2 toggle. Only the exact value "false" turns the filter off. A
# typo such as TRUE, yes or "true " must never silently open the admin ports, so
# every other value keeps the filter on (fail closed).
admin_filter_opted_out() { [[ "${ADMIN_PORT_FILTER-}" == "false" ]]; }

# $1 = v4|v6. The chain's rules in iptables-restore syntax: private sources
# RETURN, admin ports DROP for everyone else, the rest RETURN (80, 443, torrent,
# WireGuard pass through).
_admin_filter_rule_lines() {
    local src group
    local -a sources
    if [[ "$1" == "v6" ]]; then sources=("${ADMIN_FILTER_RETURN_V6[@]}"); else sources=("${ADMIN_FILTER_RETURN_V4[@]}"); fi
    for src in "${sources[@]}"; do
        printf -- '-A %s -s %s -j RETURN\n' "$ADMIN_FILTER_CHAIN" "$src"
    done
    for group in "${ADMIN_FILTER_TCP_GROUPS[@]}"; do
        printf -- '-A %s -p tcp -m multiport --dports %s -j DROP\n' "$ADMIN_FILTER_CHAIN" "$group"
    done
    printf -- '-A %s -p udp -m multiport --dports %s -j DROP\n' "$ADMIN_FILTER_CHAIN" "$ADMIN_FILTER_UDP_PORTS"
    printf -- '-A %s -j RETURN\n' "$ADMIN_FILTER_CHAIN"
}

# One iptables-restore payload. It declares only our own chain, so --noflush
# replaces that chain atomically and never touches fail2ban's DOCKER-USER jumps.
_admin_filter_payload() {
    printf '*filter\n:%s - [0:0]\n' "$ADMIN_FILTER_CHAIN"
    _admin_filter_rule_lines "$1"
    printf 'COMMIT\n'
}

# The self-contained apply script. It embeds the rules so the filter keeps
# working if the MediaStack checkout moves or goes away. Modes: apply (install
# the chain and the jump, then verify) and verify (check only; also requires
# FORWARD to reach DOCKER-USER, which exists only once Docker is up).
_admin_filter_script() {
    cat <<SCRIPT
#!/bin/sh
# $MEDIASTACK_ADMIN_FILTER_MARKER - managed by MediaStack setup, regenerated on every run. Do not edit.
set -euf
CHAIN=$ADMIN_FILTER_CHAIN
mode=\${1:-apply}
die() { echo "mediastack-admin-filter: \$*" >&2; exit 1; }

payload_v4() { cat <<'RULES'
$(_admin_filter_payload v4)
RULES
}
payload_v6() { cat <<'RULES'
$(_admin_filter_payload v6)
RULES
}
SCRIPT
    cat <<'SCRIPT'

backend() { "$1" --version 2>/dev/null | sed -n 's/.*(\(nf_tables\|legacy\)).*/\1/p'; }

# 0 when the jump exists exactly once and sits ahead of any plain RETURN.
# Docker keeps a trailing RETURN in DOCKER-USER; a jump behind it never runs.
jump_ok() {
    "$1" -w -S DOCKER-USER 2>/dev/null | awk -v j="-A DOCKER-USER -j $CHAIN" '
        $0 == j { n++; if (!seen) good = 1 }
        $0 == "-A DOCKER-USER -j RETURN" { seen = 1 }
        END { exit !(n == 1 && good) }'
}

apply_family() { # $1 iptables, $2 iptables-restore, $3 payload function
    "$1" -w -n -L DOCKER-USER >/dev/null 2>&1 || "$1" -w -N DOCKER-USER || die "cannot create DOCKER-USER with $1"
    "$3" | "$2" -w --noflush || die "$2 failed to load the $CHAIN chain"
    if ! jump_ok "$1"; then
        while "$1" -w -C DOCKER-USER -j "$CHAIN" 2>/dev/null; do
            "$1" -w -D DOCKER-USER -j "$CHAIN" || die "cannot remove a stale jump with $1"
        done
        "$1" -w -I DOCKER-USER 1 -j "$CHAIN" || die "cannot add the jump with $1"
    fi
}

verify_family() { # $1 iptables, $2 payload function
    local actual expected_file actual_file mismatch
    jump_ok "$1" || die "$1: DOCKER-USER does not jump to $CHAIN exactly once ahead of RETURN"
    expected_file=$(mktemp) || die "$1: cannot prepare $CHAIN rule verification"
    actual_file=$(mktemp) || { rm -f "$expected_file"; die "$1: cannot prepare $CHAIN rule verification"; }
    "$2" | sed -n "s/^-A $CHAIN //p" >"$expected_file"
    actual=$("$1" -w -S "$CHAIN" 2>/dev/null) || {
        rm -f "$expected_file" "$actual_file"
        die "$1: cannot read $CHAIN rules"
    }
    printf '%s\n' "$actual" | sed -n "s/^-A $CHAIN //p" >"$actual_file"
    if ! mismatch=$(awk 'NR == FNR { expected[FNR] = $0; en = FNR; next }
        { actual[FNR] = $0; an = FNR }
        END { for (n = 1; n <= (en > an ? en : an); n++)
            if (expected[n] != actual[n]) {
                printf "expected %s, found %s", expected[n] ? expected[n] : "no further rule", actual[n] ? actual[n] : "no rule"
                exit
            } }' "$expected_file" "$actual_file"); then
        rm -f "$expected_file" "$actual_file"
        die "$1: cannot compare $CHAIN rules"
    fi
    rm -f "$expected_file" "$actual_file"
    [ -z "$mismatch" ] || die "$1: first $CHAIN rule out of place: $mismatch"
}

command -v iptables >/dev/null 2>&1 || die "iptables not found"
b4=$(backend iptables)
[ -n "$b4" ] || die "cannot tell which iptables backend is in use"
# IPv6 off in the kernel leaves nothing to filter and ip6tables cannot run.
v6=0
if [ -e "${MEDIASTACK_IF_INET6:-/proc/net/if_inet6}" ]; then
    v6=1
    command -v ip6tables >/dev/null 2>&1 || die "ip6tables not found but IPv6 is enabled"
    b6=$(backend ip6tables)
    [ "$b4" = "$b6" ] || die "iptables backend mismatch: iptables is ${b4}, ip6tables is ${b6:-unknown}"
fi

case "$mode" in
    apply)
        apply_family iptables iptables-restore payload_v4
        [ "$v6" = 0 ] || apply_family ip6tables ip6tables-restore payload_v6
        ;;
    verify)
        iptables -w -C FORWARD -j DOCKER-USER 2>/dev/null \
            || die "FORWARD does not reach DOCKER-USER in the $b4 iptables backend; Docker is using a different firewall backend"
        ;;
    *) die "unknown mode: $mode" ;;
esac
verify_family iptables payload_v4
[ "$v6" = 0 ] || verify_family ip6tables payload_v6
echo "mediastack-admin-filter: $mode ok ($b4)"
SCRIPT
}

_admin_filter_unit() {
    cat <<UNIT
# $MEDIASTACK_ADMIN_FILTER_MARKER - managed by MediaStack setup, regenerated on every run. Do not edit.
[Unit]
Description=MediaStack admin-port filter (DOCKER-USER chain)
# docker.service Requires= and After= this unit (see its drop-in), so a failure
# here stops Docker instead of publishing admin ports unfiltered. Keep every
# Condition*/Assert* line out of this unit: a skipped condition would let Docker
# start without the filter.
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$MEDIASTACK_ADMIN_FILTER_SCRIPT apply
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
UNIT
}

_admin_filter_dropin() {
    cat <<DROPIN
# $MEDIASTACK_ADMIN_FILTER_MARKER - managed by MediaStack setup, regenerated on every run. Do not edit.
[Unit]
Requires=$MEDIASTACK_ADMIN_FILTER_UNIT_NAME
After=$MEDIASTACK_ADMIN_FILTER_UNIT_NAME

[Service]
ExecStartPost=$MEDIASTACK_ADMIN_FILTER_SCRIPT verify
DROPIN
}

# Record in the ledger only when one exists: the best-effort uninstall runs
# without a ledger and must not create one.
_admin_filter_ledger() {
    sudo test -f "$MEDIASTACK_STATE_FILE" || return 0
    _ms_state_set "$1" "$2"
}

# Prints the systemd-path files that exist and carry our marker.
_admin_filter_owned_files() {
    local f
    for f in "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_UNIT" "$MEDIASTACK_ADMIN_FILTER_SCRIPT"; do
        if sudo test -f "$f" && sudo grep -q "$MEDIASTACK_ADMIN_FILTER_MARKER" "$f"; then
            printf '%s\n' "$f"
        fi
    done
}

# $1 dest, $2 mode, $3 generator function. Returns 0 and sets
# _ADMIN_FILTER_CHANGED=true when the file was (re)written; returns 1 on
# failure or when the path holds a file that is not ours.
_admin_filter_write() {
    local dest="$1" mode="$2" gen="$3" tmp rc=0
    if sudo test -f "$dest" && ! sudo grep -q "$MEDIASTACK_ADMIN_FILTER_MARKER" "$dest"; then
        log_warn "$dest exists and is not MediaStack's; leaving it alone"
        return 1
    fi
    tmp=$(mktemp)
    "$gen" >"$tmp"
    if ! sudo test -f "$dest" || ! sudo cmp -s "$tmp" "$dest"; then
        sudo install -D -m "$mode" "$tmp" "$dest" || rc=1
        _ADMIN_FILTER_CHANGED=true
    fi
    rm -f "$tmp"
    return "$rc"
}

# Unchanged files and an active unit say nothing about the live chain: the unit
# is RemainAfterExit, so a flushed chain leaves it active. Verify, and on failure
# re-run apply directly (never restart: docker.service Requires= the unit) and
# verify again. Success is reported only after a passing verify.
_admin_filter_converge_installed() {
    if sudo "$MEDIASTACK_ADMIN_FILTER_SCRIPT" verify >/dev/null 2>&1; then
        log_skip "Admin-port filter already installed"
        return 0
    fi
    log_warn "Admin-port filter is installed but its rules are not live; re-applying..."
    if sudo "$MEDIASTACK_ADMIN_FILTER_SCRIPT" apply >/dev/null 2>&1 \
        && sudo "$MEDIASTACK_ADMIN_FILTER_SCRIPT" verify >/dev/null 2>&1; then
        log_ok "Admin-port filter repaired (rules re-applied)"
        return 0
    fi
    log_error "Admin-port filter rules could not be restored: $MEDIASTACK_ADMIN_FILTER_SCRIPT apply, or systemctl status $MEDIASTACK_ADMIN_FILTER_UNIT_NAME"
    return 1
}

# Install the systemd path: script, oneshot unit, docker.service drop-in. The
# chain is live when this returns 0. Any failure returns 1 with the reason logged.
setup_admin_filter_unit() {
    command -v systemctl >/dev/null 2>&1 || {
        log_error "Admin-port filter needs systemd; it cannot be installed here. Turn it off in Features & settings to continue."
        return 1
    }
    _ADMIN_FILTER_CHANGED=false
    local dropin_dir was_dir=true
    dropin_dir="$(dirname "$MEDIASTACK_ADMIN_FILTER_DROPIN")"
    sudo test -d "$dropin_dir" || was_dir=false
    _admin_filter_write "$MEDIASTACK_ADMIN_FILTER_SCRIPT" 0755 _admin_filter_script \
        && _admin_filter_write "$MEDIASTACK_ADMIN_FILTER_UNIT" 0644 _admin_filter_unit \
        && _admin_filter_write "$MEDIASTACK_ADMIN_FILTER_DROPIN" 0644 _admin_filter_dropin || {
        log_error "Could not write the admin-port filter files"
        return 1
    }
    if [[ "$was_dir" == "false" ]]; then
        _admin_filter_ledger ADMIN_FILTER_DROPIN_DIR_CREATED true
    fi
    _admin_filter_ledger ADMIN_FILTER_UNIT_INSTALLED true
    # Reload on every run, not only when a file changed: a reload that failed
    # last time leaves unchanged files that systemd has not loaded, and reporting
    # active then would let Docker start without the drop-in. Reload is idempotent.
    sudo systemctl daemon-reload || {
        log_error "systemd daemon-reload failed"
        return 1
    }
    if [[ "$_ADMIN_FILTER_CHANGED" != "true" ]] && sudo systemctl is-active --quiet "$MEDIASTACK_ADMIN_FILTER_UNIT_NAME" 2>/dev/null; then
        _admin_filter_converge_installed
        return
    fi
    log_info "Installing the admin-port filter (runs before Docker)..."
    sudo systemctl enable "$MEDIASTACK_ADMIN_FILTER_UNIT_NAME" >/dev/null 2>&1 || {
        log_error "Could not enable $MEDIASTACK_ADMIN_FILTER_UNIT_NAME"
        return 1
    }
    # Start, never restart: restarting a unit that docker.service Requires=
    # restarts Docker too. start is a no-op on an active unit, so the script
    # runs directly to re-apply the rules.
    sudo systemctl start "$MEDIASTACK_ADMIN_FILTER_UNIT_NAME" \
        && sudo "$MEDIASTACK_ADMIN_FILTER_SCRIPT" apply >/dev/null || {
        log_error "Admin-port filter failed to apply. Docker will not start until it does: systemctl status $MEDIASTACK_ADMIN_FILTER_UNIT_NAME"
        return 1
    }
    log_ok "Admin-port filter active (LAN, loopback and Tailscale only)"
}

# Re-apply and verify the rules without touching systemd state.
admin_filter_reapply() {
    sudo "$MEDIASTACK_ADMIN_FILTER_SCRIPT" apply >/dev/null
}

# Delete the live jump and chain in both families (idempotent).
_admin_filter_chain_delete_live() {
    local ipt n
    for ipt in iptables ip6tables; do
        n=0
        while sudo "$ipt" -C DOCKER-USER -j "$ADMIN_FILTER_CHAIN" >/dev/null 2>&1; do
            # A jump that survives -D must fail the teardown, not hang it.
            ((n++ < 10)) || return 1
            sudo "$ipt" -D DOCKER-USER -j "$ADMIN_FILTER_CHAIN" || return 1
        done
        if sudo "$ipt" -L "$ADMIN_FILTER_CHAIN" >/dev/null 2>&1; then
            sudo "$ipt" -F "$ADMIN_FILTER_CHAIN" && sudo "$ipt" -X "$ADMIN_FILTER_CHAIN" || return 1
        fi
    done
}

# Remove the systemd path and the live chain. The drop-in goes first and systemd
# reloads before the unit stops, so docker.service is never stopped by it. If
# that reload fails the unit keeps running and its files and ledger flag stay,
# so the next run retries. Returns non-zero when any removal fails.
admin_filter_unit_remove() {
    local rc=0 f owned
    # Only files that still carry our marker: an administrator's replacement stays.
    owned=$(_admin_filter_owned_files)
    if [[ -n "$owned" ]]; then
        if [[ "$owned" == *"$MEDIASTACK_ADMIN_FILTER_DROPIN"* ]]; then
            sudo rm -f "$MEDIASTACK_ADMIN_FILTER_DROPIN" || rc=1
            if [[ "$(_ms_state_get ADMIN_FILTER_DROPIN_DIR_CREATED 2>/dev/null || true)" == "true" ]]; then
                sudo rmdir "$(dirname "$MEDIASTACK_ADMIN_FILTER_DROPIN")" 2>/dev/null || true
            fi
        fi
        sudo systemctl daemon-reload || {
            log_error "systemd daemon-reload failed; leaving $MEDIASTACK_ADMIN_FILTER_UNIT_NAME running so Docker is not stopped. Run the removal again."
            return 1
        }
        sudo systemctl disable --now "$MEDIASTACK_ADMIN_FILTER_UNIT_NAME" >/dev/null 2>&1 || true
        for f in "$MEDIASTACK_ADMIN_FILTER_UNIT" "$MEDIASTACK_ADMIN_FILTER_SCRIPT"; do
            if [[ "$owned" == *"$f"* ]]; then
                sudo rm -f "$f" || rc=1
            fi
        done
        sudo systemctl daemon-reload || rc=1
    elif [[ "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED 2>/dev/null || true)" == "true" ]]; then
        # Files are gone but the ledger says a reload is still owed (the last one failed).
        sudo systemctl daemon-reload || rc=1
    fi
    _admin_filter_chain_delete_live || rc=1
    ((rc == 0)) || return 1
    _admin_filter_ledger ADMIN_FILTER_UNIT_INSTALLED false
    _admin_filter_ledger ADMIN_FILTER_DROPIN_DIR_CREATED false
}

# Opt-out: remove the unit path, live chain and any legacy block. The admin
# ports are then reachable from any source that is forwarded to them.
admin_filter_disable() {
    local rc=0
    admin_filter_unit_remove || rc=1
    _admin_filter_strip_ufw_blocks || rc=1
    _admin_filter_strip_dedup_hook || rc=1
    return "$rc"
}

# A host set up by an earlier version holds the chain in after.rules. Confirm the
# unit path applies and verifies first, then strip the legacy blocks, so the
# chain is never absent. On any failure the blocks stay.
_admin_filter_migrate_legacy() {
    local rc=0
    # The hook is harmful whatever the blocks' state, so it goes first.
    _admin_filter_strip_dedup_hook || rc=1
    [[ -n "$(_admin_filter_legacy_files)" ]] || return "$rc"
    log_info "Moving the admin-port filter out of UFW's after.rules..."
    admin_filter_reapply || {
        log_error "The admin-port filter did not verify; leaving the old after.rules blocks in place"
        return 1
    }
    _admin_filter_strip_ufw_blocks || return 1
    log_ok "Admin-port filter no longer depends on UFW's after.rules"
    return "$rc"
}

# Orchestrator for setup and the day-2 toggles. UFW is irrelevant here.
setup_admin_filter() {
    case "${ADMIN_PORT_FILTER-}" in
        "" | true | false) ;;
        *) log_warn "ADMIN_PORT_FILTER='${ADMIN_PORT_FILTER}' is not recognised; keeping the admin-port filter ON. Only the exact value false turns it off." ;;
    esac
    if admin_filter_opted_out; then
        # The menu shows OFF, so finish any removal that failed before and return its rc.
        if [[ -n "$(_admin_filter_owned_files)$(_admin_filter_legacy_files)" || "$(_ms_state_get ADMIN_FILTER_UNIT_INSTALLED 2>/dev/null || true)" == "true" ]]; then
            log_info "Admin-port filter is off by your choice; removing what is still installed..."
            admin_filter_disable
            return
        fi
        log_skip "Admin-port filter off by user choice (admin ports reachable from any forwarded source)"
        return 0
    fi
    setup_admin_filter_unit || return 1
    _admin_filter_migrate_legacy
}

# shellcheck source=admin-filter-legacy.sh
source "$(dirname "${BASH_SOURCE[0]}")/admin-filter-legacy.sh"
