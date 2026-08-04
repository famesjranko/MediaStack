# Owns: Intel and AMD driver-install assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/intel-amd.sh.
# ---------------------------------------------------------------------------
# install_amd_drivers / install_intel_drivers
# ---------------------------------------------------------------------------

INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
log_ok() { INSTALL_LOG_MESSAGES+=("$1"); }
log_info() { :; }
log_warn() { :; }
log_error() { INSTALL_ERROR_MESSAGES+=("$1"); }
sudo() { :; }

# AMD already installed
dpkg() { return 0; }
INSTALL_LOG_MESSAGES=()
install_amd_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "AMD VAAPI drivers already installed"; then
    pass "install_amd_drivers: already installed → skipped"
else
    fail "install_amd_drivers: already installed → skipped"
fi
unset -f dpkg

# AMD fresh install
dpkg() { return 1; }
INSTALL_LOG_MESSAGES=()
install_amd_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "AMD VAAPI drivers installed"; then
    pass "install_amd_drivers: fresh install → installed"
else
    fail "install_amd_drivers: fresh install → installed"
fi
unset -f dpkg

# AMD install failure
dpkg() { return 1; }
apt-cache() { printf '%s\n' "non-free"; }
sudo() {
    if [[ "${1:-}" == "apt-get" && "${2:-}" == "install" ]]; then
        return 42
    fi
    return 0
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if install_amd_drivers; then
    fail "install_amd_drivers: apt install failure returns nonzero"
else
    pass "install_amd_drivers: apt install failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install AMD VAAPI drivers" "install_amd_drivers: apt install failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"AMD VAAPI drivers installed"*) fail "install_amd_drivers: failed install does not log success" ;;
    *) pass "install_amd_drivers: failed install does not log success" ;;
esac
unset -f dpkg apt-cache sudo
sudo() { :; }

# Intel already installed
dpkg() { return 0; }
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
install_intel_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "Intel media drivers already installed"; then
    pass "install_intel_drivers: already installed → skipped"
else
    fail "install_intel_drivers: already installed → skipped"
fi
unset -f dpkg

# Intel fresh install
dpkg() { return 1; }
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
install_intel_drivers
if printf '%s\n' "${INSTALL_LOG_MESSAGES[@]}" | grep -q "Intel media drivers installed"; then
    pass "install_intel_drivers: fresh install → installed"
else
    fail "install_intel_drivers: fresh install → installed"
fi
unset -f dpkg

# Intel apt metadata failure
dpkg() { return 1; }
apt-cache() { printf '%s\n' "non-free"; }
sudo() {
    if [[ "${1:-}" == "apt-get" && "${2:-}" == "update" ]]; then
        return 43
    fi
    return 0
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if install_intel_drivers; then
    fail "install_intel_drivers: apt update failure returns nonzero"
else
    pass "install_intel_drivers: apt update failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to update apt metadata for Intel media drivers" "install_intel_drivers: apt update failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"Intel media drivers installed"*) fail "install_intel_drivers: failed update does not log success" ;;
    *) pass "install_intel_drivers: failed update does not log success" ;;
esac
unset -f dpkg apt-cache sudo
