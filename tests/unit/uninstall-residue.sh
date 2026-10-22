#!/usr/bin/env bash
# tests/unit/uninstall-residue.sh
#
# Contract: uninstall leaves no MediaStack Docker volumes or networks and no
# generated files in the checkout, and never touches resources it does not own.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="uninstall-residue"
scenario_begin "$CURRENT_SCENARIO"
source "$REPO_ROOT/setup.sh"
set +e +u
log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# A Docker stand-in that models labelled and unlabelled volumes and networks.
# Ids of the form <project>_x carry the project label; "mine" does not.
DOCKER_REMOVED=()
docker() {
    case "$1 $2" in
        "compose --profile") [[ "$*" == *" config "* ]] && printf '{"name":"%s"}' "${FAKE_PROJECT-mediastack}" ;;
        "volume ls")
            [[ "$*" == *"label=com.docker.compose.project=mediastack"* ]] && printf '%s\n' anon1 mediastack_data
            # Anonymous volumes carry only this label, never the project label.
            [[ "$*" == *"label=com.docker.volume.anonymous"* ]] && printf '%s\n' anonA anonB
            ;;
        "ps -aq") [[ "$*" == *"label=com.docker.compose.project=mediastack"* ]] && echo c1 ;;
        "inspect -f") printf '%s\n' anonA user_named ;;
        "volume inspect") return 1 ;;
        "network ls") [[ "$*" == *"label=com.docker.compose.project=mediastack"* ]] && printf '%s\n' socket-proxy ;;
        "volume rm" | "network rm") DOCKER_REMOVED+=("$1:$3") ;;
    esac
    return 0
}

# Given labelled volumes and an old network, plus a user volume without the label
# When the project resources are removed
# Then every labelled volume and network goes and the user volume stays
remove_project_docker_resources
assert_eq "volume:anon1 volume:mediastack_data network:socket-proxy" "${DOCKER_REMOVED[*]}" \
    "project cleanup: removes labelled volumes and networks only"

# Given the project name cannot be determined
# When the project resources are removed
# Then nothing is removed and the cleanup reports failure
DOCKER_REMOVED=()
FAKE_PROJECT=""
remove_project_docker_resources
assert_eq "1" "$?" "project cleanup: unknown project name fails"
assert_eq "0" "${#DOCKER_REMOVED[@]}" "project cleanup: unknown project name removes nothing"
unset FAKE_PROJECT

# Given an uninstall whose compose teardown succeeded
# When the uninstall destroy step runs
# Then the project resources are removed as well
SCRIPT_DIR="$TMP_DIR/tree"
mkdir -p "$SCRIPT_DIR"
DOCKER_REMOVED=()
ui_input() { echo DESTROY; }
storage_pause_watchdog_for_install() { return 0; }
sudo() { return 1; }
nuke_existing_install uninstall >/dev/null 2>&1
assert_eq "0" "$?" "uninstall: destroy step succeeds"
assert_contains "${DOCKER_REMOVED[*]}" "network:socket-proxy" "uninstall: leftover project network removed"
unset -f sudo

# Given a MediaStack container that mounts an anonymous volume and a user-named volume,
#   and another anonymous volume that no MediaStack container uses
# When the uninstall destroy step runs
# Then only the MediaStack container's anonymous volume is removed
DOCKER_REMOVED=()
sudo() { return 1; }
nuke_existing_install uninstall >/dev/null 2>&1
assert_contains "${DOCKER_REMOVED[*]}" "volume:anonA" "uninstall: anonymous volume of a MediaStack container removed"
assert_eq "no" "$([[ " ${DOCKER_REMOVED[*]} " == *" volume:anonB "* || " ${DOCKER_REMOVED[*]} " == *" volume:user_named "* ]] && echo yes || echo no)" \
    "uninstall: another anonymous volume and a user-named volume are kept"
unset -f sudo

# Given generated files beside config/ and a preserved examples/ directory
# When the runtime config is wiped
# Then the generated files are gone and examples/ remains
SCRIPT_DIR="$TMP_DIR/wipe"
mkdir -p "$SCRIPT_DIR/config/examples" "$SCRIPT_DIR/config/sonarr"
: >"$SCRIPT_DIR/.configure_issues"
: >"$SCRIPT_DIR/docker-compose.override.yml"
sudo() { "$@"; }
wipe_config_runtime
assert_eq "no" "$([[ -e "$SCRIPT_DIR/.configure_issues" ]] && echo yes || echo no)" "wipe: .configure_issues removed"
assert_eq "no" "$([[ -e "$SCRIPT_DIR/docker-compose.override.yml" ]] && echo yes || echo no)" "wipe: docker-compose.override.yml removed"
assert_eq "yes" "$([[ -d "$SCRIPT_DIR/config/examples" ]] && echo yes || echo no)" "wipe: examples/ preserved"
assert_eq "no" "$([[ -e "$SCRIPT_DIR/config/sonarr" ]] && echo yes || echo no)" "wipe: service config removed"

summary
