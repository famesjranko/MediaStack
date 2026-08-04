# Owns: NVIDIA Unlock installer and toolkit assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-install.sh.
# NVIDIA container toolkit curl failures
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-container-runtime" ]]; then
        return 1
    fi
    builtin command "$@"
}
curl() { return 47; }
sudo() {
    cat >/dev/null
    return 0
}
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: key curl failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: key curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install NVIDIA container toolkit apt key" "_install_nvidia_container_toolkit: key curl failure logs error"
unset -f curl sudo

curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            return 48
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: source curl failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: source curl failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to install NVIDIA container toolkit apt source" "_install_nvidia_container_toolkit: source curl failure logs error"
unset -f command curl sudo

# NVIDIA container toolkit configure failure
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "nvidia-container-runtime" ]]; then
        return 1
    fi
    builtin command "$@"
}
curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            printf '%s\n' "deb https://nvidia.example/debian stable main"
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        apt-get)
            return 0
            ;;
        nvidia-ctk)
            return 44
            ;;
        systemctl)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
INSTALL_LOG_MESSAGES=()
INSTALL_ERROR_MESSAGES=()
if _install_nvidia_container_toolkit; then
    fail "_install_nvidia_container_toolkit: nvidia-ctk failure returns nonzero"
else
    pass "_install_nvidia_container_toolkit: nvidia-ctk failure returns nonzero"
fi
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to configure nvidia-container-toolkit runtime" "_install_nvidia_container_toolkit: nvidia-ctk failure logs error"
case "${INSTALL_LOG_MESSAGES[*]}" in
    *"nvidia-container-toolkit installed and configured"*) fail "_install_nvidia_container_toolkit: failed nvidia-ctk does not log success" ;;
    *) pass "_install_nvidia_container_toolkit: failed nvidia-ctk does not log success" ;;
esac
unset -f command curl sudo

# install_nvidia_drivers propagates toolkit failure after finding a driver.
command() {
    case "${1:-}:${2:-}" in
        -v:nvidia-smi) return 0 ;;
        -v:nvidia-container-runtime) return 1 ;;
    esac
    builtin command "$@"
}
nvidia-smi() {
    case "$*" in
        *--query-gpu=driver_version*) printf '%s\n' "580.142" ;;
        *) return 0 ;;
    esac
}
curl() {
    local last_arg="${*: -1}"
    case "$last_arg" in
        */gpgkey)
            printf '%s\n' "fake-key"
            ;;
        */nvidia-container-toolkit.list)
            printf '%s\n' "deb https://nvidia.example/debian stable main"
            ;;
        *)
            return 1
            ;;
    esac
}
sudo() {
    case "${1:-}" in
        gpg | tee)
            cat >/dev/null
            return 0
            ;;
        apt-get)
            return 0
            ;;
        nvidia-ctk)
            return 49
            ;;
        systemctl)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
GPU_TYPE=nvidia
INSTALL_ERROR_MESSAGES=()
if install_nvidia_drivers; then
    fail "install_nvidia_drivers: toolkit failure returns nonzero"
else
    pass "install_nvidia_drivers: toolkit failure returns nonzero"
fi
assert_eq "none" "$GPU_TYPE" "install_nvidia_drivers: toolkit failure downgrades GPU type"
assert_contains "${INSTALL_ERROR_MESSAGES[*]}" "Failed to configure nvidia-container-toolkit runtime" "install_nvidia_drivers: toolkit failure logs underlying error"
unset -f command nvidia-smi curl sudo
unset GPU_TYPE

# ---------------------------------------------------------------------------
