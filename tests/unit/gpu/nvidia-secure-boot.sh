# Owns: Secure Boot state characterization for NVIDIA installation.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-driver.sh.
# ---------------------------------------------------------------------------
# nvidia_driver_check_secure_boot
# ---------------------------------------------------------------------------

mokutil() { echo "SecureBoot enabled"; }
state=$(nvidia_driver_check_secure_boot)
assert_eq "enabled" "$state" "nvidia_driver_check_secure_boot: SB enabled"
unset -f mokutil

mokutil() { echo "SecureBoot disabled"; }
state=$(nvidia_driver_check_secure_boot)
assert_eq "disabled" "$state" "nvidia_driver_check_secure_boot: SB disabled"
unset -f mokutil

# Simulate "mokutil not installed" by lying to `command -v`. The host may
# have /usr/bin/mokutil; we can't rely on PATH manipulation alone.
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "mokutil" ]]; then
        return 1
    fi
    builtin command "$@"
}
sudo() { return 1; }
state=$(nvidia_driver_check_secure_boot)
assert_eq "unavailable" "$state" "nvidia_driver_check_secure_boot: mokutil absent"
unset -f command sudo

# ---------------------------------------------------------------------------
