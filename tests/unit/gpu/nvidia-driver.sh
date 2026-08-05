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
