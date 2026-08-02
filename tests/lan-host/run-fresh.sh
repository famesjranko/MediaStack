#!/usr/bin/env bash
# Full lan-host run: wipe -> push -> install -> probe, on a real Debian box.
# The bare-metal counterpart to tests/gcp-vm/run-fresh.sh.
#
# Two install paths, chosen by the choice-matrix (tests/.env.lan-host, or the flags):
#   * DEMO baseline  — no persona/toggles: DEMO=1 ./setup.sh --full. Fast, fixed
#     defaults, no wizard, GPU=none. Proves the stack on real silicon.
#   * Wizard-driven  — a persona or any non-default toggle drives the REAL wizard via
#     tests/lib/wizard_pty.py (Stage 1 choices + Stage 3 GPU). Proves a matrix cell.
#
# Remote/Stage 2 (real domain + DDNS + Let's Encrypt) is intentionally NOT run here: a
# home LAN collides with the existing stack + an upstream reverse proxy. That proof is
# the GCP harness's job (tests/gcp-vm/); LANHOST_REMOTE=1 is refused with a pointer to it.
#
# Scope note: GCP's "LAN-only ports blocked from WAN" matrix is not ported — a home host
# behind residential NAT has no clean public-IP vantage. This surface proves what only
# real silicon can (GPU passthrough/transcoding, UFW, systemd, autoheal).
#
# usage: run-fresh.sh [--persona NAME] [--gpu MODE] [--smb] [--no-wipe] [--nvidia] [--yes]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

NO_WIPE=0 NVIDIA=0 ASSUME_YES=0
# --persona/--gpu are applied as env overrides BEFORE load_env so they win over .env
# (load_env snapshots/restores env-set LANHOST_* across the source).
while (($#)); do
    case "$1" in
        --persona)
            export LANHOST_PERSONA="${2:-}"
            shift
            ;;
        --persona=*) export LANHOST_PERSONA="${1#*=}" ;;
        --gpu)
            export LANHOST_GPU="${2:-}"
            shift
            ;;
        --gpu=*) export LANHOST_GPU="${1#*=}" ;;
        --smb) export LANHOST_SMB=1 ;;
        --no-wipe) NO_WIPE=1 ;;
        --nvidia) NVIDIA=1 ;;
        --yes) ASSUME_YES=1 ;;
        -h | --help)
            echo "usage: run-fresh.sh [--persona NAME] [--gpu MODE] [--smb] [--no-wipe] [--nvidia] [--yes]"
            exit 0
            ;;
        *) die "unknown arg: $1" ;;
    esac
    shift
done

load_env
RP=$(shq "$TARGET_PATH")
TMP="${TMPDIR:-/tmp}"

# From-scratch GPU modes (nvidia-standard/unlock) need the driver removed (--nvidia wipe)
# and two reboots: one into a clean no-driver state before installing, and one after the
# driver install so the mediastack-setup.service resume unit finalizes the GPU on boot.
FROM_SCRATCH=0
case "$LANHOST_GPU" in nvidia-standard | nvidia-unlock)
    FROM_SCRATCH=1
    NVIDIA=1
    ;;
esac

# 0. Validate the matrix cell + generate the wizard steps BEFORE any destructive action.
#    wizard-steps.py is the single source of truth for which cells the LAN live-drive
#    supports; it exits non-zero (message on stderr) for unsupported toggle combos (e.g.
#    LANHOST_REMOTE=1, nvidia-unlock/intel/amd). Generating locally here means a
#    `--persona remote-nas` / `--persona nvidia-unlock` run is refused BEFORE we stop the
#    stack or remove the NVIDIA driver — not after. (DEMO baseline needs no wizard steps.)
STEPS_JSON=""
if ((MATRIX_USE_WIZARD)); then
    STEPS_JSON="$TMP/lan-host-wizard.steps.json"
    step "Validate matrix cell + generate wizard steps (pre-wipe): persona=${LANHOST_PERSONA:-custom} gpu=$LANHOST_GPU"
    python3 "$HERE/wizard-steps.py" >"$STEPS_JSON" \
        || die "matrix cell not supported by the LAN live-drive (see message above) — refusing BEFORE any destructive action"
    ok "matrix cell validated; steps written ($STEPS_JSON)"
fi

# 1. Push code FIRST — so a subsequent --nvidia wipe runs the CURRENT product gpu.sh
#    (clean-wipe sources scripts/setup/gpu.sh from the target), and so a push failure aborts
#    before we wipe a box we can't even sync to. The rsync excludes the box's .env and the
#    gitignored config RUNTIME dirs, so it doesn't disturb the runtime state the wipe clears
#    next — but it DOES ship the tracked pre-seeded configs under config/ (step 2a re-ships
#    them after the wipe deletes the whole tree).
bash "$HERE/rsync-push.sh" || die "rsync-push failed"

# 2. Wipe (delegates the destructive guard to clean-wipe.sh)
if ((NO_WIPE)); then
    step "Skip wipe (--no-wipe)"
else
    wipe_args=()
    ((NVIDIA)) && wipe_args+=(--nvidia)
    ((ASSUME_YES)) && wipe_args+=(--yes)
    bash "$HERE/clean-wipe.sh" "${wipe_args[@]}" || die "clean-wipe failed"

    # 2a. Restore tracked seed configs the wipe just deleted. clean-wipe.sh does `rm -rf config/`
    #     to guarantee no root-owned runtime leftovers, but config/ also holds *tracked*, version-
    #     controlled seed configs a real `git clone` always has and that setup.sh reads at install
    #     time — most importantly config/examples/public-indexers.yml, which Stage 1's
    #     `--public-indexers true` path HARD-ERRORS on when absent (so indexers=1 installs would
    #     fail without this). Re-push via the same gitignore-driven rsync (the SSOT for tracked-vs-
    #     runtime, so no hardcoded list to drift): it restores the tracked tree while still keeping
    #     the gitignored runtime dirs and .env out. Cheap — only the deleted seed files re-transfer.
    bash "$HERE/rsync-push.sh" || die "post-wipe rsync-push (restore tracked seed configs) failed"
fi

# 2b. From-scratch GPU: reboot into the clean, no-driver state before installing (the
#     --nvidia wipe removed the driver + restored nouveau; a boot makes that take effect).
#     The code pushed in step 1 persists across this reboot.
if ((FROM_SCRATCH)) && ((NO_WIPE == 0)); then
    reboot_and_wait "clean no-driver state" || die "reboot into clean state failed"
    verify_clean_nvidia || die "driver not fully removed after wipe+reboot — aborting the from-scratch install (a residual driver would route Stage 3 to the 'use existing' path)"
fi

# 3. Install — DEMO baseline or wizard-driven matrix cell.
if ((MATRIX_USE_WIZARD)); then
    step "Install (wizard-driven): persona=${LANHOST_PERSONA:-custom} gpu=$LANHOST_GPU indexers=$LANHOST_INDEXERS channel=$LANHOST_CHANNEL quality=$LANHOST_QUALITY bazarr=$LANHOST_BAZARR smb=$LANHOST_SMB"
    PLAIN="$TMP/lan-host-wizard.plain.log"
    drive_wizard "./setup.sh --full" "$PLAIN" "$STEPS_JSON"
    rc=$?
    if ((FROM_SCRATCH)); then
        # setup.sh runs under `set -euo pipefail` and the from-scratch path still EXITS 0 on
        # success: run_wizard's Stage 1 ran the install (WIZARD_RAN_INSTALL=true → setup.sh returns
        # 0 at setup.sh:227) and Stage 3 only QUEUES the reboot. So success is rc==0 AND the resume
        # marker present — NOT "marker present, any rc". A non-zero rc is a genuine setup.sh failure
        # (incl. rc=124 = a wizard_pty.py step/exit timeout or expect failure), even if a marker
        # lingers from a prior run; fail loudly rather than rebooting into a finalize that may never come.
        if ((rc != 0)); then
            bad "wizard-driven from-scratch setup.sh failed (rc=$rc$( ((rc == 124)) && printf '%s' ', wizard_pty.py step/exit timeout or expect failure'); see $PLAIN) — not trusting any finalize marker; aborting GPU finalize"
        elif ssh_t "test -f $RP/.nvidia-finalize-pending"; then
            ok "driver installed; setup.sh exit 0 + reboot marker (.nvidia-finalize-pending) present"
            reboot_and_wait "load new driver + finalize" || die "post-install reboot failed"
            wait_for_gpu_finalize || true # wait_for_gpu_finalize records its own bad on timeout
        elif [[ "$(ssh_t "grep -m1 '^STAGE_3_GPU_STATE=' $RP/.env 2>/dev/null | cut -d= -f2" 2>/dev/null | tr -d "\r\"'")" == complete ]]; then
            # rc==0, no reboot marker, but Stage 3 recorded STAGE_3_GPU_STATE=complete: the freshly
            # installed driver loaded + verified LIVE (nvidia-smi worked right after install), so no
            # reboot was needed and Stage 3 finalized the GPU in-line. Stage 3 correctly skips the
            # "Reboot now?" prompt in this case (stage3.sh:stage3_reboot_prompt_needed) — which is why
            # the wizard step is marked optional. This is a real success, distinct from a software
            # fallback (which would NOT record complete); the mode-aware probe (step 4) re-asserts the
            # GPU passthrough. Common when the GPU was warm from a prior matrix cell.
            ok "driver verified live; no reboot needed — GPU finalized in-line (STAGE_3_GPU_STATE=complete)"
        else
            # rc==0, no marker, AND state != complete → setup.sh finished without finalizing the GPU
            # (the software-fallback path). Rebooting + waiting for a finalize that never comes just
            # wastes ~10 min. Fail here instead.
            bad "setup.sh exit 0 but no .nvidia-finalize-pending marker and STAGE_3_GPU_STATE!=complete — GPU not finalized (software fallback?); see $PLAIN; skipping reboot+finalize"
        fi
    else
        ((rc == 0)) && ok "wizard-driven setup.sh --full exit 0" || bad "wizard-driven setup.sh --full failed (rc=$rc; transcript $PLAIN)"
        grep -qE 'MediaStack is running!|MediaStack setup complete' "$PLAIN" 2>/dev/null \
            && ok "completion banner present" || bad "completion banner missing (see $PLAIN)"
    fi
else
    step "Install (DEMO baseline): DEMO=1 ./setup.sh --full"
    SETUP_LOG="$TMP/lan-host-setup.log"
    : >"$SETUP_LOG"
    ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no -t "$SSH_DEST" \
        "cd $RP && DEMO=1 ./setup.sh --full" >>"$SETUP_LOG" 2>&1
    rc=$?
    ((rc == 0)) && ok "setup.sh --full exit 0" || bad "setup.sh --full exit=$rc (see $SETUP_LOG)"
    grep -q 'MediaStack is running!' "$SETUP_LOG" && ok "completion banner present" || bad "completion banner missing"
fi

# 4. Probe services (mode-aware: reads the LANHOST_* toggles to assert only what this
#    install deployed). Re-reads them from .env; flag overrides propagate via the env.
bash "$HERE/probe-services.sh" || bad "service probes reported failures"

# 5. Summary
summary "LAN-HOST $( ((MATRIX_USE_WIZARD)) && echo "WIZARD ${LANHOST_PERSONA:-custom}" || echo 'DEMO')"
