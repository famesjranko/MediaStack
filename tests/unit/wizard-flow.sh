#!/usr/bin/env bash
# tests/unit/wizard-flow.sh
#
# Unit test for the wizard flows (run_wizard) and env generation
# (detect_env, write_env). Exercises the interactive UI_DEMO=1 path and the
# non-interactive DEMO=1 path, then verifies .env and config.yml outputs.
#
# No DinD, no Docker needed. Shims docker/speedtest-cli/timedatectl so the
# wizard runs entirely offline.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-flow"
scenario_begin "$CURRENT_SCENARIO"

# --- Temp workspace (acts as SCRIPT_DIR for the wizard) ---
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cp "$REPO_ROOT/config.yml" "$TMP_DIR/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR/scripts"
mkdir -p "$TMP_DIR/config/ddns-updater"

reset_fixture_config() {
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("wizard_completed: true", "wizard_completed: false")
path.write_text(text)
PY
}

reset_fixture_config "$TMP_DIR/config.yml"

# --- Shim externals ---
# Docker: shim so WG hash generation doesn't need a real daemon
docker() {
    if [[ "${1:-}" == "run" ]]; then
        echo "'fakehash\$2b\$10\$test'"
        return 0
    fi
    if [[ "${1:-}" == "--version" ]]; then
        echo "Docker version 27.0.1, build test"
        return 0
    fi
    if [[ "${1:-}" == "compose" ]]; then
        case " $* " in
            *" config --services "*)
                printf '%s\n' jellyfin sonarr radarr jackett qbittorrent jellyseerr homepage portainer uptime-kuma beszel
                if [[ " $* " == *" --profile subtitles "* ]]; then
                    printf '%s\n' bazarr
                fi
                return 0
                ;;
            *" config --images "*)
                printf '%s\n' image{1..10}
                if [[ " $* " == *" --profile subtitles "* ]]; then
                    printf '%s\n' image11
                fi
                return 0
                ;;
        esac
    fi
    command docker "$@"
}
export -f docker

# speedtest-cli: not available in unit test
speedtest-cli() { return 1; }
export -f speedtest-cli

# openssl: deterministic password generation for both demo paths
openssl() {
    if [[ "${1:-}" == "rand" && "${2:-}" == "-base64" ]]; then
        echo "GeneratedDemoPassword123"
        return 0
    fi
    command openssl "$@"
}
export -f openssl

# timedatectl: deterministic timezone
timedatectl() { echo "Etc/UTC"; }
export -f timedatectl

# Silence log_* — assertions drive output
log_ok()    { :; }
log_info()  { :; }
log_warn()  { printf '%s\n' "$1"; }
log_skip()  { :; }
log_error() { :; }

# --- Source all modules (setup.sh guard prevents main() from running) ---
# We need to set up the same environment as setup.sh
SCRIPT_DIR="$TMP_DIR"
export UI_DEMO=1

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/ui.sh"
source "$REPO_ROOT/scripts/setup/checks.sh"
source "$REPO_ROOT/scripts/setup/env_gen.sh"
source "$REPO_ROOT/scripts/setup/wizard.sh"

_stage1_install() {
    if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
        _wizard_apply_settings "balanced" "english" "0"
    fi
    return 0
}

RUN_STAGE2_COUNT=0
run_stage2() {
    RUN_STAGE2_COUNT=$((RUN_STAGE2_COUNT + 1))
    return 0
}

RUN_STAGE3_COUNT=0
run_stage3() {
    RUN_STAGE3_COUNT=$((RUN_STAGE3_COUNT + 1))
    return 0
}

# Relax strict mode for test assertions
set +e
set +u

GPU_TYPE="none"

# =========================================================================
# Test 0: ui_choose supports non-first visible defaults
# =========================================================================
choice=$(printf '\n' | UI_DEMO=0 UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Pick one:" "Compact" "Balanced" "Quality")
assert_eq "Balanced" "$choice" "ui_choose: blank input uses visible default"

choice=$(printf '9\n' | UI_DEMO=0 UI_CHOOSE_DEFAULT_INDEX=2 ui_choose "Pick one:" "Compact" "Balanced" "Quality")
assert_eq "Balanced" "$choice" "ui_choose: invalid input uses visible default"

# =========================================================================
# Test 1: detect_env sets expected variables
# =========================================================================
detect_env

assert_eq "Etc/UTC" "$_ENV_TZ" "detect_env: timezone from shimmed timedatectl"
assert_eq "$(id -u)" "$_ENV_PUID" "detect_env: PUID matches id -u"
assert_eq "$(id -g)" "$_ENV_PGID" "detect_env: PGID matches id -g"
[[ -n "$_ENV_HOST_ADDRESS" ]]
if [[ $? -eq 0 ]]; then
    pass "detect_env: HOST_ADDRESS is non-empty"
else
    fail "detect_env: HOST_ADDRESS is non-empty" "got empty"
fi

# =========================================================================
# Test 2: Full wizard in UI_DEMO=1 mode
# =========================================================================
# UI_DEMO returns first option / default for all prompts
run_wizard >/dev/null 2>&1
wizard_rc=$?

assert_eq "0" "$wizard_rc" "run_wizard: exits 0 in demo mode"
assert_eq "1" "$RUN_STAGE2_COUNT" "run_wizard: normal interactive path routes to Stage 2"
assert_eq "1" "$RUN_STAGE3_COUNT" "run_wizard: normal interactive path routes to hardware transcoding add-on"

# =========================================================================
# Test 3: .env was written with correct structure
# =========================================================================
if [[ -f "$TMP_DIR/.env" ]]; then
    pass ".env file created"
else
    fail ".env file created"
fi

# Helper to read .env values safely (handles single-quoted values)
env_val_from() {
    local env_path="$1"
    local key="$2"
    python3 -c "
import re
with open('$env_path') as f:
    for line in f:
        line = line.strip()
        if line.startswith('$key='):
            val = line[len('$key='):]
            # Strip surrounding single quotes
            if val.startswith(\"'\") and val.endswith(\"'\"):
                val = val[1:-1]
            print(val)
            break
" 2>/dev/null
}

env_val() {
    env_val_from "$TMP_DIR/.env" "$1"
}

assert_eq "Etc/UTC" "$(env_val TZ)" ".env: TZ"
assert_eq "$(id -u)" "$(env_val PUID)" ".env: PUID"
assert_eq "$(id -g)" "$(env_val PGID)" ".env: PGID"
assert_eq "/data" "$(env_val DATA_DIR)" ".env: DATA_DIR"
assert_eq "stable" "$(env_val IMAGE_CHANNEL)" ".env: IMAGE_CHANNEL default"
assert_eq "local" "$(env_val STORAGE_MODE)" ".env: STORAGE_MODE default"
assert_eq "managed" "$(env_val STORAGE_APP_WIRING)" ".env: STORAGE_APP_WIRING default"
assert_eq "/data/.mediastack-storage-ready" "$(env_val STORAGE_SENTINEL)" ".env: STORAGE_SENTINEL default"
assert_eq "admin" "$(env_val JELLYFIN_ADMIN_USER)" ".env: JELLYFIN_ADMIN_USER"
assert_eq "" "$(env_val NPM_ADMIN_EMAIL)" ".env: NPM_ADMIN_EMAIL default blank"
assert_eq "none" "$(env_val JELLYFIN_GPU)" ".env: JELLYFIN_GPU (no GPU)"
assert_eq "false" "$(env_val BAZARR_ENABLED)" ".env: BAZARR_ENABLED default"
assert_eq "data" "$(env_val SMB_SHARE_SCOPE)" ".env: SMB_SHARE_SCOPE default"
assert_eq "7.5" "$(env_val QBT_DL_LIMIT)" ".env: QBT_DL_LIMIT default (50% of 120 Mbps)"
assert_eq "1.2" "$(env_val QBT_UL_LIMIT)" ".env: QBT_UL_LIMIT default (25% of 40 Mbps)"
assert_eq "/data/torrents" "$(env_val UNPACKERR_TORRENT_PATHS)" ".env: managed Unpackerr torrent path default"

# Demo mode returns blank for domain prompt → should be example.com placeholder
assert_eq "example.com" "$(env_val DOMAIN)" ".env: DOMAIN placeholder when blank"

# Password should be non-empty (auto-generated)
pw=$(env_val JELLYFIN_ADMIN_PASSWORD)
if [[ -n "$pw" && "$pw" != "changeme" ]]; then
    pass ".env: admin password auto-generated"
else
    fail ".env: admin password auto-generated" "got '$pw'"
fi

# File permissions
perms=$(stat -c '%a' "$TMP_DIR/.env")
assert_eq "600" "$perms" ".env: chmod 600"

# =========================================================================
# Test 4: config.yml was updated
# =========================================================================
yaml_get() {
    python3 -c "
import yaml
with open('$TMP_DIR/config.yml') as f:
    c = yaml.safe_load(f)
result = $1
if isinstance(result, bool):
    print('true' if result else 'false')
else:
    print(result)
" 2>/dev/null
}

assert_eq "true" "$(yaml_get "c.get('wizard_completed', False)")" "config.yml: wizard_completed marker"

# Stage 1 writes the balanced LAN baseline
assert_eq "HD-720p/1080p" "$(yaml_get "c['quality_profile']['name']")" "config.yml: balanced preset applied"

# =========================================================================
# Test 4b: custom Unpackerr path survives safe .env quoting
# =========================================================================
python3 - "$TMP_DIR/.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
written = False
for line in lines:
    if line.startswith("UNPACKERR_TORRENT_PATHS="):
        out.append("UNPACKERR_TORRENT_PATHS='/mnt/custom downloads/$USER/torrents'")
        written = True
    else:
        out.append(line)
if not written:
    out.append("UNPACKERR_TORRENT_PATHS='/mnt/custom downloads/$USER/torrents'")
path.write_text("\n".join(out) + "\n")
PY
write_env >/dev/null 2>&1
assert_eq "/mnt/custom downloads/\$USER/torrents" "$(env_val UNPACKERR_TORRENT_PATHS)" ".env: custom Unpackerr path with spaces and dollar preserved"
assert_eq "UNPACKERR_TORRENT_PATHS='/mnt/custom downloads/\$USER/torrents'" "$(grep '^UNPACKERR_TORRENT_PATHS=' "$TMP_DIR/.env")" ".env: custom Unpackerr path is quoted"
if (set -a; source "$TMP_DIR/.env"; set +a; [[ "$UNPACKERR_TORRENT_PATHS" == "/mnt/custom downloads/\$USER/torrents" ]]); then
    pass ".env: custom Unpackerr path sources correctly"
else
    fail ".env: custom Unpackerr path sources correctly"
fi
python3 - "$TMP_DIR/.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
for line in lines:
    if line.startswith("UNPACKERR_TORRENT_PATHS="):
        out.append('UNPACKERR_TORRENT_PATHS="/mnt/O\'Brien/torrents"')
    else:
        out.append(line)
path.write_text("\n".join(out) + "\n")
PY
write_env >/dev/null 2>&1
assert_eq "/data/torrents" "$(env_val UNPACKERR_TORRENT_PATHS)" ".env: unsupported Unpackerr path quote resets to managed default"

api_special='abc&def|ghi/jkl'
python3 - "$TMP_DIR/.env" "$api_special" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
value = sys.argv[2]
lines = path.read_text().splitlines()
out = []
written = False
for line in lines:
    if line.startswith("SONARR_API_KEY="):
        out.append(f"SONARR_API_KEY='{value}'")
        written = True
    else:
        out.append(line)
if not written:
    out.append(f"SONARR_API_KEY='{value}'")
path.write_text("\n".join(out) + "\n")
PY
write_env >/dev/null 2>&1
assert_eq "$api_special" "$(env_val SONARR_API_KEY)" ".env: preserved API key with special chars survives regeneration"
assert_eq "SONARR_API_KEY='$api_special'" "$(grep '^SONARR_API_KEY=' "$TMP_DIR/.env")" ".env: preserved API key remains quoted after regeneration"

# =========================================================================
# Test 4c: Failed .env generation preserves the previous file
# =========================================================================
TMP_DIR_ATOMIC="$TMP_DIR/atomic-failure"
mkdir -p "$TMP_DIR_ATOMIC/config/ddns-updater"
printf '%s\n' \
    "SONARR_API_KEY=old-sonarr-secret" \
    "STAGE_1_COMPLETE=1" \
    "JELLYFIN_ADMIN_PASSWORD='old-admin-password'" \
    > "$TMP_DIR_ATOMIC/.env"
cp "$TMP_DIR_ATOMIC/.env" "$TMP_DIR_ATOMIC/expected.env"

SCRIPT_DIR="$TMP_DIR_ATOMIC"
cat() { return 1; }
write_env >/dev/null 2>&1
atomic_write_rc=$?
unset -f cat
SCRIPT_DIR="$TMP_DIR"

if [[ "$atomic_write_rc" -ne 0 ]]; then
    pass ".env atomic write: reports temp write failure"
else
    fail ".env atomic write: reports temp write failure" "write_env exited 0"
fi

if cmp -s "$TMP_DIR_ATOMIC/expected.env" "$TMP_DIR_ATOMIC/.env"; then
    pass ".env atomic write: previous .env preserved on write failure"
else
    fail ".env atomic write: previous .env preserved on write failure"
fi

if compgen -G "$TMP_DIR_ATOMIC/.env.tmp.*" >/dev/null; then
    fail ".env atomic write: temp file cleaned up after write failure" "$(printf '%s ' "$TMP_DIR_ATOMIC"/.env.tmp.*)"
else
    pass ".env atomic write: temp file cleaned up after write failure"
fi

# =========================================================================
# Test 5: Wizard skip on re-run
# =========================================================================
# Wizard self-skip requires the config.yml completion marker, .env, and the
# Stage 1 completion marker.
_WIZ_TZ="" _WIZ_DATA_DIR="" _WIZ_ADMIN_USER="" _WIZ_ADMIN_EMAIL="" _WIZ_ADMIN_PW=""
python3 - "$TMP_DIR/.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
written = False
for line in lines:
    if line.startswith("STAGE_1_COMPLETE="):
        out.append("STAGE_1_COMPLETE=1")
        written = True
    else:
        out.append(line)
if not written:
    out.append("STAGE_1_COMPLETE=1")
path.write_text("\n".join(out) + "\n")
PY

skip_output_file="$TMP_DIR/skip-output"
run_wizard > "$skip_output_file" 2>&1
skip_rc=$?
skip_output=$(cat "$skip_output_file")

assert_eq "0" "$skip_rc" "re-run: wizard skips (exits 0)"
assert_contains "$skip_output" "already completed" "re-run: skip message shown"
assert_eq "1" "$RUN_STAGE2_COUNT" "re-run: Stage 2 is not called when wizard is complete"
assert_eq "1" "$RUN_STAGE3_COUNT" "re-run: hardware transcoding add-on is not called when wizard is complete"

# =========================================================================
# Test 5b: Interrupted Stage 1 resumes even if config marker exists
# =========================================================================
python3 - "$TMP_DIR/.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
out = []
written = False
for line in lines:
    if line.startswith("STAGE_1_COMPLETE="):
        out.append("STAGE_1_COMPLETE=")
        written = True
    else:
        out.append(line)
if not written:
    out.append("STAGE_1_COMPLETE=")
path.write_text("\n".join(out) + "\n")
PY

resume_output_file="$TMP_DIR/resume-output"
run_wizard > "$resume_output_file" 2>&1
resume_rc=$?
resume_output=$(cat "$resume_output_file")

assert_eq "0" "$resume_rc" "interrupted marker: wizard resumes successfully"
assert_contains "$resume_output" "Stage 1 is not complete" "interrupted marker: resume warning shown"
assert_eq "2" "$RUN_STAGE2_COUNT" "interrupted marker: Stage 2 runs after Stage 1 retry"
assert_eq "2" "$RUN_STAGE3_COUNT" "interrupted marker: hardware transcoding add-on runs after Stage 1 retry"

# =========================================================================
# Test 6: Interrupted run — previous .env values become defaults
# =========================================================================
# Reset wizard_completed so wizard runs again
python3 -c "
import re
with open('$TMP_DIR/config.yml') as f:
    text = f.read()
text = re.sub(r'wizard_completed: true', 'wizard_completed: false', text)
with open('$TMP_DIR/config.yml', 'w') as f:
    f.write(text)
"

# Write a fake .env with custom values to simulate interrupted run
cat > "$TMP_DIR/.env" <<'PARTIAL'
TZ=America/New_York
DATA_DIR=/custom/data
IMAGE_CHANNEL=latest
JELLYFIN_ADMIN_USER='testuser'
JELLYFIN_ADMIN_PASSWORD='testpass'
NPM_ADMIN_EMAIL=test@test.com
DOMAIN=example.com
QBT_DL_LIMIT=50
QBT_UL_LIMIT=25
JELLYFIN_GPU=none
BAZARR_ENABLED=false
WG_HOST=example.com
WG_INIT_PASSWORD=''
WG_DEFAULT_DNS=1.1.1.1
WG_ACCESS_TIER=full-lan
WG_LAN_CIDR=192.168.1.0/24
WG_SERVER_LAN_IP=192.168.1.10
WG_INIT_ALLOWED_IPS='192.168.1.0/24'
WG_PER_CLIENT_FIREWALL=true
SONARR_API_KEY=
RADARR_API_KEY=
JELLYFIN_API_KEY=
BAZARR_API_KEY=
JELLYSEERR_API_KEY=
PORTAINER_API_KEY=
BESZEL_AGENT_KEY=
MEDIASTACK_NETWORK_PREFIX=172.28.0
MEDIASTACK_SUBNET=172.28.0.0/16
MEDIASTACK_GATEWAY=172.28.0.1
PARTIAL

# Re-run the wizard with the pre-seeded .env still in place. The flow sources
# these values up front, then rewrites .env with the new wizard output.
run_wizard >/dev/null 2>&1
assert_eq "3" "$RUN_STAGE2_COUNT" "interrupted: Stage 2 routes after Stage 1 retry"
assert_eq "3" "$RUN_STAGE3_COUNT" "interrupted: hardware transcoding add-on routes before Stage 2 retry"

# In demo mode, ui_input returns the default. Verify the values that flow
# through ui_input are preserved from the prior .env.
assert_eq "America/New_York" "$(env_val TZ)" "interrupted: TZ preserved from previous .env"
assert_eq "/custom/data" "$(env_val DATA_DIR)" "interrupted: DATA_DIR preserved"
assert_eq "latest" "$(env_val IMAGE_CHANNEL)" "interrupted: IMAGE_CHANNEL preserved"
assert_eq "testuser" "$(env_val JELLYFIN_ADMIN_USER)" "interrupted: admin user preserved"
assert_eq "172.28.0.0/16" "$(env_val MEDIASTACK_SUBNET)" "interrupted: completed legacy network subnet preserved"

# =========================================================================
# Test 7: Full wizard in DEMO=1 mode
# =========================================================================
TMP_DIR_DEMO=$(mktemp -d)
TMP_DIR_DEMO_DEFAULT=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_DEMO" "$TMP_DIR_DEMO_DEFAULT"' EXIT

cp "$REPO_ROOT/config.yml" "$TMP_DIR_DEMO/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_DEMO/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_DEMO/scripts"
mkdir -p "$TMP_DIR_DEMO/config/ddns-updater"
reset_fixture_config "$TMP_DIR_DEMO/config.yml"

SCRIPT_DIR="$TMP_DIR_DEMO"
unset UI_DEMO
export DEMO=1
GPU_TYPE="none"
RUN_STAGE2_COUNT=0
RUN_STAGE3_COUNT=0

detect_env

cat > "$TMP_DIR_DEMO/.env" <<'PRESEEDED'
DOMAIN=demo.example.test
NPM_ADMIN_EMAIL=owner@demo.test
JELLYFIN_ADMIN_PASSWORD='changeme'
BAZARR_ENABLED=true
SMB_ENABLED=true
SMB_SHARE_SCOPE=system
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
TORRENT_PORT=6999
IMAGE_CHANNEL=latest
WG_PORT=51999
PRESEEDED

run_wizard >/dev/null 2>&1
demo_wizard_rc=$?

assert_eq "0" "$demo_wizard_rc" "DEMO=1: run_wizard exits 0"
assert_eq "0" "$RUN_STAGE2_COUNT" "DEMO=1: Stage 2 is not called"
assert_eq "0" "$RUN_STAGE3_COUNT" "DEMO=1: hardware transcoding add-on is not called"
assert_eq "owner@demo.test" "$(env_val_from "$TMP_DIR_DEMO/.env" NPM_ADMIN_EMAIL)" "DEMO=1: pre-seeded email preserved"
assert_eq "example.com" "$(env_val_from "$TMP_DIR_DEMO/.env" DOMAIN)" "DEMO=1: Stage 1 stays LAN-only"
assert_eq "6999" "$(env_val_from "$TMP_DIR_DEMO/.env" TORRENT_PORT)" "DEMO=1: pre-seeded torrent port preserved"
assert_eq "latest" "$(env_val_from "$TMP_DIR_DEMO/.env" IMAGE_CHANNEL)" "DEMO=1: pre-seeded image channel preserved"
assert_eq "51820" "$(env_val_from "$TMP_DIR_DEMO/.env" WG_PORT)" "DEMO=1: Stage 1 keeps default WireGuard port"
assert_eq "true" "$(env_val_from "$TMP_DIR_DEMO/.env" BAZARR_ENABLED)" "DEMO=1: pre-seeded Bazarr enabled preserved"
assert_eq "true" "$(env_val_from "$TMP_DIR_DEMO/.env" SMB_ENABLED)" "DEMO=1: pre-seeded SMB enabled preserved"
assert_eq "system" "$(env_val_from "$TMP_DIR_DEMO/.env" SMB_SHARE_SCOPE)" "DEMO=1: pre-seeded SMB scope preserved"
assert_eq "" "$(env_val_from "$TMP_DIR_DEMO/.env" WG_INIT_PASSWORD)" "DEMO=1: Stage 1 leaves WireGuard init password empty"
assert_eq "HD-720p/1080p" "$(python3 -c "
import yaml
with open('$TMP_DIR_DEMO/config.yml') as f:
    c = yaml.safe_load(f)
print(c['quality_profile']['name'])
")" "DEMO=1: balanced preset applied"

demo_pw=$(env_val_from "$TMP_DIR_DEMO/.env" JELLYFIN_ADMIN_PASSWORD)
if [[ "$demo_pw" == "GeneratedDemoPassword123" ]]; then
    pass "DEMO=1: weak pre-seeded password replaced"
else
    fail "DEMO=1: weak pre-seeded password replaced" "got '$demo_pw'"
fi

cp "$REPO_ROOT/config.yml" "$TMP_DIR_DEMO_DEFAULT/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_DEMO_DEFAULT/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_DEMO_DEFAULT/scripts"
mkdir -p "$TMP_DIR_DEMO_DEFAULT/config/ddns-updater"
reset_fixture_config "$TMP_DIR_DEMO_DEFAULT/config.yml"

SCRIPT_DIR="$TMP_DIR_DEMO_DEFAULT"
GPU_TYPE="none"
RUN_STAGE2_COUNT=0
RUN_STAGE3_COUNT=0
detect_env

run_wizard >/dev/null 2>&1
demo_default_rc=$?

assert_eq "0" "$demo_default_rc" "DEMO=1: no-preseed run_wizard exits 0"
assert_eq "admin@mediastack.local" "$(env_val_from "$TMP_DIR_DEMO_DEFAULT/.env" NPM_ADMIN_EMAIL)" "DEMO=1: no-preseed email defaults for Beszel"
assert_eq "stable" "$(env_val_from "$TMP_DIR_DEMO_DEFAULT/.env" IMAGE_CHANNEL)" "DEMO=1: no-preseed image channel defaults stable"

unset DEMO

# =========================================================================
# Test 8: SMB enabled path prompts for explicit share scope
# =========================================================================
_orig_ui_section=$(declare -f ui_section)
_orig_ui_input_validated=$(declare -f ui_input_validated)
_orig_ui_confirm=$(declare -f ui_confirm)
_orig_ui_choose=$(declare -f ui_choose)
_orig_validate_smb_port=$(declare -f validate_smb_port)

SMB_CONFIRM_COUNT=0
SMB_SCOPE_PROMPT=""
SMB_SCOPE_PROMPT_FILE="$TMP_DIR/smb-scope-prompt"
ui_section() { :; }
ui_input_validated() {
    case "${1:-}" in
        "Data directory") echo "/srv/media" ;;
        *) echo "${2:-}" ;;
    esac
}
ui_confirm() {
    SMB_CONFIRM_COUNT=$((SMB_CONFIRM_COUNT + 1))
    case "$SMB_CONFIRM_COUNT" in
        1) return 1 ;; # Bazarr prompt
        2) return 0 ;; # SMB prompt
        *) return 0 ;;
    esac
}
validate_smb_port() { return 0; }
ui_choose() {
    printf '%s\n' "${1:-}" > "$SMB_SCOPE_PROMPT_FILE"
    echo "Full system (/): advanced admin access to the whole server."
}

_WIZ_DATA_DIR=""
_WIZ_BAZARR_ENABLED=""
_WIZ_SMB_ENABLED=""
_WIZ_SMB_SHARE_SCOPE=""
_stage1_collect_storage >/dev/null 2>&1
SMB_SCOPE_PROMPT=$(cat "$SMB_SCOPE_PROMPT_FILE" 2>/dev/null)

assert_eq "true" "$_WIZ_SMB_ENABLED" "SMB prompt: enabling SMB is preserved"
assert_eq "Choose SMB share scope:" "$SMB_SCOPE_PROMPT" "SMB prompt: asks for explicit scope after enable"
assert_eq "system" "$_WIZ_SMB_SHARE_SCOPE" "SMB prompt: full-system choice maps to system scope"

eval "$_orig_ui_section"
eval "$_orig_ui_input_validated"
eval "$_orig_ui_confirm"
eval "$_orig_ui_choose"
eval "$_orig_validate_smb_port"

# =========================================================================
# Test 9: --full reaches Docker installation before Docker checks enforce
# =========================================================================
TMP_DIR_FULL=$(mktemp -d)
trap 'rm -rf "$TMP_DIR" "$TMP_DIR_DEMO" "$TMP_DIR_FULL"' EXIT

cp "$REPO_ROOT/config.yml" "$TMP_DIR_FULL/config.yml"
cp "$REPO_ROOT/.env.example" "$TMP_DIR_FULL/.env.example"
cp -r "$REPO_ROOT/scripts" "$TMP_DIR_FULL/scripts"
mkdir -p "$TMP_DIR_FULL/config/ddns-updater"
cat > "$TMP_DIR_FULL/scripts/configure.sh" <<'FULLCONFIG'
#!/usr/bin/env bash
exit 0
FULLCONFIG
chmod +x "$TMP_DIR_FULL/scripts/configure.sh"

source "$REPO_ROOT/setup.sh"
set +e
set +u

SCRIPT_DIR="$TMP_DIR_FULL"
FULL_ORDER=()
FULL_DOCKER_INSTALLED=false
FULL_STASH_COUNT=0
FULL_WIZARD_GPU_TYPE=""

record_full_order() {
    FULL_ORDER+=("$1")
}

check_not_root() { record_full_order check_not_root; }
check_debian() { record_full_order check_debian; }
check_disk_floor() { record_full_order check_disk_floor; }
check_internet_reachability() { record_full_order check_internet_reachability; }
check_ram_warn() { record_full_order check_ram_warn; }
prompt_sudo_cache() { record_full_order prompt_sudo_cache; }
stash_gpu_type() {
    record_full_order stash_gpu_type
    FULL_STASH_COUNT=$((FULL_STASH_COUNT + 1))
    if (( FULL_STASH_COUNT == 1 )); then
        GPU_TYPE=none
    else
        GPU_TYPE=nvidia
    fi
}
detect_existing_install() { record_full_order detect_existing_install; }
install_base_packages() { record_full_order install_base_packages; }
install_docker() { record_full_order install_docker; FULL_DOCKER_INSTALLED=true; }
check_docker() {
    record_full_order check_docker
    $FULL_DOCKER_INSTALLED
}
check_compose() {
    record_full_order check_compose
    $FULL_DOCKER_INSTALLED
}
detect_gpu() { record_full_order detect_gpu; GPU_TYPE=none; }
install_nvidia_drivers() { record_full_order install_nvidia_drivers; }
install_amd_drivers() { record_full_order install_amd_drivers; }
install_intel_drivers() { record_full_order install_intel_drivers; }
cleanup_post_reboot() { record_full_order cleanup_post_reboot; }
verify_gpu_usable() { record_full_order verify_gpu_usable; }
apply_nvidia_patch() { record_full_order apply_nvidia_patch; }
detect_host_memory() { record_full_order detect_host_memory; }
setup_hardening() { record_full_order setup_hardening; }
detect_env() {
    record_full_order detect_env
    _ENV_TZ=Etc/UTC
    _ENV_PUID=1000
    _ENV_PGID=1000
    _ENV_HOST_ADDRESS=127.0.0.1
}
run_wizard() {
    record_full_order run_wizard
    FULL_WIZARD_GPU_TYPE="$GPU_TYPE"
    WIZARD_RAN_INSTALL=true
    cat > "$SCRIPT_DIR/.env" <<'FULLENV'
TZ=Etc/UTC
PUID=1000
PGID=1000
DATA_DIR=/tmp/ms-data
HOST_ADDRESS=127.0.0.1
JELLYFIN_ADMIN_USER='admin'
JELLYFIN_ADMIN_PASSWORD='GeneratedDemoPassword123'
NPM_ADMIN_EMAIL=
JELLYFIN_GPU=none
DOMAIN=example.com
REMOTE_WEB_STATE=skipped
WG_HOST=example.com
WG_PORT=51820
WG_INIT_PASSWORD=''
WG_DEFAULT_DNS=1.1.1.1
WG_ACCESS_TIER=full-lan
WG_LAN_CIDR=192.168.1.0/24
WG_SERVER_LAN_IP=127.0.0.1
WG_INIT_ALLOWED_IPS='192.168.1.0/24'
WG_PER_CLIENT_FIREWALL=true
TORRENT_PORT=6881
QBT_DL_LIMIT=0
QBT_UL_LIMIT=0
BAZARR_ENABLED=false
SMB_ENABLED=false
STAGE_1_COMPLETE=1
FULLENV
}
setup_ufw_service_ports() { record_full_order setup_ufw_service_ports; }
setup_samba() { record_full_order setup_samba; }
stop_existing_stack() { record_full_order stop_existing_stack; }
create_data_dirs() { record_full_order create_data_dirs; }
create_config_dirs() { record_full_order create_config_dirs; }
generate_override() { record_full_order generate_override; }
pull_images() { record_full_order pull_images; }
start_stack() { record_full_order start_stack; }
wait_all_healthy() { record_full_order wait_all_healthy; }
print_access_info() { record_full_order print_access_info; }
setup_hardening() { record_full_order setup_hardening; }

python3() {
    if [[ "${1:-}" == "-c" && "${2:-}" == "import yaml" ]]; then
        return 0
    fi
    command python3 "$@"
}

sudo() {
    record_full_order sudo
    return 0
}

main --full >/dev/null 2>&1
full_rc=$?
full_order_text="${FULL_ORDER[*]}"

assert_eq "0" "$full_rc" "--full: main exits 0 with side effects stubbed"
assert_contains "$full_order_text" "install_docker check_docker check_compose" "--full: Docker checks run after install_docker"
assert_contains "$full_order_text" "install_base_packages check_internet_reachability install_docker check_docker check_compose stash_gpu_type" "--full: reachability is rechecked after base packages install, before Docker install"
full_internet_count=0
for token in "${FULL_ORDER[@]}"; do
    [[ "$token" == "check_internet_reachability" ]] && full_internet_count=$((full_internet_count + 1))
done
assert_eq "2" "$full_internet_count" "--full: internet reachability runs before and after base package install"
assert_eq "2" "$FULL_STASH_COUNT" "--full: GPU detection runs before and after base package install"
assert_eq "nvidia" "$FULL_WIZARD_GPU_TYPE" "--full: hardware transcoding receives post-pciutils GPU detection"
if [[ "$full_order_text" == *"check_docker"*"install_docker"* ]]; then
    fail "--full: check_docker does not run before install_docker" "order: $full_order_text"
else
    pass "--full: check_docker does not run before install_docker"
fi
assert_contains "$full_order_text" "run_wizard setup_ufw_service_ports setup_samba" "main: post-wizard host integration still runs after stage install"
if [[ "$full_order_text" == *"run_wizard"*"stop_existing_stack"* || "$full_order_text" == *"run_wizard"*"pull_images"* || "$full_order_text" == *"run_wizard"*"start_stack"* ]]; then
    fail "main: legacy stack install is skipped after stage install" "order: $full_order_text"
else
    pass "main: legacy stack install is skipped after stage install"
fi

# =========================================================================
# Summary
# =========================================================================
scenario_end "$CURRENT_SCENARIO"
summary
