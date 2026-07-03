# tests/lib/dind.sh — Docker-in-Docker helpers
# Source-time: define config. No side effects.

: "${DIND_NAME:=ms-test-dind}"
: "${DIND_IMAGE:=ms-dind:debian}"
: "${DIND_TIMEOUT:=30}"
: "${DIND_PORTS:=}"

# Repo root = parent of tests/
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Build the Debian DinD image from tests/Dockerfile.dind if it's missing.
# Cached by docker's layer cache — no-op once built unless the Dockerfile
# changes. Stays on debian:bookworm-slim to match production's distro.
dind_build() {
    if docker image inspect "$DIND_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    echo -e "${BLUE}[dind]${NC} building $DIND_IMAGE from tests/Dockerfile.dind"
    docker build -q -t "$DIND_IMAGE" -f "$REPO_ROOT/tests/Dockerfile.dind" "$REPO_ROOT/tests" >/dev/null
}

# Wipe any previous container and launch a fresh DinD. Idempotent.
# -v on removal is essential: our Dockerfile declares /var/lib/docker as a
# VOLUME (for the inner daemon's graph driver) so every launch creates an
# anonymous volume. Without -v those volumes pile up at ~2-5 GB each until the
# host disk fills. Same flag is used in dind_down().
dind_up() {
    dind_build
    docker rm -fv "$DIND_NAME" >/dev/null 2>&1 || true
    echo -e "${BLUE}[dind]${NC} starting $DIND_NAME ($DIND_IMAGE)"

    # If the pull-through mirror is up, point DinD's inner dockerd at it. The
    # mirror lives on the host at 127.0.0.1:$PORT — from inside DinD we reach
    # it via the Docker bridge gateway (host.docker.internal with --add-host).
    # Our dind-entrypoint.sh mirrors docker:dind's behaviour of prepending
    # `dockerd` when the first CMD arg starts with `-`, so we can pass
    # dockerd flags as positional args.
    local hostargs=() dockerd_args=() portargs=()
    for port_spec in $(echo "$DIND_PORTS" | tr ',' ' '); do
        [[ -n "$port_spec" ]] && portargs+=(-p "$port_spec")
    done
    if [[ "${MS_TEST_NO_CACHE:-0}" != "1" ]] \
        && docker ps --format '{{.Names}}' | grep -qx "${MS_CACHE_MIRROR_NAME:-ms-registry-mirror}"; then
        local mirror_host="host.docker.internal:${MS_CACHE_MIRROR_PORT:-5000}"
        hostargs+=(--add-host=host.docker.internal:host-gateway)
        dockerd_args+=(
            "--registry-mirror=http://${mirror_host}"
            "--insecure-registry=${mirror_host}"
        )
        echo -e "${BLUE}[dind]${NC} using registry mirror: http://${mirror_host}"
    fi

    docker run -d --privileged \
        --name "$DIND_NAME" \
        -e DOCKER_TLS_CERTDIR= \
        "${hostargs[@]}" \
        "${portargs[@]}" \
        "$DIND_IMAGE" \
        "${dockerd_args[@]}" >/dev/null

    local waited=0
    while (( waited < DIND_TIMEOUT )); do
        if docker exec "$DIND_NAME" docker info >/dev/null 2>&1; then
            echo -e "${BLUE}[dind]${NC} dockerd ready (${waited}s)"
            # Pre-create the workdir so `dind_exec` works from this point on,
            # even before the repo has been copied in. All runtime deps
            # (bash/python3/curl/grep/sed/gettext-base/docker-compose-v2)
            # are pre-baked into the Debian DinD image — see tests/Dockerfile.dind.
            docker exec "$DIND_NAME" mkdir -p /root/MediaStack >/dev/null 2>&1
            return 0
        fi
        sleep 1; waited=$((waited + 1))
    done
    echo -e "${RED}[dind]${NC} dockerd did not come up in ${DIND_TIMEOUT}s"
    docker logs "$DIND_NAME" 2>&1 | tail -30
    return 1
}

# Copy the working tree into the DinD at /root/MediaStack, excluding .git and
# runtime state. Uses tar-pipe so the copy is single-pass and honours excludes.
dind_copy_repo() {
    echo -e "${BLUE}[dind]${NC} copying repo to /root/MediaStack"
    docker exec "$DIND_NAME" mkdir -p /root/MediaStack
    # Exclude: .git, .env (host's local), nvidia-patch clone, any backups,
    # runtime subdirs of config/ that are gitignored. The pre-seed *templates*
    # under config/examples/defaults/ must be included — create_config_dirs (and
    # create_config_dirs_in_dind) seed the live config/{fail2ban,homepage,jackett,
    # qbittorrent} copies from them. config/examples/ is not excluded below, so
    # the templates always reach DinD.
    tar --exclude=./.git \
        --exclude=./.nvidia-patch \
        --exclude=./.env \
        --exclude=./backups \
        --exclude=./tests/.dind-state \
        --exclude=./config/portainer \
        --exclude=./config/beszel \
        -cf - -C "$REPO_ROOT" . \
        | docker exec -i "$DIND_NAME" tar -xf - -C /root/MediaStack
    # Detect a broken copy (PIPESTATUS covers both ends regardless of pipefail).
    # Without this a partial/failed extract goes unnoticed and every later
    # `docker exec -w /root/MediaStack` chdir-fails, cascading across the shared
    # DinD in --reset-between runs.
    local st=("${PIPESTATUS[@]}")
    if [[ "${st[0]}" -ne 0 || "${st[1]}" -ne 0 ]]; then
        echo -e "${RED}[dind]${NC} repo copy tar pipe failed (host tar=${st[0]}, container tar=${st[1]})"
        return 1
    fi
    if ! docker exec -w /root/MediaStack "$DIND_NAME" test -f docker-compose.yml; then
        echo -e "${RED}[dind]${NC} repo copy incomplete: /root/MediaStack/docker-compose.yml missing"
        return 1
    fi
}

# Run a command inside the DinD with /root/MediaStack as CWD.
# Usage: dind_exec "docker compose ps"
dind_exec() {
    docker exec -w /root/MediaStack "$DIND_NAME" sh -c "$*"
}

# Strip services from the DinD copy's docker-compose.yml. Used when a local
# image for a service isn't available and we want to run a subset E2E without
# burning Hub pulls. Services are given as MS_TEST_STRIP_SERVICES (comma or
# space separated). Scenarios should check the same env var and skip the
# relevant assertions. The host's docker-compose.yml is never touched.
dind_strip_services() {
    local strip="${MS_TEST_STRIP_SERVICES:-}"
    [[ -z "$strip" ]] && return 0

    local list
    list=$(echo "$strip" | tr ',' ' ')
    echo -e "${BLUE}[dind]${NC} stripping services from compose: $list"

    # Edit compose inside DinD via python3 (already installed by dind_up).
    # -i is essential: without it docker exec closes stdin, the heredoc
    # doesn't reach python's `-` stdin reader, and the script silently no-ops.
    docker exec -i -w /root/MediaStack "$DIND_NAME" python3 - "$list" <<'PYEOF'
import sys, yaml
strip = set(sys.argv[1].split())
with open('docker-compose.yml') as f:
    c = yaml.safe_load(f) or {}
svcs = c.get('services') or {}
removed = [s for s in strip if s in svcs]
for s in removed:
    del svcs[s]
# Clean up depends_on references to removed services so remaining services
# don't fail validation.
for svc in svcs.values():
    deps = svc.get('depends_on')
    if not deps:
        continue
    if isinstance(deps, dict):
        for dep in list(deps.keys()):
            if dep in strip:
                del deps[dep]
        if not deps:
            svc.pop('depends_on', None)
    elif isinstance(deps, list):
        svc['depends_on'] = [d for d in deps if d not in strip]
        if not svc['depends_on']:
            svc.pop('depends_on', None)
with open('docker-compose.yml', 'w') as f:
    yaml.safe_dump(c, f, sort_keys=False)
print(f"  removed: {' '.join(removed) if removed else '(none found)'}")
PYEOF
}

# Reset the DinD to a clean slate WITHOUT tearing down the DinD itself or its
# loaded images. Used by run.sh's --reset-between so a whole battery of
# scenarios can share one DinD (paying the image sideload once) while each still
# starts pristine. Removes every container, then prunes anonymous volumes and
# custom networks, then restores a clean repo copy — undoing any scenario that
# stubbed scripts/configure.sh, wrote .env, or generated runtime config (the
# config/ bind-mount sources live under the repo dir). Images are left intact,
# so no re-pull / re-sideload happens.
dind_reset() {
    echo -e "${BLUE}[dind]${NC} reset: clearing containers/volumes/networks + restoring repo (images kept)"
    # Prune runs while /root/MediaStack still exists (dind_exec sets it as CWD).
    dind_exec 'ids=$(docker ps -aq); [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1; true' || true
    dind_exec 'docker volume prune -f >/dev/null 2>&1; docker network prune -f >/dev/null 2>&1; true' || true
    # The prior scenario's containers bind-mount config/* under the repo dir; if
    # `docker rm -f` hasn't fully released them, `rm -rf` hits a busy mountpoint
    # and leaves a dirty tree the copy then lands on. Lazily unmount any leftover
    # mounts under the dir, then delete — retry once if the first rm fails.
    # ponytail: one unmount+retry covers the rm/rm-f race; escalate to a full
    # dind_down/dind_up only if this proves insufficient in practice.
    local _unmount='for m in $(findmnt -rno TARGET 2>/dev/null | grep "^/root/MediaStack" | sort -r); do umount -l "$m" 2>/dev/null; done; true'
    dind_exec "$_unmount" || true
    if ! dind_exec "rm -rf /root/MediaStack"; then
        dind_exec "$_unmount" || true
        dind_exec "rm -rf /root/MediaStack" || true
    fi
    dind_copy_repo || return 1
    dind_strip_services
}

# Resolve the image ref for a service, honoring a test-only override.
# Reads MS_TEST_IMAGE_OVERRIDES ("svc=ref" pairs, comma or space separated).
# Used host-side for code paths that launch an image OUTSIDE compose (e.g. the
# smoke scenario's standalone NPM container). Returns the override when present
# for that service, else the supplied default.
# Usage: img=$(ms_test_image npm jc21/nginx-proxy-manager:2)
ms_test_image() {
    local svc="$1" default="$2" pair match="" osvc seen=" "
    for pair in $(echo "${MS_TEST_IMAGE_OVERRIDES:-}" | tr ',' ' '); do
        # Validate EVERY token to the SAME contract as dind_override_images
        # (which aborts the run on a malformed/duplicate pair). A space-split
        # fragment like 'bar:1' from "npm=foo bar:1" has no '=' and is rejected
        # rather than silently dropped; the ref charset blocks shell
        # metacharacters (this value is interpolated into a `docker run`
        # command, e.g. smoke's standalone NPM).
        if [[ "$pair" != *=* ]]; then
            echo "ms_test_image: malformed override token (need svc=ref): '$pair'" >&2
            return 1
        fi
        osvc="${pair%%=*}"
        if [[ ! "$osvc" =~ ^[A-Za-z0-9._-]+$ || ! "${pair#*=}" =~ ^[A-Za-z0-9._:/@-]+$ ]]; then
            echo "ms_test_image: unsafe override token: '$pair'" >&2
            return 1
        fi
        if [[ "$seen" == *" $osvc "* ]]; then
            echo "ms_test_image: duplicate override for service: '$osvc'" >&2
            return 1
        fi
        seen+="$osvc "
        [[ "$osvc" == "$svc" ]] && match="${pair#*=}"
    done
    [[ -n "$match" ]] && { echo "$match"; return 0; }
    echo "$default"
}

# Override service image tags in the DinD copy's docker-compose.yml for
# candidate-image upgrade preflight. Pairs come from MS_TEST_IMAGE_OVERRIDES
# ("svc=ref", comma or space separated). Unlike dind_strip_services, this
# FAILS HARD on a typo: an unknown service, empty ref, or malformed pair aborts
# the run — a silently-ignored override would test the pinned image and give
# false confidence in a candidate bump. The host's compose is never touched.
dind_override_images() {
    local overrides="${MS_TEST_IMAGE_OVERRIDES:-}"
    [[ -z "$overrides" ]] && return 0

    local list
    list=$(echo "$overrides" | tr ',' ' ')
    echo -e "${BLUE}[dind]${NC} overriding compose images: $list"

    # -i is essential (see dind_strip_services). python3 validates every pair
    # and exits nonzero (aborting the run) on any problem before writing.
    # Stable-channel tests generate image overrides from docs/operations/image-digests.lock,
    # so digest refs also patch the DinD copy of that lock. Tag-only overrides
    # switch the DinD copy to IMAGE_CHANNEL=latest so the compose image patch is
    # not hidden behind the stable lock.
    docker exec -i -w /root/MediaStack "$DIND_NAME" python3 - "$list" <<'PYEOF'
import pathlib
import re
import sys

import yaml

pairs = sys.argv[1].split()
with open('docker-compose.yml') as f:
    c = yaml.safe_load(f) or {}
svcs = c.get('services') or {}
errors, patches, seen = [], [], set()
for p in pairs:
    if p.count('=') != 1:
        errors.append(f"malformed override (need svc=ref): {p!r}")
        continue
    svc, ref = p.split('=', 1)
    if not svc or not ref:
        errors.append(f"empty service or image ref: {p!r}")
    elif not re.fullmatch(r'[A-Za-z0-9._-]+', svc):
        errors.append(f"unsafe service name: {svc!r}")
    elif not re.fullmatch(r'[A-Za-z0-9._:/@-]+', ref):
        errors.append(f"shell-unsafe image ref: {ref!r}")
    elif svc not in svcs:
        errors.append(f"unknown service: {svc!r} (not in docker-compose.yml)")
    elif svc in seen:
        errors.append(f"duplicate override for service: {svc!r}")
    else:
        seen.add(svc)
        patches.append((svc, svcs[svc].get('image', '<none>'), ref))
if errors:
    for e in errors:
        sys.stderr.write(f"[image-override] ERROR: {e}\n")
    sys.exit(1)

lock_updates = {}
needs_latest_channel = False
for svc, old, ref in patches:
    svcs[svc]['image'] = ref
    sys.stderr.write(f"[image-override] {svc}: {old} -> {ref}\n")
    if '@sha256:' in ref:
        image, digest = ref.rsplit('@', 1)
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
            sys.stderr.write(f"[image-override] ERROR: invalid digest ref for {svc}: {ref}\n")
            sys.exit(1)
        lock_updates[svc] = (image, digest)
    else:
        needs_latest_channel = True

with open('docker-compose.yml', 'w') as f:
    yaml.safe_dump(c, f, sort_keys=False)

if lock_updates:
    lock_path = pathlib.Path('docs/operations/image-digests.lock')
    if not lock_path.exists():
        sys.stderr.write("[image-override] ERROR: docs/operations/image-digests.lock missing; cannot patch stable override digests\n")
        sys.exit(1)
    lines = lock_path.read_text().splitlines()
    out, seen_lock = [], set()
    for line in lines:
        if not line or line.startswith('#') or line.startswith('service\timage\tdigest'):
            out.append(line)
            continue
        parts = line.split('\t')
        if len(parts) not in (3, 5):
            sys.stderr.write(f"[image-override] ERROR: invalid lock row: {line!r}\n")
            sys.exit(1)
        svc = parts[0]
        if svc in lock_updates:
            image, digest = lock_updates[svc]
            if len(parts) == 3:
                parts = [svc, image, digest]
            else:
                parts[1] = image
                parts[2] = digest
            seen_lock.add(svc)
            sys.stderr.write(f"[image-override] stable lock {svc}: {image}@{digest}\n")
        out.append('\t'.join(parts))
    missing = sorted(set(lock_updates) - seen_lock)
    if missing:
        sys.stderr.write(f"[image-override] ERROR: lock missing service rows: {', '.join(missing)}\n")
        sys.exit(1)
    lock_path.write_text('\n'.join(out) + '\n')

if needs_latest_channel:
    env_path = pathlib.Path('.env.example')
    if env_path.exists():
        text = env_path.read_text()
        if re.search(r'^IMAGE_CHANNEL=', text, re.M):
            text = re.sub(r'^IMAGE_CHANNEL=.*$', 'IMAGE_CHANNEL=latest', text, flags=re.M)
        else:
            text += '\nIMAGE_CHANNEL=latest\n'
        env_path.write_text(text)
        sys.stderr.write("[image-override] tag-only override: set DinD .env.example IMAGE_CHANNEL=latest\n")

# Record old->new so the image-override scenario can flag a vacuous same-tag override.
with open('tests/.image-override-applied', 'w') as rf:
    for svc, old, ref in patches:
        rf.write(f"{svc}\t{old}\t{ref}\n")
PYEOF
}

# Same but connects stdin/tty — useful for manual debugging via --keep.
dind_exec_tty() {
    docker exec -it -w /root/MediaStack "$DIND_NAME" sh -c "$*"
}

# Tail logs for a service running inside the stack inside DinD.
dind_logs() {
    dind_exec "docker compose logs --no-color --tail=50 $1"
}

# Teardown. KEEP_ALWAYS=1 keeps regardless of pass/fail (for diagnostic runs).
# KEEP_ON_FAIL=1 keeps only when at least one FAIL was recorded.
dind_down() {
    if [[ "${KEEP_ALWAYS:-0}" == "1" || ( "${KEEP_ON_FAIL:-0}" == "1" && "${FAIL_COUNT:-0}" -gt 0 ) ]]; then
        echo ""
        echo -e "${YELLOW}[dind]${NC} --keep + failures → leaving $DIND_NAME running"
        echo -e "${YELLOW}[dind]${NC} inspect with: docker exec -it $DIND_NAME sh"
        echo -e "${YELLOW}[dind]${NC} clean up with: docker rm -fv $DIND_NAME"
        return 0
    fi
    docker rm -fv "$DIND_NAME" >/dev/null 2>&1 || true
    echo -e "${BLUE}[dind]${NC} torn down"
}
