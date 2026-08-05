#!/usr/bin/env bash
# tests/unit/wizard-flow/env-write.sh
#
# detect_env, run_wizard in UI_DEMO=1 mode, the .env file it writes, the
# config.yml quality-profile marker, and .env write robustness (safe quoting
# for special-character values, atomic-write failure preserving the prior
# file).

# =========================================================================
# Test 1: detect_env sets expected variables
# =========================================================================
detect_env

assert_eq "Etc/UTC" "$_ENV_TZ" "detect_env: timezone from shimmed timedatectl"
assert_eq "$(id -u)" "$_ENV_PUID" "detect_env: PUID matches id -u"
assert_eq "$(id -g)" "$_ENV_PGID" "detect_env: PGID matches id -g"
[[ -n "$_ENV_HOST_ADDRESS" ]]
# Intentional: capture the [[ ]] boolean exit status.
# shellcheck disable=SC2319
if [[ $? -eq 0 ]]; then
    pass "detect_env: HOST_ADDRESS is non-empty"
else
    fail "detect_env: HOST_ADDRESS is non-empty" "got empty"
fi

# =========================================================================
# Test 2: Full wizard in UI_DEMO=1 mode
# =========================================================================
# UI_DEMO returns first option / default for all prompts. Stdin is closed
# (</dev/null) so the run is reliably non-TTY, which also lets us assert that
# the Stage-order orientation note (gated on [[ -t 0 ]]) stays silent off-TTY.
wizard_out_file="$TMP_DIR/wizard_test2_output.txt"
run_wizard </dev/null >"$wizard_out_file" 2>&1
wizard_rc=$?
wizard_out=$(cat "$wizard_out_file")

assert_eq "0" "$wizard_rc" "run_wizard: exits 0 in demo mode"
assert_eq "1" "$RUN_STAGE2_COUNT" "run_wizard: normal interactive path routes to Stage 2"
assert_eq "1" "$RUN_STAGE3_COUNT" "run_wizard: normal interactive path routes to hardware transcoding add-on"

# The stage-order orientation note is interactive-only; a non-TTY run must
# stay byte-stable so scripted/CI output is unchanged.
if [[ "$wizard_out" == *"Core media server is ready"* ]]; then
    fail "run_wizard: stage-order note suppressed on non-TTY" "note leaked into non-TTY output"
else
    pass "run_wizard: stage-order note suppressed on non-TTY"
fi

# =========================================================================
# Test 2b: wizard run-path UX guards (stage-order note, interrupt trap)
# =========================================================================
# Source-text guard so a future edit can't silently delete the orientation
# copy (declare -f strips comments but keeps the strings + the TTY guard).
run_wizard_src=$(declare -f run_wizard)
assert_contains "$run_wizard_src" "Core media server is ready" "run_wizard: stage-order orientation copy present"
assert_contains "$run_wizard_src" "-t 0" "run_wizard: orientation note is TTY-gated"

# The interrupt handler + its install must live in setup.sh, and the install
# must be gated on an interactive TTY (adjacent lines) so non-TTY CI / piped /
# post-reboot signal handling is unchanged.
setup_src=$(cat "$REPO_ROOT/setup.sh")
assert_contains "$setup_src" "_setup_on_interrupt()" "setup.sh: interrupt handler defined"
# Whitespace-normalised so the guard check survives reindentation but still
# proves the trap install sits directly inside an interactive-TTY block.
setup_src_norm=$(printf '%s' "$setup_src" | tr -s '[:space:]' ' ')
assert_contains "$setup_src_norm" "if [[ -t 0 ]]; then trap '_setup_on_interrupt' INT TERM" "setup.sh: interrupt trap gated on an interactive TTY"

# Leak guard: sourcing setup.sh must NOT install an INT trap (the install
# lives inside main(), which the BASH_SOURCE==\$0 guard keeps from running).
leaked_int=$(bash -c "_src=source; \"\$_src\" '$REPO_ROOT/setup.sh' >/dev/null 2>&1; trap -p INT" 2>/dev/null)
if [[ -z "$leaked_int" ]]; then
    pass "setup.sh: sourcing installs no INT trap (no leak into sourced shells)"
else
    fail "setup.sh: sourcing installs no INT trap" "leaked: $leaked_int"
fi

# Trap-preservation enabler: the background ui_spin must RESTORE the caller's
# INT trap, not
# reset it to default — otherwise the interrupt handler is wiped after the
# first spinner. UI_DEMO=0 forces the real background-process branch.
_saved_ui_demo="$UI_DEMO"
UI_DEMO=0
trap 'echo SENTINEL_INT_TRAP' INT
ui_spin "trap-preservation probe" true >/dev/null 2>&1
spin_int_after=$(trap -p INT)
trap - INT
UI_DEMO="$_saved_ui_demo"
if [[ "$spin_int_after" == *"SENTINEL_INT_TRAP"* ]]; then
    pass "ui_spin: restores caller's INT trap instead of clearing it"
else
    fail "ui_spin: restores caller's INT trap instead of clearing it" "got: ${spin_int_after:-<empty>}"
fi

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

# Password is the UI_DEMO walk-through placeholder. The admin password is NEVER
# auto-generated — _stage1_collect_admin requires a user-set + confirmed value on a
# real install, and uses a fixed valid placeholder only under the UI_DEMO/--demo guard.
assert_eq "DemoAdminPassword123" "$(env_val JELLYFIN_ADMIN_PASSWORD)" ".env: admin password is the UI_DEMO placeholder (user-set, never auto-generated)"

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
assert_eq "1080p Balanced" "$(yaml_get "c['quality_profile']['name']")" "config.yml: 1080p Balanced applied"

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
if (
    set -a
    source "$TMP_DIR/.env"
    set +a
    [[ "$UNPACKERR_TORRENT_PATHS" == "/mnt/custom downloads/\$USER/torrents" ]]
); then
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
    >"$TMP_DIR_ATOMIC/.env"
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
