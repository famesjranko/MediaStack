# Owns: GPU detection and selection assertions.
# Sources: tests/unit/gpu-branching.sh setup and scripts/setup/gpu/detection.sh.
# shellcheck disable=SC2034 # JELLYFIN_GPU is consumed by detect_gpu in product code.
# ---------------------------------------------------------------------------
# detect_gpu
# ---------------------------------------------------------------------------

lspci() { printf '01:00.0 VGA compatible controller: NVIDIA Corporation GA104\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "nvidia" "$GPU_TYPE" "detect_gpu: nvidia via VGA line"
unset -f lspci

lspci() {
    printf '%s\n' \
        '00:00.0 Host bridge: Intel Corporation Host Bridge' \
        '00:02.0 Display controller: Intel Corporation UHD Graphics' \
        '01:00.0 VGA compatible controller: NVIDIA Corporation GA104' \
        '02:00.0 3D controller: NVIDIA Corporation GA104' \
        '03:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 14'
}
JELLYFIN_GPU=amd
GPU_TYPE=""
detect_gpu
assert_eq "nvidia amd intel" "${GPU_CANDIDATES[*]}" "detect_gpu: mixed vendors are deduplicated in priority order"
assert_eq "amd" "$GPU_TYPE" "detect_gpu: configured available vendor becomes the default"
unset JELLYFIN_GPU
unset -f lspci

lspci() { printf '06:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Navi 14\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "amd" "$GPU_TYPE" "detect_gpu: amd via VGA line"
unset -f lspci

lspci() { printf '06:00.0 VGA compatible controller: Radeon RX 580 Series\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "amd" "$GPU_TYPE" "detect_gpu: amd via Radeon branding"
unset -f lspci

lspci() { printf '00:02.0 VGA compatible controller: Intel Corporation UHD Graphics\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "intel" "$GPU_TYPE" "detect_gpu: intel via VGA line"
unset -f lspci

# Headless Intel iGPU shows as "Display controller", not "VGA"
lspci() { printf '00:02.0 Display controller: Intel Corporation UHD Graphics 630\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "intel" "$GPU_TYPE" "detect_gpu: intel via Display controller (headless)"
unset -f lspci

# Non-GPU AMD device (chipset/bridge) should NOT match — display-class filter
lspci() { printf '00:00.0 Host bridge: Advanced Micro Devices, Inc. [AMD] Starship/Matisse Root Complex\n00:01.0 SATA controller: AMD FCH SATA Controller\n'; }
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: AMD chipset without VGA line → none"
unset -f lspci

# Empty lspci → none (no renderD128 fallback)
lspci() { :; }
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: empty lspci → none"
unset -f lspci

(
    set -euo pipefail
    log_ok() { :; }
    log_info() { :; }
    log_warn() { :; }
    log_error() { :; }
    lspci() { :; }
    GPU_TYPE=""
    detect_gpu
    [[ "$GPU_TYPE" == "none" ]]
)
assert_eq "0" "$?" "detect_gpu: empty lspci does not abort under set -e"
unset -f lspci

# Missing lspci command → none with warning
command() {
    if [[ "${1:-}" == "-v" && "${2:-}" == "lspci" ]]; then
        return 1
    fi
    builtin command "$@"
}
GPU_TYPE=""
detect_gpu
assert_eq "none" "$GPU_TYPE" "detect_gpu: lspci missing → none"
unset -f command

# Disposable characterization retained without changing the historical output:
# exercise direct helper fallbacks that the detect_gpu cases only reach
# indirectly.
GPU_CANDIDATES=(intel amd)
if ! gpu_candidate_available amd; then
    fail "gpu_candidate_available: finds a configured candidate"
fi
if [[ "$(gpu_brand_label unexpected)" != "unexpected" ]]; then
    fail "gpu_brand_label: unknown vendor falls back to its input"
fi
GPU_UNINSTALL_CALLS=()
sudo() { GPU_UNINSTALL_CALLS+=("$*"); }
gpu_uninstall
if [[ "${GPU_UNINSTALL_CALLS[*]}" != "rm -f $MEDIASTACK_GPU_NONFREE_LIST $MEDIASTACK_GPU_BACKPORTS_LIST" ]]; then
    fail "gpu_uninstall: removes both MediaStack-owned apt source files"
fi
unset -f sudo
unset GPU_UNINSTALL_CALLS
