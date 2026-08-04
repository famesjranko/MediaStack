# Owns: unattended-upgrades behavior tests.
# Sources: tests/unit/hardening.sh setup and scripts/setup/hardening/updates.sh.

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
