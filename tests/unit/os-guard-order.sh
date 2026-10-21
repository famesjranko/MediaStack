#!/usr/bin/env bash
# tests/unit/os-guard-order.sh
#
# Contract tests for where setup.sh main() applies the OS guard: install and
# configure paths are refused on an unsupported OS (after repairing a Docker apt
# source that older code broke), while --uninstall runs on any host.
# Standalone: bash tests/unit/os-guard-order.sh
# Each case runs main() in a subshell with the downstream functions stubbed to
# record call order; nothing touches the real host.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck disable=SC2034 # read by tests/lib/assert.sh for failure labels
CURRENT_SCENARIO="os-guard-order"
scenario_begin "$CURRENT_SCENARIO"

FAKE_ROOT=$(mktemp -d)
trap 'rm -rf "$FAKE_ROOT"' EXIT

printf 'PRETTY_NAME="Ubuntu 24.04 LTS"\nID=ubuntu\nID_LIKE=debian\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"$FAKE_ROOT/ubuntu"
printf 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\nID=debian\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n' >"$FAKE_ROOT/debian12"
printf 'PRETTY_NAME="Debian GNU/Linux trixie/sid"\nID=debian\nVERSION_CODENAME=trixie\n' >"$FAKE_ROOT/sid"
# The line the old writer put on Ubuntu hosts.
printf 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian       noble stable\n' >"$FAKE_ROOT/docker.list.template"

# run_main <os-release fixture> [env assignments...] -- [main args...]
# Prints the recorded calls (one per line), then "RC=<exit status>".
run_main() {
    local osrel="$1"
    shift
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do
        envs+=("$1")
        shift
    done
    shift
    cp "$FAKE_ROOT/docker.list.template" "$FAKE_ROOT/docker.list"
    (
        cd "$REPO_ROOT" || exit 97
        export "${envs[@]}"
        # shellcheck source=../../setup.sh
        source ./setup.sh
        set +e
        set +u
        # shellcheck disable=SC2034  # read by the apt-source helpers in scripts/setup/packages.sh
        {
            MEDIASTACK_OS_RELEASE="$osrel"
            MEDIASTACK_DOCKER_APT_LIST="$FAKE_ROOT/docker.list"
            MEDIASTACK_DOCKER_APT_KEY="$FAKE_ROOT/docker.gpg"
        }
        rec() { echo "CALL $1"; }
        sudo() { "$@"; }
        # Real remove_broken_docker_apt_source is wrapped to record, then runs.
        eval "_real_$(declare -f remove_broken_docker_apt_source)"
        remove_broken_docker_apt_source() {
            rec remove_broken_docker_apt_source
            _real_remove_broken_docker_apt_source
        }
        ui_banner() { :; }
        log_ok() { :; }
        log_info() { :; }
        log_warn() { :; }
        log_error() { echo "ERROR $*"; }
        check_not_root() { :; }
        prompt_sudo_cache() { :; }
        record_launcher_outcome() { :; }
        ui_confirm() { return 0; }
        validate_install_state() {
            rec validate_install_state
            return 1
        }
        uninstall_best_effort_cleanup() { rec uninstall_best_effort_cleanup; }
        # First step past the OS guard on the install path: stop here.
        check_disk_floor() {
            rec past_os_guard
            exit 99
        }
        install_base_packages() { rec install_base_packages; }
        main "$@"
        echo "MAIN_RETURNED"
    ) 2>&1
    echo "RC=$?"
}

# -- A2/A6: install path on Ubuntu --------------------------------------------
# Given an Ubuntu host with a MediaStack docker.list for "linux/debian noble"
# When the default install path runs
# Then the broken source is removed, setup refuses naming Ubuntu, and no
#   package install or later step runs
out=$(run_main "$FAKE_ROOT/ubuntu" --)
assert_contains "$out" "CALL remove_broken_docker_apt_source" "install on Ubuntu: broken Docker apt source is repaired before refusing"
assert_contains "$out" "ERROR Unsupported OS: Ubuntu 24.04 LTS" "install on Ubuntu: refusal names the detected OS"
assert_contains "$out" "RC=1" "install on Ubuntu: exits non-zero"
assert_not_contains "$out" "CALL install_base_packages" "install on Ubuntu: install_base_packages is never called"
assert_not_contains "$out" "past_os_guard" "install on Ubuntu: no step after the OS guard runs"
assert_eq "gone" "$([[ -e "$FAKE_ROOT/docker.list" ]] && echo present || echo gone)" "install on Ubuntu: the broken docker.list is gone"
repair_line=$(grep -n 'CALL remove_broken' <<<"$out" | head -1 | cut -d: -f1)
refuse_line=$(grep -n 'RC=' <<<"$out" | head -1 | cut -d: -f1)
assert_eq "1" "$((repair_line < refuse_line ? 1 : 0))" "install on Ubuntu: repair is recorded before the refusal exit"

# -- A4: every alternate install-ish path keeps the policy ---------------------
out=$(run_main "$FAKE_ROOT/ubuntu" -- --full)
assert_contains "$out" "RC=1" "--full on Ubuntu: refused"
assert_not_contains "$out" "past_os_guard" "--full on Ubuntu: stops at the OS guard"

out=$(run_main "$FAKE_ROOT/ubuntu" DEMO=1 UI_DEMO=1 --)
assert_contains "$out" "RC=1" "DEMO=1 on Ubuntu: refused"
assert_not_contains "$out" "past_os_guard" "DEMO=1 on Ubuntu: stops at the OS guard"

out=$(run_main "$FAKE_ROOT/ubuntu" STAGE_1_COMPLETE=1 --)
assert_contains "$out" "RC=1" "re-run with STAGE_1_COMPLETE=1 on Ubuntu: refused"
assert_not_contains "$out" "past_os_guard" "re-run with STAGE_1_COMPLETE=1 on Ubuntu: stops at the OS guard"

out=$(run_main "$FAKE_ROOT/sid" --)
assert_contains "$out" "RC=1" "install on Debian testing without VERSION_ID: refused"
assert_not_contains "$out" "past_os_guard" "install on Debian testing without VERSION_ID: stops at the OS guard"

# -- Supported OS still proceeds ----------------------------------------------
# Given Debian 12 When the install path runs Then it passes the OS guard
# and the working-or-absent Docker source is not touched.
out=$(run_main "$FAKE_ROOT/debian12" --)
assert_contains "$out" "CALL past_os_guard" "install on Debian 12: passes the OS guard"
assert_not_contains "$out" "CALL remove_broken_docker_apt_source" "install on Debian 12: no repair on the supported path"

# -- A2: --uninstall on a non-Debian host --------------------------------------
# Given an Ubuntu host with no ownership ledger
# When ./setup.sh --uninstall runs
# Then it reaches validate_install_state and the best-effort cleanup, not the refusal
out=$(run_main "$FAKE_ROOT/ubuntu" -- --uninstall)
assert_contains "$out" "CALL validate_install_state" "--uninstall on Ubuntu: reaches validate_install_state"
assert_contains "$out" "CALL uninstall_best_effort_cleanup" "--uninstall on Ubuntu: reaches the best-effort cleanup"
assert_not_contains "$out" "Unsupported OS" "--uninstall on Ubuntu: is not refused"
assert_not_contains "$out" "CALL install_base_packages" "--uninstall on Ubuntu: never installs packages"

summary
