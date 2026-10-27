# tests/scenarios/wizard-ui-features-add-wireguard.sh — Features & settings "Add WireGuard VPN" PTY flow.
#
# Sources the `mediastack` launcher (root guard stripped) on a READY-HTTPS install
# with no WireGuard, then drives Features & settings -> "Add WireGuard VPN" over a
# real PTY. The launcher's setup runner is replaced by a shell that sources
# setup.sh and runs the REAL run_wireguard_recovery (the code `setup.sh
# --wireguard` runs), so the menu row, the Stage 2 WireGuard prompts and the .env
# write are the production ones. Only slow or host-changing edges are stubbed
# (image pull, stack start, UFW rules); each stub logs to a file.
#   - decline : "no" at the opt-in prompt -> .env and config.yml byte-identical,
#               no stack or firewall step
#   - accept  : Server-only tier -> only the WG_ keys change, stack and firewall
#               steps run, HTTPS state and domain are preserved
# Image-free, so it runs in the default tier with the other wizard-ui scenarios.

_wg_menu_seed_and_fixture() {
    local fixture="$1"
    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack
rm -f .env /tmp/wg-effects
cp .env.example .env
mkdir -p config/ddns-updater config/state /tmp/ms-wizard-wg
cp config/examples/config.yml config.yml
sed -i \
  -e 's#^TZ=.*#TZ=Etc/UTC#' \
  -e 's#^DATA_DIR=.*#DATA_DIR=/tmp/ms-wizard-wg#' \
  -e 's#^HOST_ADDRESS=.*#HOST_ADDRESS=192.168.1.50#' \
  -e 's#^JELLYFIN_ADMIN_USER=.*#JELLYFIN_ADMIN_USER=admin#' \
  -e 's#^JELLYFIN_ADMIN_PASSWORD=.*#JELLYFIN_ADMIN_PASSWORD=WizardAdminPass123#' \
  -e 's#^NPM_ADMIN_EMAIL=.*#NPM_ADMIN_EMAIL=owner@remote.test#' \
  -e 's#^STAGE_1_COMPLETE=.*#STAGE_1_COMPLETE=1#' \
  -e 's#^DOMAIN=.*#DOMAIN=media.remote.test#' \
  -e 's#^REMOTE_WEB_STATE=.*#REMOTE_WEB_STATE=ready#' \
  -e \"s#^WG_INIT_PASSWORD=.*#WG_INIT_PASSWORD=''#\" \
  .env
grep -q '^REMOTE_WEB_STATE=' .env || echo 'REMOTE_WEB_STATE=ready' >> .env
sha256sum .env config.yml > /tmp/wg-before.sha

# The launcher refuses to run as root (EUID guard); DinD runs as root, so source a
# same-directory copy with only that guard stripped.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi\$/d' mediastack > .ms-launcher-test.sh
source ./.ms-launcher-test.sh
set -a; source .env; set +a

_docker_reachable(){ return 0; }
_service_is_running(){ return 0; }
storage_is_nas(){ return 1; }
_ddns_configured(){ return 1; }
recovery_menu_transcoding_available(){ return 1; }

# Stand-in for the launcher's setup runner: run the real setup.sh recovery in a
# subshell on the same PTY, with host-changing edges stubbed and logged.
_run_setup_return() {
    echo \"RUN_SETUP:\$*\"
    (
        source ./setup.sh
        source tests/lib/wizard-stub-common.sh
        ms_stub_core
        ms_stub_common_env
        ms_stub_service_lifecycle
        prompt_sudo_cache() { :; }
        net_detect_lan_cidr() { printf '192.168.1.0/24\\n'; }
        setup_ufw_wireguard_clients() { echo setup_ufw_wireguard_clients >> /tmp/wg-effects; }
        setup_ufw_service_ports() { echo setup_ufw_service_ports >> /tmp/wg-effects; }
        pull_images() { echo pull_images >> /tmp/wg-effects; }
        start_stack() { echo start_stack >> /tmp/wg-effects; }
        run_wireguard_recovery
        echo \"SETUP_RC:\$?\"
    )
}

submenu_features
BASH
chmod +x $fixture"
}

_wg_menu_run() {
    local name="$1" steps_json="$2"
    local fixture="/tmp/wizard-features-wg.sh"
    local steps="/tmp/wizard-features-wg.steps.json"
    local plain_log="/tmp/wizard-features-wg.plain.log"

    _wg_menu_seed_and_fixture "$fixture"
    dind_exec "cat >$steps <<'JSON'
$steps_json
JSON"
    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui features add-wireguard [$name]: PTY flow exits 0"
    else
        fail "wizard-ui features add-wireguard [$name]: PTY flow exits 0"
        dind_exec "tail -200 $plain_log 2>/dev/null || true"
        return 1
    fi
}

run_scenario() {
    local plain_log="/tmp/wizard-features-wg.plain.log" transcript

    # ---- Path 1: decline at the opt-in prompt ---------------------------------
    _wg_menu_run "decline" '[
  {"expect": "Manage features & settings"},
  {"send": "1\n"},
  {"expect": "Set up a WireGuard VPN for admin access\\?"},
  {"send": "n\n"},
  {"expect": "No changes made"},
  {"expect": "Manage features & settings"},
  {"send": "11\n"}
]' || return 1
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "1) Add WireGuard VPN" "wizard-ui features add-wireguard [decline]: menu offers Add WireGuard VPN"
    assert_contains "$transcript" "RUN_SETUP:0 Add WireGuard VPN --wireguard" "wizard-ui features add-wireguard [decline]: row runs setup.sh --wireguard"
    if dind_exec "cd /root/MediaStack && sha256sum -c /tmp/wg-before.sha" >/dev/null 2>&1; then
        pass "wizard-ui features add-wireguard [decline]: .env and config.yml byte-identical"
    else
        fail "wizard-ui features add-wireguard [decline]: .env and config.yml byte-identical"
    fi
    assert_eq "" "$(dind_exec "cat /tmp/wg-effects 2>/dev/null || true")" "wizard-ui features add-wireguard [decline]: no stack or firewall step ran"

    # ---- Path 2: accept with the Server-only tier -----------------------------
    _wg_menu_run "accept" '[
  {"expect": "Manage features & settings"},
  {"send": "1\n"},
  {"expect": "Set up a WireGuard VPN for admin access\\?"},
  {"send": "y\n"},
  {"expect": "WireGuard UDP port"},
  {"send": "\n"},
  {"expect": "VPN access level for your admin device"},
  {"send": "2\n"},
  {"expect": "Start WireGuard with these settings\\?"},
  {"send": "y\n"},
  {"expect": "SETUP_RC:0"},
  {"expect": "Manage features & settings"},
  {"send": "11\n"}
]' || return 1
    assert_eq "WizardAdminPass123" "$(env_get WG_INIT_PASSWORD)" "wizard-ui features add-wireguard [accept]: WG_INIT_PASSWORD set from the admin password"
    assert_eq "server" "$(env_get WG_ACCESS_TIER)" "wizard-ui features add-wireguard [accept]: selected tier saved"
    assert_eq "media.remote.test" "$(env_get WG_HOST)" "wizard-ui features add-wireguard [accept]: endpoint follows the ready domain"
    assert_eq "ready" "$(env_get REMOTE_WEB_STATE)" "wizard-ui features add-wireguard [accept]: HTTPS state stays ready"
    assert_eq "media.remote.test" "$(env_get DOMAIN)" "wizard-ui features add-wireguard [accept]: domain unchanged"
    assert_eq "setup_ufw_wireguard_clients setup_ufw_service_ports pull_images start_stack" "$(dind_exec "tr '\n' ' ' </tmp/wg-effects" | sed 's/ *$//')" "wizard-ui features add-wireguard [accept]: firewall converges, then the stack starts"
}
