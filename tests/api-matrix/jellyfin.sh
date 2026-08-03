# tests/api-matrix/jellyfin.sh — Jellyfin library-config + Sonarr/Radarr
# notification-connection matrix.
#
# Deliberately scoped to "library/notification config states":
# configure_jellyfin_libraries' match/drift/absent branches, and the exact
# wiring configure_arr_jellyfin_connection writes into Sonarr/Radarr. Encoding,
# streaming bitrate, server name, and networking are already covered at their
# default point by fresh-install's assert_jellyfin_configured — duplicating
# that here would just re-test the same default cell twice.

_jfm_storage_wiring() {
    env_get STORAGE_APP_WIRING
}

_jfm_api_key() {
    dind_exec "grep -oP '^JELLYFIN_API_KEY=\K.*' .env" | tr -d "'" | tr -d '"'
}

_jfm_cfg_libraries() {
    dind_exec "bash -c 'CONFIG_FILE=/tmp/ms-jellyfin-matrix.yml; export CONFIG_FILE; SCRIPT_DIR=\$PWD; export SCRIPT_DIR; source scripts/lib/common.sh; cfg_jf_libraries'"
}

# Bounded retry budget for the readiness race the pollers below guard. Generous
# on purpose: every poll below exits the instant the subsystem answers, so a
# larger ceiling costs
# nothing on a ready service and only helps a slow/contended DinD — where the
# first-run wizard can confirm "Admin user created" (or an *arr write) tens of
# seconds before VirtualFolders / the notification list is queryable. ~15 × (up
# to 3s curl + 1s sleep) ≈ 60s worst case, exited early on the first success.
_JFM_READY_RETRIES=15

# Bounded retry: the first-run wizard can confirm "Admin user created" a beat
# before the VirtualFolders subsystem is queryable, especially under DinD
# resource contention. Retries the whole dind_exec call rather than
# looping inside its sh -c string, so no extra quoting layer is introduced.
_jfm_libraries() {
    local api_key="$1" out
    for _ in $(seq "$_JFM_READY_RETRIES"); do
        out=$(dind_exec "curl -sf --max-time 3 -H 'Authorization: MediaBrowser Client=\"ApiMatrix\", Device=\"Test\", DeviceId=\"api-matrix\", Version=\"1.0\", Token=\"$api_key\"' http://localhost:8096/Library/VirtualFolders") && {
            printf '%s' "$out"
            return 0
        }
        sleep 1
    done
    return 1
}

# Print "<path>" if a library named $2 exists in the $1 VirtualFolders JSON,
# or "absent" if it does not.
_jfm_lib_path() {
    local json="$1" name="$2"
    JFM_JSON="$json" JFM_NAME="$name" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["JFM_JSON"])
lib = next((l for l in items if l.get("Name") == os.environ["JFM_NAME"]), None)
print("absent" if lib is None else (lib.get("Locations") or [""])[0], end="")
PY
}

# Bounded retry: the same DinD-resource-contention race as
# _jfm_libraries — this hits a different service's API right after a
# config-mutating apply, with no guarantee the write is queryable instantly.
_jfm_notification() {
    local base="$1" key="$2" out
    for _ in $(seq "$_JFM_READY_RETRIES"); do
        out=$(dind_exec "curl -sf --max-time 3 -H 'X-Api-Key: $key' $base/notification") && {
            printf '%s' "$out"
            return 0
        }
        sleep 1
    done
    return 1
}

# Print a canonical (sorted-key) JSON object for the MediaBrowser entry in $1,
# or "ABSENT" if none exists. Used both for field lookups and for the
# byte-for-byte unchanged-after-re-run check.
_jfm_mediabrowser_entry() {
    JFM_JSON="$1" python3 - <<'PY'
import json
import os

items = json.loads(os.environ["JFM_JSON"])
entry = next((n for n in items if n.get("implementation") == "MediaBrowser"), None)
if entry is None:
    print("ABSENT", end="")
else:
    print(json.dumps(entry, sort_keys=True, separators=(",", ":")), end="")
PY
}

# Look up $2 in a MediaBrowser entry's top-level keys, falling back to its
# `fields` array (where host/port/apiKey/updateLibrary etc. actually live).
_jfm_entry_field() {
    local entry="$1" field="$2"
    JFM_ENTRY="$entry" JFM_FIELD="$field" python3 - <<'PY'
import json
import os

entry = json.loads(os.environ["JFM_ENTRY"])
field = os.environ["JFM_FIELD"]
if field in entry:
    value = entry[field]
else:
    fields = {f["name"]: f.get("value") for f in entry.get("fields", [])}
    value = fields.get(field, "")
if isinstance(value, bool):
    print("True" if value else "False", end="")
else:
    print(value, end="")
PY
}

matrix_jellyfin() {
    local sonarr_key="$1" sonarr_base="$2" radarr_key="$3" radarr_base="$4"
    local apply_log libraries lib_name lib_path
    local jf_api_key

    # Both configure_jellyfin_libraries and configure_arr_jellyfin_connection
    # silently no-op under manual app wiring — guard so a harness default
    # change doesn't quietly turn this whole module into a no-op pass.
    if [[ "$(_jfm_storage_wiring)" == "manual" ]]; then
        fail "Jellyfin api-matrix: harness storage wiring is managed (not manual)" \
            "STORAGE_APP_WIRING=manual would no-op every assertion below"
        skip "Jellyfin api-matrix: all remaining module assertions" "storage wiring guard failed"
        return
    fi
    pass "Jellyfin api-matrix: harness storage wiring is managed (not manual)"

    # ------------------------------------------------------------------
    # State 1: first-run wizard creates the config.yml-driven libraries
    # ------------------------------------------------------------------
    if dind_exec "bash tests/api-matrix/push_jellyfin.sh seed-config 'Movies:movies:/data/media/movies' 'TV Shows:tvshows:/data/media/tv'"; then
        pass "Jellyfin api-matrix: throwaway config seeded with default libraries"
    else
        fail "Jellyfin api-matrix: throwaway config seeded with default libraries"
        skip "Jellyfin api-matrix: all remaining module assertions" "config seed failed"
        return
    fi

    apply_log=$(dind_exec "bash tests/api-matrix/push_jellyfin.sh apply" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "Jellyfin api-matrix: product configurator applied (first-run wizard)"
    else
        fail "Jellyfin api-matrix: product configurator applied (first-run wizard)" "$apply_log"
        skip "Jellyfin api-matrix: all remaining module assertions" "first-run apply failed"
        return
    fi
    # The auth-subsystem-not-ready and bad-credentials branches both return 0
    # with everything downstream skipped — a silent no-op, not a script error.
    # Fail loud here rather than let library assertions below mismatch confusingly.
    assert_contains "$apply_log" "Admin user created" \
        "Jellyfin api-matrix: first-run wizard actually created the admin (not a silent skip)"

    jf_api_key=$(_jfm_api_key)
    [[ -n "$jf_api_key" ]] && pass "Jellyfin api-matrix: permanent API key saved to .env" \
        || {
            fail "Jellyfin api-matrix: permanent API key saved to .env"
            skip "Jellyfin api-matrix: all remaining module assertions" "no API key"
            return
        }
    # save_jellyfin_api_key falls back to a transient session token (with only
    # a log_warn) if permanent-key creation fails - that degraded path would
    # still populate .env, so check the log too.
    if echo "$apply_log" | grep -q "Could not create permanent Jellyfin API key"; then
        fail "Jellyfin api-matrix: permanent API key creation did not fall back to a session token"
    else
        pass "Jellyfin api-matrix: permanent API key creation did not fall back to a session token"
    fi

    libraries=$(_jfm_libraries "$jf_api_key") || {
        fail "Jellyfin api-matrix: VirtualFolders API readable"
        skip "Jellyfin api-matrix: all remaining module assertions" "VirtualFolders unreadable"
        return
    }
    pass "Jellyfin api-matrix: VirtualFolders API readable"

    while IFS=: read -r lib_name _ lib_path; do
        [[ -n "$lib_name" ]] || continue
        assert_eq "$lib_path" "$(_jfm_lib_path "$libraries" "$lib_name")" \
            "Jellyfin api-matrix: library '$lib_name' matches config.yml after first-run wizard"
    done < <(_jfm_cfg_libraries)

    # ------------------------------------------------------------------
    # State 2: re-apply with one unchanged library (match), one with a
    # drifted path (warn, not overwritten - no re-root), and one brand-new
    # library (absent -> created). One apply call exercises all three
    # branches of configure_jellyfin_libraries at once.
    # ------------------------------------------------------------------
    if dind_exec "bash tests/api-matrix/push_jellyfin.sh seed-config 'Movies:movies:/data/media/movies' 'TV Shows:tvshows:/data/media/tv-renamed' 'Music:music:/data/media/music'"; then
        pass "Jellyfin api-matrix: throwaway config re-seeded with match+drift+absent cells"
    else
        fail "Jellyfin api-matrix: throwaway config re-seeded with match+drift+absent cells"
        skip "Jellyfin api-matrix: state 2-4 assertions" "re-seed failed"
        return
    fi

    apply_log=$(dind_exec "bash tests/api-matrix/push_jellyfin.sh apply" 2>&1)
    if [[ $? -eq 0 ]]; then
        pass "Jellyfin api-matrix: product configurator re-applied"
    else
        fail "Jellyfin api-matrix: product configurator re-applied" "$apply_log"
        skip "Jellyfin api-matrix: state 2-4 assertions" "re-apply failed"
        return
    fi
    assert_contains "$apply_log" "Jellyfin wizard already completed, authenticating" \
        "Jellyfin api-matrix: re-apply took the already-completed-wizard branch"
    assert_contains "$apply_log" "Jellyfin library 'Movies' already matches your settings" \
        "Jellyfin api-matrix: unchanged library skips (match branch)"
    assert_contains "$apply_log" "Jellyfin library 'TV Shows' path differs from config.yml" \
        "Jellyfin api-matrix: drifted library warns instead of re-rooting (drift branch)"
    assert_contains "$apply_log" "Library: Music (/data/media/music)" \
        "Jellyfin api-matrix: brand-new library created (absent branch)"

    libraries=$(_jfm_libraries "$jf_api_key") || {
        fail "Jellyfin api-matrix: VirtualFolders API readable after re-apply"
        skip "Jellyfin api-matrix: state 2 library-path assertions + states 3-4" "VirtualFolders unreadable after re-apply"
        return
    }
    assert_eq "/data/media/movies" "$(_jfm_lib_path "$libraries" "Movies")" \
        "Jellyfin api-matrix: matched library path unchanged"
    assert_eq "/data/media/tv" "$(_jfm_lib_path "$libraries" "TV Shows")" \
        "Jellyfin api-matrix: drifted library path NOT overwritten (no silent re-root)"
    assert_eq "/data/media/music" "$(_jfm_lib_path "$libraries" "Music")" \
        "Jellyfin api-matrix: new library created at config.yml path"

    # ------------------------------------------------------------------
    # State 3: Sonarr/Radarr -> Jellyfin notification connection (create)
    # ------------------------------------------------------------------
    local app base key trigger_field
    for app in sonarr radarr; do
        if [[ "$app" == sonarr ]]; then
            base="$sonarr_base"
            key="$sonarr_key"
            trigger_field=onImportComplete
        else
            base="$radarr_base"
            key="$radarr_key"
            trigger_field=onDownload
        fi

        apply_log=$(dind_exec "bash tests/api-matrix/push_jellyfin.sh connect $app '$base' '$key'" 2>&1)
        if [[ $? -eq 0 ]]; then
            pass "Jellyfin api-matrix: ${app} -> Jellyfin connection applied"
        else
            fail "Jellyfin api-matrix: ${app} -> Jellyfin connection applied" "$apply_log"
            skip "Jellyfin api-matrix: ${app} connection-wiring + idempotent re-run assertions" "connect apply failed"
            continue
        fi

        local notif entry
        notif=$(_jfm_notification "$base" "$key") || {
            fail "Jellyfin api-matrix: ${app} notification API readable"
            skip "Jellyfin api-matrix: ${app} connection-wiring + idempotent re-run assertions" "notification API unreadable"
            continue
        }
        entry=$(_jfm_mediabrowser_entry "$notif")
        if [[ "$entry" == "ABSENT" ]]; then
            fail "Jellyfin api-matrix: ${app} MediaBrowser connection exists" "not configured"
            skip "Jellyfin api-matrix: ${app} connection-wiring + idempotent re-run assertions" "connection not configured"
            continue
        fi
        pass "Jellyfin api-matrix: ${app} MediaBrowser connection exists"

        assert_eq "jellyfin" "$(_jfm_entry_field "$entry" host)" \
            "Jellyfin api-matrix: ${app} connection host points at jellyfin"
        assert_eq "8096" "$(_jfm_entry_field "$entry" port)" \
            "Jellyfin api-matrix: ${app} connection port is 8096"
        # apiKey is a privacy:"apiKey" field - Sonarr/Radarr mask it as
        # "********" on every GET, even with ?includeSecrets=true, so its
        # value can never be verified from outside (matches why sonarr.sh/
        # radarr.sh's own fresh-install assertions never check it either).
        assert_eq "True" "$(_jfm_entry_field "$entry" updateLibrary)" \
            "Jellyfin api-matrix: ${app} connection triggers a library update"
        assert_eq "True" "$(_jfm_entry_field "$entry" "$trigger_field")" \
            "Jellyfin api-matrix: ${app} connection fires on the documented trigger ($trigger_field)"

        # ------------------------------------------------------------
        # State 4: re-run unchanged - idempotent skip, object untouched
        # ------------------------------------------------------------
        local before_entry after_notif after_entry
        before_entry="$entry"
        apply_log=$(dind_exec "bash tests/api-matrix/push_jellyfin.sh connect $app '$base' '$key'" 2>&1)
        if [[ $? -eq 0 ]]; then
            pass "Jellyfin api-matrix: ${app} -> Jellyfin connection re-applied (idempotent)"
        else
            fail "Jellyfin api-matrix: ${app} -> Jellyfin connection re-applied (idempotent)" "$apply_log"
            skip "Jellyfin api-matrix: ${app} idempotent re-run assertions" "re-apply failed"
            continue
        fi
        assert_contains "$apply_log" "${app^} Jellyfin connection already configured" \
            "Jellyfin api-matrix: ${app} re-run took the already-configured skip path"

        after_notif=$(_jfm_notification "$base" "$key") || {
            fail "Jellyfin api-matrix: ${app} notification API readable after re-run"
            skip "Jellyfin api-matrix: ${app} connection-unchanged assertion" "notification API unreadable after re-run"
            continue
        }
        after_entry=$(_jfm_mediabrowser_entry "$after_notif")
        assert_eq "$before_entry" "$after_entry" \
            "Jellyfin api-matrix: ${app} connection unchanged after idempotent re-run"
    done
}
