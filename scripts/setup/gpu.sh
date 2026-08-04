# Owns: GPU entry wiring, source-time paths, and ordered concern loading.
# Sources: common.sh, lib/render-device.sh, lib/nvidia_patch.sh, and gpu/*.
# =============================================================================
# MediaStack Setup — GPU detection, driver install, and verification
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# Globals set: GPU_CANDIDATES (transient vendor array),
# GPU_TYPE ("nvidia"|"amd"|"intel"|"none"), NEEDS_REBOOT (bool).

_GPU_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/render-device.sh
source "$_GPU_HELPER_DIR/lib/render-device.sh"
# shellcheck source=../lib/nvidia_patch.sh
source "$_GPU_HELPER_DIR/lib/nvidia_patch.sh"
unset _GPU_HELPER_DIR

# apt sources this module owns. Single source of truth so install and uninstall
# can never drift (see gpu_uninstall). Plain assignment — this file is re-sourced.
# shellcheck disable=SC2034 # consumed by gpu/nvidia-apt.sh and gpu/updates callers
MEDIASTACK_GPU_NONFREE_LIST=/etc/apt/sources.list.d/mediastack-nonfree.list
# shellcheck disable=SC2034 # consumed by gpu/nvidia-apt.sh and gpu/updates callers
MEDIASTACK_GPU_BACKPORTS_LIST=/etc/apt/sources.list.d/mediastack-backports.list

_GPU_CONCERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/gpu" && pwd)"
# shellcheck source=gpu/detection.sh
source "$_GPU_CONCERNS_DIR/detection.sh"
# shellcheck source=gpu/nvidia-driver.sh
source "$_GPU_CONCERNS_DIR/nvidia-driver.sh"
# shellcheck source=gpu/nvidia-install.sh
source "$_GPU_CONCERNS_DIR/nvidia-install.sh"
# shellcheck source=gpu/nvidia-apt.sh
source "$_GPU_CONCERNS_DIR/nvidia-apt.sh"
# shellcheck source=gpu/nvidia-patch.sh
source "$_GPU_CONCERNS_DIR/nvidia-patch.sh"
# shellcheck source=gpu/intel-amd.sh
source "$_GPU_CONCERNS_DIR/intel-amd.sh"
# shellcheck source=gpu/verify.sh
source "$_GPU_CONCERNS_DIR/verify.sh"
unset _GPU_CONCERNS_DIR
