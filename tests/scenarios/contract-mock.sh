# tests/scenarios/contract-mock.sh — configurators against tests/mock/serve.py.
#
# Image-free (--no-preload) proof that the Sonarr/Radarr configurator code
# speaks its declared contract: no service containers, no compose. The mock
# binds localhost:8989 (sonarr) and localhost:7878 (radarr) — the exact
# fixed ports scripts/lib/common.sh's service_local_url() always resolves —
# so scripts/configure.sh reaches it through the same "port a user has" it
# always uses, with no test-only branch added to scripts/.
#
# What this does NOT exercise: real container startup/health, first-run
# auth handshakes, or config drift across restarts — the api-matrix layer
# (image-backed) and the DinD battery stay responsible for those.

CONTRACT_MOCK_JOURNAL=/tmp/contract-mock-journal.jsonl

contract_mock_start_server() {
    dind_exec "[ -f /tmp/contract-mock.pid ] && kill \"\$(cat /tmp/contract-mock.pid)\" 2>/dev/null; sleep 1
rm -f $CONTRACT_MOCK_JOURNAL
nohup python3 tests/mock/serve.py \
    --service sonarr:8989 --service radarr:7878 \
    --journal $CONTRACT_MOCK_JOURNAL \
    --ready-file /tmp/contract-mock.ready \
    >/tmp/contract-mock.log 2>&1 & echo \$! > /tmp/contract-mock.pid" >/dev/null 2>&1
}

contract_mock_stop_server() {
    dind_exec "[ -f /tmp/contract-mock.pid ] && kill \"\$(cat /tmp/contract-mock.pid)\" 2>/dev/null; rm -f /tmp/contract-mock.pid /tmp/contract-mock.ready" >/dev/null 2>&1
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
# config.yml/env surface for that value (a product seam; see the ticket's
# Comments), so the scenario has to write the file directly, the same way it
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
./scripts/configure.sh --only sonarr,radarr
'" >"$log_path" 2>&1; then
        pass "contract-mock: scripts/configure.sh --only sonarr,radarr exits 0"
    else
        fail "contract-mock: scripts/configure.sh --only sonarr,radarr exits 0"
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
        radarr:host-config-get; do
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
