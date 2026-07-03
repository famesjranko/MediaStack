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
cat > "$TMP_DIR/.env" <<'EOF'
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=example.com
EOF

JELLYFIN_ADMIN_USER="mediaadmin"
NPM_ADMIN_EMAIL="owner@home.test"
TORRENT_PORT="6881"
WG_PORT="51820"
GPU_TYPE="none"
SMB_ENABLED="false"
BAZARR_ENABLED="false"
unset REMOTE_WEB_STATE

output=$(print_access_info)

assert_contains "$output" "http://" "stage1-completion: prints LAN URL base"
assert_contains "$output" ":8096" "stage1-completion: includes Jellyfin LAN URL"
assert_contains "$output" "Portainer        http://" "stage1-completion: includes Portainer URL"
assert_contains "$output" "mediaadmin / (admin password above)" "stage1-completion: Portainer login uses wizard admin username + points at the admin password"
assert_contains "$output" "You can stop here. Your media server works on the LAN." "stage1-completion: completion message"
assert_contains "$output" "To enable remote access (HTTPS, VPN), choose Features & settings -> Add remote access from the menu." "stage1-completion: retry hint"

cat > "$TMP_DIR/.env" <<'EOF'
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

cat > "$TMP_DIR/.env" <<'EOF'
JELLYFIN_ADMIN_PASSWORD='GeneratedPassword123'
DOMAIN=example.com
JELLYFIN_GPU=nvidia
STAGE_3_GPU_STATE=complete
EOF
output=$(print_access_info)
assert_contains "$output" "GPU: NVIDIA transcoding enabled" "stage1-completion: completed Stage 3 advertises transcoding enabled"

scenario_end "$CURRENT_SCENARIO"
summary
