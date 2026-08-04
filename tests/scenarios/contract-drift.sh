# tests/scenarios/contract-drift.sh — live contract-drift replay.
#
# Image-bump preflight / scheduled drift-alert scenario, NOT the PR gate (see
# docs/operations/upgrades.md "Preflight a candidate image" and TARGET.md's
# "CI placement is fixed"). Brings up the same API-bearing services
# tests/scenarios/api-matrix.sh already brings up (tests/api-matrix/bringup.sh
# — one bring-up, reused, never duplicated) and runs tests/contracts/replay.py
# in live mode against Sonarr and Radarr's real APIs, diffing only the
# declared `reads` fields of their safe (GET, no `{id}`) endpoints.
#
# The other contract-covered services (qbittorrent, jackett, jellyfin, seerr,
# and the live-replay-only services with no bring-up here at all — npm,
# portainer, wireguard, bazarr, beszel, uptime-kuma) are not yet wired into
# live replay: their auth shapes (query/cookie/basic) aren't credentialed by
# this scenario. Recorded as a follow-up, not silently dropped — see the
# ticket's Comments.

source tests/api-matrix/bringup.sh

run_scenario() {
    api_matrix_bring_up || return 1

    if [[ -z "$API_MATRIX_SONARR_KEY" || -z "$API_MATRIX_RADARR_KEY" ]]; then
        fail "contract-drift: Sonarr/Radarr API keys available for replay"
        return 1
    fi

    local log_path="/tmp/contract-drift-replay.out"
    if dind_exec "python3 tests/contracts/replay.py live \
        --service sonarr:http://localhost:8989:$API_MATRIX_SONARR_KEY \
        --service radarr:http://localhost:7878:$API_MATRIX_RADARR_KEY" \
        >"$log_path" 2>&1; then
        pass "contract-drift: replay.py live mode (sonarr, radarr)"
    else
        fail "contract-drift: replay.py live mode (sonarr, radarr)"
        tail -80 "$log_path"
        return 1
    fi
}
