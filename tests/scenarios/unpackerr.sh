# tests/scenarios/unpackerr.sh — focused Unpackerr image-drift oracle.
#
# It configures the real qBittorrent/Sonarr/Radarr closure, then replaces only
# Radarr's unavailable completed-download event with a strict local queue stub.
# The recreated Unpackerr container keeps its production URL, generated API key,
# torrent path, and data mount; the test-only override shortens its two timers.

source tests/assertions/qbittorrent.sh
source tests/assertions/unpackerr.sh

UNPACKERR_STUB=unpackerr-radarr-stub
UNPACKERR_STUB_IMAGE=busybox@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028

unpackerr_cleanup() {
    dind_exec "docker rm -f $UNPACKERR_STUB" >/dev/null 2>&1 || true
    dind_exec "rm -rf /tmp/unpackerr-radarr-stub" >/dev/null 2>&1 || true
}

unpackerr_finish() {
    unpackerr_cleanup
    trap 'on_exit 130' INT
    trap 'on_exit 143' TERM
}

unpackerr_interrupted() {
    unpackerr_cleanup
    on_exit "$1"
}

unpackerr_seed_fixture() {
    docker exec -i -w /root/MediaStack "$DIND_NAME" python3 <<'PY'
import os
import zipfile

fixture_dir = "/tmp/ms-data/torrents/unpackerr-queue-fixture"
os.makedirs(fixture_dir, exist_ok=True)
source = "/tmp/unpackerr-queue-fixture.txt"
archive = os.path.join(fixture_dir, "fixture.zip")
with open(source, "w", encoding="utf-8") as handle:
    handle.write("unpackerr-queue-fixture-ok")
with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as handle:
    handle.write(source, arcname="fixture.txt")
os.chown(fixture_dir, 1000, 1000)
os.chown(archive, 1000, 1000)
PY
}

unpackerr_write_test_override() {
    dind_exec 'cat > docker-compose.unpackerr-test.yml <<EOF
services:
  unpackerr:
    environment:
      - UN_INTERVAL=15s
      - UN_START_DELAY=1s
EOF'
}

unpackerr_assert_production_timers() {
    local values
    values=$(dind_exec "docker compose config | python3 -c '
import sys, yaml
env = yaml.safe_load(sys.stdin)[\"services\"][\"unpackerr\"][\"environment\"]
if isinstance(env, list):
    env = dict(item.split(\"=\", 1) for item in env)
print(env.get(\"UN_INTERVAL\", \"\"))
print(env.get(\"UN_START_DELAY\", \"\"))
'" | tr -d '\r')
    local interval start_delay
    interval=$(sed -n '1p' <<<"$values")
    start_delay=$(sed -n '2p' <<<"$values")
    assert_eq "2m" "$interval" "unpackerr: production poll interval remains 2m"
    assert_eq "1m" "$start_delay" "unpackerr: production start delay remains 1m"
}

unpackerr_assert_radarr_qbittorrent_client() {
    local key="$1" result
    result=$(dind_exec "curl -sf -H 'X-Api-Key: $key' http://localhost:7878/api/v3/downloadclient" \
        | python3 -c '
import json, sys
try:
    clients = json.load(sys.stdin)
except Exception:
    print("invalid-json")
    raise SystemExit
client = next((item for item in clients if item.get("implementation") == "QBittorrent"), None)
if client is None:
    print("missing")
    raise SystemExit
fields = {item.get("name"): item.get("value") for item in client.get("fields", [])}
checks = {
    "protocol": client.get("protocol"),
    "host": fields.get("host"),
    "port": fields.get("port"),
    "category": fields.get("movieCategory"),
    "removeCompletedDownloads": client.get("removeCompletedDownloads"),
    "removeFailedDownloads": client.get("removeFailedDownloads"),
}
want = {
    "protocol": "torrent", "host": "qbittorrent", "port": 8080,
    "category": "radarr", "removeCompletedDownloads": True,
    "removeFailedDownloads": True,
}
print("ok" if checks == want else "drift")
' 2>/dev/null | tr -d '\r\n')
    assert_eq "ok" "$result" "unpackerr: Radarr uses configured qBittorrent torrent client"
}

unpackerr_write_radarr_stub() {
    local key="$1"
    docker exec -i -w /root/MediaStack -e "EXPECTED_KEY=$key" "$DIND_NAME" python3 <<'PY'
import os
from pathlib import Path

root = Path("/tmp/unpackerr-radarr-stub")
root.mkdir(parents=True, exist_ok=True)
(root / "request.result").write_text("not-requested\n")
(root / "handler.sh").write_text(r'''#!/bin/sh
set -eu
request=""
api_key=""
IFS= read -r request || exit 0
request=$(printf '%s' "$request" | tr -d '\r')
while IFS= read -r header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
    case "$header" in
        X-Api-Key:*) api_key=${header#X-Api-Key: } ;;
    esac
done
valid_path=false
case "$request" in
    "GET /api/v3/queue?"*)
        query=${request#GET /api/v3/queue?}
        query=${query% HTTP/*}
        # Only the page is pinned (Unpackerr always asks for page 1); pageSize
        # is the client's own default and isn't load-bearing for this oracle,
        # so it's checked for presence, not an exact value. Checked as two
        # independent substrings, not one combined glob: "&page=1&" and
        # "pageSize=" share the "&" between them in the real query string, so
        # a single *A*B* pattern can never match both.
        page_ok=false
        pagesize_ok=false
        case "&$query&" in *"&page=1&"*) page_ok=true ;; esac
        case "&$query&" in *"pageSize="*) pagesize_ok=true ;; esac
        if [ "$page_ok" = true ] && [ "$pagesize_ok" = true ]; then
            valid_path=true
        fi
        ;;
esac
if [ "$valid_path" = true ] && [ "$api_key" = "$EXPECTED_KEY" ]; then
    printf '%s\n' ok > /state/request.result
    body='{"page":1,"pageSize":500,"totalRecords":1,"records":[{"title":"unpackerr-queue-fixture","status":"Completed","protocol":"torrent","outputPath":"/data/torrents/unpackerr-queue-fixture","downloadId":"unpackerr-fixture-download","movieId":1,"size":1,"sizeleft":0}]}'
    printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
else
    printf '%s\n' rejected > /state/request.result
    body='{"error":"request rejected"}'
    printf 'HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
fi
''')
(root / "handler.sh").chmod(0o755)
PY
}

unpackerr_start_radarr_stub() {
    local key="$1"
    if dind_exec "docker run -d --name $UNPACKERR_STUB --network mediastack --network-alias radarr -e EXPECTED_KEY=$key -v /tmp/unpackerr-radarr-stub:/stub:ro -v /tmp/unpackerr-radarr-stub:/state $UNPACKERR_STUB_IMAGE nc -lk -p 7878 -e /stub/handler.sh" >/dev/null 2>&1; then
        pass "unpackerr: strict Radarr queue stub started"
    else
        fail "unpackerr: strict Radarr queue stub started"
        return 1
    fi
}

run_scenario() {
    unpackerr_cleanup
    trap 'unpackerr_interrupted 130' INT
    trap 'unpackerr_interrupted 143' TERM

    dind_exec "mkdir -p /tmp/ms-data/media/tv /tmp/ms-data/media/movies /tmp/ms-data/torrents/tv /tmp/ms-data/torrents/movies /tmp/ms-data/torrents/incomplete && chown -R 1000:1000 /tmp/ms-data"
    create_config_dirs_in_dind
    dind_exec "cp .env.example .env"
    env_set TZ Etc/UTC
    env_set PUID 1000
    env_set PGID 1000
    env_set DATA_DIR /tmp/ms-data
    env_set HOST_ADDRESS 127.0.0.1
    env_set JELLYFIN_GPU none
    env_set JELLYFIN_ADMIN_PASSWORD UnpackerrFixturePassword
    dind_exec "bash -c 'source setup.sh && detect_host_memory && generate_override none'"
    unpackerr_seed_fixture
    unpackerr_write_test_override
    unpackerr_assert_production_timers

    local compose_base="docker compose -f docker-compose.yml -f docker-compose.override.yml"
    local compose_test="$compose_base -f docker-compose.unpackerr-test.yml"
    local up_log=/tmp/unpackerr-compose-up.out
    if dind_exec "$compose_base up -d qbittorrent sonarr radarr unpackerr" >"$up_log" 2>&1; then
        pass "unpackerr: compose up qBittorrent Sonarr Radarr Unpackerr"
    else
        fail "unpackerr: compose up qBittorrent Sonarr Radarr Unpackerr"
        tail -80 "$up_log"
        unpackerr_finish
        return 1
    fi

    local svc ok=true
    for svc in flaresolverr jackett qbittorrent sonarr radarr unpackerr; do
        if wait_healthy "$svc" 300; then
            pass "unpackerr: $svc healthy"
        else
            fail "unpackerr: $svc healthy"
            ok=false
        fi
    done
    if ! $ok; then
        dind_exec "docker compose ps"
        unpackerr_finish
        return 1
    fi

    local configure_log=/tmp/unpackerr-configure.out
    if dind_exec "UI_ASCII=1 ./scripts/configure.sh --only qbittorrent,sonarr,radarr" >"$configure_log" 2>&1; then
        pass "unpackerr: configure qBittorrent Sonarr Radarr exits 0"
    else
        fail "unpackerr: configure qBittorrent Sonarr Radarr exits 0"
        tail -80 "$configure_log"
        unpackerr_finish
        return 1
    fi

    assert_qbittorrent_configured
    local sonarr_key radarr_key
    sonarr_key=$(get_api_key_from_xml "config/sonarr/config.xml")
    radarr_key=$(get_api_key_from_xml "config/radarr/config.xml")
    if [[ -z "$sonarr_key" || -z "$radarr_key" ]]; then
        fail "unpackerr: generated Arr API keys available" "Sonarr or Radarr config.xml key missing"
        unpackerr_finish
        return 1
    fi
    unpackerr_assert_radarr_qbittorrent_client "$radarr_key"

    # The real Radarr instance cannot create an offline, completed queue record.
    # Remove it only after its product configuration has been asserted, then give
    # the deterministic stub its exact `radarr` network alias. Unpackerr retains
    # the standard http://radarr:7878 endpoint and generated API key.
    if ! dind_exec "docker rm -f radarr unpackerr" >/dev/null 2>&1; then
        fail "unpackerr: remove real Radarr and stale Unpackerr before stub"
        unpackerr_finish
        return 1
    fi
    unpackerr_write_radarr_stub "$radarr_key"
    unpackerr_start_radarr_stub "$radarr_key" || {
        unpackerr_finish
        return 1
    }

    if dind_exec "$compose_test up -d --no-deps --force-recreate unpackerr" >/dev/null 2>&1; then
        pass "unpackerr: recreated against Radarr queue stub"
    else
        fail "unpackerr: recreated against Radarr queue stub"
        unpackerr_finish
        return 1
    fi
    if wait_healthy unpackerr 120; then
        pass "unpackerr: healthy against Radarr queue stub"
    else
        fail "unpackerr: healthy against Radarr queue stub"
        unpackerr_finish
        return 1
    fi

    assert_unpackerr_configured "$sonarr_key" "$radarr_key"
    assert_unpackerr_extracted
    local stub_result
    stub_result=$(dind_exec "cat /tmp/unpackerr-radarr-stub/request.result" | tr -d '\r\n')
    assert_eq "ok" "$stub_result" "unpackerr: requested completed Radarr queue with generated API key"

    unpackerr_finish
}
