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
        "$TMP_DIR/sandbox/scripts/launcher" \
        "$TMP_DIR/sandbox/scripts/services/qbittorrent" \
        "$TMP_DIR/sandbox/scripts/services/beszel" \
        "$TMP_DIR/sandbox/scripts/setup/gpu"

    cp "$REPO_ROOT/scripts/update.sh" "$TMP_DIR/sandbox/scripts/update.sh"
    cp "$REPO_ROOT/scripts/lib/common.sh" "$TMP_DIR/sandbox/scripts/lib/common.sh"
    cp "$REPO_ROOT/scripts/lib/term-caps.sh" "$TMP_DIR/sandbox/scripts/lib/term-caps.sh"   # common.sh sources it
    cp "$REPO_ROOT/scripts/lib/env-update.sh" "$TMP_DIR/sandbox/scripts/lib/env-update.sh" # common.sh sources it
    cp "$REPO_ROOT/scripts/lib/profiles.sh" "$TMP_DIR/sandbox/scripts/lib/profiles.sh"     # canonical profile mapping
    cp "$REPO_ROOT/scripts/setup/override.sh" "$TMP_DIR/sandbox/scripts/setup/override.sh"
    cp "$REPO_ROOT/scripts/setup/gpu/compose.sh" "$TMP_DIR/sandbox/scripts/setup/gpu/compose.sh"
    cp "$REPO_ROOT/docs/operations/image-digests.lock" "$TMP_DIR/sandbox/docs/operations/image-digests.lock"
    cp "$REPO_ROOT/scripts/launcher/converge.sh" "$TMP_DIR/sandbox/scripts/launcher/converge.sh"
    chmod +x "$TMP_DIR/sandbox/scripts/update.sh"
    # The convergence steps are covered in launcher-converge.sh; here only the
    # wiring is under test, so the two heavy modules are recorders.
    cat >"$TMP_DIR/sandbox/scripts/setup/hardening.sh" <<'STUB'
setup_admin_filter() { printf 'setup_admin_filter\n' >> "$UPDATE_DOCKER_LOG"; return "${UPDATE_FILTER_RC:-0}"; }
ufw_remove_legacy_beszel_rule() { printf 'ufw_remove_legacy_beszel_rule\n' >> "$UPDATE_DOCKER_LOG"; }
setup_ufw_wireguard_clients() { printf 'setup_ufw_wireguard_clients\n' >> "$UPDATE_DOCKER_LOG"; }
STUB
    cat >"$TMP_DIR/sandbox/scripts/services/qbittorrent/main.sh" <<'STUB'
qbt_narrow_legacy_whitelist() { printf 'qbt_narrow_legacy_whitelist\n' >> "$UPDATE_DOCKER_LOG"; }
STUB
    cat >"$TMP_DIR/sandbox/scripts/services/beszel/main.sh" <<'STUB'
beszel_converge_local_system() { printf 'beszel_converge_local_system\n' >> "$UPDATE_DOCKER_LOG"; }
STUB
    cat >"$TMP_DIR/sandbox/scripts/setup/storage.sh" <<'STUB'
storage_guard_before_start() { printf 'storage_guard_before_start\n' >> "$UPDATE_DOCKER_LOG"; }
STUB
    cat >"$TMP_DIR/sandbox/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$UPDATE_DOCKER_LOG"
if [[ "${1:-}" == "compose" && "$*" == *" ps --status running"* ]]; then
    exit 0
fi
exit 0
STUB
    chmod +x "$TMP_DIR/sandbox/bin/docker"
    : >"$TMP_DIR/docker.log"
}

run_update() {
    PATH="$TMP_DIR/sandbox/bin:$PATH" \
        UPDATE_FILTER_RC="${UPDATE_FILTER_RC:-0}" \
        UPDATE_DOCKER_LOG="$TMP_DIR/docker.log" \
        "$TMP_DIR/sandbox/scripts/update.sh" "$@" 2>&1
}

assert_not_contains_local() {
    local haystack="$1" needle="$2" name="$3"
    case "$haystack" in
        *"$needle"*) fail "$name" "'$needle' was found" ;;
        *) pass "$name" ;;
    esac
}

setup_update_sandbox
output=$(run_update)
rc=$?
log=$(cat "$TMP_DIR/docker.log")

assert_eq "0" "$rc" "update.sh default update exits zero"
assert_contains "$log" "pull" "update.sh default pulls images"
assert_contains "$log" "storage_guard_before_start" "update.sh still runs storage guard before recreate"
assert_contains "$log" "up -d --remove-orphans" "update.sh default recreates containers"
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
printf '%s\n' "IMAGE_CHANNEL=latest" >"$TMP_DIR/sandbox/.env"
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

# --- profile selection comes from the user's configuration -------------------
# Given .env enables the proxy and subtitles profiles and autoheal is disabled,
# and Docker reports nothing running (an exited service must still be recreated)
# When update.sh runs
# Then it pulls and recreates with the canonical flags for exactly those profiles
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/profiles.sh"

setup_update_sandbox
printf '%s\n' "DOMAIN=box.example.com" "BAZARR_ENABLED=true" "AUTOHEAL_ENABLED=false" >"$TMP_DIR/sandbox/.env"
output=$(run_update)
log=$(cat "$TMP_DIR/docker.log")
flags="--profile subtitles --profile proxy"

assert_contains "$output" "Proxy profile detected" "update.sh announces the enabled proxy profile"
assert_contains "$output" "Subtitles profile detected" "update.sh announces the enabled subtitles profile"
assert_contains "$log" "compose $flags pull" "update.sh pulls with the enabled profiles even though nothing is running"
assert_contains "$log" "compose $flags up -d --remove-orphans" "update.sh recreates the enabled profiles even though nothing is running"
assert_not_contains_local "$log" "--profile autoheal" "update.sh leaves a disabled profile out"
assert_not_contains_local "$log" "--profile remote" "update.sh leaves a profile with no configuration out"

# Given autoheal is on by default and its container is exited
# When update.sh runs
# Then autoheal is in the recreate set
setup_update_sandbox
output=$(run_update)
log=$(cat "$TMP_DIR/docker.log")
assert_contains "$log" "compose --profile autoheal up -d --remove-orphans" "update.sh recreates default-on autoheal regardless of running state"

# --- a code update converges MediaStack's own host state -----------------------
# Given a finished install
# When update.sh recreates the containers
# Then the admin-port filter is converged after the recreate
setup_update_sandbox
output=$(run_update)
rc=$?
log=$(cat "$TMP_DIR/docker.log")
assert_eq "0" "$rc" "update.sh converge: succeeds when the filter converges"
assert_contains "$log" "setup_admin_filter" "update.sh converge: runs the admin-port filter step"
assert_contains "$log" "beszel_converge_local_system" "update.sh converge: runs the Beszel step"
assert_contains "$log" "ufw_remove_legacy_beszel_rule" "update.sh converge: runs the legacy UFW rule cleanup"
assert_contains "$log" "setup_ufw_wireguard_clients" "update.sh converge: converges the WireGuard UFW rule"
assert_contains "$output" "Applying MediaStack changes" "update.sh converge: tells the user it is applying them"
recreate_line=$(grep -n 'up -d --remove-orphans' "$TMP_DIR/docker.log" | head -1 | cut -d: -f1)
filter_line=$(grep -n '^setup_admin_filter' "$TMP_DIR/docker.log" | head -1 | cut -d: -f1)
if [[ -n "$recreate_line" && -n "$filter_line" && "$recreate_line" -lt "$filter_line" ]]; then
    pass "update.sh converge: runs after the recreate"
else
    fail "update.sh converge: runs after the recreate" "recreate at ${recreate_line:-none}, filter at ${filter_line:-none}"
fi

# Given the admin-port filter fails to apply
# When update.sh runs
# Then it still finishes the update, then exits non-zero and names the action
setup_update_sandbox
output=$(UPDATE_FILTER_RC=1 run_update)
rc=$?
assert_eq "1" "$rc" "update.sh converge: a failed filter apply makes the update fail"
assert_contains "$output" "Update complete" "update.sh converge: a failed filter does not abort the update itself"
assert_contains "$output" "Apply changes from a MediaStack update" "update.sh converge: the failure names the launcher action"

scenario_end "$CURRENT_SCENARIO"
summary
