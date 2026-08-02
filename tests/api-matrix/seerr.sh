# tests/api-matrix/seerr.sh — Sonarr/Radarr -> Seerr connection matrix.
#
# Deliberately scoped to "service connections": the exact wiring
# connect_arr_to_seerr writes into Seerr for each app, plus its idempotent
# already-connected skip path. Jellyfin library-sync membership, default
# permissions/quotas, and trustProxy are already covered at their default
# point by fresh-install's assert_seerr_configured - duplicating that here
# would just re-test the same default cell twice. apiKey is a Seerr-internal
# field of uncertain mask behavior on GET (matches why jellyfin.sh never
# asserts the Sonarr/Radarr-masked apiKey field either); not checked.
#
# Runs after the jellyfin module (test-5), which already brings up Jellyfin
# and completes its first-run wizard - the same ordering configure.sh itself
# uses (configure_jellyfin always runs before configure_seerr). So this
# module's SSO login assumes the admin already exists; it does not bootstrap
# Jellyfin itself.

_srm_storage_wiring() {
    env_get STORAGE_APP_WIRING
}

_srm_cfg_field() {
    local field="$1"
    dind_exec "bash -c 'CONFIG_FILE=\$PWD/config.yml; export CONFIG_FILE; SCRIPT_DIR=\$PWD; export SCRIPT_DIR; source scripts/lib/common.sh; cfg_field \"$field\"'"
}

# Mirrors connect_arr_to_seerr's own profile resolution (match by configured
# name, else the first live profile) against the SAME live qualityprofile
# list, so the expected id/name reflects whatever name the quality /
# quality-rename modules left Sonarr/Radarr in - not a stale config.yml
# snapshot from before those modules ran.
# curl a JSON *arr endpoint inside DinD with a short retry. The *arr APIs answer
# with transient non-2xx under load; an unguarded `curl -sf` miss here
# would silently yield an empty expected value and a FALSE assertion (e.g.
# "expected empty, got 8/1080p Balanced" when the product stored a valid
# profile). Retry a few times before giving up.
_srm_curl_json() {
    local url="$1" key="$2" out attempt
    for attempt in 1 2 3; do
        out=$(dind_exec "curl -sf -H 'X-Api-Key: $key' $url") && {
            printf '%s' "$out"
            return 0
        }
        sleep "$attempt"
    done
    return 1
}

_srm_expected_profile_field() {
    local base="$1" key="$2" target_name="$3" field="$4"
    local profiles
    profiles=$(_srm_curl_json "$base/qualityprofile" "$key") || return 1
    SRM_PROFILES="$profiles" SRM_TARGET="$target_name" SRM_FIELD="$field" python3 - <<'PY'
import json
import os

profiles = json.loads(os.environ["SRM_PROFILES"])
target = os.environ["SRM_TARGET"]
match = next((p for p in profiles if p.get("name") == target), profiles[0] if profiles else {"id": 1, "name": "Any"})
print(match.get(os.environ["SRM_FIELD"]), end="")
PY
}

# Mirrors connect_arr_to_seerr's Sonarr-only language-profile lookup
# (first live language profile's id, or 1 if none).
_srm_expected_lang_id() {
    local base="$1" key="$2"
    local profiles
    profiles=$(_srm_curl_json "$base/languageprofile" "$key") || {
        echo "1"
        return
    }
    SRM_PROFILES="$profiles" python3 - <<'PY'
import json
import os

try:
    profiles = json.loads(os.environ["SRM_PROFILES"])
    print(profiles[0]["id"] if profiles else 1, end="")
except Exception:
    print(1, end="")
PY
}

_srm_login() {
    local jf_user="$1" jf_pw="$2" cookiejar="$3"
    local body http_code
    body=$(dind_exec "JF_USER='$jf_user' JF_PW='$jf_pw' python3 -c '
import os, json
print(json.dumps({\"username\": os.environ[\"JF_USER\"], \"password\": os.environ[\"JF_PW\"]}))'")
    http_code=$(dind_exec "rm -f $cookiejar; curl -sS -o /dev/null -w '%{http_code}' \
        -c $cookiejar -b $cookiejar \
        -H 'Content-Type: application/json' \
        -X POST http://localhost:5055/api/v1/auth/jellyfin \
        -d '$body'" | tr -d '\r\n')
    [[ "$http_code" == "200" ]]
}

_srm_settings() {
    local app="$1" cookiejar="$2"
    dind_exec "curl -sf -c $cookiejar -b $cookiejar http://localhost:5055/api/v1/settings/$app"
}

# Print the canonical (sorted-key) JSON of the first settings entry, or
# "ABSENT" if the array is empty. Used both for field lookups and for the
# byte-for-byte unchanged-after-re-run check.
_srm_entry() {
    SRM_JSON="$1" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["SRM_JSON"])
print("ABSENT" if not items else json.dumps(items[0], sort_keys=True, separators=(",", ":")), end="")
PY
}

_srm_field() {
    local entry="$1" field="$2"
    SRM_ENTRY="$entry" SRM_FIELD="$field" python3 - <<'PY'
import json
import os

entry = json.loads(os.environ["SRM_ENTRY"])
value = entry.get(os.environ["SRM_FIELD"], "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

matrix_seerr() {
    local sonarr_key="$1" sonarr_base="$2" radarr_key="$3" radarr_base="$4"
    local jf_user="$5" jf_pw="$6"
    local cookiejar="/tmp/ms-seerr-matrix.cookie"
    local apply_log settings entry

    # Same guard as jellyfin.sh: under manual app wiring, the jellyfin module
    # (test-5) no-ops its library/admin bootstrap, so the SSO admin this
    # module's login depends on would never exist - fail loud here instead of
    # cascading into a confusing login failure downstream.
    if [[ "$(_srm_storage_wiring)" == "manual" ]]; then
        fail "Seerr api-matrix: harness storage wiring is managed (not manual)" \
            "STORAGE_APP_WIRING=manual would no-op the jellyfin module's SSO-admin bootstrap"
        skip "Seerr api-matrix: all remaining module assertions" "storage wiring guard failed"
        return
    fi
    pass "Seerr api-matrix: harness storage wiring is managed (not manual)"

    # ------------------------------------------------------------------
    # State 1: run the real configure_seerr - bootstrap auth, library sync,
    # and the Sonarr/Radarr connections this module actually covers. The
    # jellyfin module (test-5) already created the SSO admin this needs.
    # ------------------------------------------------------------------
    apply_log=$(dind_exec "bash tests/api-matrix/push_seerr.sh apply" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "Seerr api-matrix: product configurator applied (first-run setup)"
    else
        fail "Seerr api-matrix: product configurator applied (first-run setup)" "$apply_log"
        skip "Seerr api-matrix: all remaining module assertions" "first-run apply failed"
        return
    fi
    assert_contains "$apply_log" "Signed in to Seerr as $jf_user" \
        "Seerr api-matrix: first-run setup actually signed in (not a silent skip)"

    if _srm_login "$jf_user" "$jf_pw" "$cookiejar"; then
        pass "Seerr api-matrix: harness session authenticated"
    else
        fail "Seerr api-matrix: harness session authenticated"
        skip "Seerr api-matrix: all remaining module assertions" "harness session login failed"
        return
    fi

    local app base key port expected
    for app in sonarr radarr; do
        if [[ "$app" == sonarr ]]; then
            base="$sonarr_base"
            key="$sonarr_key"
            port=8989
        else
            base="$radarr_base"
            key="$radarr_key"
            port=7878
        fi

        settings=$(_srm_settings "$app" "$cookiejar") || {
            fail "Seerr api-matrix: ${app} settings API readable"
            skip "Seerr api-matrix: ${app} connection-wiring + idempotent re-run assertions" "settings API unreadable"
            continue
        }
        entry=$(_srm_entry "$settings")
        if [[ "$entry" == "ABSENT" ]]; then
            fail "Seerr api-matrix: ${app} connection exists" "not configured"
            skip "Seerr api-matrix: ${app} connection-wiring + idempotent re-run assertions" "connection not configured"
            continue
        fi
        pass "Seerr api-matrix: ${app} connection exists"

        assert_eq "$app" "$(_srm_field "$entry" hostname)" \
            "Seerr api-matrix: ${app} connection hostname points at $app"
        assert_eq "$port" "$(_srm_field "$entry" port)" \
            "Seerr api-matrix: ${app} connection port is $port"
        assert_eq "False" "$(_srm_field "$entry" useSsl)" \
            "Seerr api-matrix: ${app} connection does not use SSL"
        assert_eq "True" "$(_srm_field "$entry" isDefault)" \
            "Seerr api-matrix: ${app} connection is the default server"
        assert_eq "False" "$(_srm_field "$entry" is4k)" \
            "Seerr api-matrix: ${app} connection is not a 4K server"
        assert_eq "True" "$(_srm_field "$entry" syncEnabled)" \
            "Seerr api-matrix: ${app} connection has scan sync enabled"
        assert_eq "False" "$(_srm_field "$entry" preventSearch)" \
            "Seerr api-matrix: ${app} connection does not prevent search"
        assert_eq "$(_srm_cfg_field "${app}.root_folder")" "$(_srm_field "$entry" activeDirectory)" \
            "Seerr api-matrix: ${app} connection root directory matches config.yml"

        local target_name
        target_name=$(_srm_cfg_field quality_profile.name)
        expected=$(_srm_expected_profile_field "$base" "$key" "$target_name" id)
        assert_eq "$expected" "$(_srm_field "$entry" activeProfileId)" \
            "Seerr api-matrix: ${app} connection quality profile id resolves the live profile list"
        expected=$(_srm_expected_profile_field "$base" "$key" "$target_name" name)
        assert_eq "$expected" "$(_srm_field "$entry" activeProfileName)" \
            "Seerr api-matrix: ${app} connection quality profile name resolves the live profile list"

        if [[ "$app" == sonarr ]]; then
            assert_eq "True" "$(_srm_field "$entry" enableSeasonFolders)" \
                "Seerr api-matrix: sonarr connection enables season folders"
            expected=$(_srm_expected_lang_id "$base" "$key")
            assert_eq "$expected" "$(_srm_field "$entry" activeLanguageProfileId)" \
                "Seerr api-matrix: sonarr connection language profile id resolves the live profile list"
        else
            assert_eq "released" "$(_srm_field "$entry" minimumAvailability)" \
                "Seerr api-matrix: radarr connection minimum availability is released"
        fi

        # --------------------------------------------------------------
        # State 2: re-run unchanged - idempotent skip, object untouched.
        # --------------------------------------------------------------
        local before_entry after_settings after_entry connect_log
        before_entry="$entry"
        connect_log=$(dind_exec "bash tests/api-matrix/push_seerr.sh connect $app $cookiejar" 2>&1)
        if [[ $? -eq 0 ]]; then
            pass "Seerr api-matrix: ${app} connection re-applied (idempotent)"
        else
            fail "Seerr api-matrix: ${app} connection re-applied (idempotent)" "$connect_log"
            skip "Seerr api-matrix: ${app} idempotent re-run assertions" "re-apply failed"
            continue
        fi
        assert_contains "$connect_log" "already connected to Seerr" \
            "Seerr api-matrix: ${app} re-run took the already-connected skip path"

        after_settings=$(_srm_settings "$app" "$cookiejar") || {
            fail "Seerr api-matrix: ${app} settings API readable after re-run"
            skip "Seerr api-matrix: ${app} connection-unchanged assertion" "settings API unreadable after re-run"
            continue
        }
        after_entry=$(_srm_entry "$after_settings")
        assert_eq "$before_entry" "$after_entry" \
            "Seerr api-matrix: ${app} connection unchanged after idempotent re-run"
    done
}
