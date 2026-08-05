# tests/scenarios/contract-mock.sh — configurators against tests/mock/serve.py.
#
# Image-free (--no-preload) proof that configurator code speaks its declared
# contract: no service containers, no compose. The mock binds localhost:8989
# (sonarr), localhost:7878 (radarr) and localhost:6767 (bazarr) — the exact
# fixed ports scripts/lib/common.sh's service_local_url() always resolves —
# so scripts/configure.sh reaches it through the same "port a user has" it
# always uses, with no test-only branch added to scripts/.
#
# What this does NOT exercise: real container startup/health, first-run
# auth handshakes, or config drift across restarts — the api-matrix layer
# (image-backed) and the DinD battery stay responsible for those.
#
# Coverage beyond the sonarr/radarr pilot: bazarr's configurator
# makes exactly one HTTP call (GET /api/system/settings, a static API key
# known upfront from config.yaml — no login dance), so it fits the same
# static-credential shape as sonarr/radarr and is added here.
#
# Excluded — jackett, qbittorrent, jellyfin, seerr, npm. Each configurator's
# first call is the credential-acquisition/session-establishing request
# itself (Jackett's cookie-seeding POST /UI/Dashboard, qBittorrent's
# POST /auth/login, Jellyfin's unauthenticated /Startup/* wizard before an
# admin exists, Seerr's POST /auth/jellyfin bootstrap, NPM's unauthenticated
# POST /api/users seeding the first admin). tests/contracts/*.yml declares
# one auth shape per service, checked on every endpoint including that one —
# so the mock's shape check would 401 the very call that is supposed to
# establish the session, before the credential it checks for exists. That
# login/session dance is exactly the case tests/mock/README.md reserves for
# tests/api-matrix/ (covered there: jackett.sh, qbittorrent.sh, jellyfin.sh,
# seerr.sh; npm has no api-matrix module — its live behavior is exercised by
# the dedicated npm-heal scenario and the stage2 flows instead). Representing
# a per-endpoint auth exemption would mean a schema extension serving five
# services' worth of one-off shape, or a per-service branch in serve.py —
# both against the mock harness's hard constraints (generic, no per-service
# branches) — so this is recorded as a seam
# finding rather than implemented here.

CONTRACT_MOCK_JOURNAL=/tmp/contract-mock-journal.jsonl

# Pinned by digest, same image already used by tests/scenarios/autoheal.sh and
# unpackerr.sh for lightweight container-presence fixtures — no new pin.
CONTRACT_MOCK_BAZARR_FIXTURE_IMAGE=busybox@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028

contract_mock_start_server() {
    dind_exec "[ -f /tmp/contract-mock.pid ] && kill \"\$(cat /tmp/contract-mock.pid)\" 2>/dev/null; sleep 1
rm -f $CONTRACT_MOCK_JOURNAL
nohup python3 tests/mock/serve.py \
    --service sonarr:8989 --service radarr:7878 --service bazarr:6767 \
    --journal $CONTRACT_MOCK_JOURNAL \
    --ready-file /tmp/contract-mock.ready \
    >/tmp/contract-mock.log 2>&1 & echo \$! > /tmp/contract-mock.pid" >/dev/null 2>&1
}

contract_mock_stop_server() {
    dind_exec "[ -f /tmp/contract-mock.pid ] && kill \"\$(cat /tmp/contract-mock.pid)\" 2>/dev/null; rm -f /tmp/contract-mock.pid /tmp/contract-mock.ready; docker rm -f bazarr >/dev/null 2>&1 || true" >/dev/null 2>&1
}

contract_mock_wait_ready() {
    local _
    for _ in $(seq 1 20); do
        dind_exec "test -f /tmp/contract-mock.ready" && return 0
        sleep 0.5
    done
    return 1
}

# Seed the API-key XML each service normally writes to config/<app>/config.xml
# on first boot — the configurator reads it via get_api_key(), and there is no
# config.yml/env surface for that value (a known product seam), so the
# scenario has to write the file directly, the same way it
# would exist on a real host after Sonarr/Radarr's own first start.
contract_mock_seed_api_keys() {
    dind_exec "mkdir -p config/sonarr config/radarr
cat > config/sonarr/config.xml <<'XML'
<Config><ApiKey>mock-sonarr-key</ApiKey></Config>
XML
cat > config/radarr/config.xml <<'XML'
<Config><ApiKey>mock-radarr-key</ApiKey></Config>
XML"
}

# Seed the real first-boot state Bazarr's configurator reads: config.yaml
# (v1.5+ stores everything there, including the API key normally minted on
# first start) already showing sonarr/radarr connected and general settings
# applied — matching tests/mock/fixtures/bazarr/system-settings.json exactly
# — plus a bazarr.db with one language-profile row. Both already-applied, so
# the configurator takes its documented skip paths only: it never reaches
# the `docker compose restart bazarr` branch, which has nothing to restart
# in this image-free scenario.
contract_mock_seed_bazarr() {
    dind_exec "mkdir -p config/bazarr/config config/bazarr/db
cat > config/bazarr/config/config.yaml <<'YAML'
auth:
  apikey: mock-bazarr-key
sonarr:
  apikey: mock-sonarr-key
radarr:
  apikey: mock-radarr-key
general:
  use_sonarr: true
  use_radarr: true
YAML
python3 -c \"
import sqlite3
conn = sqlite3.connect('config/bazarr/db/bazarr.db')
conn.execute('CREATE TABLE table_languages_profiles (profileId INTEGER, name TEXT, items TEXT, cutoff TEXT, mustContain TEXT, mustNotContain TEXT, originalFormat TEXT)')
conn.execute(\\\"INSERT INTO table_languages_profiles VALUES (1, 'English', '[]', NULL, '[]', '[]', 'False')\\\")
conn.commit()
conn.close()
\""
}

# configure_bazarr is gated behind container_running bazarr (scripts/configure.sh)
# — a real check against a real docker container, not something reachable
# through config.yml/.env. No compose is up in this image-free scenario, so a
# minimal placeholder container stands in for it; all HTTP traffic still goes
# to the mock on localhost:6767, not to this container. Recorded as a seam
# finding: bazarr is the only configurator gated on live container state
# rather than the service being reachable.
contract_mock_seed_bazarr_container() {
    dind_exec "docker rm -f bazarr >/dev/null 2>&1
docker run -d --name bazarr $CONTRACT_MOCK_BAZARR_FIXTURE_IMAGE sleep 600" >/dev/null 2>&1
}

run_scenario() {
    create_config_dirs_in_dind
    # The runner (tests/run.sh --reset-between, wired into every caller of this
    # scenario) restores a pristine repo copy — including scripts/configure.sh —
    # before this scenario runs, so no defensive docker-cp restore is needed
    # here even after a wizard scenario stubbed configure.sh earlier in the
    # same battery. See tests/README.md "DinD state between scenarios". This
    # scenario still seeds its own preconditions: config.yml/.env don't exist
    # in a pristine repo copy (only the templates do).
    dind_exec "cp config/examples/config.yml config.yml"
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-contract-mock-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set JELLYFIN_ADMIN_USER mock-admin
    env_set JELLYFIN_ADMIN_PASSWORD ContractMockAdminPw123

    contract_mock_seed_api_keys
    contract_mock_seed_bazarr
    contract_mock_seed_bazarr_container

    if contract_mock_start_server && contract_mock_wait_ready; then
        pass "contract-mock: serve.py listening on sonarr/radarr ports"
    else
        fail "contract-mock: serve.py listening on sonarr/radarr ports"
        dind_exec "cat /tmp/contract-mock.log 2>/dev/null || true"
        contract_mock_stop_server
        return 1
    fi

    local log_path="/tmp/contract-mock-configure.out"
    if dind_exec "timeout 60 bash -lc '
set -a
source .env
set +a
./scripts/configure.sh --only sonarr,radarr,bazarr
'" >"$log_path" 2>&1; then
        pass "contract-mock: scripts/configure.sh --only sonarr,radarr,bazarr exits 0"
    else
        fail "contract-mock: scripts/configure.sh --only sonarr,radarr,bazarr exits 0"
        tail -80 "$log_path"
        contract_mock_stop_server
        return 1
    fi

    # --- Journal assertions: the request sequence the contract predicts. ---
    local journal
    journal=$(dind_exec "cat $CONTRACT_MOCK_JOURNAL 2>/dev/null")

    if [[ -n "$journal" ]]; then
        pass "contract-mock: journal recorded requests"
    else
        fail "contract-mock: journal recorded requests"
        echo "--- configure output (journal was empty) ---"
        tail -40 "$log_path"
        dind_exec "tail -20 /tmp/contract-mock.log 2>/dev/null || true"
        contract_mock_stop_server
        return 1
    fi

    local expected_endpoint
    for expected_endpoint in \
        sonarr:root-folder-list sonarr:root-folder-create \
        sonarr:media-management-get sonarr:media-management-update \
        sonarr:download-client-list sonarr:download-client-create \
        sonarr:quality-profile-list sonarr:quality-profile-create \
        sonarr:config-naming-get sonarr:config-naming-update \
        sonarr:host-config-get \
        radarr:root-folder-list radarr:root-folder-create \
        radarr:media-management-get radarr:media-management-update \
        radarr:download-client-list radarr:download-client-create \
        radarr:quality-profile-list radarr:quality-profile-create \
        radarr:config-naming-get radarr:config-naming-update \
        radarr:host-config-get \
        bazarr:system-settings; do
        local service="${expected_endpoint%%:*}" endpoint="${expected_endpoint#*:}"
        if echo "$journal" | python3 -c "
import json, sys
service, endpoint = sys.argv[1], sys.argv[2]
found = any(
    (r := json.loads(line)).get('service') == service and r.get('endpoint') == endpoint
    for line in sys.stdin if line.strip()
)
sys.exit(0 if found else 1)
" "$service" "$endpoint"; then
            pass "contract-mock: journal has $expected_endpoint"
        else
            fail "contract-mock: journal has $expected_endpoint"
        fi
    done

    # Auth shape: every recorded request must have carried the contract's
    # declared X-Api-Key header, or the mock would have journaled a 401.
    if echo "$journal" | python3 -c "
import json, sys
statuses = [json.loads(line).get('status') for line in sys.stdin if line.strip()]
sys.exit(1 if 401 in statuses else 0)
"; then
        pass "contract-mock: no 401s recorded (auth header present on every call)"
    else
        fail "contract-mock: no 401s recorded (auth header present on every call)"
    fi

    contract_mock_stop_server
}
