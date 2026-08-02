#!/usr/bin/env bash
# =============================================================================
# Launcher UAT harness — stand up a real GCP VM with Stage 1 installed,
# then leave it ready for user-simulating UAT exploration of
# ./mediastack (the front-door launcher) and the underlying setup wizard.
# =============================================================================
# Differs from run-fresh.sh:
#   - Stops AFTER Stage 1 (no Stage 2 remote, no assertions)
#   - Leaves VM running with REMOTE_WEB_STATE=unchecked so the launcher's
#     "Add a feature → Add remote access" path is testable from a clean state
#   - Designed for a tester to SSH in and explore interactively
#
# Wall-time: ~6-8 min plus exploration. The VM incurs GCP charges while it is
# running; don't forget to delete it when done.
#
# See tests/gcp-vm/README.md for prerequisites (gcloud auth, .env.gcp,
# firewall tags). This harness reuses that setup.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
ENV_FILE="${GCP_ENV_FILE:-$REPO_ROOT/tests/.env.gcp}"
STARTUP="$HERE/startup.sh"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "✗ $ENV_FILE not found — copy tests/.env.gcp.example to tests/.env.gcp and fill it in"
    exit 2
fi
if [[ ! -f "$STARTUP" ]]; then
    echo "✗ $STARTUP not found"
    exit 2
fi

set -a
source "$ENV_FILE"
set +a
for name in PROJECT_ID ZONE INSTANCE MACHINE_TYPE BOOT_DISK_SIZE GCP_EXPECT_TARGET; do
    if [[ -z "${!name:-}" ]]; then
        echo "✗ missing required value in $ENV_FILE: $name" >&2
        exit 2
    fi
done
GCP_TARGET="$PROJECT_ID/$ZONE/$INSTANCE"
if [[ "$GCP_EXPECT_TARGET" != "$GCP_TARGET" ]]; then
    echo "✗ refusing destructive GCP run: GCP_EXPECT_TARGET '$GCP_EXPECT_TARGET' != '$GCP_TARGET'" >&2
    exit 2
fi
if [[ "$PROJECT_ID" == "your-gcp-project-id" ]]; then
    echo "✗ refusing live GCP run: replace every placeholder in $ENV_FILE first" >&2
    exit 2
fi
SSH_HOST="$INSTANCE.$ZONE.$PROJECT_ID"

step() {
    echo
    echo "=== [$(date +%H:%M:%S)] $*"
}
ok() { echo "  ✓ $*"; }
bad() { echo "  ✗ $*"; }

step "0. Delete existing VM (if any)"
gcloud --project="$PROJECT_ID" compute instances delete "$INSTANCE" --zone="$ZONE" --quiet 2>&1 | tail -1

step "1. Create VM with mediastack-public tag"
gcloud --project="$PROJECT_ID" compute instances create "$INSTANCE" --zone="$ZONE" --machine-type="$MACHINE_TYPE" \
    --image-family=debian-12 --image-project=debian-cloud --boot-disk-type=pd-standard \
    --boot-disk-size="$BOOT_DISK_SIZE" --tags=mediastack-public \
    --metadata-from-file=startup-script="$STARTUP" 2>&1 | tail -3

step "2. Refresh SSH config"
gcloud --project="$PROJECT_ID" compute config-ssh 2>&1 | tail -1

step "3. Wait for SSH ready"
for i in $(seq 1 30); do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_HOST" \
        'test -d /opt/MediaStack && command -v rsync && command -v git' >/dev/null 2>&1; then
        ok "SSH+startup ready in $((i * 5))s"
        break
    fi
    sleep 5
done

step "4. Rsync repo to /opt/MediaStack"
ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'sudo rm -rf /opt/MediaStack /tmp/MediaStack && mkdir -p /tmp/MediaStack' >/dev/null
rsync -az \
    --filter=':- .gitignore' \
    --exclude=.git \
    --exclude=.env \
    --exclude=tests/.env.gcp \
    --exclude='tests/*-plan.md' \
    --exclude='tests/*-findings.md' \
    --exclude=.nvidia-patch/ \
    --exclude=.nvidia-tmp/ \
    --exclude=docker-compose.override.yml \
    --exclude=config/jellyfin/ \
    --exclude=config/sonarr/ \
    --exclude=config/radarr/ \
    --exclude=config/seerr/ \
    --exclude=config/unpackerr/ \
    --exclude=config/homepage/services.yaml \
    --exclude=config/homepage/logs/ \
    --exclude=config/npm/ \
    --exclude=config/wireguard/ \
    --exclude=config/ddns-updater/ \
    --exclude=config/bazarr/ \
    --exclude=config/uptime-kuma/ \
    --exclude=config/beszel/ \
    --exclude=config/qbittorrent/qBittorrent/data/ \
    --exclude=config/qbittorrent/qBittorrent/ipc-socket \
    --exclude=config/qbittorrent/qBittorrent/lockfile \
    --exclude=config/qbittorrent/qBittorrent/config/ \
    --exclude=backups/ \
    -e "ssh -o StrictHostKeyChecking=no" \
    "$REPO_ROOT/" "$SSH_HOST:/tmp/MediaStack/" 2>&1 | tail -2
ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'sudo mv /tmp/MediaStack /opt/MediaStack && sudo chown -R $(id -un):$(id -gn) /opt/MediaStack' >/dev/null

step "5. Stage 1 install via setup.sh --full (DEMO defaults; no Stage 2)"
# DEMO=1 makes the wizard auto-pick defaults non-interactively. We use
# setup.sh directly here (not the launcher) for a known-good Stage 1
# baseline — the tester will exercise the launcher's install dispatch
# later via "Wipe and reinstall" through the launcher's menu.
SETUP_LOG=/tmp/launcher-uat-install.log
: >"$SETUP_LOG"
ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no -t "$SSH_HOST" \
    'cd /opt/MediaStack && DEMO=1 ./setup.sh --full' >>"$SETUP_LOG" 2>&1
RC=$?
if ((RC == 0)); then ok "Stage 1 install rc=0"; else
    bad "Stage 1 install rc=$RC (see $SETUP_LOG)"
    exit "$RC"
fi
grep -q 'MediaStack is running!' "$SETUP_LOG" && ok "completion banner present" || bad "completion banner missing"

EXT_IP=$(gcloud --project="$PROJECT_ID" compute instances describe "$INSTANCE" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)

cat <<HANDOFF

================================================================
LAUNCHER-UAT VM IS READY FOR EXPLORATION
================================================================

  SSH host:      $SSH_HOST
  External IP:   $EXT_IP
  Setup log:     $SETUP_LOG (on this host)
  GCP zone:      $ZONE / $PROJECT_ID

State left for the tester:
  ✓ Stage 1 complete — LAN-only stack, ~13 default-profile services running
  ✗ Stage 2 NOT configured (REMOTE_WEB_STATE=unchecked)
      → testable via launcher: Features & settings → Add remote access
  ✗ Hardware transcoding NOT configured (no GPU on GCP VMs)
      → reachable via the top-level "Manage hardware transcoding (GPU)" item
        (it is never offered in the Features submenu)

Recommended exploration entry point (interactive, with TTY):
  ssh -t $SSH_HOST 'cd /opt/MediaStack && ./mediastack'

For automated option-driving (capture output for analysis):
  # Option 1 is the read-only "View access info" view (URLs, logins, remote, ports).
  ssh $SSH_HOST 'cd /opt/MediaStack && MEDIASTACK_NONINTERACTIVE=1 bash -c "printf \"1\n\" | ./mediastack" 2>&1'

Stage 2 credentials available in tests/.env.gcp:
  DOMAIN              for "Add remote access" prompt
  DDNS_PASSWORD       Dynu API password (Dynu no longer prompts for a username)
  NPM_LE_SERVER       LE staging endpoint (UNTRUSTED but unrate-limited)

Helpful diagnostics (read-only):
  ssh $SSH_HOST 'cat /opt/MediaStack/.env'
  ssh $SSH_HOST 'docker ps --format "table {{.Names}}\t{{.Status}}"'
  ssh $SSH_HOST 'docker logs <service>'
  ssh $SSH_HOST 'cd /opt/MediaStack && tail -200 /tmp/gcp-fresh-*.log'

To reset to fresh-installed state:
  bash tests/gcp-vm/run-launcher-uat.sh   (~6-8 min plus GCP charges)

To delete the VM (DO THIS WHEN DONE — it incurs charges while running):
  gcloud --project="$PROJECT_ID" compute instances delete "$INSTANCE" --zone="$ZONE" --quiet

================================================================
HANDOFF
