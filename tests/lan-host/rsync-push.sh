#!/usr/bin/env bash
# Push local code to a lan-host test target, excluding runtime state.
# Mirrors the gitignore-driven rsync contract in tests/gcp-vm/run-fresh.sh:
# --filter handles the gitignored runtime configs/.env. Pre-seeds now sync as
# templates under config/examples/ (tracked); the remote's create_config_dirs
# seeds the live config/<svc> copies from them on install.
#
# usage: rsync-push.sh [--dry-run]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/_lib.sh"

DRYRUN=0
while (($#)); do
    case "$1" in
        -n | --dry-run) DRYRUN=1 ;;
        -h | --help)
            echo "usage: rsync-push.sh [--dry-run]"
            exit 0
            ;;
        *) die "unknown arg: $1" ;;
    esac
    shift
done

load_env
RP=$(shq "$TARGET_PATH")

step "Rsync $REPO_ROOT -> $SSH_DEST:$TARGET_PATH"
ssh_t "mkdir -p $RP"

rsync_args=(
    -az --delete
    --filter=':- .gitignore' # excludes .env, config/ runtime dirs, override, .nvidia-* (gitignored)
    --exclude=.git
    --exclude=.env           # never ship the box's generated runtime .env
    --exclude='tests/.env.*' # never ship local test secrets/templates
    --exclude=docs/private/  # setup.sh reads docs/operations/image-digests.lock (stable channel),
    # so push docs/ — only carve out docs/private/ (mirrors the gcp harness)
    --exclude=docker-compose.override.yml
    # config/portainer/ is container-created and root-owned on a live target but is NOT
    # in .gitignore, so the gitignore filter won't skip it. Exclude it explicitly so the
    # `--delete` generator doesn't try to opendir it as the non-root push user (rsync
    # code 23). No-op in the wipe-first flow (gone by push time); needed for --no-wipe.
    --exclude=config/portainer/
)
((DRYRUN)) && rsync_args+=(-n)

# --delete protects excluded paths from removal on the receiver (no --delete-excluded),
# so the box's .env and runtime configs survive a code sync.
rsync "${rsync_args[@]}" -e "ssh -o StrictHostKeyChecking=no" \
    "$REPO_ROOT/" "$SSH_DEST:$TARGET_PATH/"
rc=$?
# 0 = ok; 24 = "source files vanished mid-transfer" (benign on a live tree). Anything
# else — notably 23 (partial transfer, e.g. unreadable root-owned dirs on the target) —
# means the push did NOT fully reconcile. Fail loudly so run-fresh.sh's `|| die` fires
# instead of proceeding to install on a half-synced repo.
((rc == 0 || rc == 24)) \
    || die "rsync failed (exit $rc) — push incomplete. If the target has a live, root-owned config tree, wipe it first (clean-wipe.sh)."

((DRYRUN)) && ok "rsync dry-run complete (nothing changed)" || ok "rsync complete"
