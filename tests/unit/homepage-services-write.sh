#!/usr/bin/env bash
# tests/unit/homepage-services-write.sh
#
# Guards configure_homepage's services.yaml write (scripts/services/homepage/main.sh).
# The homepage container runs as root and rewrites services.yaml, leaving a
# root-owned file the setup user cannot open for write. The write must still
# succeed (atomic rename) and must never report success when it fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/scripts/lib/common.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/services/homepage/main.sh"

CURRENT_SCENARIO="homepage-services-write"
scenario_begin "$CURRENT_SCENARIO"

if [[ $(id -u) -eq 0 ]]; then
    echo "SKIP: root ignores file modes; cannot simulate an unwritable file"
    exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'chmod -R u+w "$TMP_DIR" 2>/dev/null; rm -rf "$TMP_DIR"' EXIT

# Stubs: no containers, no sudo.
service_container_running() { return 1; }
sudo() { return 1; }
SCRIPT_DIR="$TMP_DIR"
HOST_ADDRESS="10.0.0.5"

fresh_config() {
    rm -rf "$TMP_DIR/config"
    mkdir -p "$TMP_DIR/config/homepage"
}

# 1. Given a services.yaml the user cannot write but whose directory is writable
fresh_config
echo "stale: true" >"$TMP_DIR/config/homepage/services.yaml"
chmod 444 "$TMP_DIR/config/homepage/services.yaml"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
# Then the file is replaced, success is logged, and no permission error shows
assert_file_not_contains "$TMP_DIR/config/homepage/services.yaml" "stale: true" "read-only file is replaced"
assert_contains "$out" "services.yaml generated" "success logged after real write"
assert_not_contains "$out" "Permission denied" "no permission error leaks"

# 2. Given a services.yaml in a directory the user cannot write (and no sudo)
fresh_config
echo "stale: true" >"$TMP_DIR/config/homepage/services.yaml"
chmod 444 "$TMP_DIR/config/homepage/services.yaml"
chmod 555 "$TMP_DIR/config/homepage"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
chmod 755 "$TMP_DIR/config/homepage"
# Then it warns with the path and a fix, and never logs success
assert_not_contains "$out" "services.yaml generated" "no success line on failed write"
assert_contains "$out" "$TMP_DIR/config/homepage/services.yaml" "warning names the path"
assert_contains "$out" "chown" "warning names the fix"
assert_file_contains "$TMP_DIR/config/homepage/services.yaml" "stale: true" "old file left intact"

# 3. Given a normal writable config dir with no services.yaml
fresh_config
# When configure_homepage runs twice
out1=$(configure_homepage 2>&1)
out2=$(configure_homepage 2>&1)
# Then the first run generates the file and the second skips it
assert_contains "$out1" "services.yaml generated" "first run generates"
assert_contains "$out2" "already up to date" "second run is a no-op"
assert_file_contains "$TMP_DIR/config/homepage/services.yaml" "10.0.0.5" "content uses host address"

# 4. Given a widgets.yaml the user cannot write, in a writable dir, with a stale cputemp
fresh_config
printf 'resources:\n    cputemp: maybe\n' >"$TMP_DIR/config/homepage/widgets.yaml"
chmod 444 "$TMP_DIR/config/homepage/widgets.yaml"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
# Then the widgets file is edited by rename and no sed error leaks
assert_file_not_contains "$TMP_DIR/config/homepage/widgets.yaml" "cputemp: maybe" "read-only widgets.yaml is edited"
assert_not_contains "$out" "Permission denied" "no sed permission error leaks"
assert_contains "$out" "cputemp" "cputemp result is logged"

# 5. Given a widgets.yaml in a directory the user cannot write (and no sudo)
fresh_config
printf 'resources:\n    cputemp: maybe\n' >"$TMP_DIR/config/homepage/widgets.yaml"
chmod 444 "$TMP_DIR/config/homepage/widgets.yaml"
chmod 555 "$TMP_DIR/config/homepage"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
chmod 755 "$TMP_DIR/config/homepage"
# Then it warns with the path and logs no cputemp or network success
assert_contains "$out" "widgets.yaml not updated" "warning names the failed widgets write"
assert_not_contains "$out" "cputemp enabled" "no cputemp-enabled success on failed write"
assert_not_contains "$out" "cputemp disabled" "no cputemp-disabled success on failed write"
assert_not_contains "$out" "network widget:" "no network success on failed write"

# 6. Given a stale settings.yaml layout in a directory the user cannot write after services.yaml exists
fresh_config
configure_homepage >/dev/null 2>&1
printf 'layout: {}\n' >"$TMP_DIR/config/homepage/settings.yaml"
chmod 444 "$TMP_DIR/config/homepage/settings.yaml" "$TMP_DIR/config/homepage/services.yaml"
chmod 555 "$TMP_DIR/config/homepage"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
chmod 755 "$TMP_DIR/config/homepage"
# Then it warns about settings.yaml and does not log the layout as updated
assert_contains "$out" "settings.yaml not updated" "warning names the failed settings write"
assert_not_contains "$out" "layout updated" "no layout success on failed write"

# 7. Given a read-only settings.yaml in a writable directory
fresh_config
configure_homepage >/dev/null 2>&1
printf 'layout: {}\n' >"$TMP_DIR/config/homepage/settings.yaml"
chmod 444 "$TMP_DIR/config/homepage/settings.yaml"
# When configure_homepage runs
out=$(configure_homepage 2>&1)
# Then the layout is rewritten by rename and logged as updated
assert_contains "$out" "layout updated" "layout success logged after real write"
assert_file_not_contains "$TMP_DIR/config/homepage/settings.yaml" "layout: {}" "settings layout replaced"

# 8. Given a widgets.yaml in a directory the user cannot write, on a NAS install
fresh_config
printf -- '- resources:\n    cpu: true\n    memory: true\n    disk: /data\n' >"$TMP_DIR/config/homepage/widgets.yaml"
chmod 555 "$TMP_DIR/config/homepage"
# When the NAS label is applied
out=$(_homepage_apply_nas_label "$TMP_DIR/config/homepage/widgets.yaml" true 2>&1)
chmod 755 "$TMP_DIR/config/homepage"
# Then it warns and does not log the NAS label as enabled
assert_contains "$out" "widgets.yaml not updated" "warning names the failed NAS label write"
assert_not_contains "$out" "NAS storage label enabled" "no NAS success on failed write"

# 9. Given a read-only widgets.yaml in a writable directory on a NAS install
fresh_config
printf -- '- resources:\n    cpu: true\n    memory: true\n    disk: /data\n' >"$TMP_DIR/config/homepage/widgets.yaml"
chmod 444 "$TMP_DIR/config/homepage/widgets.yaml"
# When the NAS label is applied
out=$(_homepage_apply_nas_label "$TMP_DIR/config/homepage/widgets.yaml" true 2>&1)
# Then the label block is written and success is logged
assert_contains "$out" "NAS storage label enabled" "NAS success logged after real write"
assert_file_contains "$TMP_DIR/config/homepage/widgets.yaml" "label: NAS" "NAS block written"

scenario_end "$CURRENT_SCENARIO"
summary
