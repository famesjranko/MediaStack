# Owns: NVIDIA driver ownership and health assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/nvidia-apt.sh.
# NVIDIA driver-management modes: Standard (Debian apt) vs Unlock (.run + patch)
# ---------------------------------------------------------------------------
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

# --- nvidia_driver_source: none / debian / foreign ---
command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 1 ;; *) builtin command "$@" ;; esac }
dpkg-query() { return 1; }
assert_eq "none" "$(nvidia_driver_source)" "nvidia_driver_source: no nvidia-smi → none"
unset -f command dpkg-query

command() { case "${1:-}:${2:-}" in -v:nvidia-smi) return 0 ;; *) builtin command "$@" ;; esac }
nvidia-smi() { return 0; }
dpkg-query() { printf 'install ok installed'; }
assert_eq "debian" "$(nvidia_driver_source)" "nvidia_driver_source: nvidia-driver package present → debian"
if nvidia_driver_healthy; then
    pass "nvidia_driver_healthy: healthy runtime is independent of Debian ownership"
else
    fail "nvidia_driver_healthy: healthy runtime is independent of Debian ownership"
fi
nvidia-smi() { [[ "$*" == *"--query-gpu"* ]] && printf '535.100\n' || return 1; }
assert_eq "debian" "$(nvidia_driver_source)" "nvidia_driver_source: unhealthy Debian driver retains Debian ownership"
if nvidia_driver_healthy; then
    fail "nvidia_driver_healthy: failing nvidia-smi -L is unhealthy"
else
    pass "nvidia_driver_healthy: failing nvidia-smi -L is unhealthy"
fi
unset -f dpkg-query
dpkg-query() { return 1; }
assert_eq "foreign" "$(nvidia_driver_source)" "nvidia_driver_source: non-packaged driver → foreign"
assert_eq "535.100" "$(nvidia_driver_version)" "nvidia_driver_version: returns one normalized version"
nvidia-smi() { printf '535.100\n550.20\n'; }
if nvidia_driver_version >/dev/null; then
    fail "nvidia_driver_version: rejects mixed loaded driver versions"
else
    pass "nvidia_driver_version: rejects mixed loaded driver versions"
fi
unset -f dpkg-query nvidia-smi command
