#!/usr/bin/env bash
# Full GCP fresh test: delete VM → recreate → rsync → setup → verify.
#
# Validates the same surfaces the DinD battery cannot:
#   - real Let's Encrypt (staging) HTTP-01 cert issuance
#   - real Dynu DDNS push + public DNS propagation
#   - real GCP firewall (admin-port LAN/VPN-only contract)
#   - real public HTTPS through the proxy
#
# Loads tests/.env.gcp (gitignored). See tests/gcp-vm/README.md.
# `--preflight` validates the local bundle and target approval without calling
# gcloud, ssh, rsync, or any live endpoint.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
PREFLIGHT=0
case "${1:-}" in
    --preflight) PREFLIGHT=1 ;;
    -h | --help)
        echo "usage: run-fresh.sh [--preflight]"
        exit 0
        ;;
    "") ;;
    *)
        echo "✗ unknown arg: $1" >&2
        exit 2
        ;;
esac

ENV_FILE="${GCP_ENV_FILE:-$REPO_ROOT/tests/.env.gcp}"
USING_EXAMPLE=0
if ((PREFLIGHT)) && [[ -z "${GCP_ENV_FILE:-}" && ! -f "$ENV_FILE" ]]; then
    ENV_FILE="$REPO_ROOT/tests/.env.gcp.example"
    USING_EXAMPLE=1
fi
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
required=(PROJECT_ID ZONE INSTANCE MACHINE_TYPE BOOT_DISK_SIZE DOMAIN NPM_ADMIN_EMAIL DDNS_PASSWORD GCP_EXPECT_TARGET)
missing=()
for name in "${required[@]}"; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
done
if ((${#missing[@]})); then
    echo "✗ missing required value(s) in $ENV_FILE: ${missing[*]}" >&2
    exit 2
fi
GCP_TARGET="$PROJECT_ID/$ZONE/$INSTANCE"
if [[ "$GCP_EXPECT_TARGET" != "$GCP_TARGET" ]]; then
    echo "✗ refusing destructive GCP run: GCP_EXPECT_TARGET '$GCP_EXPECT_TARGET' != '$GCP_TARGET'" >&2
    exit 2
fi
if ((!PREFLIGHT)) && { [[ "$PROJECT_ID" == "your-gcp-project-id" ]] || [[ "$DOMAIN" == "mediastack.example.org" ]] || [[ "$DDNS_PASSWORD" == "your-dynu-password" ]]; }; then
    echo "✗ refusing live GCP run: replace every placeholder in $ENV_FILE first" >&2
    exit 2
fi
if [[ -z "${NPM_LE_SERVER+x}" ]]; then
    NPM_LE_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
fi

if ((PREFLIGHT)); then
    local_files=(
        "$HERE/run-fresh.sh"
        "$HERE/run-launcher-uat.sh"
        "$STARTUP"
        "$REPO_ROOT/tests/assertions/npm.sh"
        "$REPO_ROOT/tests/unit/gcp-wan-ports.sh"
    )
    for path in "${local_files[@]}"; do
        [[ -s "$path" ]] || {
            echo "✗ missing/empty dependency: $path" >&2
            exit 2
        }
    done
    bash -n "$HERE/run-fresh.sh" "$HERE/run-launcher-uat.sh" "$STARTUP"
    if ((USING_EXAMPLE)); then
        echo "✓ GCP harness placeholder-bundle preflight passed"
        echo "  copy tests/.env.gcp.example to tests/.env.gcp and replace every placeholder before a live run"
    else
        echo "✓ GCP harness preflight passed for approved target $GCP_TARGET"
    fi
    echo "  no cloud, network, SSH, or destructive action was attempted"
    exit 0
fi

SSH_HOST="$INSTANCE.$ZONE.$PROJECT_ID"
JF_FQDN="jellyfin.${DOMAIN}"
SEERR_FQDN="seerr.${DOMAIN}"
LAN_ONLY_TCP_PORTS=(
    81
    3000
    3001
    5055
    6767
    7878
    8000
    8080
    8090
    8096
    8191
    8989
    9000
    9117
    45876
    51821
)

step() {
    echo
    echo "=== [$(date +%H:%M:%S)] $*"
}
ok() { echo "  ✓ $*"; }
bad() {
    echo "  ✗ $*"
    FAILS+=("$*")
}
shq() { printf '%q' "$1"; }
FAILS=()

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
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_HOST" 'test -d /opt/MediaStack && command -v rsync && command -v git' >/dev/null 2>&1; then
        ok "SSH+startup ready in $((i * 5))s"
        break
    fi
    sleep 5
done

step "4. Rsync repo (excluding local secrets and runtime state)"
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
ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'wc -l /opt/MediaStack/scripts/services/npm/main.sh'

DOMAIN_Q=$(shq "$DOMAIN")
NPM_ADMIN_EMAIL_Q=$(shq "$NPM_ADMIN_EMAIL")
NPM_LE_SERVER_Q=$(shq "$NPM_LE_SERVER")

step "5. Pre-seed Stage 2 inputs into .env (no ddns config yet)"
# IMPORTANT: do NOT write config/ddns-updater/config.json here. The
# detect_existing_install (scripts/setup/checks.sh:205) treats `.env` plus a
# ddns config as evidence of an existing install and shows a recovery menu
# that DEMO=1 cannot navigate non-interactively. The ddns config is written
# in step 7 instead, after Stage 1 has completed and we are deliberately
# transitioning into Stage 2.
ssh -o StrictHostKeyChecking=no "$SSH_HOST" "
set -euo pipefail
cd /opt/MediaStack

cat > .env <<ENVEOF
DOMAIN=${DOMAIN_Q}
NPM_ADMIN_EMAIL=${NPM_ADMIN_EMAIL_Q}
NPM_LE_SERVER=${NPM_LE_SERVER_Q}
ENVEOF
chmod 600 .env
" >/dev/null

step "6. Stage 1 LAN-safe baseline: DEMO=1 ./setup.sh --full"
SETUP_LOG=/tmp/gcp-fresh-setup.log
: >"$SETUP_LOG"
ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no -t "$SSH_HOST" 'cd /opt/MediaStack && DEMO=1 ./setup.sh --full' >>"$SETUP_LOG" 2>&1
SETUP_RC=$?
if ((SETUP_RC == 0)); then ok "Stage 1 setup.sh --full exit 0"; else bad "Stage 1 setup.sh --full exit=$SETUP_RC"; fi
grep -q 'MediaStack is running!' "$SETUP_LOG" && ok "setup completion banner present" || bad "setup completion banner missing"

step "7. Restore remote inputs in .env (no manual DDNS work)"
# IMPORTANT: do NOT write config/ddns-updater/config.json or start
# ddns-updater here. The whole point of this test is to exercise the
# Stage 2 wizard's DDNS-collection path end-to-end:
#   wizard prompts for creds → write_env writes config.json →
#   configure.sh starts ddns-updater → ddns-updater pushes to Dynu →
#   public DNS converges → LE issues certs.
# Pre-seeding here would hide bugs in any of those links and turn this
# integration test into a smoke test.
ssh -o StrictHostKeyChecking=no "$SSH_HOST" "
set -euo pipefail
cd /opt/MediaStack
DOMAIN=${DOMAIN_Q} NPM_ADMIN_EMAIL=${NPM_ADMIN_EMAIL_Q} NPM_LE_SERVER=${NPM_LE_SERVER_Q} python3 - <<'PY'
import os
import pathlib

path = pathlib.Path('.env')
updates = {
    'DOMAIN': os.environ['DOMAIN'],
    'NPM_ADMIN_EMAIL': os.environ['NPM_ADMIN_EMAIL'],
    'NPM_LE_SERVER': os.environ['NPM_LE_SERVER'],
    'REMOTE_WEB_STATE': 'unchecked',
}
lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    if '=' not in line or line.startswith('#'):
        out.append(line)
        continue
    key = line.split('=', 1)[0]
    if key in updates:
        out.append(f'{key}={updates[key]}')
        seen.add(key)
    else:
        out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f'{key}={value}')
path.write_text('\n'.join(out) + '\n')
path.chmod(0o600)
PY
" >/dev/null

EXT_IP=$(gcloud --project="$PROJECT_ID" compute instances describe "$INSTANCE" --zone="$ZONE" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')
ok "Stage 2 .env updated (DDNS will be collected by the wizard in step 8)"

step "8. Stage 2 remote proof: ./setup.sh --remote"
REMOTE_LOG=/tmp/gcp-fresh-remote.log
: >"$REMOTE_LOG"

# Wizard prompt order (Stage 2):
#   1. _stage2_offer       — ui_choose [Enable/Skip/Tell more]    → "" (default 1 = Enable)
#   2. _stage2_collect_domain has-domain [Yes/No-show-options]    → "" (default 1 = Yes)
#   3. ui_input_validated  hostname                                → DOMAIN
#   4. _stage2_offer_ddns  ui_choose "static public IP?" [No-dyn/Yes-static] → "1" (No = dynamic)
#   4b. _stage2_offer_ddns ui_choose "Choose your DDNS provider:" → "2" (#248: DuckDNS is
#       index 1/default now; this harness proves the live Dynu path, so send "2" = Dynu)
#   5. _stage2_offer_ddns  ui_input  "Dynu password" (visible)     → DDNS_PASSWORD
#       (#248: Dynu no longer prompts for a username — it is ignored by the API
#       and auto-filled as a constant placeholder, so no DDNS_USERNAME answer.)
#   --- DNS check loops with auto-retry; on a fresh push, propagation
#       converges within 60-120s so the manual menu never fires.
#   7. _stage2_port_gate   — auto-passes on GCP, no prompt
#   8. _stage2_collect_wireguard ui_input_validated WG port        → "" (default 51820)
#   9.                          ui_choose access tier              → "" (default 1 = Full LAN)
#   9b.                         ui_input_validated LAN CIDR        → "" (accepts detected default)
#  10. _stage2_collect_jellyfin_remote_bitrate
#         ui_input upload bandwidth                                → "100"
#         ui_input per-viewer cap                                  → "" (suggested default)
#  11. _stage2_confirm    ui_choose [Install/Back/Skip]            → "" (default 1 = Install)
#
# read returns empty string on EOF, which all our defaults handle correctly,
# so trailing newlines are safe even if a future wizard tweak adds prompts. The
# "2" after the static/dynamic "1" selects Dynu in the provider picker — DuckDNS
# is index 1 (the default) and Dynu is index 2 as of #248.
build_wizard_input() {
    printf '\n\n%s\n1\n2\n%s\n\n\n\n100\n\n\n\n\n\n' \
        "$DOMAIN" "$DDNS_PASSWORD"
}

# Test-rig retry policy for the GCP LE-secondary co-location flake.
# Production (setup.sh) deliberately does NOT auto-retry; the user is told
# to rerun ./setup.sh --remote. Inside the GCP test rig there is no human
# at the terminal, so we accept ONE retry — only when Stage 2 logged a
# `partial` or `transient` classification (the LE GCP-secondary flake
# shape, see tests/gcp-vm/README.md). Any other failure class hard-fails.
run_remote_attempt() {
    local attempt_label="$1"
    echo "===== ATTEMPT: $attempt_label =====" >>"$REMOTE_LOG"
    build_wizard_input | ssh -o ServerAliveInterval=20 -o StrictHostKeyChecking=no "$SSH_HOST" \
        "cd /opt/MediaStack && ./setup.sh --remote" \
        >>"$REMOTE_LOG" 2>&1
}

run_remote_attempt "first"
REMOTE_RC=$?
RETRIED=0
RETRY_REASON=""
if ((REMOTE_RC != 0)); then
    CLASS=$(awk -F'classification: ' '/Stage 2 LE classification:/ {print $2}' "$REMOTE_LOG" \
        | tail -1 | tr -d '\r' | awk '{print $1}')
    if [[ "$CLASS" == "partial" || "$CLASS" == "transient" ]]; then
        RETRY_REASON="$CLASS"
        echo "  ⚠ first attempt failed with classification=$CLASS (GCP LE-secondary co-location flake)"
        echo "  ⚠ test-rig policy: retrying ONCE after 90s (production code never retries; this is test-only)"
        sleep 90
        run_remote_attempt "retry-after-${CLASS}"
        REMOTE_RC=$?
        RETRIED=1
    fi
fi

if ((RETRIED == 1)); then
    if ((REMOTE_RC == 0)); then
        ok "setup.sh --remote exit 0 (after retry; first attempt was $RETRY_REASON)"
    else
        bad "setup.sh --remote exit=$REMOTE_RC after retry (first attempt also failed: $RETRY_REASON)"
    fi
else
    if ((REMOTE_RC == 0)); then ok "setup.sh --remote exit 0 (first attempt)"; else bad "setup.sh --remote exit=$REMOTE_RC"; fi
fi
grep -q 'Remote access is ready' "$REMOTE_LOG" && ok "Stage 2 ready banner present" || bad "Stage 2 ready banner missing"
# #237: Dynu now verifies through the ephemeral blackhole container, not the
# deleted curl preflight. The ready banner above already requires that path to
# have accepted the creds; assert the legacy copy is gone as a cheap regression
# guard (robust to the new tier wording).
grep -q "Verified against Dynu's API" "$REMOTE_LOG" \
    && bad "legacy Dynu curl-preflight copy present (ephemeral verify should have replaced it)" \
    || ok "Dynu verified via ephemeral container (legacy curl preflight removed)"

step "9. Whitelist tester IP in fail2ban (avoid self-ban from probes)"
MY_IP="$(curl -s ifconfig.me)"
ssh -o StrictHostKeyChecking=no "$SSH_HOST" "
for j in jellyfin seerr npm; do
  docker exec fail2ban fail2ban-client set \$j addignoreip $MY_IP >/dev/null 2>&1 || true
done
" 2>&1 | tail -1

step "10. Containers healthy"
ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'docker ps --format "{{.Names}}\t{{.Status}}"' >/tmp/gcp-ps.out
N=$(grep -c "(healthy)\|Up [0-9]" /tmp/gcp-ps.out)
if ((N >= 16)); then ok "$N containers up"; else bad "only $N containers healthy"; fi
grep -q wireguard /tmp/gcp-ps.out && ok "wireguard up (remote profile auto-started)" || bad "wireguard not up"
grep -q ddns-updater /tmp/gcp-ps.out && ok "ddns-updater up (proxy profile auto-started)" || bad "ddns-updater not up"

step "11. Fail2ban 3 jails"
JAILS=$(ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'docker exec fail2ban fail2ban-client status 2>&1 | grep "Number of jail"' | tr -d '\r')
# npm-ratelimit ships disabled by default (rate_limiting.enabled=false, ADR-35).
if [[ "$JAILS" == *"3"* ]]; then ok "fail2ban: $JAILS"; else bad "fail2ban: $JAILS"; fi

step "12. NPM test guard"
ssh -o StrictHostKeyChecking=no "$SSH_HOST" 'cd /opt/MediaStack && bash tests/assertions/npm.sh' >/dev/null 2>&1 \
    && ok "tests/assertions/npm.sh PASS" || bad "tests/assertions/npm.sh FAIL"

step "13. External HTTPS — staging certs expected"
# Dynu DDNS push to public resolvers can lag setup completion by minutes.
# configure.sh's DNS gate uses the VM's local resolver so it sees the new IP
# immediately; tester-side resolution depends on Dynu's authoritative server
# accepting the update + recursive resolvers refreshing. Poll up to 5 min.
# Wait for BOTH FQDNs to propagate — Dynu may stagger pushes for separate
# subdomains, so jellyfin can resolve seconds-to-minutes before seerr.
for i in $(seq 1 30); do
    JF_RES=$(dig +short "$JF_FQDN" | tail -1)
    SEERR_RES=$(dig +short "$SEERR_FQDN" | tail -1)
    if [[ "$JF_RES" == "$EXT_IP" && "$SEERR_RES" == "$EXT_IP" ]]; then
        ok "DNS propagated to tester for both FQDNs ($EXT_IP) after $((i * 10))s"
        break
    fi
    sleep 10
done
JF_HTTP=$(curl -ksI -m 10 "https://$JF_FQDN" 2>/dev/null | head -1 | tr -d '\r')
SEERR_HTTP=$(curl -ksI -m 10 "https://$SEERR_FQDN" 2>/dev/null | head -1 | tr -d '\r')
[[ "$JF_HTTP" == *"302"* || "$JF_HTTP" == *"200"* ]] && ok "jellyfin HTTPS ($JF_HTTP)" || bad "jellyfin HTTPS '$JF_HTTP'"
[[ "$SEERR_HTTP" == *"307"* || "$SEERR_HTTP" == *"200"* ]] && ok "seerr HTTPS ($SEERR_HTTP)" || bad "seerr HTTPS '$SEERR_HTTP'"

JF_ISSUER=$(echo | timeout 10 openssl s_client -servername "$JF_FQDN" -connect "$JF_FQDN:443" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
SEERR_ISSUER=$(echo | timeout 10 openssl s_client -servername "$SEERR_FQDN" -connect "$SEERR_FQDN:443" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null)
# When NPM_LE_SERVER points at staging, expect "STAGING" issuer; otherwise expect a real LE issuer.
EXPECTED_ISSUER="STAGING"
[[ "$NPM_LE_SERVER" != *"staging"* ]] && EXPECTED_ISSUER="Let's Encrypt"
[[ "$JF_ISSUER" == *"$EXPECTED_ISSUER"* ]] && ok "jellyfin $EXPECTED_ISSUER cert" || bad "jellyfin issuer: $JF_ISSUER"
[[ "$SEERR_ISSUER" == *"$EXPECTED_ISSUER"* ]] && ok "seerr $EXPECTED_ISSUER cert" || bad "seerr issuer: $SEERR_ISSUER"

step "14. LAN-only Docker ports blocked from WAN (security boundary)"
EXT="$EXT_IP"
for port in "${LAN_ONLY_TCP_PORTS[@]}"; do
    nc -zvw 3 "$EXT" "$port" >/dev/null 2>&1 && bad "LAN-only TCP port $port REACHABLE" || ok "LAN-only TCP port $port blocked"
done

step "15. Public ports open"
for port in 80 443 6881; do
    nc -zvw 3 "$EXT" "$port" >/dev/null 2>&1 && ok "public port $port open" || bad "public port $port not open"
done

echo
echo "=== GCP FRESH TEST SUMMARY ==="
if ((${#FAILS[@]} == 0)); then
    echo "✓ ALL CHECKS PASSED"
    exit 0
else
    echo "✗ ${#FAILS[@]} FAILURE(S):"
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
