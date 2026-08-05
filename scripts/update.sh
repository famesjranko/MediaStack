#!/usr/bin/env bash
# =============================================================================
# MediaStack Update - Pull selected image channel and recreate containers
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

PRUNE_IMAGES=false

usage() {
    cat <<'EOF'
Usage: ./scripts/update.sh [--prune]

Pull the configured MediaStack image channel and recreate containers.

IMAGE_CHANNEL in .env controls the channel:
  stable  MediaStack-tested digests from docs/operations/image-digests.lock
  latest  Current upstream image tags from docker-compose.yml

Options:
  --prune     Also run docker image prune -f after the update. This is
              host-wide and removes dangling images from every Docker project
              on this host.
  -h, --help  Show this help.
EOF
}

while (($# > 0)); do
    case "$1" in
        --prune)
            PRUNE_IMAGES=true
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi
CONFIG_FILE="$SCRIPT_DIR/config.yml"
source "$SCRIPT_DIR/scripts/lib/common.sh"
source "$SCRIPT_DIR/scripts/setup/override.sh"
source "$SCRIPT_DIR/scripts/setup/storage.sh"

IMAGE_CHANNEL="${IMAGE_CHANNEL:-stable}"
case "${IMAGE_CHANNEL,,}" in
    stable | latest)
        IMAGE_CHANNEL="${IMAGE_CHANNEL,,}"
        ;;
    *)
        echo "Invalid IMAGE_CHANNEL '${IMAGE_CHANNEL}'. Use 'stable' or 'latest'." >&2
        exit 1
        ;;
esac

detect_host_memory
generate_override "${JELLYFIN_GPU:-none}"

# Capture-then-grep avoids SIGPIPE+pipefail race: `compose ps | grep -q` reads
# false because grep's early exit SIGPIPE-signals docker compose under
# `set -euo pipefail`. Word boundaries (\b) keep `npm` from matching `pnpm` in
# seerr's COMMAND column.
PROFILE_ARGS=""
PROXY_PS=$(docker compose --profile proxy ps --status running 2>/dev/null || true)
if grep -qE '\b(npm|fail2ban|ddns-updater)\b' <<<"$PROXY_PS"; then
    PROFILE_ARGS="$PROFILE_ARGS --profile proxy"
    echo "Proxy profile detected (NPM + fail2ban + DDNS) - updating those too"
fi
REMOTE_PS=$(docker compose --profile remote ps --status running 2>/dev/null || true)
if grep -qE '\bwireguard\b' <<<"$REMOTE_PS"; then
    PROFILE_ARGS="$PROFILE_ARGS --profile remote"
    echo "Remote access profile detected - updating those too"
fi
SUBTITLES_PS=$(docker compose --profile subtitles ps --status running 2>/dev/null || true)
if grep -qE '\bbazarr\b' <<<"$SUBTITLES_PS"; then
    PROFILE_ARGS="$PROFILE_ARGS --profile subtitles"
    echo "Subtitles profile detected (Bazarr) - updating that too"
fi
AUTOHEAL_PS=$(docker compose --profile autoheal ps --status running 2>/dev/null || true)
if grep -qE '\bautoheal\b' <<<"$AUTOHEAL_PS"; then
    PROFILE_ARGS="$PROFILE_ARGS --profile autoheal"
    echo "Autoheal profile detected - updating that too"
fi

if [[ "$IMAGE_CHANNEL" == "latest" ]]; then
    echo "Pulling latest upstream image tags..."
else
    echo "Pulling MediaStack-tested stable image digests..."
fi
PULL_OK=false
BACKOFF=10
for attempt in 1 2 3; do
    if docker compose $PROFILE_ARGS pull 2>&1; then
        PULL_OK=true
        break
    fi
    if ((attempt < 3)); then
        echo "Pull failed (attempt ${attempt}/3). Retrying in ${BACKOFF}s..."
        sleep "$BACKOFF"
        BACKOFF=$((BACKOFF * 2))
    fi
done
if ! $PULL_OK; then
    echo "WARNING: Some images could not be pulled after 3 attempts."
    echo "Continuing with cached images..."
fi

echo ""
echo "Recreating containers with new images..."
storage_guard_before_start
docker compose $PROFILE_ARGS up -d --remove-orphans

# After the image bumps, verify each log-parsed service's fail2ban filter still
# matches its (possibly changed) log format — the silent break the day-2 health
# checks target. Wait briefly for jellyfin/seerr to become ready so the active
# probe lands. Silent when fail2ban isn't running. health.sh is set -e safe and
# sources its own deps.
if source "$SCRIPT_DIR/scripts/lib/health.sh" 2>/dev/null && _health_f2b_running; then
    echo ""
    echo "Verifying fail2ban protection still matches current log formats..."
    for _hc_svc in jellyfin seerr; do
        docker inspect "$_hc_svc" >/dev/null 2>&1 || continue # not in this deploy → don't wait on it
        for _hc_i in $(seq 1 30); do
            _health_svc_healthy "$_hc_svc" && break
            sleep 2
        done
    done
    health_present_fail2ban_updates jellyfin seerr
fi

echo ""
if $PRUNE_IMAGES; then
    echo "Cleaning up dangling Docker images across this host..."
    echo "WARNING: docker image prune is host-wide; it can remove dangling images from other Docker projects on this machine."
    # NOTE: docker image prune is host-wide — it removes dangling (untagged,
    # unreferenced) images from every Docker project on this host, not just
    # MediaStack's. The obvious scoping fix `--filter label=com.docker.compose.project=mediastack`
    # is a no-op: compose project labels live on containers/networks/volumes, not
    # on pulled images, and MediaStack uses `image:` (no `build:`). Running
    # containers' images are protected; the prune only sweeps untagged leftovers
    # from prior `compose pull` cycles. On a single-project host this is what
    # users want. Multi-project hosts: see https://docs.docker.com/reference/cli/docker/image/prune/
    docker image prune -f
else
    echo "Skipping image prune. Dangling images from old service versions are left in place."
    echo "Run ./scripts/update.sh --prune to reclaim that disk space with Docker's host-wide image prune."
fi

echo ""
echo "Update complete. Current status:"
docker compose $PROFILE_ARGS ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
