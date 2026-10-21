#!/usr/bin/env bash
# tests/unit/stage1-completion.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="stage1-completion"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/setup/stack.sh"
# print_access_info calls gpu_brand_label, which now lives in gpu.sh.
source "$REPO_ROOT/scripts/setup/gpu.sh"

set +e
set +u

SCRIPT_DIR="$TMP_DIR"
cat >"$TMP_DIR/.env" <<'EOF'
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=example.com
EOF

# Fixtures consumed by print_access_info in scripts/setup/stack/summary.sh.
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
JELLYFIN_ADMIN_USER="mediaadmin"
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
NPM_ADMIN_EMAIL="owner@home.test"
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
TORRENT_PORT="6881"
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
WG_PORT="51820"
GPU_TYPE="none"
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
SMB_ENABLED="false"
# shellcheck disable=SC2034 # read by print_access_info in scripts/setup/stack/summary.sh
BAZARR_ENABLED="false"
unset REMOTE_WEB_STATE

output=$(print_access_info)

assert_contains "$output" "http://" "stage1-completion: prints LAN URL base"
assert_contains "$output" ":8096" "stage1-completion: includes Jellyfin LAN URL"
assert_contains "$output" "Portainer        http://" "stage1-completion: includes Portainer URL"
assert_contains "$output" "mediaadmin / (admin password above)" "stage1-completion: Portainer login uses wizard admin username + points at the admin password"
assert_contains "$output" "You can stop here. Your media server works on the LAN." "stage1-completion: completion message"
assert_contains "$output" "To enable remote access (HTTPS, VPN), choose Features & settings -> Add remote access from the menu." "stage1-completion: retry hint"

cat >"$TMP_DIR/.env" <<'EOF'
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=example.com
JELLYFIN_GPU=none
STAGE_3_GPU_STATE=
EOF
# Fixture consumed by the sourced product code under test.
# shellcheck disable=SC2034
GPU_TYPE="nvidia"
output=$(print_access_info)
if [[ "$output" == *"GPU: NVIDIA transcoding enabled"* ]]; then
    fail "stage1-completion: detected GPU alone does not advertise transcoding enabled"
else
    pass "stage1-completion: detected GPU alone does not advertise transcoding enabled"
fi

cat >"$TMP_DIR/.env" <<'EOF'
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=example.com
JELLYFIN_GPU=nvidia
STAGE_3_GPU_STATE=complete
EOF
output=$(print_access_info)
assert_contains "$output" "GPU: NVIDIA transcoding enabled" "stage1-completion: completed Stage 3 advertises transcoding enabled"

# --- _stage1_install outcome: a failed Jellyfin probe must not read as success ---
# Runs _stage1_install in a subshell under errexit (as setup.sh does) with
# stubbed services and curl, then the same "record completed" step setup.sh
# performs next. Prints "rc|marker|outcome".
run_install_case() {
    local api_key="$1" curl_mode="$2"
    local dir result
    dir=$(mktemp -d)
    result="$dir/result"
    mkdir -p "$dir/scripts"
    printf "JELLYFIN_API_KEY=%s\nSTAGE_1_COMPLETE=\n" "$api_key" >"$dir/.env"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/scripts/configure.sh"
    chmod +x "$dir/scripts/configure.sh"
    (
        SCRIPT_DIR="$REPO_ROOT"
        source "$REPO_ROOT/scripts/lib/common.sh"
        source "$REPO_ROOT/scripts/setup/checks.sh"
        source "$REPO_ROOT/scripts/setup/stages/stage1.sh"
        source "$REPO_ROOT/scripts/setup/stage1/demo.sh"
        SCRIPT_DIR="$dir"
        _ENV_HOST_ADDRESS=127.0.0.1
        export UFW_ENABLED=false
        export MEDIASTACK_LAUNCHER_RESULT="$result"
        log_info() { :; }
        log_ok() { :; }
        log_warn() { :; }
        _wizard_apply_settings() { :; }
        _stage1_source_env() { :; }
        _stage1_final_nas_preflight() { :; }
        storage_pause_watchdog_for_install() { :; }
        stop_existing_stack() { :; }
        create_data_dirs() { :; }
        create_config_dirs() { :; }
        generate_override() { :; }
        storage_install_watchdog() { :; }
        pull_images() { :; }
        start_stack() { :; }
        wait_all_healthy() { :; }
        setup_hardening() { :; }
        setup_samba() { :; }
        print_access_info() { :; }
        df() { printf "Filesystem 1G-blocks Used Available Use%% Mounted on\nfixture 1000G 1G 500G 1%% /\n"; }
        curl() {
            [[ "$curl_mode" == ok ]] && return 0
            [[ "$curl_mode" == health-only && "$*" == */health* ]] && return 0
            return 22
        }
        set -e
        _stage1_install
        record_launcher_outcome completed
    ) >/dev/null 2>&1
    local rc=$?
    local marker outcome=""
    marker=$(grep -c "^STAGE_1_COMPLETE='1'" "$dir/.env")
    [[ -s "$result" ]] && outcome=$(<"$result")
    rm -rf "$dir"
    echo "$rc|$marker|$outcome"
}

# Given a valid API key and a 200 from /Users, When Stage 1 install finishes, Then the marker is written, rc is 0 and the outcome is completed.
assert_eq "0|1|completed" "$(run_install_case key ok)" \
    "stage1 outcome: authenticated /Users probe writes the marker and records completed"
# Given an API key but a failing /Users probe, When Stage 1 install finishes, Then no marker is written, rc is non-zero and no outcome is recorded.
assert_eq "1|0|" "$(run_install_case key fail)" \
    "stage1 outcome: failed /Users probe leaves no marker, returns non-zero, records nothing"
# Given no API key but a responding /health, When Stage 1 install finishes, Then it fails with no marker and no outcome.
assert_eq "1|0|" "$(run_install_case "" health-only)" \
    "stage1 outcome: /health-only response (no API key) is a failure"
# Given no API key and no Jellyfin response, When Stage 1 install finishes, Then it fails with no marker and no outcome.
assert_eq "1|0|" "$(run_install_case "" fail)" \
    "stage1 outcome: no Jellyfin response is a failure"

scenario_end "$CURRENT_SCENARIO"
summary
