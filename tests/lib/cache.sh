# tests/lib/cache.sh — image caching to avoid Docker Hub rate limits.
#
# Two complementary mechanisms:
#
# 1. Pull-through registry mirror (`ms-registry-mirror` container bound on the
#    Docker bridge gateway). DinD's inner dockerd is configured to use it as a
#    mirror for docker.io. First pull of any image hits Hub once and caches;
#    all subsequent DinD runs are free.
#
# 2. Image sideload from host Docker. After DinD starts, any image present on
#    the host (e.g. because you run MediaStack in production on the same box)
#    is `docker save`'d and piped into the DinD daemon directly. Zero network,
#    works offline, near-instant.
#
# Both run automatically when tests/run.sh spins up DinD. Disable by setting
# `MS_TEST_NO_CACHE=1`.

: "${MS_CACHE_MIRROR_NAME:=ms-registry-mirror}"
: "${MS_CACHE_MIRROR_PORT:=5000}"
: "${MS_CACHE_MIRROR_VOLUME:=ms-registry-cache}"
: "${MS_CACHE_MIRROR_STARTED_BY_RUN:=0}"
: "${MS_CACHE_MIRROR_KEEP:=0}"
# Use the upstream Distribution image from GitHub Container Registry, not
# docker.io/registry. Docker Hub rate-limits anonymous pulls; GHCR doesn't,
# which matters because bootstrapping the mirror itself would otherwise be
# gated by the very thing the mirror is meant to solve.
: "${MS_CACHE_MIRROR_IMAGE:=ghcr.io/distribution/distribution:3.0.0}"

# Start (or reuse) the pull-through mirror. Idempotent.
cache_mirror_up() {
    if [[ "${MS_TEST_NO_CACHE:-0}" == "1" ]]; then
        MS_CACHE_MIRROR_STARTED_BY_RUN=0
        return 0
    fi

    if docker ps --format '{{.Names}}' | grep -qx "$MS_CACHE_MIRROR_NAME"; then
        MS_CACHE_MIRROR_STARTED_BY_RUN=1
        echo -e "${BLUE}[cache]${NC} reusing mirror: $MS_CACHE_MIRROR_NAME"
        return 0
    fi

    # Restart stopped container if present, else create fresh.
    if docker ps -a --format '{{.Names}}' | grep -qx "$MS_CACHE_MIRROR_NAME"; then
        docker start "$MS_CACHE_MIRROR_NAME" >/dev/null || return 1
        MS_CACHE_MIRROR_STARTED_BY_RUN=1
        echo -e "${BLUE}[cache]${NC} started existing mirror: $MS_CACHE_MIRROR_NAME"
        return 0
    fi

    echo -e "${BLUE}[cache]${NC} starting pull-through mirror ($MS_CACHE_MIRROR_NAME) on :$MS_CACHE_MIRROR_PORT"
    # --restart=no: the mirror is a dev convenience for this repo's test
    # harness, not production infra. It's started on demand by tests/run.sh
    # and torn down on normal runner exit via cache_mirror_down (which keeps
    # the volume). The cache survives container removal so next session re-uses it.
    # Bind on the Docker bridge gateway (default 172.17.0.1) so DinD's inner
    # dockerd can reach it via host.docker.internal. Binding on 127.0.0.1
    # would be more private but blocks access from child Docker containers,
    # which is the entire point of the mirror. Detect the gateway dynamically
    # so this works on boxes that customise the default bridge subnet.
    local bridge_ip
    bridge_ip=$(docker network inspect bridge --format '{{ (index .IPAM.Config 0).Gateway }}' 2>/dev/null)
    bridge_ip="${bridge_ip:-172.17.0.1}"

    if ! docker run -d \
        --name "$MS_CACHE_MIRROR_NAME" \
        --restart no \
        -v "$MS_CACHE_MIRROR_VOLUME":/var/lib/registry \
        -e REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io \
        -p "${bridge_ip}:${MS_CACHE_MIRROR_PORT}:5000" \
        "$MS_CACHE_MIRROR_IMAGE" >/dev/null; then
        return 1
    fi
    MS_CACHE_MIRROR_STARTED_BY_RUN=1
    echo -e "${BLUE}[cache]${NC} mirror bound on ${bridge_ip}:${MS_CACHE_MIRROR_PORT} (accessible from Docker containers, not LAN)"
}

# Tear down the mirror container but keep its volume. Use between dev sessions
# when you don't want the container idling. Next cache_mirror_up re-attaches
# the volume and the cache is intact.
cache_mirror_stop() {
    if docker ps -a --format '{{.Names}}' | grep -qx "$MS_CACHE_MIRROR_NAME"; then
        if ! docker rm -f "$MS_CACHE_MIRROR_NAME" >/dev/null; then
            return 1
        fi
        echo -e "${BLUE}[cache]${NC} stopped mirror (cache volume $MS_CACHE_MIRROR_VOLUME preserved)"
    fi
    MS_CACHE_MIRROR_STARTED_BY_RUN=0
}

# Stop the MediaStack mirror used by this run, preserving the cache volume.
# Set MS_CACHE_MIRROR_KEEP=1 to keep it warm after normal test exits.
cache_mirror_down() {
    [[ "${MS_CACHE_MIRROR_KEEP:-0}" == "1" ]] && return 0
    [[ "${MS_CACHE_MIRROR_STARTED_BY_RUN:-0}" == "1" ]] || return 0
    cache_mirror_stop
}

# Sideload into DinD any images already present on the host that the compose
# file references. Images missing on the host fall through to the mirror on
# first use. Safe to call more than once.
cache_preload_into_dind() {
    [[ "${MS_TEST_NO_CACHE:-0}" == "1" ]] && return 0

    local compose="${REPO_ROOT}/docker-compose.yml"
    [[ -f "$compose" ]] || return 0

    # Compose image tags. Use python3 for robustness over awk/grep (handles
    # quoted strings, variable substitutions we can't evaluate).
    local images
    images=$(
        python3 - "$compose" <<'PYEOF'
import sys, re, yaml
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}
imgs = set()
for svc in (c.get('services') or {}).values():
    img = svc.get('image')
    if img and '${' not in img:   # skip variable-templated images
        imgs.add(img)
for i in sorted(imgs):
    print(i)
PYEOF
    )

    local loaded=0 skipped=0
    for img in $images; do
        if ! docker image inspect "$img" >/dev/null 2>&1; then
            skipped=$((skipped + 1))
            continue
        fi
        docker save "$img" | docker exec -i "$DIND_NAME" docker load >/dev/null 2>&1 \
            && loaded=$((loaded + 1))
    done

    echo -e "${BLUE}[cache]${NC} sideloaded $loaded image(s) from host; $skipped not on host (mirror will handle)"
}

# One-shot maintenance: purge the cache volume. Does not remove the mirror
# container — that's a trivial `docker rm -f`.
cache_mirror_purge() {
    docker rm -f "$MS_CACHE_MIRROR_NAME" >/dev/null 2>&1 || true
    docker volume rm "$MS_CACHE_MIRROR_VOLUME" >/dev/null 2>&1 || true
    echo -e "${BLUE}[cache]${NC} purged cache (container + volume)"
}
