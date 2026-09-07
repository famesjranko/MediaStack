# Owns: the DOCKER-USER jump dedup hook (/etc/ufw/after.init) behaviour tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/firewall.sh.

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
assert_contains "$(cat "$MEDIASTACK_UFW_AFTER_INIT")" \
    "ip6tables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT" \
    "dedup hook: block trims the IPv6 jump too (after6.rules re-appends it as well)"
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
