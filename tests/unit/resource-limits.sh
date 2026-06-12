#!/usr/bin/env bash
# tests/unit/resource-limits.sh
#
# Pure-bash unit test for host-proportional resource limits: detect_host_memory,
# compute_mem_limit, generate_override. No DinD, no Docker, no network.
#
# Tests exercise the arithmetic (floor/cap clamping, memswap 1.5x ratio) at
# multiple simulated host sizes (512MB, 4GB, 8GB, 64GB) and verify the
# override YAML for all three GPU paths (nvidia, intel, none).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="resource-limits"
echo -e "${CYAN}${BOLD}▶ scenario: resource-limits${NC}"

# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

set +e
set +u

log_ok()    { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }

# Override SCRIPT_DIR so generate_override writes to a temp directory
TMPDIR_WORK=$(mktemp -d)
SCRIPT_DIR="$TMPDIR_WORK"
mkdir -p "$TMPDIR_WORK/docs/operations"
cp "$REPO_ROOT/docs/operations/image-digests.lock" "$TMPDIR_WORK/docs/operations/image-digests.lock"
trap 'rm -rf "$TMPDIR_WORK"' EXIT
IMAGE_CHANNEL=latest

# Extract the `jellyfin:` top-level service block from a generated override.
# Needed because the file also contains a `beszel-agent:` block that adds an
# unrelated `devices:` directive (S.M.A.R.T. monitoring) on hosts with SCSI
# or NVMe disks. A whole-file grep for `runtime:` / `devices:` would mistake
# that S.M.A.R.T. block for a GPU directive leaking into the `none` branch.
_jellyfin_block() {
    awk '/^  jellyfin:/{found=1; next} /^  [a-z]/{found=0} found' "$1"
}

# ---------------------------------------------------------------------------
# compute_mem_limit — floor clamping
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=512
result=$(compute_mem_limit 3 64 512)
assert_eq "64m" "$result" "compute_mem_limit: floor clamping (3% of 512MB = 15 < floor 64)"

HOST_MEMORY_MB=2048
result=$(compute_mem_limit 2 64 256)
assert_eq "64m" "$result" "compute_mem_limit: floor clamping (2% of 2GB = 40 < floor 64)"

# ---------------------------------------------------------------------------
# compute_mem_limit — cap clamping
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=65536
result=$(compute_mem_limit 40 1024 8192)
assert_eq "8192m" "$result" "compute_mem_limit: cap clamping (40% of 64GB = 26214 > cap 8192)"

HOST_MEMORY_MB=65536
result=$(compute_mem_limit 12 256 4096)
assert_eq "4096m" "$result" "compute_mem_limit: cap clamping (12% of 64GB = 7864 > cap 4096)"

# ---------------------------------------------------------------------------
# compute_mem_limit — normal path (within bounds)
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=8192
result=$(compute_mem_limit 12 256 4096)
assert_eq "983m" "$result" "compute_mem_limit: normal (12% of 8GB = 983)"

HOST_MEMORY_MB=4096
result=$(compute_mem_limit 40 1024 8192)
assert_eq "1638m" "$result" "compute_mem_limit: normal (40% of 4GB = 1638)"

HOST_MEMORY_MB=16384
result=$(compute_mem_limit 5 128 1024)
assert_eq "819m" "$result" "compute_mem_limit: normal (5% of 16GB = 819)"

# ---------------------------------------------------------------------------
# detect_host_memory — real host
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=0
detect_host_memory
if [[ "$HOST_MEMORY_MB" -gt 0 ]] 2>/dev/null; then
    pass "detect_host_memory: HOST_MEMORY_MB=${HOST_MEMORY_MB} (positive integer)"
else
    fail "detect_host_memory: positive integer" "got '$HOST_MEMORY_MB'"
fi

# ---------------------------------------------------------------------------
# generate_override — all compose-image services get mem_limit + memswap_limit
# ---------------------------------------------------------------------------

ALL_SERVICES="jellyfin sonarr radarr jackett qbittorrent flaresolverr seerr unpackerr bazarr homepage portainer npm fail2ban wireguard ddns-updater uptime-kuma beszel beszel-agent autoheal"

compose_services=$(python3 - <<PY
import yaml

with open("$REPO_ROOT/docker-compose.yml") as f:
    compose = yaml.safe_load(f) or {}
for name, spec in (compose.get("services") or {}).items():
    if isinstance(spec, dict) and spec.get("image"):
        print(name)
PY
)
override_services=$(_compose_image_services)
lock_services=$(awk -F '\t' 'NR > 3 && $1 != "" && $1 !~ /^#/ {print $1}' "$TMPDIR_WORK/docs/operations/image-digests.lock")

if diff -u <(printf '%s\n' "$compose_services" | sort) <(printf '%s\n' "$override_services" | sort) >/dev/null; then
    pass "stable image service list matches docker-compose.yml"
else
    fail "stable image service list matches docker-compose.yml" "$(diff -u <(printf '%s\n' "$compose_services" | sort) <(printf '%s\n' "$override_services" | sort))"
fi

if diff -u <(printf '%s\n' "$compose_services" | sort) <(printf '%s\n' "$lock_services" | sort) >/dev/null; then
    pass "stable image lock rows match docker-compose.yml"
else
    fail "stable image lock rows match docker-compose.yml" "$(diff -u <(printf '%s\n' "$compose_services" | sort) <(printf '%s\n' "$lock_services" | sort))"
fi

HOST_MEMORY_MB=4096
generate_override none
override="$TMPDIR_WORK/docker-compose.override.yml"

if [[ -f "$override" ]]; then
    pass "generate_override none: file created (not deleted)"
else
    fail "generate_override none: file created" "file missing"
fi

for svc in $ALL_SERVICES; do
    if grep -q "^  ${svc}:" "$override" 2>/dev/null; then
        pass "generate_override none: $svc block present"
    else
        fail "generate_override none: $svc block present"
    fi
done

for svc in $ALL_SERVICES; do
    # Extract mem_limit value for this service (next mem_limit line after the service header)
    mem_val=$(awk "/^  ${svc}:/{found=1} found && /mem_limit:/{print \$2; exit}" "$override")
    if [[ -n "$mem_val" && "$mem_val" != "0" ]]; then
        pass "generate_override none: $svc has mem_limit ($mem_val)"
    else
        fail "generate_override none: $svc has mem_limit" "got '$mem_val'"
    fi
done

# none path: no GPU directives in the jellyfin block
jf=$(_jellyfin_block "$override")
if ! grep -qE "runtime:|devices:" <<<"$jf"; then
    pass "generate_override none: no GPU directives"
else
    fail "generate_override none: no GPU directives" "found runtime: or devices: in jellyfin block"
fi

# ---------------------------------------------------------------------------
# generate_override — nvidia path
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=4096
generate_override nvidia

jf=$(_jellyfin_block "$override")
if grep -q "runtime: nvidia" <<<"$jf"; then
    pass "generate_override nvidia: runtime: nvidia present"
else
    fail "generate_override nvidia: runtime: nvidia present"
fi

if grep -q "NVIDIA_VISIBLE_DEVICES" <<<"$jf"; then
    pass "generate_override nvidia: NVIDIA_VISIBLE_DEVICES present"
else
    fail "generate_override nvidia: NVIDIA_VISIBLE_DEVICES present"
fi

if grep -q "nvidia-smi" <<<"$jf" && grep -q "curl -sf http://localhost:8096/health" <<<"$jf"; then
    pass "generate_override nvidia: healthcheck verifies Jellyfin and NVIDIA runtime"
else
    fail "generate_override nvidia: healthcheck verifies Jellyfin and NVIDIA runtime"
fi

# ---------------------------------------------------------------------------
# generate_override — intel path
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=4096
getent() { echo "render:x:109:"; }
generate_override intel
unset -f getent

jf=$(_jellyfin_block "$override")
if grep -q "/dev/dri:/dev/dri" <<<"$jf"; then
    pass "generate_override intel: /dev/dri:/dev/dri present"
else
    fail "generate_override intel: /dev/dri:/dev/dri present"
fi

if grep -q 'group_add:' <<<"$jf"; then
    pass "generate_override intel: group_add present"
else
    fail "generate_override intel: group_add present"
fi

# ---------------------------------------------------------------------------
# generate_override — amd path (same passthrough as intel)
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=4096
getent() { echo "render:x:109:"; }
generate_override amd
unset -f getent

jf=$(_jellyfin_block "$override")
if grep -q "/dev/dri:/dev/dri" <<<"$jf"; then
    pass "generate_override amd: /dev/dri:/dev/dri present"
else
    fail "generate_override amd: /dev/dri:/dev/dri present"
fi

if grep -q 'group_add:' <<<"$jf"; then
    pass "generate_override amd: group_add present"
else
    fail "generate_override amd: group_add present"
fi

# ---------------------------------------------------------------------------
# generate_override — FlareSolverr retains cpus: 1.0
# ---------------------------------------------------------------------------

if grep -q "cpus: 1.0" "$override"; then
    pass "generate_override: flaresolverr cpus: 1.0 present"
else
    fail "generate_override: flaresolverr cpus: 1.0 present"
fi

# ---------------------------------------------------------------------------
# memswap_limit = 1.5x mem_limit for all services
# ---------------------------------------------------------------------------

HOST_MEMORY_MB=8192
generate_override none

for svc in $ALL_SERVICES; do
    mem_raw=$(awk "/^  ${svc}:/{found=1} found && /mem_limit:/{print \$2; exit}" "$override")
    swap_raw=$(awk "/^  ${svc}:/{found=1} found && /memswap_limit:/{print \$2; exit}" "$override")
    mem_num="${mem_raw%m}"
    swap_num="${swap_raw%m}"
    expected_swap=$(( mem_num * 3 / 2 ))
    if [[ "$swap_num" -eq "$expected_swap" ]] 2>/dev/null; then
        pass "memswap 1.5x: $svc (${mem_raw} → ${swap_raw})"
    else
        fail "memswap 1.5x: $svc" "mem=${mem_raw} swap=${swap_raw} expected=${expected_swap}m"
    fi
done

# ---------------------------------------------------------------------------
# Host memory comment in override header
# ---------------------------------------------------------------------------

if grep -q "Host memory: 8192MB" "$override"; then
    pass "generate_override: host memory recorded in header comment"
else
    fail "generate_override: host memory recorded in header comment"
fi

# ---------------------------------------------------------------------------
# image channel — stable pins accepted digests, latest leaves compose tags
# ---------------------------------------------------------------------------

IMAGE_CHANNEL=stable
HOST_MEMORY_MB=4096
generate_override none
if grep -qE '^    image: jellyfin/jellyfin:latest@sha256:[0-9a-f]{64}$' "$override"; then
    pass "generate_override stable: jellyfin image pinned to digest"
else
    fail "generate_override stable: jellyfin image pinned to digest"
fi
if grep -qE '^    image: ghcr\.io/wg-easy/wg-easy:15@sha256:[0-9a-f]{64}$' "$override"; then
    pass "generate_override stable: major-tag service pinned to digest"
else
    fail "generate_override stable: major-tag service pinned to digest"
fi
if grep -q "Image channel: stable" "$override"; then
    pass "generate_override stable: channel recorded in header"
else
    fail "generate_override stable: channel recorded in header"
fi

IMAGE_CHANNEL=latest
generate_override none
if ! grep -qE '^    image: ' "$override"; then
    pass "generate_override latest: no image overrides emitted"
else
    fail "generate_override latest: no image overrides emitted"
fi

IMAGE_CHANNEL=stable
mv "$TMPDIR_WORK/docs/operations/image-digests.lock" "$TMPDIR_WORK/docs/operations/image-digests.lock.bak"
generate_override none >/dev/null 2>&1
missing_lock_rc=$?
mv "$TMPDIR_WORK/docs/operations/image-digests.lock.bak" "$TMPDIR_WORK/docs/operations/image-digests.lock"
if [[ "$missing_lock_rc" -ne 0 ]]; then
    pass "generate_override stable: missing lock fails"
else
    fail "generate_override stable: missing lock fails"
fi
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
IMAGE_CHANNEL=latest

echo -e "${CYAN}◀ resource-limits done${NC}"
summary
