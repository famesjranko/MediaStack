# tests/api-matrix/jackett.sh — Jackett indexer-config + server-state matrix.
#
# Deterministic, local-only slice of configure_jackett's contract: indexer
# enable/skip, the FlareSolverr-URL set-once cycle, and the admin-password
# set-once cycle, plus the graceful "indexer not in this image's catalog"
# path. Live Torznab/Cloudflare reachability is NOT this module's job — that
# is deliberately covered (and documented as non-deterministic) by
# wizard-presets.sh / docs/operations/upgrades.md's FlareSolverr confidence
# boundary. The two real indexer ids below (eztv, yts) are the same ids that
# scenario already drives successfully against live trackers, so picking
# them here carries no extra catalog-drift risk versus what's already in CI.

_jkm_api_key() {
    dind_exec "python3 -c \"import json; print(json.load(open('config/jackett/Jackett/ServerConfig.json')).get('APIKey',''))\""
}

_jkm_login() {
    local password="$1"
    dind_exec "rm -f /tmp/ms-jackett-matrix.cookie; curl -sf -c /tmp/ms-jackett-matrix.cookie -X POST http://localhost:9117/UI/Dashboard --data-urlencode 'password=$password'" >/dev/null
}

_jkm_configured() {
    local api_key="$1"
    dind_exec "curl -sf -b /tmp/ms-jackett-matrix.cookie 'http://localhost:9117/api/v2.0/indexers?configured=true&apikey=$api_key'"
}

_jkm_server_config() {
    local api_key="$1"
    dind_exec "curl -sf -b /tmp/ms-jackett-matrix.cookie 'http://localhost:9117/api/v2.0/server/config?apikey=$api_key'"
}

_jkm_configured_ids() {
    JKM_JSON="$1" python3 - <<'PY'
import json
import os

indexers = json.loads(os.environ["JKM_JSON"])
print(" ".join(sorted(i.get("id", "") for i in indexers if i.get("configured"))))
PY
}

_jkm_json_field() {
    local json="$1" field="$2"
    JKM_JSON="$json" JKM_FIELD="$field" python3 - <<'PY'
import json
import os

value = json.loads(os.environ["JKM_JSON"]).get(os.environ["JKM_FIELD"], "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

matrix_jackett() {
    local password="$1"
    local api_key server_cfg configured apply_log

    # State 1: seed two already-CI-proven public indexers plus one bogus id,
    # apply the product configurator once.
    if dind_exec "bash tests/api-matrix/push_jackett.sh seed-config eztv:tv yts:movies definitely-not-a-real-indexer-xyz:general"; then
        pass "Jackett api-matrix: throwaway config seeded with 2 valid + 1 bogus indexer"
    else
        fail "Jackett api-matrix: throwaway config seeded with 2 valid + 1 bogus indexer"
        skip "Jackett api-matrix: all remaining module assertions" "config seed failed"
        return
    fi

    apply_log=$(dind_exec "bash tests/api-matrix/push_jackett.sh apply" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "Jackett api-matrix: product configurator applied"
    else
        fail "Jackett api-matrix: product configurator applied" "$apply_log"
        skip "Jackett api-matrix: all remaining module assertions" "first apply failed"
        return
    fi
    assert_contains "$apply_log" "not available in Jackett" \
        "Jackett api-matrix: bogus indexer logged as not available"

    api_key=$(_jkm_api_key) || {
        fail "Jackett api-matrix: API key readable"
        skip "Jackett api-matrix: all remaining module assertions" "API key unreadable"
        return
    }
    [[ -n "$api_key" ]] && pass "Jackett api-matrix: API key readable" \
        || {
            fail "Jackett api-matrix: API key readable"
            skip "Jackett api-matrix: all remaining module assertions" "API key empty"
            return
        }

    # Log in only AFTER apply completes — configure_jackett may trigger an
    # internal FlareSolverr-config-triggered webhost restart (~20s) and
    # re-seed its OWN cookie jar; logging in before that would race a session
    # this module doesn't own.
    if _jkm_login "$password"; then
        pass "Jackett api-matrix: shared admin credentials authenticate"
    else
        fail "Jackett api-matrix: shared admin credentials authenticate"
        skip "Jackett api-matrix: all remaining module assertions" "login failed"
        return
    fi

    configured=$(_jkm_configured "$api_key") || {
        fail "Jackett api-matrix: configured-indexers API readable"
        skip "Jackett api-matrix: indexer/server-config + re-run assertions" "configured-indexers API unreadable"
        return
    }
    pass "Jackett api-matrix: configured-indexers API readable"
    assert_eq "eztv yts" "$(_jkm_configured_ids "$configured")" \
        "Jackett api-matrix: exactly the 2 valid indexers are configured"

    server_cfg=$(_jkm_server_config "$api_key") || {
        fail "Jackett api-matrix: server-config API readable"
        skip "Jackett api-matrix: server-config + re-run assertions" "server-config API unreadable"
        return
    }
    pass "Jackett api-matrix: server-config API readable"
    assert_eq "http://flaresolverr:8191" "$(_jkm_json_field "$server_cfg" flaresolverrurl)" \
        "Jackett api-matrix: FlareSolverr URL set"
    [[ -n "$(_jkm_json_field "$server_cfg" password)" ]] \
        && pass "Jackett api-matrix: admin password set" \
        || fail "Jackett api-matrix: admin password set"

    # State 2: re-run unchanged — every branch in configure_jackett should
    # take its skip path. Prove the skip path actually ran via its log lines,
    # not just "the field didn't change" (which a lucky no-op could also
    # produce).
    apply_log=$(dind_exec "bash tests/api-matrix/push_jackett.sh apply" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "Jackett api-matrix: product configurator re-applied (idempotent)"
    else
        fail "Jackett api-matrix: product configurator re-applied (idempotent)" "$apply_log"
        skip "Jackett api-matrix: re-run skip-path + post-re-run assertions" "re-apply failed"
        return
    fi
    assert_contains "$apply_log" "eztv already configured" \
        "Jackett api-matrix: re-run skips already-configured eztv"
    assert_contains "$apply_log" "yts already configured" \
        "Jackett api-matrix: re-run skips already-configured yts"
    assert_contains "$apply_log" "FlareSolverr already configured" \
        "Jackett api-matrix: re-run skips FlareSolverr (already set)"
    assert_contains "$apply_log" "Jackett admin password already set" \
        "Jackett api-matrix: re-run skips admin password (already set)"

    configured=$(_jkm_configured "$api_key") || {
        fail "Jackett api-matrix: configured-indexers API readable after re-run"
        skip "Jackett api-matrix: configured-indexers-unchanged assertion" "configured-indexers API unreadable after re-run"
        return
    }
    assert_eq "eztv yts" "$(_jkm_configured_ids "$configured")" \
        "Jackett api-matrix: configured indexers unchanged after re-run"
}
