# tests/assertions/seerr.sh — Seerr evidence after configure.sh.
#
# The Sonarr/Radarr checks do not stop at "an entry exists": each stored entry
# must name the intended container, port and root folder, carry the app's real
# API key and the configured quality profile, and Seerr's own connection test
# against those stored values must answer with that profile and root folder.
# A failed read is a FAIL, never an empty list.

# Print "<root folder>|<quality profile name>" for one app from the DinD
# config.yml, or "ERR:<why>". Args: <sonarr|radarr>
seerr_expected_arr_wiring() {
    dind_python "$1" 2>&1 <<'PY' | tr -d '\r'
import sys

import yaml

app = sys.argv[1]
try:
    with open("config.yml") as fh:
        cfg = yaml.safe_load(fh) or {}
except (OSError, yaml.YAMLError) as exc:
    print(f"ERR:config.yml unreadable: {exc}")
    sys.exit(0)
root = (cfg.get(app) or {}).get("root_folder")
profile = (cfg.get("quality_profile") or {}).get("name")
if not isinstance(root, str) or not root or not isinstance(profile, str) or not profile:
    print(f"ERR:config.yml lacks {app}.root_folder or quality_profile.name")
    sys.exit(0)
if "|" in root or "|" in profile:
    print("ERR:root folder or profile name contains '|'")
    sys.exit(0)
print(f"{root}|{profile}")
PY
}

# Validate the stored Seerr entry for one app (GET /settings/<app> body on
# stdin). Prints "OK|<connection-test request body>" or "FAIL|<why>".
# Env: SEERR_APP, SEERR_PORT, SEERR_KEY, SEERR_ROOT, SEERR_PROFILE.
seerr_arr_entry_report() {
    python3 -I -c '
import json
import os
import sys

app = os.environ["SEERR_APP"]
try:
    entries = json.load(sys.stdin)
except ValueError as exc:
    print(f"FAIL|GET /settings/{app} is not JSON: {exc}")
    sys.exit(0)
if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
    print(f"FAIL|GET /settings/{app} is not a list of server entries")
    sys.exit(0)
if not entries:
    print(f"FAIL|no {app} server configured in Seerr")
    sys.exit(0)
defaults = [e for e in entries if e.get("isDefault") is True]
if len(defaults) != 1:
    print(f"FAIL|expected exactly one default {app} server, found {len(defaults)} of {len(entries)}")
    sys.exit(0)
entry = defaults[0]
want = {
    "hostname": app,
    "port": int(os.environ["SEERR_PORT"]),
    "useSsl": False,
    "apiKey": os.environ["SEERR_KEY"],
    "activeDirectory": os.environ["SEERR_ROOT"],
    "activeProfileName": os.environ["SEERR_PROFILE"],
    "syncEnabled": True,
    "is4k": False,
}
wrong = []
for field, expected in want.items():
    if entry.get(field) != expected:
        if field == "apiKey":
            wrong.append("apiKey differs from the config.xml key of the app")
        else:
            wrong.append(f"{field}={entry.get(field)!r} want {expected!r}")
if wrong:
    print("FAIL|" + "; ".join(wrong))
    sys.exit(0)
body = {
    "hostname": entry["hostname"],
    "port": entry["port"],
    "apiKey": entry["apiKey"],
    "useSsl": entry["useSsl"],
    "baseUrl": entry.get("baseUrl", ""),
}
print("OK|" + json.dumps(body))
'
}

# Judge the answer of POST /settings/<app>/test (stdin). Prints "OK|<n>
# profiles, <m> root folders" or "FAIL|<why>". Env: SEERR_ROOT, SEERR_PROFILE.
seerr_arr_test_report() {
    python3 -I -c '
import json
import os
import sys

want_profile = os.environ["SEERR_PROFILE"]
want_root = os.environ["SEERR_ROOT"]
try:
    data = json.load(sys.stdin)
except ValueError as exc:
    print(f"FAIL|test response is not JSON: {exc}")
    sys.exit(0)
profiles = data.get("profiles") if isinstance(data, dict) else None
folders = data.get("rootFolders") if isinstance(data, dict) else None
if not isinstance(profiles, list) or not isinstance(folders, list):
    print("FAIL|test response lacks profiles/rootFolders lists")
    sys.exit(0)
names = sorted(p.get("name") for p in profiles if isinstance(p, dict) and p.get("name"))
paths = sorted(f.get("path") for f in folders if isinstance(f, dict) and f.get("path"))
wrong = []
if want_profile not in names:
    wrong.append(f"profile {want_profile!r} not offered ({names})")
if want_root not in paths:
    wrong.append(f"root folder {want_root!r} not offered ({paths})")
print("FAIL|" + "; ".join(wrong) if wrong else f"OK|{len(profiles)} profiles, {len(folders)} root folders")
'
}

# Assert one app is wired into Seerr and that Seerr can reach it with the stored
# credentials. Args: <sonarr|radarr> <port> <cookie jar> <seerr url>
seerr_assert_arr_connected() {
    local app="$1" port="$2" jar="$3" url="$4"
    local label="step 6 Seerr: ${app^}"
    local key expected root profile settings report body
    key=$(get_api_key_from_xml "config/$app/config.xml")
    if [[ -z "$key" ]]; then
        fail "$label connected" "no API key in config/$app/config.xml"
        return 0
    fi
    expected=$(seerr_expected_arr_wiring "$app")
    if [[ "$expected" != *"|"* ]]; then
        fail "$label connected" "fixture: ${expected:-no output}"
        return 0
    fi
    root="${expected%%|*}"
    profile="${expected#*|}"
    if ! settings=$(dind_exec "curl -sf --max-time 20 -c $jar -b $jar $url/api/v1/settings/$app"); then
        fail "$label connected" "GET /settings/$app failed"
        return 0
    fi
    report=$(printf '%s' "$settings" \
        | SEERR_APP="$app" SEERR_PORT="$port" SEERR_KEY="$key" SEERR_ROOT="$root" SEERR_PROFILE="$profile" \
            seerr_arr_entry_report)
    case "$report" in
        OK\|*) pass "$label connected (host=$app port=$port key=app key root=$root profile=$profile)" ;;
        *)
            fail "$label connected" "${report#FAIL|}"
            return 0
            ;;
    esac
    # Real connection test from Seerr to the app with the stored values.
    body="${report#OK|}"
    local body_path="/tmp/seerr-${app}-test.json" resp_path="/tmp/seerr-${app}-test.out" code test_report
    printf '%s' "$body" | dind_write_file "$body_path"
    code=$(dind_exec "curl -sS --max-time 30 -o $resp_path -w '%{http_code}' -c $jar -b $jar \
        -H 'Content-Type: application/json' -X POST $url/api/v1/settings/$app/test -d @$body_path" | tr -d '\r\n')
    if [[ "$code" != "200" ]]; then
        fail "$label reachable with stored credentials" "POST /settings/$app/test returned HTTP ${code:-000}"
        return 0
    fi
    test_report=$(dind_exec "cat $resp_path" | SEERR_ROOT="$root" SEERR_PROFILE="$profile" seerr_arr_test_report)
    case "$test_report" in
        OK\|*) pass "$label reachable with stored credentials (${test_report#OK|})" ;;
        *) fail "$label reachable with stored credentials" "${test_report#FAIL|}" ;;
    esac
}

assert_seerr_configured() {
    local jf_password="$1"
    local jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    local seerr_pub
    seerr_pub=$(dind_exec "curl -sf --max-time 20 http://localhost:5055/api/v1/settings/public")
    if echo "$seerr_pub" | grep -q '"initialized":true'; then
        pass "step 6 Seerr: initialized"
    else
        fail "step 6 Seerr: initialized"
    fi

    local seerr_url="http://localhost:5055"
    local seerr_cookie="/tmp/seerr-test-cookie"
    local seerr_auth_body
    seerr_auth_body=$(dind_exec "JF_USER='$jf_user' JF_PW='$jf_password' python3 -c '
import os, json
print(json.dumps({\"username\": os.environ[\"JF_USER\"], \"password\": os.environ[\"JF_PW\"]}))'")
    local seerr_auth_http
    seerr_auth_http=$(dind_exec "curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
        -c $seerr_cookie -b $seerr_cookie \
        -H 'Content-Type: application/json' \
        -X POST $seerr_url/api/v1/auth/jellyfin \
        -d '$seerr_auth_body'" | tr -d '\r\n')
    if [[ "$seerr_auth_http" != "200" ]]; then
        fail "step 6 Seerr: Sonarr connected" "could not authenticate to Seerr (HTTP $seerr_auth_http)"
        fail "step 6 Seerr: Radarr connected" "could not authenticate to Seerr"
        fail "step 6 Seerr: libraries synced" "could not authenticate to Seerr"
        return 0
    fi

    seerr_assert_arr_connected sonarr 8989 "$seerr_cookie" "$seerr_url"
    seerr_assert_arr_connected radarr 7878 "$seerr_cookie" "$seerr_url"

    local seerr_jf_settings seerr_lib_names
    seerr_jf_settings=$(dind_exec "curl -sf --max-time 20 -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/jellyfin")
    seerr_lib_names=$(echo "$seerr_jf_settings" | python3 -c '
import sys, json
d = json.load(sys.stdin)
libs = d.get("libraries", [])
names = sorted(l.get("name","") for l in libs if l.get("enabled"))
print(",".join(names))' 2>/dev/null)
    if echo "$seerr_lib_names" | grep -q 'Movies' && echo "$seerr_lib_names" | grep -q 'TV Shows'; then
        pass "step 6 Seerr: libraries synced (${seerr_lib_names})"
    else
        fail "step 6 Seerr: libraries synced (Movies + TV Shows)" "got '${seerr_lib_names}'"
    fi

    # trustProxy ("Enable Proxy Support") must be on behind NPM so Seerr
    # reads the real client IP. It lives in settings.network (NOT settings.main)
    # and is enabled only when remote-ready. A LAN-only install has no proxy,
    # so there it must stay off.
    local seerr_net seerr_trust want_trust="True" trust_label="enabled (remote-ready)"
    if [[ "${ASSERT_REMOTE_STATE:-ready}" != ready ]]; then
        want_trust="False"
        trust_label="disabled (LAN-only)"
    fi
    seerr_net=$(dind_exec "curl -sf --max-time 20 -c $seerr_cookie -b $seerr_cookie $seerr_url/api/v1/settings/network")
    seerr_trust=$(echo "$seerr_net" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("trustProxy"))' 2>/dev/null)
    if [[ "$seerr_trust" == "$want_trust" ]]; then
        pass "step 6 Seerr: trustProxy $trust_label"
    else
        fail "step 6 Seerr: trustProxy $trust_label" "settings/network trustProxy=$seerr_trust"
    fi
}

# A fresh Seerr already matches the default quotas in config.yml, so the first
# configure run only reads them. Set a movie quota in config.yml and run the
# configurator again with contract tracing: it must write the quota through
# the settings API and read it back. config.yml is then restored whatever the
# outcome, and the configurator runs once more, so Seerr returns to the
# config.yml quotas for the checks that follow.
assert_seerr_quota_update() {
    local log=/tmp/configure-seerr-quota.out
    if ! dind_exec 'cp -p config.yml /tmp/config.yml.quota-bak'; then
        fail "Seerr: config.yml saved for the quota check"
        return 0
    fi
    if ! dind_python <<'PY'; then
import yaml

with open("config.yml", encoding="utf-8") as fh:
    config = yaml.safe_load(fh)
config["seerr"]["quotas"]["movie"]["limit"] = 5
with open("config.yml", "w", encoding="utf-8") as fh:
    yaml.safe_dump(config, fh, sort_keys=False)
PY
        fail "Seerr: config.yml movie quota set for the update check"
    elif dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/configure.sh --only seerr" >"$log" 2>&1 \
        && grep -q 'quotas 5 movies/7d' "$log"; then
        pass "Seerr: configure.sh writes a changed config.yml quota and reads it back"
    else
        fail "Seerr: configure.sh writes a changed config.yml quota and reads it back"
        tail -20 "$log"
    fi
    # The restore runs on every path above, so the quota cannot outlive the check.
    if dind_exec 'mv /tmp/config.yml.quota-bak config.yml' \
        && dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/configure.sh --only seerr" >"$log" 2>&1 \
        && grep -q 'Seerr: admin-approval required, quotas' "$log" \
        && ! grep -q 'quotas 5 movies/7d' "$log"; then
        pass "Seerr: restored config.yml quotas are written back to Seerr"
    else
        fail "Seerr: restored config.yml quotas are written back to Seerr"
        tail -20 "$log"
    fi
}
