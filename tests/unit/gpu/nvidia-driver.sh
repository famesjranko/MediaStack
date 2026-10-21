# Owns: NVIDIA driver-resolution failure characterization.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-driver.sh.
# NVIDIA driver resolver curl failures
_nvidia_tmp="$(mktemp -d)"
_driver_ver=""
_run_file=""
curl() { return 45; }
INSTALL_ERROR_MESSAGES=()
if nvidia_driver_resolve_driver; then
    fail "nvidia_driver_resolve_driver: README curl failure returns nonzero"
else
    pass "nvidia_driver_resolve_driver: README curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Could not fetch nvidia-patch README" "nvidia_driver_resolve_driver: README curl failure logs error"
unset -f curl

_driver_ver=""
_run_file=""
lspci() { :; }
curl() {
    case "$*" in
        *raw.githubusercontent.com*)
            printf '%s\n' '| 580.142 | Linux x86_64 | YES | [driver](https://download.nvidia.com/XFree86/Linux-x86_64/580.142/NVIDIA-Linux-x86_64-580.142.run) |'
            return 0
            ;;
        *NVIDIA-Linux-x86_64-580.142.run*)
            return 46
            ;;
        *)
            return 1
            ;;
    esac
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if nvidia_driver_resolve_driver; then
    fail "nvidia_driver_resolve_driver: driver download curl failure returns nonzero"
else
    pass "nvidia_driver_resolve_driver: driver download curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to download driver 580.142" "nvidia_driver_resolve_driver: driver download curl failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"NVIDIA driver 580.142 downloaded"*) fail "nvidia_driver_resolve_driver: failed download does not log success" ;;
    *) pass "nvidia_driver_resolve_driver: failed download does not log success" ;;
esac
rm -rf "$_nvidia_tmp"
unset _nvidia_tmp _driver_ver _run_file
unset -f curl lspci

# --- _nvidia_driver_check_compat: an early-exiting parser leaves no stderr noise ---
# Given a supportedchips page larger than a pipe buffer that matches on its first
# line, and a caller that ignores SIGPIPE (systemd resume does),
# When the compatibility check runs,
# Then it prints the section and writes nothing to stderr (no "Broken pipe").
curl() {
    printf 'Current NVIDIA GPUs devid1BB3\n'
    head -c 300000 /dev/zero | tr '\0' 'x'
    printf '\n'
}
_compat_err=$(
    trap '' PIPE
    _nvidia_driver_check_compat 580.142 1bb3 2>&1 >/dev/null
)
_compat_out=$(
    trap '' PIPE
    _nvidia_driver_check_compat 580.142 1bb3 2>/dev/null
)
assert_eq "current" "$_compat_out" "_nvidia_driver_check_compat: early match still reports the section"
assert_eq "" "$_compat_err" "_nvidia_driver_check_compat: early match writes no Broken pipe noise"
unset -f curl
unset _compat_err _compat_out
