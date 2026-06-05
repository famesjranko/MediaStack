#!/usr/bin/env bash
# =============================================================================
# Re-apply nvidia-patch after driver updates
# =============================================================================
# Run this after updating NVIDIA drivers (apt upgrade, etc.)
# See: https://github.com/keylase/nvidia-patch
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="$SCRIPT_DIR/.nvidia-patch"
PATCH_RUN_DIR=""

# shellcheck source=lib/nvidia_patch.sh
source "$SCRIPT_DIR/scripts/lib/nvidia_patch.sh"

cleanup() {
    [[ -n "$PATCH_RUN_DIR" ]] && rm -rf "$PATCH_RUN_DIR"
    # Never let the conditional's exit status leak into the script's exit code
    # (an early `exit 0` before PATCH_RUN_DIR is set would otherwise become 1).
    return 0
}
trap cleanup EXIT

FORCE=0
for arg in "$@"; do
    case "$arg" in
        -f|--force) FORCE=1 ;;
        -h|--help)  echo "Usage: scripts/nvidia-repatch.sh [--force]"; exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: scripts/nvidia-repatch.sh [--force]" >&2
            exit 2
            ;;
    esac
done

# nvidia-patch is only meaningful in Unlock mode. Standard (Debian-managed) and
# "existing" installs are not patched and are maintained by apt — repatching them
# is wrong, so no-op with guidance unless --force is given. Mode is read from
# .env (NVIDIA_DRIVER_MODE is unquoted there).
NVIDIA_DRIVER_MODE=""
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    while IFS='=' read -r _k _v; do
        if [[ "$_k" == "NVIDIA_DRIVER_MODE" ]]; then
            NVIDIA_DRIVER_MODE="$_v"
            break
        fi
    done < "$SCRIPT_DIR/.env"
fi

if [[ "$NVIDIA_DRIVER_MODE" != "unlock" && "$FORCE" != "1" ]]; then
    echo "NVIDIA_DRIVER_MODE='${NVIDIA_DRIVER_MODE:-standard}' - this system is not using the"
    echo "patch-managed (Unlock NVENC) driver, so there is nothing to repatch."
    echo "Standard/existing drivers are maintained by apt and must not be patched."
    echo "Re-run with --force only if you deliberately want to patch this driver."
    exit 0
fi

if ! command -v nvidia-smi &>/dev/null; then
    echo "ERROR: NVIDIA drivers not loaded"
    exit 1
fi

DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
echo "NVIDIA driver version: $DRIVER_VER"

if ! nvidia_patch_prepare_repo "$PATCH_DIR"; then
    echo "ERROR: nvidia-patch verification failed"
    echo "Clean or remove $PATCH_DIR, then update MediaStack if newer driver support is needed."
    exit 1
fi

if ! PATCH_RUN_DIR=$(nvidia_patch_export_run_tree "$PATCH_DIR"); then
    echo "ERROR: could not export verified nvidia-patch tree"
    exit 1
fi

# Confirm keylase has indexed this driver version before running the patch.
# Without the compat check, a newly-released driver produces a hard failure
# mid-patch. With it, we exit cleanly with actionable guidance.
if ! bash "$PATCH_RUN_DIR/patch.sh" -c "$DRIVER_VER" &>/dev/null; then
    echo "Driver $DRIVER_VER is not supported by MediaStack's reviewed nvidia-patch commit:"
    echo "    $(nvidia_patch_expected_commit)"
    echo "Update MediaStack once a newer reviewed nvidia-patch commit is available."
    exit 0
fi

# Apply NVENC patch
echo "Applying NVENC patch..."
sudo bash "$PATCH_RUN_DIR/patch.sh"

# Apply NvFBC patch
if [[ -f "$PATCH_RUN_DIR/patch-fbc.sh" ]]; then
    echo "Applying NvFBC patch..."
    sudo bash "$PATCH_RUN_DIR/patch-fbc.sh"
fi

echo ""
echo "Done. Patches applied for driver $DRIVER_VER"
