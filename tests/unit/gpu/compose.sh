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

# ---------------------------------------------------------------------------
# Atomic, serialised writes: concurrent runs and a killed run leave a valid file
# ---------------------------------------------------------------------------

# Strict YAML check: PyYAML silently keeps the last of two equal keys, so the
# loader here rejects duplicates at any depth. Prints the service count.
_override_strict_services() {
    python3 - "$1" <<'PY'
import sys
import yaml


class Strict(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    keys = [loader.construct_object(k, deep=True) for k, _ in node.value]
    dup = {k for k in keys if keys.count(k) > 1}
    if dup:
        raise yaml.constructor.ConstructorError(None, None, f"duplicate keys {sorted(dup)}", node.start_mark)
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
print(len(yaml.load(open(sys.argv[1]), Strict)["services"]))  # noqa: S506 - SafeLoader subclass
PY
}

# Hooks around the real image-line helper: GEN_PAUSE widens the window in which
# two runs overlap; GEN_KILL makes the run die (SIGKILL) part way through.
eval "$(declare -f _compose_image_line | sed '1s/_compose_image_line/_real_compose_image_line/')"
_compose_image_line() {
    [[ "${GEN_PAUSE:-}" == 1 && "$1" == sonarr ]] && sleep 0.4
    [[ "${GEN_KILL:-}" == 1 && "$1" == radarr ]] && kill -KILL "$GEN_SELF"
    _real_compose_image_line "$@"
}
OVERRIDE="$TMPDIR_WORK/docker-compose.override.yml"
generate_override none
SERVICE_COUNT="$(_override_strict_services "$OVERRIDE" 2>&1 | tail -n 1)"
assert_eq "1" "$([[ "$SERVICE_COUNT" =~ ^[0-9]+$ ]] && ((SERVICE_COUNT > 10)) && echo 1 || echo 0)" "generate_override: a single run writes a strict-valid override with its services"

# Given two setup runs start together and overlap for a while,
# When both generate the override (one nvidia, one without a GPU),
# Then the file is one complete override with no duplicated key and no temp file is left.
rm -f "$OVERRIDE"
export GEN_PAUSE=1
(generate_override nvidia) &
pid_a=$!
(generate_override none) &
pid_b=$!
wait "$pid_a" "$pid_b"
unset GEN_PAUSE
_services="$(_override_strict_services "$OVERRIDE" 2>&1 | tail -n 1)"
assert_eq "$SERVICE_COUNT" "$_services" "generate_override: concurrent runs leave a duplicate-free override with every service"
assert_eq "1" "$(grep -c '^  jellyfin:$' "$OVERRIDE")" "generate_override: concurrent runs write the jellyfin service once"
assert_eq "" "$(ls -A "$TMPDIR_WORK/.tmp" 2>/dev/null)" "generate_override: concurrent runs leave no temp file behind"

# Given a valid override exists and a run is killed part way through writing,
# When the next run generates the override again,
# Then the killed run left the old file untouched, and the next run replaces it cleanly.
generate_override none
cp "$OVERRIDE" "$TMPDIR_WORK/override.before"
{
    (
        export GEN_KILL=1 GEN_SELF="$BASHPID"
        generate_override nvidia
    )
} 2>/dev/null
assert_eq "0" "$(cmp -s "$OVERRIDE" "$TMPDIR_WORK/override.before" && echo 0 || echo 1)" "generate_override: a killed run leaves the previous override untouched"
generate_override nvidia
assert_eq "$SERVICE_COUNT" "$(_override_strict_services "$OVERRIDE" 2>&1 | tail -n 1)" "generate_override: the run after a killed one writes a valid override"
assert_contains "$(<"$OVERRIDE")" "runtime: nvidia" "generate_override: the run after a killed one applies the requested GPU"
assert_eq "" "$(ls -A "$TMPDIR_WORK/.tmp" 2>/dev/null)" "generate_override: the stale temp file of a killed run is swept"

# Given another setup run holds the lock on the repository directory,
# When a run asks for the override,
# Then it gives up with a message naming the lock and the 60 second wait, and leaves the old file alone.
# (The wait is shortened to 1s here so the case stays fast; the argument 60 is asserted.)
generate_override none
cp "$OVERRIDE" "$TMPDIR_WORK/override.before"
# -o: only flock holds the lock; the sleep is killed with it below so it cannot hold the output pipe open.
flock -o "$TMPDIR_WORK" sleep 30 &
_holder=$!
sleep 0.3
_flock_args=""
_logged=""
flock() {
    _flock_args="$*"
    local _a=("$@")
    [[ "${_a[0]}" == "-w" ]] && _a[1]=1
    command flock "${_a[@]}"
}
log_error() { _logged="$*"; }
_lock_rc=0
generate_override nvidia || _lock_rc=$?
unset -f flock
log_error() { :; }
pkill -P "$_holder" 2>/dev/null
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null
assert_eq "1" "$_lock_rc" "generate_override: a held lock makes the run fail instead of waiting forever"
assert_contains "$_flock_args" "-w 60" "generate_override: the lock wait is bounded to 60 seconds"
assert_contains "$_logged" "Another MediaStack run holds the lock" "generate_override: a lock timeout names the other run"
assert_eq "0" "$(cmp -s "$OVERRIDE" "$TMPDIR_WORK/override.before" && echo 0 || echo 1)" "generate_override: a lock timeout leaves the previous override untouched"
unset _holder _flock_args _logged _lock_rc
unset -f _compose_image_line _real_compose_image_line _override_strict_services
unset OVERRIDE SERVICE_COUNT pid_a pid_b _services
