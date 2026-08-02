#!/usr/bin/env bash
# Shared helpers for the lan-host real-host test harness.
# Sourced by rsync-push.sh, clean-wipe.sh, probe-services.sh, run-fresh.sh.
#
# Mirrors the conventions in tests/gcp-vm/run-fresh.sh (env loader, step/ok/bad,
# FAILS[] summary, the Stage 2 wizard input contract) so both live-host surfaces
# read the same way. See tests/lan-host/README.md.

# Resolve repo root from this lib's location: tests/lan-host/_lib.sh -> repo root.
LANHOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LANHOST_LIB_DIR/../.." && pwd)"
ENV_FILE="$REPO_ROOT/tests/.env.lan-host"

FAILS=()
step() {
    echo
    echo "=== [$(date +%H:%M:%S)] $*"
}
ok() { echo "  ✓ $*"; }
bad() {
    echo "  ✗ $*"
    FAILS+=("$*")
}
shq() { printf '%q' "$1"; } # shell-quote a value for the remote shell
die() {
    echo "✗ $*" >&2
    exit 2
}

# Fail fast if any named variable is empty/unset.
require() {
    local missing=() v
    for v in "$@"; do
        [[ -n "${!v:-}" ]] || missing+=("$v")
    done
    ((${#missing[@]} == 0)) || die "missing required var(s) in tests/.env.lan-host: ${missing[*]}"
}

# Load tests/.env.lan-host into the environment and derive connection vars.
load_env() {
    [[ -f "$ENV_FILE" ]] \
        || die "$ENV_FILE not found — copy tests/.env.lan-host.example to tests/.env.lan-host and fill it in"
    # LANHOST_* already set in the environment (run-fresh.sh's --persona/--gpu flags, or
    # values inherited by a child script) must win over the .env file. Snapshot the
    # non-empty ones, source .env, then restore them — so overrides survive the source
    # and propagate consistently from a parent script to the probe it invokes.
    local _k
    declare -A _ov=()
    for _k in LANHOST_PERSONA LANHOST_GPU LANHOST_INDEXERS LANHOST_CHANNEL LANHOST_QUALITY LANHOST_BAZARR LANHOST_SMB LANHOST_REMOTE; do
        [[ -n "${!_k:-}" ]] && _ov[$_k]="${!_k}"
    done
    set -a
    source "$ENV_FILE"
    set +a
    for _k in "${!_ov[@]}"; do printf -v "$_k" '%s' "${_ov[$_k]}"; done
    : "${NPM_LE_SERVER:=https://acme-staging-v02.api.letsencrypt.org/directory}"
    require TARGET_HOST TARGET_USER
    : "${TARGET_PATH:=/home/$TARGET_USER/MediaStack}"
    # rsync --delete (rsync-push.sh) and `sudo rm -rf $RP/...` (clean-wipe.sh) operate
    # under TARGET_PATH. Refuse root-ish / bare-home values so a misconfigured
    # TARGET_PATH=/ or =/home/user can't mirror-delete outside the repo directory.
    local tp="${TARGET_PATH%/}"
    [[ "$tp" == /*/?* ]] || die "TARGET_PATH must be an absolute path at least two levels deep (got '$TARGET_PATH')"
    case "$tp" in /home/*) [[ "$tp" == /home/*/* ]] || die "TARGET_PATH '$tp' is a bare home dir — point it at a subdirectory" ;; esac
    TARGET_PATH="$tp"
    SSH_DEST="$TARGET_USER@$TARGET_HOST"
    load_matrix
}

# Normalise the choice-matrix toggles (set in tests/.env.lan-host, already sourced
# by load_env). A LANHOST_PERSONA expands into a toggle preset; any explicit
# LANHOST_* value already in the environment wins (`:=` only fills the unset/empty).
# Probe-services.sh + run-fresh.sh read these to drive the right install path and to
# assert only the services a given install actually deploys.
load_matrix() {
    case "${LANHOST_PERSONA:-}" in
        "" | none) ;;
        lan-minimal)
            : "${LANHOST_GPU:=none}"
            : "${LANHOST_QUALITY:=720p-compact}"
            ;;
        nvidia-existing)
            : "${LANHOST_GPU:=nvidia-existing}"
            ;;
        nvidia-standard)
            : "${LANHOST_GPU:=nvidia-standard}"
            ;;
        nvidia-unlock)
            : "${LANHOST_GPU:=nvidia-unlock}"
            : "${LANHOST_QUALITY:=1080p-large}"
            ;;
        remote-nas)
            : "${LANHOST_REMOTE:=1}"
            : "${LANHOST_INDEXERS:=1}"
            : "${LANHOST_CHANNEL:=latest}"
            : "${LANHOST_BAZARR:=1}"
            ;;
        *) die "unknown LANHOST_PERSONA '$LANHOST_PERSONA' (lan-minimal|nvidia-existing|nvidia-standard|nvidia-unlock|remote-nas)" ;;
    esac
    # Global defaults for anything still unset → the DEMO Mode A baseline.
    : "${LANHOST_GPU:=none}"
    : "${LANHOST_INDEXERS:=0}"
    : "${LANHOST_CHANNEL:=stable}"
    : "${LANHOST_QUALITY:=1080p-balanced}"
    : "${LANHOST_BAZARR:=0}"
    : "${LANHOST_SMB:=0}"
    : "${LANHOST_REMOTE:=0}"
    # Validate enums (fail-fast on a typo'd toggle).
    case "$LANHOST_GPU" in none | intel | amd | nvidia-existing | nvidia-standard | nvidia-unlock) ;; *) die "LANHOST_GPU '$LANHOST_GPU' invalid" ;; esac
    case "$LANHOST_INDEXERS" in 0 | 1) ;; *) die "LANHOST_INDEXERS must be 0 or 1 (got '$LANHOST_INDEXERS')" ;; esac
    case "$LANHOST_CHANNEL" in stable | latest) ;; *) die "LANHOST_CHANNEL must be stable or latest (got '$LANHOST_CHANNEL')" ;; esac
    case "$LANHOST_QUALITY" in 720p-compact | 720p-balanced | 720p-large | 1080p-compact | 1080p-balanced | 1080p-large) ;; *) die "LANHOST_QUALITY must be <720p|1080p>-<compact|balanced|large> (got '$LANHOST_QUALITY')" ;; esac
    case "$LANHOST_BAZARR" in 0 | 1) ;; *) die "LANHOST_BAZARR must be 0 or 1 (got '$LANHOST_BAZARR')" ;; esac
    case "$LANHOST_SMB" in 0 | 1) ;; *) die "LANHOST_SMB must be 0 or 1 (got '$LANHOST_SMB')" ;; esac
    case "$LANHOST_REMOTE" in 0 | 1) ;; *) die "LANHOST_REMOTE must be 0 or 1 (got '$LANHOST_REMOTE')" ;; esac
    # Drive the real wizard (vs the fast DEMO baseline) whenever anything deviates from
    # the DEMO defaults — a persona, a GPU mode, indexers, latest channel, non-balanced
    # quality, Bazarr, SMB, or remote.
    MATRIX_USE_WIZARD=0
    if [[ -n "${LANHOST_PERSONA:-}" ]] \
        || [[ "$LANHOST_GPU" != none ]] || [[ "$LANHOST_INDEXERS" == 1 ]] \
        || [[ "$LANHOST_CHANNEL" != stable ]] || [[ "$LANHOST_QUALITY" != 1080p-balanced ]] \
        || [[ "$LANHOST_BAZARR" == 1 ]] || [[ "$LANHOST_SMB" == 1 ]] || [[ "$LANHOST_REMOTE" == 1 ]]; then
        MATRIX_USE_WIZARD=1
    fi
    export LANHOST_PERSONA LANHOST_GPU LANHOST_INDEXERS LANHOST_CHANNEL LANHOST_QUALITY \
        LANHOST_BAZARR LANHOST_SMB LANHOST_REMOTE MATRIX_USE_WIZARD
}

# ssh wrappers — non-interactive test box, so skip the host-key prompt churn.
ssh_t() { ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_DEST" "$@"; }
ssh_tty() { ssh -t -o StrictHostKeyChecking=no "$SSH_DEST" "$@"; }

# Print a FAILS[] summary and return 0/1 (use as the final command for exit code).
summary() {
    local label="${1:-LAN-HOST}" f
    echo
    echo "=== $label SUMMARY ==="
    if ((${#FAILS[@]} == 0)); then
        echo "✓ ALL CHECKS PASSED"
        return 0
    fi
    echo "✗ ${#FAILS[@]} FAILURE(S):"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    return 1
}

# Drive the REAL, un-stubbed wizard on the target via tests/lib/wizard_pty.py,
# co-located on the box (the same PTY engine the DinD wizard-ui-* scenarios use).
#   $1 = setup command to drive, e.g. "./setup.sh --full"
#   $2 = local path to receive the plain (ANSI-stripped) transcript for review
#   $3 = local steps-JSON, generated + cell-validated by run-fresh.sh BEFORE any wipe
# wizard_pty.py expect/sends the real prompts and fails loudly (exit 124) on any step/exit
# timeout or expect failure. Returns wizard_pty.py's exit code (0 = all steps sent and setup.sh
# exited 0; 124 = a timeout/exception; otherwise setup.sh's own non-zero exit). Replaces the old
# positional printf heredoc.
drive_wizard() {
    local cmd="$1" local_plain="$2" local_steps="$3"
    local r_steps='/tmp/lan-host-wizard.steps.json'
    local r_raw='/tmp/lan-host-wizard.raw.log'
    local r_plain='/tmp/lan-host-wizard.plain.log'
    local rp
    rp=$(shq "$TARGET_PATH")

    [[ -s "$local_steps" ]] \
        || die "drive_wizard: steps file '$local_steps' missing/empty (run-fresh.sh generates it pre-wipe)"

    # Push the steps that run-fresh.sh generated from the LOCAL wizard-steps.py — the copy
    # under review — and which already validated the matrix cell BEFORE any destruction.
    # Single generation point, no dependence on the target's (possibly stale) checkout.
    step "Push wizard steps to target ($r_steps)"
    ssh_t "cat > $r_steps" <"$local_steps" || die "failed to push wizard steps to target"

    step "Drive real wizard via PTY: $cmd"
    ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no "$SSH_DEST" \
        "cd $rp && python3 tests/lib/wizard_pty.py --command $(shq "$cmd") --steps $r_steps \
--raw-log $r_raw --plain-log $r_plain --cwd $rp --step-timeout 60 --exit-timeout 2400 --expect-exit 0"
    local rc=$?
    ssh_t "cat $r_plain 2>/dev/null" >"$local_plain" 2>/dev/null || true
    return $rc
}

# Reboot the target and block until SSH answers again. The from-scratch GPU flow needs
# reboots — driver removal/install only take effect across a boot.
reboot_and_wait() {
    local why="${1:-reboot}" i
    step "Reboot target ($why) — waiting for it to come back"
    # The reboot drops this connection, so ignore the ssh exit status.
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 "$SSH_DEST" 'sudo systemctl reboot' >/dev/null 2>&1 || true
    sleep 15 # let it actually go down before polling
    for i in $( # ~5 min of polling after the initial 15s
        seq 1 60
    ); do
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 "$SSH_DEST" 'true' 2>/dev/null; then
            ok "target back after ~$((15 + i * 5))s"
            return 0
        fi
        sleep 5
    done
    bad "target did not return within timeout after reboot ($why)"
    return 1
}

# After the post-install reboot, mediastack-setup.service finalizes the GPU on boot
# (loads the new driver, verifies, restarts jellyfin with the GPU). Poll the target's
# .env until STAGE_3_GPU_STATE=complete (or time out ~10 min).
wait_for_gpu_finalize() {
    local rp i state="" max=60 # 60×10s = 10 min — Standard: post-reboot load+verify+nvenc+transcode
    rp=$(shq "$TARGET_PATH")
    # Unlock finalizes via the .run path. When nouveau blocked the pre-reboot install (common on a
    # Maxwell box driving the console), the kernel-module COMPILE lands here on top of nvidia-patch +
    # verify + test transcode — so give it a wider budget rather than mistaking a slow compile for a
    # stuck finalize.
    [[ "${LANHOST_GPU:-}" == nvidia-unlock ]] && max=120 # up to ~20 min for the post-reboot .run build
    step "Wait for post-reboot GPU finalize (mediastack-setup.service)"
    for i in $(seq 1 "$max"); do
        state=$(ssh_t "grep -m1 '^STAGE_3_GPU_STATE=' $rp/.env 2>/dev/null | cut -d= -f2" 2>/dev/null | tr -d "\r\"'")
        if [ "$state" = complete ]; then
            ok "GPU finalize complete after ~$((i * 10))s"
            return 0
        fi
        sleep 10
    done
    bad "GPU finalize did not reach STAGE_3_GPU_STATE=complete in time (last='${state:-?}')"
    return 1
}

# Assert the target is genuinely driver-free (run between the --nvidia wipe+reboot and a
# from-scratch install, so a residual driver can't silently derail the fresh-install path
# — setup.sh would otherwise route to the "use existing driver" branch). Checks the things
# that actually matter: no driver packages (container toolkit kept), no nvidia kernel
# module loaded, nvidia-smi gone.
verify_clean_nvidia() {
    step "Verify clean no-driver state (uninstall actually complete?)"
    local rp
    rp=$(shq "$TARGET_PATH")
    # Residual apt-managed driver packages: count via the PRODUCT's OWN selector
    # (gpu.sh:_nvidia_debian_driver_packages) rather than a parallel regex, so this can't drift from
    # the exact set the wizard purges. Sourced with gpu.sh's documented context (SCRIPT_DIR +
    # common.sh). `wc -l` reads all input (no SIGPIPE) and always exits 0; `|| echo ERR` fires only
    # when sourcing/declare fails — so a sourcing failure can't masquerade as "0 packages" (false-PASS).
    local drv
    drv=$(ssh_t "cd $rp && SCRIPT_DIR=\$(pwd) bash -c 'source scripts/lib/common.sh && source scripts/setup/gpu.sh && declare -F _nvidia_debian_driver_packages >/dev/null && _nvidia_debian_driver_packages | wc -l || echo ERR'" 2>/dev/null)
    drv=${drv//[[:space:]]/}
    # Kernel module + nvidia-smi + apt-consistency in one quoted heredoc (sent verbatim → no
    # local/remote quote-nesting hazard). The .run case (not apt-managed) is caught by MOD/SMI below.
    local out mod smi brk brkmsg
    out=$(
        ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_DEST" bash -s <<'REMOTE'
echo "MOD=$(lsmod 2>/dev/null | awk '/^nvidia/{print $1}' | tr '\n' ',')"
echo "SMI=$(command -v nvidia-smi >/dev/null && echo present || echo absent)"
# Judge apt by apt-get check's EXIT STATUS (0 = consistent), not a substring match: an
# interrupted dpkg leaves a broken state that need not print the literal "unmet"/"broken".
# Mirrors the product's own gate in scripts/setup/packages.sh:install_base_packages.
aptmsg=$(sudo apt-get check 2>&1); echo "BRK=$?"
echo "BRKMSG=$(printf '%s' "$aptmsg" | tr '\n\r' '  ' | cut -c1-160)"
REMOTE
    )
    mod=$(printf '%s\n' "$out" | sed -n 's/^MOD=//p')
    smi=$(printf '%s\n' "$out" | sed -n 's/^SMI=//p')
    brk=$(printf '%s\n' "$out" | sed -n 's/^BRK=//p' | tr -dc '0-9')
    brkmsg=$(printf '%s\n' "$out" | sed -n 's/^BRKMSG=//p')
    local clean=1
    case "$drv" in
        0) ok "no nvidia driver packages (via gpu.sh:_nvidia_debian_driver_packages; toolkit kept)" ;;
        '' | ERR | *[!0-9]*)
            bad "could not count driver packages via gpu.sh:_nvidia_debian_driver_packages (got '${drv:-empty}') — cannot confirm clean removal"
            clean=0
            ;;
        *)
            bad "nvidia driver packages still installed ($drv)"
            clean=0
            ;;
    esac
    [ -z "${mod//,/}" ] && ok "no nvidia kernel module loaded" || {
        bad "nvidia kernel module still loaded (${mod%,})"
        clean=0
    }
    [ "$smi" = absent ] && ok "nvidia-smi absent" || {
        bad "nvidia-smi still present (driver remnant)"
        clean=0
    }
    [ "${brk:-1}" = 0 ] && ok "apt dependency state consistent" || {
        bad "apt reports broken/unmet deps (apt-get check rc=${brk:-?}: ${brkmsg:-no detail}) — would block setup's prerequisite install"
        clean=0
    }
    ((clean))
}
