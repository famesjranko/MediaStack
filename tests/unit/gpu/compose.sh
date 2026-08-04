# Owns: generated Compose GPU branch assertions.
# Sources: stage3-gpu-content.sh setup and scripts/setup/gpu/compose.sh.
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
