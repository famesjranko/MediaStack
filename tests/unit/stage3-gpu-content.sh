#!/usr/bin/env bash
# tests/unit/stage3-gpu-content.sh
#
# Cross-branch exclusivity tests for `generate_override` GPU output. For each
# GPU type (none, nvidia, intel, amd), assert the jellyfin: block contains
# ONLY the directives expected for that type — no leakage from other branches.
#
# Why this exists: tests/unit/resource-limits.sh covers "what should be
# present" per type but doesn't catch cross-contamination (e.g., a regression
# that adds `runtime: nvidia` to the `none` path). tests/unit/stage3-flow.sh
# stubs generate_override entirely. So if a future edit accidentally moves
# `runtime: nvidia` outside the `nvidia)` case arm, only this file would
# catch it.
#
# Pure-bash; no DinD/Docker/network. Same shim pattern as resource-limits.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="stage3-gpu-content"
echo -e "${CYAN}${BOLD}▶ scenario: stage3-gpu-content${NC}"

# shellcheck source=../../setup.sh
source "$REPO_ROOT/setup.sh"

set +e
set +u

log_ok()    { :; }
log_info()  { :; }
log_warn()  { :; }
log_error() { :; }

TMPDIR_WORK=$(mktemp -d)
SCRIPT_DIR="$TMPDIR_WORK"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
HOST_MEMORY_MB=4096
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
IMAGE_CHANNEL=latest

# Extract the jellyfin: top-level service block from a generated override.
# Same helper as tests/unit/resource-limits.sh — duplicated rather than
# extracted because the unit test files are intentionally self-contained.
_jellyfin_block() {
    awk '/^  jellyfin:/{found=1; next} /^  [a-z]/{found=0} found' "$1"
}

# Stub getent so intel/amd resolve a render gid without touching the host.
getent() { echo "render:x:109:"; }

# Each case below runs generate_override <type>, then asserts on the jellyfin
# block content. PRESENT lines must appear; ABSENT lines must not.

# ---------------------------------------------------------------------------
# none: no GPU directives at all in the jellyfin block
# ---------------------------------------------------------------------------

generate_override none
jf=$(_jellyfin_block "$TMPDIR_WORK/docker-compose.override.yml")

for needle in "runtime:" "devices:" "group_add:" "NVIDIA_VISIBLE_DEVICES" "NVIDIA_DRIVER_CAPABILITIES" "/dev/dri" "nvidia-smi"; do
    if ! grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content none: jellyfin block omits '$needle'"
    else
        fail "stage3-gpu-content none: jellyfin block omits '$needle'" "found unexpected directive"
    fi
done

# ---------------------------------------------------------------------------
# nvidia: runtime + NVIDIA_* env, no intel/amd passthrough leakage
# ---------------------------------------------------------------------------

generate_override nvidia
jf=$(_jellyfin_block "$TMPDIR_WORK/docker-compose.override.yml")

for needle in "runtime: nvidia" "NVIDIA_VISIBLE_DEVICES=all" "NVIDIA_DRIVER_CAPABILITIES=all" "healthcheck:" "curl -sf http://localhost:8096/health" "nvidia-smi"; do
    if grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content nvidia: jellyfin block contains '$needle'"
    else
        fail "stage3-gpu-content nvidia: jellyfin block contains '$needle'"
    fi
done

for needle in "/dev/dri" "group_add:"; do
    if ! grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content nvidia: jellyfin block omits '$needle' (intel/amd leak)"
    else
        fail "stage3-gpu-content nvidia: jellyfin block omits '$needle'" "intel/amd directive leaked into nvidia path"
    fi
done

# ---------------------------------------------------------------------------
# intel: /dev/dri + group_add, no nvidia leakage
# ---------------------------------------------------------------------------

generate_override intel
jf=$(_jellyfin_block "$TMPDIR_WORK/docker-compose.override.yml")

for needle in "/dev/dri:/dev/dri" "group_add:"; do
    if grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content intel: jellyfin block contains '$needle'"
    else
        fail "stage3-gpu-content intel: jellyfin block contains '$needle'"
    fi
done

for needle in "runtime: nvidia" "NVIDIA_VISIBLE_DEVICES" "NVIDIA_DRIVER_CAPABILITIES" "nvidia-smi"; do
    if ! grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content intel: jellyfin block omits '$needle' (nvidia leak)"
    else
        fail "stage3-gpu-content intel: jellyfin block omits '$needle'" "nvidia directive leaked into intel path"
    fi
done

# ---------------------------------------------------------------------------
# amd: same shape as intel — /dev/dri + group_add, no nvidia leakage
# ---------------------------------------------------------------------------

generate_override amd
jf=$(_jellyfin_block "$TMPDIR_WORK/docker-compose.override.yml")

for needle in "/dev/dri:/dev/dri" "group_add:"; do
    if grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content amd: jellyfin block contains '$needle'"
    else
        fail "stage3-gpu-content amd: jellyfin block contains '$needle'"
    fi
done

for needle in "runtime: nvidia" "NVIDIA_VISIBLE_DEVICES" "NVIDIA_DRIVER_CAPABILITIES" "nvidia-smi"; do
    if ! grep -qF "$needle" <<<"$jf"; then
        pass "stage3-gpu-content amd: jellyfin block omits '$needle' (nvidia leak)"
    else
        fail "stage3-gpu-content amd: jellyfin block omits '$needle'" "nvidia directive leaked into amd path"
    fi
done

unset -f getent

summary
