# tests/assertions/unpackerr.sh — focused Unpackerr drift-oracle assertions.

unpackerr_env() {
    local key="$1" out
    out=$(dind_exec "docker exec unpackerr printenv $key" 2>/dev/null) || return 1
    printf '%s' "$out" | tr -d '\r\n'
}

assert_unpackerr_configured() {
    local sonarr_key="$1" radarr_key="$2"

    if ! dind_exec "docker exec unpackerr true" >/dev/null 2>&1; then
        fail "unpackerr: container reachable for env inspection" "docker exec unpackerr failed"
        return 1
    fi

    assert_eq "$sonarr_key" "$(unpackerr_env UN_SONARR_0_API_KEY)" "unpackerr: generated Sonarr API key reaches container"
    assert_eq "$radarr_key" "$(unpackerr_env UN_RADARR_0_API_KEY)" "unpackerr: generated Radarr API key reaches container"
    assert_eq "http://sonarr:8989" "$(unpackerr_env UN_SONARR_0_URL)" "unpackerr: standard Sonarr URL preserved"
    assert_eq "http://radarr:7878" "$(unpackerr_env UN_RADARR_0_URL)" "unpackerr: standard Radarr URL preserved"
    assert_eq "/data/torrents" "$(unpackerr_env UN_SONARR_0_PATHS_0)" "unpackerr: standard Sonarr torrent path preserved"
    assert_eq "/data/torrents" "$(unpackerr_env UN_RADARR_0_PATHS_0)" "unpackerr: standard Radarr torrent path preserved"
    assert_eq "15s" "$(unpackerr_env UN_INTERVAL)" "unpackerr: test poll interval applied"
    assert_eq "1s" "$(unpackerr_env UN_START_DELAY)" "unpackerr: test start delay applied"

    local data_mount
    data_mount=$(dind_exec "docker inspect --format '{{range .Mounts}}{{if eq .Destination \"/data\"}}{{.Source}}{{end}}{{end}}' unpackerr" | tr -d '\r\n')
    assert_eq "/tmp/ms-data" "$data_mount" "unpackerr: standard data bind mount preserved"
}

assert_unpackerr_extracted() {
    local fixture_dir="/tmp/ms-data/torrents/unpackerr-queue-fixture"
    local extracted_file="$fixture_dir/fixture.txt"
    local timeout=120 waited=0

    while ((waited < timeout)); do
        dind_exec "test -f $extracted_file" && break
        sleep 2
        waited=$((waited + 2))
    done

    if dind_exec "test -f $extracted_file"; then
        pass "unpackerr: completed Radarr queue item extracted"
    else
        fail "unpackerr: completed Radarr queue item extracted" "$extracted_file missing after ${timeout}s"
        return 1
    fi

    local content
    content=$(dind_exec "cat $extracted_file" | tr -d '\r\n')
    assert_eq "unpackerr-queue-fixture-ok" "$content" "unpackerr: extracted payload content matches fixture"

    if dind_exec "test -f $fixture_dir/fixture.zip"; then
        pass "unpackerr: original archive remains for torrent seeding"
    else
        fail "unpackerr: original archive remains for torrent seeding" "fixture.zip missing"
    fi

    local logs
    logs=$(dind_exec "docker logs unpackerr 2>&1" || true)
    if echo "$logs" | grep -qiE "panic|fatal"; then
        fail "unpackerr: log clean of panic/fatal" "fatal startup failure found"
    else
        pass "unpackerr: log clean of panic/fatal"
    fi
}
