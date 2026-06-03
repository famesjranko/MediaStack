#!/usr/bin/env bash
# Unit test - scripts/update.sh option parsing and prune defaults.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="update"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

setup_update_sandbox() {
    rm -rf "$TMP_DIR/sandbox"
    mkdir -p "$TMP_DIR/sandbox/bin" \
        "$TMP_DIR/sandbox/docs/operations" \
        "$TMP_DIR/sandbox/scripts/lib" \
        "$TMP_DIR/sandbox/scripts/setup"

    cp "$REPO_ROOT/scripts/update.sh" "$TMP_DIR/sandbox/scripts/update.sh"
    cp "$REPO_ROOT/scripts/lib/common.sh" "$TMP_DIR/sandbox/scripts/lib/common.sh"
    cp "$REPO_ROOT/scripts/setup/override.sh" "$TMP_DIR/sandbox/scripts/setup/override.sh"
    cp "$REPO_ROOT/docs/operations/image-digests.lock" "$TMP_DIR/sandbox/docs/operations/image-digests.lock"
    chmod +x "$TMP_DIR/sandbox/scripts/update.sh"
    cat > "$TMP_DIR/sandbox/scripts/setup/storage.sh" <<'STUB'
storage_guard_before_start() { printf 'storage_guard_before_start\n' >> "$UPDATE_DOCKER_LOG"; }
STUB
    cat > "$TMP_DIR/sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UPDATE_DOCKER_LOG"
if [[ "${1:-}" == "compose" && "$*" == *" ps --status running"* ]]; then
    exit 0
fi
exit 0
STUB
    chmod +x "$TMP_DIR/sandbox/bin/docker"
    : > "$TMP_DIR/docker.log"
}

run_update() {
    PATH="$TMP_DIR/sandbox/bin:$PATH" \
        UPDATE_DOCKER_LOG="$TMP_DIR/docker.log" \
        "$TMP_DIR/sandbox/scripts/update.sh" "$@" 2>&1
}

assert_not_contains_local() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "'$needle' was found" ;;
        *)           pass "$name" ;;
    esac
}

setup_update_sandbox
output=$(run_update)
rc=$?
log=$(cat "$TMP_DIR/docker.log")

assert_eq "0" "$rc" "update.sh default update exits zero"
assert_contains "$log" "compose pull" "update.sh default pulls images"
assert_contains "$log" "storage_guard_before_start" "update.sh still runs storage guard before recreate"
assert_contains "$log" "compose up -d --remove-orphans" "update.sh default recreates containers"
assert_not_contains_local "$log" "image prune -f" "update.sh default does not prune host images"
assert_contains "$(cat "$TMP_DIR/sandbox/docker-compose.override.yml")" "Image channel: stable" "update.sh default regenerates stable override"
assert_contains "$output" "Skipping image prune" "update.sh default tells user prune was skipped"

setup_update_sandbox
output=$(run_update --prune)
rc=$?
log=$(cat "$TMP_DIR/docker.log")

assert_eq "0" "$rc" "update.sh --prune exits zero"
assert_contains "$log" "image prune -f" "update.sh --prune runs Docker image prune"
assert_contains "$output" "host-wide" "update.sh --prune warns about host-wide cleanup"

setup_update_sandbox
printf '%s\n' "IMAGE_CHANNEL=latest" > "$TMP_DIR/sandbox/.env"
output=$(run_update)
rc=$?
override_text=$(cat "$TMP_DIR/sandbox/docker-compose.override.yml")

assert_eq "0" "$rc" "update.sh latest channel exits zero"
assert_contains "$override_text" "Image channel: latest" "update.sh latest regenerates latest override"
assert_not_contains_local "$override_text" "image:" "update.sh latest omits image overrides"

setup_update_sandbox
output=$(run_update --bogus)
rc=$?
log=$(cat "$TMP_DIR/docker.log")

assert_eq "2" "$rc" "update.sh rejects unknown options"
assert_contains "$output" "Unknown option: --bogus" "update.sh reports unknown option"
assert_not_contains_local "$log" "compose" "update.sh unknown option exits before Docker calls"

scenario_end "$CURRENT_SCENARIO"
summary
