#!/usr/bin/env bash
# Full reset of a lan-host test target: stop containers, drop their state, delete
# generated files. DESTRUCTIVE and REMOTE.
#
# Highest-stakes script in this harness: it runs `sudo rm -rf` over SSH, and the
# production stack lives on a DIFFERENT box than the test target. A mistyped
# TARGET_HOST must not be wipeable. Two gates, neither bypassable by accident:
#   * non-interactive (--yes / CONFIRM=1): TARGET_HOST must equal LANHOST_EXPECT.
#   * interactive: the operator must retype the target hostname.
#
# usage: clean-wipe.sh [--nvidia] [--data] [--yes]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

WIPE_NVIDIA=0 WIPE_DATA=0 ASSUME_YES=0
while (($#)); do
    case "$1" in
        --nvidia) WIPE_NVIDIA=1 ;;
        --data) WIPE_DATA=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h | --help)
            echo "usage: clean-wipe.sh [--nvidia] [--data] [--yes]"
            exit 0
            ;;
        *) die "unknown arg: $1" ;;
    esac
    shift
done
[[ "${CONFIRM:-0}" == 1 ]] && ASSUME_YES=1

load_env
RP=$(shq "$TARGET_PATH")

echo "About to WIPE MediaStack on:"
echo "    host : $SSH_DEST"
echo "    path : $TARGET_PATH"
((WIPE_NVIDIA)) && echo "    + remove NVIDIA drivers"
((WIPE_DATA)) && echo "    + remove /data (media)"

# --- Destructive-action guard -------------------------------------------
if ((ASSUME_YES)); then
    [[ -n "${LANHOST_EXPECT:-}" ]] \
        || die "refusing --yes wipe: set LANHOST_EXPECT in tests/.env.lan-host to the intended test host"
    [[ "$TARGET_HOST" == "$LANHOST_EXPECT" ]] \
        || die "refusing --yes wipe: TARGET_HOST ($TARGET_HOST) != LANHOST_EXPECT ($LANHOST_EXPECT)"
    ok "expected-host guard satisfied ($TARGET_HOST)"
else
    read -r -p "Type the target hostname ($TARGET_HOST) to confirm wipe: " typed
    [[ "$typed" == "$TARGET_HOST" ]] || die "hostname mismatch — aborting wipe"
fi

# Stop containers BEFORE deleting config: running containers recreate config
# files (e.g. Seerr settings.json) immediately, causing stale next-install state.
step "Stop all compose services (every profile: subtitles/autoheal/proxy/remote)"
# --profile '*' selects ALL profiles, matching the product's own destroy (checks.sh:390). Plain
# `--profile all` is a literal profile NAME (there is no 'all' profile), so it would leave every
# profiled container running (stack.sh:524) — the brute-force fallback below still catches them,
# but this graceful down does the network teardown compose expects.
ssh_t "cd $RP && docker compose --profile '*' down" 2>/dev/null || true

step "Stop/remove any stragglers not managed by compose"
ssh_t 'docker stop $(docker ps -q) 2>/dev/null; docker rm $(docker ps -aq) 2>/dev/null' || true

step "Remove Docker volumes (database state, download history)"
ssh_t 'docker volume prune -f' || true

step "Remove generated config, .env, and override (may be root-owned from mounts)"
# CRITICAL: if this fails (SSH down, sudo refused, busy mount) the next install is NOT fresh —
# stale config/.env would make a "clean" run lie. set -e is off here, so check it explicitly.
ssh_t "sudo rm -rf $RP/config $RP/.env $RP/docker-compose.override.yml" \
    || die "failed to remove generated config/.env/override on $TARGET_HOST — the wipe is incomplete; refusing to report success"

# Clear stale Stage 3 GPU finalize state on EVERY wipe (not just --nvidia). A prior interrupted
# GPU run leaves .nvidia-finalize-pending + the mediastack-setup.service resume unit, and
# setup.sh checks both BEFORE normal setup (setup.sh:42,53) — so without this even a non-GPU
# "fresh" run would be hijacked into post-reboot finalize mode. Mirror the product's own destroy
# (checks.sh removes the marker) for the marker/banner, and CALL the product's cleanup_post_reboot
# (sourced with its documented SCRIPT_DIR + common.sh context) to safely disable/remove the resume
# unit rather than duplicating that logic. Best-effort: the critical marker is removed by the rm
# above regardless of whether reboot.sh can be sourced.
step "Clear stale Stage 3 GPU finalize state (marker + resume unit + login banner)"
ssh_t "rm -f $RP/.nvidia-finalize-pending $RP/.setup-result; sudo rm -f /etc/profile.d/mediastack-setup-result.sh" || true
ssh_t "cd $RP && SCRIPT_DIR=\$(pwd) bash -c 'source scripts/lib/common.sh && source scripts/setup/reboot.sh && cleanup_post_reboot'" || true

if ((WIPE_NVIDIA)); then
    step "Remove NVIDIA driver via the wizard's OWN code (gpu.sh: prepare_nvidia_debian_to_unlock)"
    # A .run-installed driver is removed by its own uninstaller — the product's apt removal
    # below only knows apt-managed drivers (this covers the .run/Unlock case).
    ssh_t 'command -v nvidia-uninstall >/dev/null 2>&1 && sudo nvidia-uninstall --silent 2>/dev/null || true' || true
    # Call the ACTUAL wizard removal instead of duplicating its package list — that duplication
    # is exactly the test/product drift we want to avoid. Source the documented context
    # (SCRIPT_DIR + scripts/lib/common.sh) then gpu.sh, and run the real function: it selects the
    # driver stack (_nvidia_debian_driver_packages), apt-marks the container toolkit to protect
    # it, apt-get purges with dependency cascade, and unloads modules / queues a reboot. No-op on
    # a box with no apt driver. Harness reboot #1 then completes it.
    #
    # Fail loudly if that product code can't be sourced/found on the target (stale or incomplete
    # checkout) rather than silently skipping the real removal: run-fresh.sh pushes current code
    # before this wipe, so a miss here is a genuine problem worth stopping for. The function's
    # OWN non-zero exit is tolerated (it no-ops on a box with no apt driver); verify_clean_nvidia
    # (post-reboot) is the authoritative gate that the removal actually completed.
    ssh -o StrictHostKeyChecking=no "$SSH_DEST" \
        "cd $RP && SCRIPT_DIR=\$(pwd) bash -c 'source scripts/lib/common.sh || exit 97; source scripts/setup/gpu.sh || exit 97; declare -F prepare_nvidia_debian_to_unlock >/dev/null || exit 98; prepare_nvidia_debian_to_unlock'"
    nv_rc=$?
    case $nv_rc in
        97) die "clean-wipe --nvidia: could not source scripts/lib/common.sh + scripts/setup/gpu.sh on $TARGET_HOST (incomplete checkout?) — push current code first" ;;
        98) die "clean-wipe --nvidia: gpu.sh:prepare_nvidia_debian_to_unlock not defined on $TARGET_HOST (stale checkout?) — push current code first" ;;
        0) ok "wizard driver-removal ran (prepare_nvidia_debian_to_unlock)" ;;
        # prepare_nvidia_debian_to_unlock returns 0 on a no-driver box (gpu.sh: empty package list →
        # return 0), so any non-zero here is a REAL failure — an apt purge / nouveau-blacklist error,
        # or an SSH/cd error that meant the removal never ran. Refusing to print "wipe complete" for a
        # half-removed driver: a residual driver would silently route the next Stage 3 to "use existing".
        *) die "clean-wipe --nvidia: NVIDIA driver removal FAILED on $TARGET_HOST (rc=$nv_rc — apt purge/blacklist failure, or SSH/cd error). The driver is not cleanly removed; aborting before reporting success." ;;
    esac
    # Harness-only: clear the wizard's .run build/patch artifacts + refresh initramfs so reboot
    # #1 boots into a clean no-driver state.
    ssh_t "sudo rm -rf /usr/src/nvidia-* $RP/.nvidia-tmp $RP/.nvidia-patch; sudo update-initramfs -u 2>/dev/null" || true
fi

if ((WIPE_DATA)); then
    step "Remove /data (media) — rarely needed"
    # CRITICAL when requested: a failed /data removal must not be reported as a successful wipe.
    ssh_t 'sudo rm -rf /data' \
        || die "failed to remove /data on $TARGET_HOST — the --data wipe is incomplete; refusing to report success"
fi

ok "wipe complete on $SSH_DEST"
