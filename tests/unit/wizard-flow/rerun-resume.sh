#!/usr/bin/env bash
# tests/unit/wizard-flow/rerun-resume.sh
#
# Re-run behaviour against a previously-written .env: the wizard self-skip
# marker, resuming an interrupted Stage 1 despite a stale completion marker,
# and previous .env values surviving as defaults on a re-run.
#
# Uses env_val/env_val_from from env-write.sh (sourced earlier by the
# orchestrator).

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
run_wizard >"$skip_output_file" 2>&1
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
run_wizard >"$resume_output_file" 2>&1
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
cat >"$TMP_DIR/.env" <<'PARTIAL'
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
SEERR_API_KEY=
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
