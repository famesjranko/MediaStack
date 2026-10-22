#!/usr/bin/env bash
# tests/unit/wireguard-ufw.sh
#
# Contract tests for the UFW rule that lets WireGuard tier traffic reach the
# host: allow from exactly the wireguard container's /32, comment
# MediaStack:WireGuard-clients, present only while the remote profile is on and
# UFW is active. ufw is a small stateful fake that prints `ufw status numbered`
# in ufw's real column layout, so the rule parsing is exercised end to end.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wireguard-ufw"
scenario_begin "$CURRENT_SCENARIO"
source "$REPO_ROOT/setup.sh"
source "$REPO_ROOT/scripts/launcher/converge.sh"
source "$REPO_ROOT/scripts/setup/stages/stage2.sh"
set +e +u

log_ok() { :; }
log_info() { :; }
log_warn() { :; }
log_error() { :; }
log_skip() { :; }
_ms_state_set() { :; }
_ms_state_get() { echo 0; }

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
# SCRIPT_DIR is the tree whose .env the code under test reads.
SCRIPT_DIR="$TMP_DIR/tree"
mkdir -p "$SCRIPT_DIR"
ln -s "$REPO_ROOT/scripts" "$SCRIPT_DIR/scripts"
unset MEDIASTACK_NETWORK_PREFIX UFW_ENABLED

TAG="MediaStack:WireGuard-clients"
RULES="$TMP_DIR/rules" # one "to|source|comment" line per rule
UFW_STATE="active"
UFW_CALLS="$TMP_DIR/calls"
MS_UFW_SBIN_PATH="$TMP_DIR/ufw-bin"
: >"$MS_UFW_SBIN_PATH"
chmod +x "$MS_UFW_SBIN_PATH"

# Fake `sudo ufw ...`. Only the subcommands the code uses are modelled.
sudo() {
    [[ "$1" == ufw ]] || return 0
    shift
    printf '%s\n' "$*" >>"$UFW_CALLS"
    case "$1" in
        status)
            echo "Status: $UFW_STATE"
            [[ "$UFW_STATE" == active ]] || return 0
            if [[ "${2:-}" == numbered ]]; then
                printf '\n     To                         Action      From\n     --                         ------      ----\n'
                local n=0 to src comment
                while IFS='|' read -r to src comment; do
                    n=$((n + 1))
                    printf '[%2d] %-26s ALLOW IN    %-26s# %s\n' "$n" "$to" "$src" "$comment"
                done <"$RULES"
            fi
            ;;
        allow)
            [[ -n "${UFW_FAIL_ALLOW:-}" ]] && return 1
            shift
            local to=Anywhere src=Anywhere comment=""
            if [[ "$1" == from ]]; then
                src=$2
                shift 2
                [[ "$1" == to ]] && shift 2
            else
                to=$1
                shift
            fi
            [[ "$1" == comment ]] && comment=$2
            grep -qxF "$to|$src|$comment" "$RULES" || echo "$to|$src|$comment" >>"$RULES"
            ;;
        --force)
            [[ "$2" == delete ]] && sed -i "${3}d" "$RULES"
            ;;
        show)
            while IFS='|' read -r to src comment; do
                echo "ufw allow from $src to any comment '$comment'"
            done <"$RULES"
            ;;
    esac
    return 0
}

# Writes the .env the profile detection and prefix lookup read.
write_env_file() { printf '%s\n' "$@" >"$SCRIPT_DIR/.env"; }
reset_host() {
    cat >"$RULES" <<'RULES_EOF'
22/tcp|192.168.0.0/16|MediaStack:SSH-LAN
9999/tcp|Anywhere|user rule
51820/udp|Anywhere|MediaStack:WireGuard
RULES_EOF
    UFW_STATE=active
    : >"$UFW_CALLS"
    unset UFW_ENABLED MEDIASTACK_NETWORK_PREFIX
    write_env_file "WG_INIT_PASSWORD='secret'"
}
wg_rule_lines() { grep -c "|$TAG\$" "$RULES"; }
others_intact() {
    grep -qxF '22/tcp|192.168.0.0/16|MediaStack:SSH-LAN' "$RULES" \
        && grep -qxF '9999/tcp|Anywhere|user rule' "$RULES" \
        && grep -qxF '51820/udp|Anywhere|MediaStack:WireGuard' "$RULES"
}
write_calls() { grep -cE '^(allow|--force delete)' "$UFW_CALLS"; }

# Given the remote profile is on and UFW is active with the compose default subnet
# When the rule is converged
# Then exactly one rule allows the wireguard container's /32 with the exact comment
reset_host
setup_ufw_wireguard_clients
assert_eq "1" "$(wg_rule_lines)" "wg rule: added once when WireGuard and UFW are on"
assert_eq "Anywhere|172.28.0.11|$TAG" "$(grep "|$TAG\$" "$RULES")" "wg rule: source is the container /32 on the 172.28.0 fallback, to any port"
assert_eq "true" "$(others_intact && echo true)" "wg rule: the other rules are untouched"
assert_not_contains "$(cat "$RULES")" "172.16.0.0/12" "wg rule: never widens to the Docker range"

# Given MEDIASTACK_NETWORK_PREFIX is set in .env
# When the rule is converged
# Then the source follows that prefix
reset_host
write_env_file "WG_INIT_PASSWORD='secret'" "MEDIASTACK_NETWORK_PREFIX=172.30.4"
setup_ufw_wireguard_clients
assert_eq "Anywhere|172.30.4.11|$TAG" "$(grep "|$TAG\$" "$RULES")" "wg rule: source follows MEDIASTACK_NETWORK_PREFIX from .env"

# Given the remote profile is on and UFW is active
# When the rule is converged twice
# Then the second run changes nothing
reset_host
setup_ufw_wireguard_clients
: >"$UFW_CALLS"
setup_ufw_wireguard_clients
assert_eq "0" "$(write_calls)" "wg rule: a second run writes nothing"
assert_eq "1" "$(wg_rule_lines)" "wg rule: still exactly one after a second run"

# Given WireGuard is not enabled
# When the rule is converged
# Then no rule is added
reset_host
write_env_file "WG_INIT_PASSWORD=''"
setup_ufw_wireguard_clients
assert_eq "0" "$(wg_rule_lines)" "wg rule: absent when WireGuard is off"

# Given UFW is inactive
# When the rule is converged
# Then no rule is added
reset_host
UFW_STATE=inactive
setup_ufw_wireguard_clients
assert_eq "0" "$(write_calls)" "wg rule: nothing written while UFW is inactive"

# Given the user turned MediaStack's UFW off while a UFW is still active
# When the rule is converged
# Then no rule is added
reset_host
UFW_ENABLED=false
setup_ufw_wireguard_clients
assert_eq "0" "$(wg_rule_lines)" "wg rule: absent when UFW_ENABLED=false"

# Given the rule exists and WireGuard is then removed
# When the rule is converged
# Then the rule is removed and every other rule is kept
reset_host
setup_ufw_wireguard_clients
write_env_file "WG_INIT_PASSWORD=''"
setup_ufw_wireguard_clients
assert_eq "0" "$(wg_rule_lines)" "wg rule: removed when WireGuard is removed"
assert_eq "true" "$(others_intact && echo true)" "wg rule: removal keeps the other rules, including MediaStack:WireGuard"

# Given the rule exists for an old subnet prefix
# When the prefix changes and the rule is converged
# Then the old source is replaced, not kept beside the new one
reset_host
write_env_file "WG_INIT_PASSWORD='secret'" "MEDIASTACK_NETWORK_PREFIX=172.29.0"
setup_ufw_wireguard_clients
write_env_file "WG_INIT_PASSWORD='secret'" "MEDIASTACK_NETWORK_PREFIX=172.31.0"
setup_ufw_wireguard_clients
assert_eq "Anywhere|172.31.0.11|$TAG" "$(grep "|$TAG\$" "$RULES")" "wg rule: a changed prefix replaces the old source"

# Given a rule whose comment only starts with MediaStack:WireGuard-clients
# When WireGuard is removed and the rule is converged
# Then that rule is not MediaStack's and stays
reset_host
echo "Anywhere|10.1.1.1|${TAG}-extra" >>"$RULES"
write_env_file "WG_INIT_PASSWORD=''"
setup_ufw_wireguard_clients
assert_eq "1" "$(grep -c -- "-extra\$" "$RULES")" "wg rule: matching is by exact comment"

# Given the rule is installed and UFW is switched off through the UFW teardown
# When _uninstall_ufw runs (UFW toggle OFF and full uninstall share it)
# Then the rule is gone and the user's rule stays
reset_host
setup_ufw_wireguard_clients
_ufw_defaults() { echo "deny allow"; }
_ufw_rule_hash() { echo hash; }
_admin_filter_strip_dedup_hook() { return 0; }
detect_ssh_server_ports() { :; }
unset SSH_CONNECTION
_uninstall_ufw
assert_eq "0" "$(wg_rule_lines)" "wg rule: removed by the UFW teardown (UFW off and uninstall)"
assert_eq "true" "$(grep -qxF '9999/tcp|Anywhere|user rule' "$RULES" && echo true)" "wg rule: the teardown keeps the user's rule"

# Given an existing install that predates the rule
# When the converge action runs
# Then the rule is added, and a failure to add it fails the action
stub_converge_steps() {
    MEDIASTACK_ADMIN_FILTER_DROPIN=x
    setup_admin_filter() { return 0; }
    json_get() { :; }
    qbt_narrow_legacy_whitelist() { :; }
    beszel_converge_local_system() { return 0; }
    ufw_remove_legacy_beszel_rule() { return 0; }
    docker() { echo false; }
}
stub_converge_steps
reset_host
converge_mediastack_state
assert_eq "0" "$?" "converge: succeeds on an existing install"
assert_eq "Anywhere|172.28.0.11|$TAG" "$(grep "|$TAG\$" "$RULES")" "converge: adds the rule to an existing install"
setup_ufw_wireguard_clients() { return 1; }
converge_mediastack_state
assert_eq "1" "$?" "converge: a rule that cannot be converged fails the action"
unset -f setup_ufw_wireguard_clients
source "$REPO_ROOT/scripts/setup/hardening/firewall.sh"

# Given UFW is off and WireGuard is enabled
# When the user turns the Firewall (UFW) toggle ON
# Then the WireGuard rule is added, and a failure to add it is reported as a failed action
WG_TREE="$TMP_DIR/toggle-tree"
mkdir -p "$WG_TREE/scripts/setup"
ln -s "$REPO_ROOT/scripts/lib" "$WG_TREE/scripts/lib"
cat >"$WG_TREE/scripts/setup/hardening.sh" <<HARDENING_EOF
source "$REPO_ROOT/scripts/setup/hardening/firewall.sh"
setup_ufw() { :; }
setup_ufw_service_ports() { :; }
setup_admin_filter() { :; }
HARDENING_EOF
source "$REPO_ROOT/scripts/launcher/features.sh"
ui_confirm() { return 0; }
ui_log() { :; }
_feature_persist_or_report() { UFW_ENABLED=true; }
validate_install_state() { return 0; }
admin_filter_opted_out() { return 0; }
launcher_pause_for_menu() { :; }
TOGGLE_RC=""
_show_action_result() { TOGGLE_RC=$1; }
reset_host
SCRIPT_DIR="$WG_TREE"
write_env_file "WG_INIT_PASSWORD='secret'"
UFW_ENABLED=false
action_toggle_ufw >/dev/null
assert_eq "0" "$TOGGLE_RC" "ufw toggle ON: succeeds"
assert_eq "Anywhere|172.28.0.11|$TAG" "$(grep "|$TAG\$" "$RULES")" "ufw toggle ON: adds the WireGuard rule"
sed -i "/|$TAG\$/d" "$RULES"
UFW_FAIL_ALLOW=1
UFW_ENABLED=false
action_toggle_ufw >/dev/null
assert_eq "1" "$TOGGLE_RC" "ufw toggle ON: a rule that cannot be added fails the action"
SCRIPT_DIR="$TMP_DIR/tree"
unset UFW_ENABLED UFW_FAIL_ALLOW

# Given Stage 2 enables remote access
# When the Stage 2 install runs
# Then it converges the WireGuard firewall rule after .env is written
STAGE2_ORDER=""
_stage2_seed_wizard_defaults() { :; }
write_env() { STAGE2_ORDER+="write_env "; }
stage2_preserve_stage1_marker() { :; }
_stage2_source_env() { :; }
setup_ufw_wireguard_clients() { STAGE2_ORDER+="wg_rule "; }
pull_images() { :; }
start_stack() { :; }
wait_all_healthy() { :; }
service_container_running() { return 1; }
f2b_uninstall_reload_watcher() { :; }
_stage2_ddns_unverified() { return 0; }
print_access_info() { :; }
_WIZ_WG_ENABLED=true _WIZ_ADMIN_PW=pw _WIZ_JELLYFIN_BITRATE="" UI_DEMO=1 \
    _stage2_install >/dev/null 2>&1 </dev/null
assert_contains "$STAGE2_ORDER" "write_env wg_rule" "stage 2: converges the WireGuard rule after writing .env"

summary
