# tests/lib/stack.sh — helpers that operate on the MediaStack inside DinD.
# Sourced by scenarios. Assumes lib/dind.sh already sourced so dind_exec exists.

# Block until a compose service reports healthy (or no healthcheck → running).
# Args: <service> [timeout_seconds (default 300)]
wait_healthy() {
    local svc="$1" timeout="${2:-300}" waited=0 status
    while ((waited < timeout)); do
        status=$(dind_exec "docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $svc 2>/dev/null" | tr -d '\r\n' || echo "")
        case "$status" in
            healthy | running) return 0 ;;
            unhealthy)
                echo "  $svc → unhealthy"
                return 1
                ;;
        esac
        sleep 3
        waited=$((waited + 3))
    done
    echo "  $svc → $status (timeout after ${timeout}s)"
    return 1
}

# Extract <ApiKey>...</ApiKey> from a Sonarr/Radarr config.xml path inside DinD.
get_api_key_from_xml() {
    local path="$1"
    dind_exec "test -f $path && sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' $path | head -1" | tr -d '\r\n'
}

# Read Jackett APIKey from ServerConfig.json inside DinD.
get_jackett_api_key() {
    dind_exec "python3 -c \"import json; print(json.load(open('config/jackett/Jackett/ServerConfig.json')).get('APIKey',''))\"" | tr -d '\r\n'
}

# Write a single KEY=VALUE pair to /root/MediaStack/.env inside DinD.
# Replaces existing line or appends if absent.
#
# Values are passed via env vars to avoid shell re-expansion inside DinD —
# critical for bcrypt hashes ($) and anything with & | etc. Values are written
# **single-quoted** so they survive bash `source` and Docker Compose's .env
# parser with $ " \ # and other shell-special chars intact. A literal single
# quote in the value is rejected (no `'\''` continuation — neither Compose
# nor our non-tech-user contract handles that cleanly).
env_set() {
    local key="$1" value="$2"
    docker exec -i -w /root/MediaStack -e "ENV_KEY=$key" -e "ENV_VAL=$value" "$DIND_NAME" python3 <<'PY'
import os, pathlib, sys
key = os.environ["ENV_KEY"]
val = os.environ["ENV_VAL"]
# Pre-quoted values pass through verbatim — callers sometimes pass "''"
# deliberately (e.g. WG_INIT_PASSWORD empty-but-quoted) or '<foo>' from an
# earlier env_set round-trip. Check before the single-quote rejection below.
if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
    quoted = val
elif "'" in val:
    sys.exit(f"env_set: value for {key} contains a single quote — not supported")
else:
    quoted = f"'{val}'"
p = pathlib.Path(".env")
lines = p.read_text().splitlines(keepends=True) if p.exists() else []
out = []
replaced = False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={quoted}\n")
        replaced = True
    else:
        out.append(line)
if not replaced:
    out.append(f"{key}={quoted}\n")
p.write_text("".join(out))
PY
}

# Read a value from .env inside DinD (unquoting single/double quotes).
env_get() {
    local key="$1"
    docker exec -i -w /root/MediaStack -e "ENV_KEY=$key" "$DIND_NAME" python3 <<'PY'
import os, pathlib
key = os.environ["ENV_KEY"]
p = pathlib.Path(".env")
if not p.exists(): raise SystemExit(0)
for line in p.read_text().splitlines():
    if line.startswith(key + "="):
        val = line.split("=", 1)[1]
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
            val = val[1:-1]
        print(val, end="")
        break
PY
}

# Pre-create the directories that setup.sh:create_config_dirs() would create.
# Mirrors the logic in setup.sh so scenarios don't have to re-derive it.
create_config_dirs_in_dind() {
    dind_exec '
set -e
for svc in jellyfin sonarr radarr jackett qbittorrent seerr unpackerr homepage portainer wireguard ddns-updater bazarr uptime-kuma beszel; do
    mkdir -p config/${svc}
done
# setup.sh runs as the installing user, so this bind-mounted directory is
# user-owned in production. Keep the fixture that way so wg-easy capability
# coverage catches missing DAC_OVERRIDE.
chown 1000:1000 config/wireguard
chmod 755 config/wireguard
# ddns-updater image runs as uid 1000 (no PUID/PGID support)
chown 1000:1000 config/ddns-updater
mkdir -p config/npm/data config/npm/letsencrypt config/jellyfin/cache
# Seed live pre-seed configs from the tracked templates (mirrors
# seed_config_from_templates in scripts/setup/stack.sh — NOT sourced: this runs
# under sh + set -e without common.sh, so a log_* call would abort it). This is
# what makes fail2ban load its jails / jackett + qbittorrent get their baseline
# in DinD now that the live copies are gitignored and only templates are copied
# in. Newline-read (no -d) for dash compatibility; config paths have no spaces.
tpl=config/examples/defaults
if [ -d "$tpl" ]; then
    find "$tpl" -type f | while read -r f; do
        dest="config/${f#"$tpl"/}"
        [ -f "$dest" ] || { mkdir -p "$(dirname "$dest")"; cp "$f" "$dest"; }
    done
fi
# Seed the live config.yml from its template (mirrors seed_root_config in
# scripts/setup/wizard.sh). config.yml is gitignored, so dind_copy_repo does not
# carry it in on a clean checkout — scenarios that read it directly (demo-lan,
# existing-install-nuke) or run the wizard depend on this seed.
[ -f config.yml ] || cp config/examples/config.yml config.yml
mkdir -p config/fail2ban/jail.d config/fail2ban/filter.d
# Log-source dirs for fail2ban (must exist before fail2ban mounts them).
mkdir -p config/npm/data/logs config/jellyfin/log config/seerr/logs
# Placeholder log files so fail2ban jail globs match at boot (fail2ban
# refuses to start if any glob matches zero files).
touch config/jellyfin/log/log_.log config/npm/data/logs/default-host_.log config/npm/data/logs/proxy-host-___.log config/seerr/logs/seerr-.log
# The official Seerr image writes /app/config as uid/gid 1000.
chown -R 1000:1000 config/seerr
'
}

# Is this service stripped via MS_TEST_STRIP_SERVICES?
svc_stripped() {
    local _s
    _s=" $(echo "${MS_TEST_STRIP_SERVICES:-}" | tr ',' ' ') "
    [[ "$_s" == *" $1 "* ]]
}

# ---------------------------------------------------------------------------
# Pebble ACME test infrastructure
# ---------------------------------------------------------------------------

# Write NPM overrides so it uses Pebble instead of Let's Encrypt.
npm_acme_override() {
    echo -e "${BLUE}[pebble]${NC} writing NPM ACME overrides for Pebble"
    dind_exec 'mkdir -p config/npm'
    dind_exec 'cat > config/npm/letsencrypt.test.ini <<EOF
text = True
non-interactive = True
webroot-path = /data/letsencrypt-acme-challenge
key-type = ecdsa
elliptic-curve = secp384r1
no-verify-ssl = True
EOF'
    # NPM reads the ACME endpoint from the container env var LE_SERVER.
    # The base compose substitutes ${NPM_LE_SERVER:-prod} at PARSE TIME and
    # bakes that value into LE_SERVER on the container — so adding a
    # NPM_LE_SERVER container env in the override has no effect on the
    # already-substituted LE_SERVER. We have to override LE_SERVER directly.
    dind_exec 'cat > docker-compose.acme-test.yml <<EOF
services:
  npm:
    environment:
      - LE_SERVER=https://pebble:14000/dir
    volumes:
      - ./config/npm/letsencrypt.test.ini:/etc/letsencrypt.ini:ro
EOF'
}

# Ensure an image is present in DinD, retrying a cold pull; inspect-first so a
# registry blip can't fail a scenario whose image is already cached (GHCR/pebble).
dind_pull_retry() { # <image>
    local img="$1" attempt
    for attempt in 1 2 3; do
        dind_exec "docker image inspect $img >/dev/null 2>&1 || docker pull $img >/dev/null 2>&1" && return 0
        ((attempt < 3)) && sleep $((attempt * 5))
    done
    return 1
}

# Launch Pebble + challtestsrv inside DinD on the mediastack network.
# Pebble validates HTTP-01 challenges; its default httpPort is 5002 but NPM
# listens on 80, so we mount a custom config overriding httpPort to 80.
pebble_up() {
    echo -e "${BLUE}[pebble]${NC} starting pebble-challtestsrv"
    dind_pull_retry ghcr.io/letsencrypt/pebble-challtestsrv \
        || {
            echo -e "${BLUE}[pebble]${NC} challtestsrv image pull failed after retries"
            return 1
        }
    dind_exec 'docker run -d --name pebble-challtestsrv --network mediastack \
        ghcr.io/letsencrypt/pebble-challtestsrv >/dev/null'

    local waited=0
    while ((waited < 30)); do
        if dind_exec 'curl -s -o /dev/null -w "%{http_code}" http://$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" pebble-challtestsrv):8055/' 2>/dev/null | grep -qE '^[0-9]+$'; then
            echo -e "${BLUE}[pebble]${NC} challtestsrv ready (${waited}s)"
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done
    if ((waited >= 30)); then
        echo -e "${BLUE}[pebble]${NC} challtestsrv did not become ready within 30s"
        return 1
    fi

    echo -e "${BLUE}[pebble]${NC} starting pebble"
    dind_pull_retry ghcr.io/letsencrypt/pebble \
        || {
            echo -e "${BLUE}[pebble]${NC} pebble image pull failed after retries"
            return 1
        }
    dind_exec 'cat > /tmp/pebble-config.json <<PEBBLECFG
{
  "pebble": {
    "listenAddress": "0.0.0.0:14000",
    "managementListenAddress": "0.0.0.0:15000",
    "certificate": "test/certs/localhost/cert.pem",
    "privateKey": "test/certs/localhost/key.pem",
    "httpPort": 80,
    "tlsPort": 5001,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false,
    "retryAfter": {"authz": 5, "order": 10},
    "keyAlgorithm": "ecdsa"
  }
}
PEBBLECFG'
    dind_exec 'docker run -d --name pebble --network mediastack \
        -e PEBBLE_VA_NOSLEEP=1 \
        -e PEBBLE_WFE_NONCEREJECT=0 \
        -v /tmp/pebble-config.json:/test/config/pebble-config.json:ro \
        ghcr.io/letsencrypt/pebble \
        -dnsserver pebble-challtestsrv:8053 >/dev/null'

    waited=0
    while ((waited < 30)); do
        if dind_exec 'curl -sk https://$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" pebble):14000/dir' >/dev/null 2>&1; then
            echo -e "${BLUE}[pebble]${NC} pebble ready (${waited}s)"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    echo -e "${BLUE}[pebble]${NC} pebble did not become ready within 30s"
    return 1
}

# Point all Pebble DNS queries at NPM's container IP.
pebble_setup_dns() {
    local npm_ip
    npm_ip=$(dind_exec "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' npm" | tr -d '\r\n')
    if [ -z "$npm_ip" ]; then
        echo -e "${BLUE}[pebble]${NC} failed to get NPM container IP"
        return 1
    fi
    echo -e "${BLUE}[pebble]${NC} setting default DNS A record to NPM @ ${npm_ip}"
    local challtestsrv_ip
    challtestsrv_ip=$(dind_exec "docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pebble-challtestsrv" | tr -d '\r\n')
    dind_exec "curl -sf -X POST http://${challtestsrv_ip}:8055/set-default-ipv4 \
        -d '{\"ip\":\"${npm_ip}\"}'"
    dind_exec "curl -sf -X POST http://${challtestsrv_ip}:8055/set-default-ipv6 \
        -d '{\"ip\":\"\"}'"
}

# Remove Pebble containers inside DinD.
pebble_down() {
    echo -e "${BLUE}[pebble]${NC} tearing down pebble containers"
    dind_exec 'docker rm -f pebble pebble-challtestsrv 2>/dev/null || true'
}
