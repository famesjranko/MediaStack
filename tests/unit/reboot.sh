#!/usr/bin/env bash
# tests/unit/reboot.sh
#
# Focused coverage for post-reboot banner/result rendering and unit paths.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="reboot"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

BANNER_CAPTURE="$TMP_ROOT/profile"
SERVICE_CAPTURE="$TMP_ROOT/mediastack-setup.service"
sudo() {
    case "${1:-}" in
        tee)
            shift
            case "${1:-}" in
                /etc/profile.d/mediastack-setup-result.sh)
                    command tee "$BANNER_CAPTURE"
                    ;;
                /etc/systemd/system/mediastack-setup.service)
                    command tee "$SERVICE_CAPTURE"
                    ;;
                *)
                    command tee "$TMP_ROOT/unknown-tee-output"
                    ;;
            esac
            ;;
        chmod|rm|systemctl)
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

USER="setupuser"
SCRIPT_DIR="$TMP_ROOT/custom checkout \${USER} 100%"
mkdir -p "$SCRIPT_DIR" "$TMP_ROOT/home"

source "$REPO_ROOT/scripts/setup/reboot.sh"

schedule_post_reboot >/dev/null 2>&1
service_content="$(cat "$SERVICE_CAPTURE")"
escaped_script_dir="${SCRIPT_DIR//\\/\\x5c}"
escaped_script_dir="${escaped_script_dir//$'\t'/\\x09}"
escaped_script_dir="${escaped_script_dir// /\\x20}"
escaped_script_dir="${escaped_script_dir//\"/\\x22}"
escaped_script_dir="${escaped_script_dir//%/%%}"

assert_contains "$service_content" "WorkingDirectory=$escaped_script_dir" "post-reboot service: WorkingDirectory uses systemd-escaped checkout path"
assert_contains "$service_content" "ExecStart=:$escaped_script_dir/setup.sh" "post-reboot service: ExecStart uses systemd-escaped checkout path with substitution disabled"
if [[ "$service_content" == *"WorkingDirectory=$SCRIPT_DIR"* || "$service_content" == *"ExecStart=$SCRIPT_DIR/setup.sh"* ]]; then
    fail "post-reboot service: generated unit does not contain raw checkout path with spaces"
else
    pass "post-reboot service: generated unit does not contain raw checkout path with spaces"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    verify_output="$(systemd-analyze verify "$SERVICE_CAPTURE" 2>&1 || true)"
    if [[ "$verify_output" == *"bad unit file setting"* || "$verify_output" == *"WorkingDirectory= path is not absolute"* || "$verify_output" == *"Command $TMP_ROOT/custom is not executable"* ]]; then
        fail "post-reboot service: generated unit verifies with escaped checkout path" "$verify_output"
    else
        pass "post-reboot service: generated unit verifies with escaped checkout path"
    fi
else
    skip "post-reboot service: generated unit verifies with escaped checkout path" "systemd-analyze unavailable"
fi

install_post_reboot_banner >/dev/null 2>&1

expected_result="$SCRIPT_DIR/.setup-result"
profile_content="$(cat "$BANNER_CAPTURE")"

assert_contains "$profile_content" "_ms_setup_result='$expected_result'" "reboot banner: profile script stores actual setup-result path"
if bash -n "$BANNER_CAPTURE"; then
    pass "reboot banner: generated profile script parses"
else
    fail "reboot banner: generated profile script parses"
fi
if [[ "$profile_content" == *'$HOME/MediaStack/.setup-result'* ]]; then
    fail "reboot banner: profile script does not hardcode home checkout"
else
    pass "reboot banner: profile script does not hardcode home checkout"
fi

printf '%s\n' "post reboot result from custom checkout" > "$expected_result"
profile_output="$(HOME="$TMP_ROOT/home" bash -c 'sudo() { return 0; }; source "$1"' _ "$BANNER_CAPTURE" 2>&1)"
assert_contains "$profile_output" "post reboot result from custom checkout" "reboot banner: login reads result from actual checkout"
if [[ -f "$expected_result" ]]; then
    fail "reboot banner: login removes consumed setup-result"
else
    pass "reboot banner: login removes consumed setup-result"
fi

write_setup_result ok
ok_result="$(cat "$expected_result")"
assert_contains "$ok_result" "cd '$SCRIPT_DIR' && ./mediastack" "reboot result ok: command uses actual checkout path"
if [[ "$ok_result" == *"cd ~/MediaStack"* ]]; then
    fail "reboot result ok: command does not hardcode home checkout"
else
    pass "reboot result ok: command does not hardcode home checkout"
fi

write_setup_result error
error_result="$(cat "$expected_result")"
assert_contains "$error_result" "cd '$SCRIPT_DIR' && ./setup.sh" "reboot result error: rerun command uses actual checkout path"
if [[ "$error_result" == *"cd ~/MediaStack"* ]]; then
    fail "reboot result error: command does not hardcode home checkout"
else
    pass "reboot result error: command does not hardcode home checkout"
fi

scenario_end "$CURRENT_SCENARIO"
summary
