#!/usr/bin/env bash
# tests/unit/env-resource-limits.sh
#
# MS_DISABLE_RESOURCE_LIMITS must survive a write_env rewrite of .env, so a
# later process that regenerates docker-compose.override.yml keeps the chosen
# limit policy (issue #102). No Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# Read by tests/lib/assert.sh for failure labels.
# shellcheck disable=SC2034
CURRENT_SCENARIO="env-resource-limits"
scenario_begin "$CURRENT_SCENARIO"

# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/setup/env-gen.sh"
set +e +u

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Seeds a fixture .env (GPU and Stage 3 state plus the given limits line),
# rewrites it with write_env in a subshell, then regenerates the override in a
# fresh clean-environment process, as the next setup run would.
# Args: case name, limits line ("" = key absent). Sets $ENV_FILE, $OVERRIDE,
# $WRITE_OUT.
rewrite_and_regenerate() {
    local name="$1" limits_line="$2"
    local dir="$WORK/$name"
    mkdir -p "$dir/config/ddns-updater" "$dir/docs/operations"
    cp "$REPO_ROOT/.env.example" "$dir/.env.example"
    cp "$REPO_ROOT/docs/operations/image-digests.lock" "$dir/docs/operations/"
    {
        [[ -n "$limits_line" ]] && printf '%s\n' "$limits_line"
        printf '%s\n' JELLYFIN_GPU=nvidia STAGE_3_GPU_STATE=complete STAGE_3_GPU_VENDOR=nvidia \
            STAGE_3_GPU_ENCODER=nvenc STAGE_3_GPU_RENDER_DEVICE=/dev/dri/renderD128 NVIDIA_DRIVER_MODE=standard
    } >"$dir/.env"
    WRITE_OUT=$(
        SCRIPT_DIR="$dir"
        unset MS_DISABLE_RESOURCE_LIMITS
        # Fixture values the sourced writer reads.
        # shellcheck disable=SC2034
        _ENV_PUID=1000 _ENV_PGID=1000 _ENV_HOST_ADDRESS=192.168.1.10 _WIZ_TZ=Etc/UTC _WIZ_DATA_DIR=/data
        # shellcheck disable=SC2034
        _WIZ_ADMIN_USER=admin _WIZ_ADMIN_PW=pw _WIZ_ADMIN_EMAIL=a@example.com
        log_warn() { printf 'WARN: %s\n' "$1"; }
        write_env 2>&1
    )
    ENV_FILE="$dir/.env"
    OVERRIDE="$dir/docker-compose.override.yml"
    env -i PATH="$PATH" HOME="$HOME" bash -c '
        source "$1/setup.sh"
        SCRIPT_DIR="$2"
        log_ok() { :; }; log_info() { :; }; log_warn() { :; }
        set -a; source "$2/.env"; set +a
        HOST_MEMORY_MB=4096
        generate_override "$JELLYFIN_GPU"
    ' _ "$REPO_ROOT" "$dir" >/dev/null 2>&1
}

# The value a fresh process reads from the rewritten .env (the writer may quote it).
limits_value() {
    env -i bash -c 'set -a; source "$1"; echo "${MS_DISABLE_RESOURCE_LIMITS-UNSET}"' _ "$ENV_FILE"
}

assert_hardware_kept() {
    local name="$1"
    assert_file_contains "$ENV_FILE" "JELLYFIN_GPU=" "$name: JELLYFIN_GPU key kept"
    assert_eq "nvidia" "$(env -i bash -c 'set -a; source "$1"; echo "$JELLYFIN_GPU"' _ "$ENV_FILE")" "$name: JELLYFIN_GPU value kept"
    assert_eq "complete" "$(env -i bash -c 'set -a; source "$1"; echo "$STAGE_3_GPU_STATE"' _ "$ENV_FILE")" "$name: STAGE_3_GPU_STATE kept"
    assert_eq "/dev/dri/renderD128" "$(env -i bash -c 'set -a; source "$1"; echo "$STAGE_3_GPU_RENDER_DEVICE"' _ "$ENV_FILE")" "$name: STAGE_3_GPU_RENDER_DEVICE kept"
    assert_file_contains "$OVERRIDE" "runtime: nvidia" "$name: override keeps the GPU runtime"
}

assert_limits_stripped() {
    assert_file_not_contains "$OVERRIDE" "mem_limit:" "$1: override has no mem_limit"
    assert_file_not_contains "$OVERRIDE" "memswap_limit:" "$1: override has no memswap_limit"
    assert_file_not_contains "$OVERRIDE" "cpus:" "$1: override has no cpus"
}

assert_limits_kept() {
    assert_file_contains "$OVERRIDE" "mem_limit:" "$1: override keeps mem_limit"
    assert_file_contains "$OVERRIDE" "memswap_limit:" "$1: override keeps memswap_limit"
    assert_file_contains "$OVERRIDE" "cpus:" "$1: override keeps cpus"
}

# Given a .env that opts out of resource limits
# When write_env rewrites it and a fresh process regenerates the override
# Then the opt-out is still true and the override has no caps
rewrite_and_regenerate opt-out "MS_DISABLE_RESOURCE_LIMITS=true"
assert_eq "true" "$(limits_value)" "true: key written as true"
assert_limits_stripped "true"
assert_hardware_kept "true"

# Given a .env that explicitly keeps limits on
# When write_env rewrites it and a fresh process regenerates the override
# Then the value stays false and the override keeps the caps
rewrite_and_regenerate explicit-false "MS_DISABLE_RESOURCE_LIMITS=false"
assert_eq "false" "$(limits_value)" "false: key written as false"
assert_limits_kept "false"
assert_hardware_kept "false"

# Given a .env without the key
# When write_env rewrites it and a fresh process regenerates the override
# Then the key defaults to false and the override keeps the caps
rewrite_and_regenerate absent ""
assert_eq "false" "$(limits_value)" "absent: key defaults to false"
assert_limits_kept "absent"
assert_hardware_kept "absent"

# Given hand-edited spellings of true: TRUE, 'true' and "true"
# When write_env rewrites each
# Then each is normalised to the exact value true
for spelling in TRUE "'true'" '"true"'; do
    rewrite_and_regenerate "spell-${spelling//[^A-Za-z]/}" "MS_DISABLE_RESOURCE_LIMITS=$spelling"
    assert_eq "true" "$(limits_value)" "$spelling: normalised to true"
    assert_limits_stripped "$spelling"
done

# Given an empty value
# When write_env rewrites it
# Then the key is false and the caps stay
rewrite_and_regenerate empty "MS_DISABLE_RESOURCE_LIMITS="
assert_eq "false" "$(limits_value)" "empty: treated as false"
assert_limits_kept "empty"

# Given an unsupported value such as yes or 1
# When write_env rewrites it
# Then the key becomes false with a warning, never true, and the caps stay
for bad in yes 1; do
    rewrite_and_regenerate "bad-$bad" "MS_DISABLE_RESOURCE_LIMITS=$bad"
    assert_eq "false" "$(limits_value)" "$bad: not turned into true"
    assert_contains "$WRITE_OUT" "Ignoring invalid MS_DISABLE_RESOURCE_LIMITS '$bad'" "$bad: warns about the unsupported value"
    assert_limits_kept "$bad"
done

summary
