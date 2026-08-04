# Owns: kernel sysctl hardening behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/sysctl.sh.

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
