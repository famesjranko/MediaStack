# Owns: stage3_* — The NVIDIA post-reboot finalize marker: path, boot-id read, write/remove, field readers, and reboot-prompt gating.
# Sources: python3 for marker JSON; stage3_prompt_nvidia_reboot (nvidia-finalize.sh) via stage3_prompt_pending_nvidia_reboot.

_stage3_marker_path() {
    printf '%s/.nvidia-finalize-pending' "$SCRIPT_DIR"
}

stage3_current_boot_id() {
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        cat /proc/sys/kernel/random/boot_id
    else
        printf 'unknown\n'
    fi
}

stage3_marker_exists() {
    [[ -f "$(_stage3_marker_path)" ]]
}

stage3_write_nvidia_marker() {
    # Records the driver-management mode + install source so post-reboot
    # finalization runs the right resume path and applies the patch only for
    # unlock. install_source is "apt" (Standard) or "run" (Unlock .run cache).
    local driver_mode="${1:-unlock}"
    local install_source="${2:-run}"
    local expected_driver_version="${3:-}"
    local marker tmp
    marker="$(_stage3_marker_path)"
    tmp="${marker}.tmp"
    MARKER_PATH="$tmp" MARKER_BOOT_ID="$(stage3_current_boot_id)" \
    MARKER_DRIVER_MODE="$driver_mode" MARKER_INSTALL_SOURCE="$install_source" \
    MARKER_EXPECTED_DRIVER_VERSION="$expected_driver_version" python3 - <<'PY'
import datetime
import json
import os
import pathlib

path = pathlib.Path(os.environ["MARKER_PATH"])
payload = {
    "schema": 3,
    "gpu_type": "nvidia",
    "nvidia_driver_mode": os.environ.get("MARKER_DRIVER_MODE", "unlock"),
    "install_source": os.environ.get("MARKER_INSTALL_SOURCE", "run"),
    "encoder": "nvenc",
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "created_boot_id": os.environ.get("MARKER_BOOT_ID", "unknown"),
    "pending": [
        "driver_verify",
        "docker_runtime_verify",
        "encoder_config",
        "test_transcode",
        "summary",
    ],
}
expected = os.environ.get("MARKER_EXPECTED_DRIVER_VERSION", "")
if expected:
    payload["expected_driver_version"] = expected
path.write_text(json.dumps(payload, indent=2) + "\n")
PY
    chmod 600 "$tmp"
    mv "$tmp" "$marker"
}

stage3_remove_nvidia_marker() {
    rm -f "$(_stage3_marker_path)"
}

# Discard a prepared-but-not-finalized NVIDIA driver setup (one that is waiting
# for a reboot) so the user can pick a different driver mode instead of being
# locked into finishing the pending install. Clears the finalize marker and any
# cached .run, and removes the installed .run driver (if present) so a fresh
# Standard/Unlock choice starts from a clean slate. The GPU hardware is still
# detected afterwards, so run_stage3 re-offers the mode menu.
_stage3_discard_pending_setup() {
    ui_log info "Discarding the prepared NVIDIA driver setup..."
    stage3_remove_nvidia_marker
    rm -rf "$SCRIPT_DIR/.nvidia-tmp" 2>/dev/null || true
    if command -v nvidia-uninstall >/dev/null 2>&1; then
        ui_spin "Removing the prepared NVIDIA .run driver..." sudo nvidia-uninstall -s || true
        # Clear bash's cached nvidia-smi path so re-detection sees it is gone.
        hash -r
    fi
    NEEDS_REBOOT=false
}

stage3_marker_boot_id() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("created_boot_id", ""))
except Exception:
    print("")
PY
}

# Echo the driver-management mode recorded in the finalize marker (standard|
# unlock|existing). Empty if the marker is absent/unreadable (older schema 1
# markers had no mode field — finalization treats that as "unlock").
stage3_marker_driver_mode() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("nvidia_driver_mode", ""))
except Exception:
    print("")
PY
}

stage3_marker_expected_driver_version() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("expected_driver_version", ""))
except Exception:
    print("")
PY
}

stage3_marker_install_source() {
    local marker
    marker="$(_stage3_marker_path)"
    [[ -f "$marker" ]] || return 1
    python3 - "$marker" <<'PY' 2>/dev/null
import json
import sys

try:
    print(json.load(open(sys.argv[1])).get("install_source", ""))
except Exception:
    print("")
PY
}

stage3_marker_ready_to_finalize() {
    stage3_marker_exists || return 1

    local marker_boot current_boot
    marker_boot="$(stage3_marker_boot_id)"
    current_boot="$(stage3_current_boot_id)"
    [[ -n "$marker_boot" && -n "$current_boot" ]] || return 1
    [[ "$marker_boot" != "$current_boot" ]]
}

stage3_pending_nvidia_reboot_same_boot() {
    stage3_marker_exists || return 1
    ! stage3_marker_ready_to_finalize
}

stage3_reboot_prompt_needed() {
    [[ "${NEEDS_REBOOT:-false}" == "true" ]] && stage3_marker_exists
}

stage3_prompt_pending_nvidia_reboot() {
    stage3_pending_nvidia_reboot_same_boot || return 0
    NEEDS_REBOOT=true
    stage3_prompt_nvidia_reboot
}
