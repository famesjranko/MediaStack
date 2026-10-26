#!/usr/bin/env bash
# tests/unit/arr-jellyfin-connection.sh
#
# Sonarr/Radarr -> Jellyfin notification record: what a normal re-run reports
# about an existing record (never a write), and what the explicit, confirmed
# repair changes. Stubs the *arr API with a stateful fake; one case drives the
# real API helpers over a stubbed curl to prove the key never reaches argv.
# No Docker, no network.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="arr-jellyfin-connection"
scenario_begin "$CURRENT_SCENARIO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CALLS="$TMP/calls"
LOG="$TMP/log"
PUT_BODY="$TMP/put-body.json"
POST_BODY="$TMP/post-body.json"

# shellcheck disable=SC2034 # read by common.sh's cfg_* helpers
CONFIG_FILE=/dev/null
SCRIPT_DIR="$REPO_ROOT"
source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/lib/json.sh"
source "$REPO_ROOT/scripts/lib/arr/main.sh"
# The real API helpers, kept for the argv case after the fakes replace them.
REAL_API_FNS=$(declare -f api_get api_post api_put)

set +e
set +u

SENTINEL='S3ntinelJellyfinKey'
APP_KEY='S3ntinelAppKey'
export JELLYFIN_API_KEY="$SENTINEL"

log_ok() { echo "OK: $*" >>"$LOG"; }
log_info() { echo "INFO: $*" >>"$LOG"; }
log_warn() { echo "WARN: $*" >>"$LOG"; }
log_skip() { echo "SKIP: $*" >>"$LOG"; }
log_error() { echo "ERROR: $*" >>"$LOG"; }
log_drift() { echo "WARN: $*" >>"$LOG"; }
sleep() { :; }
ui_confirm() {
    echo "CONFIRM($2): $1" >>"$LOG"
    [[ "${CONFIRM:-no}" == yes ]]
}

# A realistic stored record: masked key, non-default event selections, tags and
# a field this code has never heard of. Args: id name host port notify
mkrec() {
    python3 -c '
import json, sys
i, name, host, port, notify = sys.argv[1:6]
print(json.dumps({
    "id": int(i), "name": name, "implementation": "MediaBrowser",
    "implementationName": "Emby / Jellyfin", "configContract": "MediaBrowserSettings",
    "onGrab": True, "onImportComplete": True, "onUpgrade": False, "onRename": True,
    "onHealthIssue": False, "tags": [3, 4], "includeHealthWarnings": True,
    "futureField": {"keep": "me"},
    "fields": [
        {"order": 0, "name": "host", "value": host, "type": "textbox"},
        {"order": 1, "name": "port", "value": int(port), "type": "number"},
        {"order": 2, "name": "useSsl", "value": False, "type": "checkbox"},
        {"order": 3, "name": "urlBase", "value": "", "type": "textbox"},
        {"order": 4, "name": "apiKey", "value": "********", "type": "textbox", "privacy": "apiKey"},
        {"order": 5, "name": "notify", "value": notify == "1", "type": "checkbox"},
        {"order": 6, "name": "updateLibrary", "value": True, "type": "checkbox"},
    ]}))' "$@"
}

# The fake *arr. Records live in REC_<id>; TEST_<id> is what the test endpoint
# answers for that id: ok, stale (Jellyfin rejects the key) or down.
LIST=""
declare -a IDS=()
add_rec() {
    local id="$1"
    shift
    printf -v "REC_$id" '%s' "$(mkrec "$id" "$@")"
    printf -v "TEST_$id" '%s' "${TEST_STATE:-ok}"
    IDS+=("$id")
}
set_test() { printf -v "TEST_$1" '%s' "$2"; }
build_list() {
    local id v out=""
    for id in "${IDS[@]}"; do
        v="REC_$id"
        out+="${out:+,}${!v}"
    done
    LIST="[$out]"
}

api_get() {
    echo "GET $1" >>"$CALLS"
    case "$1" in
        */notification)
            [[ "$LIST" == FAIL ]] && {
                echo "api_get $1: HTTP 500" >&2
                return 1
            }
            printf '%s' "$LIST"
            ;;
        */notification/*)
            local v="REC_${1##*/}"
            [[ -n "${!v:-}" ]] || return 1
            printf '%s' "${!v}"
            ;;
    esac
}

api_post() {
    echo "POST $1" >>"$CALLS"
    printf '%s' "$3" >"$POST_BODY"
    case "$1" in
        */notification/test)
            local id v
            id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' <<<"$3")
            v="TEST_$id"
            case "${!v:-ok}" in
                ok) printf '{}' ;;
                stale)
                    echo "api_post $1: HTTP 400 [{\"isWarning\": false, \"propertyName\": \"ApiKey\", \"errorMessage\": \"API Key is invalid\"}]" >&2
                    return 1
                    ;;
                *)
                    echo "api_post $1: connection failed" >&2
                    return 1
                    ;;
            esac
            ;;
        *) printf '{"id":99}' ;;
    esac
}

# A saved key makes the stored record valid again, unless the case says the
# save did not take effect (PUT_FIXES=no).
api_put() {
    echo "PUT $1" >>"$CALLS"
    printf '%s' "$3" >"$PUT_BODY"
    [[ "${PUT_RESULT:-ok}" == ok ]] || return 1
    [[ "${PUT_FIXES:-yes}" == yes ]] && printf -v "TEST_${1##*/}" ok
    return 0
}

reset() {
    : >"$CALLS"
    : >"$LOG"
    rm -f "$PUT_BODY" "$POST_BODY"
    IDS=()
    LIST=""
    CONFIRM=no
    PUT_RESULT=ok
    PUT_FIXES=yes
    TEST_STATE=ok
    export JELLYFIN_API_KEY="$SENTINEL"
}

# Writes are a PUT or a POST that is not the test endpoint.
write_calls() { grep -cE '^PUT |^POST [^ ]*/notification(\?.*)?$' "$CALLS"; }
count_calls() { grep -cE "$1" "$CALLS"; }
count_log() { grep -cE "$1" "$LOG"; }

rerun() { configure_arr_jellyfin_connection sonarr http://sonarr/api/v3 "$APP_KEY" >/dev/null 2>&1; }

# --- A2: a matching record is left alone -------------------------------------
# Given Sonarr holds one MediaStack-created record whose stored key Jellyfin accepts
reset
add_rec 1 Jellyfin jellyfin 8096 0
build_list
# When configuration re-runs
rerun
# Then it logs the existing skip message
assert_eq "1" "$(count_log '^SKIP: Sonarr Jellyfin connection already configured$')" "match: the existing skip message is logged"
# And it warns about nothing
assert_eq "0" "$(count_log '^(WARN|ERROR)')" "match: no warning"
# And it makes no write call
assert_eq "0" "$(write_calls)" "match: no POST or PUT"

# --- A3: a stale key is reported without the key --------------------------------
# Given the same record, but Jellyfin now rejects its stored key
reset
add_rec 1 Jellyfin jellyfin 8096 0
set_test 1 stale
build_list
# When configuration re-runs
rerun
warn=$(grep '^WARN' "$LOG")
# Then the warning names the app, the record name and id, and both repair paths
assert_contains "$warn" "Sonarr Jellyfin connection 'Jellyfin' (id 1)" "stale: warning names app, record name and id"
assert_contains "$warn" "Features & settings -> Repair Jellyfin connections" "stale: warning names the launcher action"
assert_contains "$warn" "--repair-jellyfin-connections" "stale: warning names the CLI flag"
# And the skip message is not claimed
assert_eq "0" "$(count_log '^SKIP')" "stale: no 'already configured' claim"
# And nothing is written
assert_eq "0" "$(write_calls)" "stale: no POST or PUT"
# And the key appears in no log line and in no request body the re-run sent
assert_eq "0" "$(grep -c "$SENTINEL" "$LOG")" "stale: key absent from the log"
assert_eq "0" "$(grep -c "$SENTINEL" "$POST_BODY")" "stale: key absent from the test request body"

# --- A4: several records, user-managed records, notify ---------------------------
# Given a good managed record, a stale managed record, a stale user-managed record
# with another name, a good user-managed record on another host, and a managed
# record that also notifies users
reset
add_rec 1 Jellyfin jellyfin 8096 0
TEST_STATE=stale add_rec 2 Jellyfin jellyfin 8096 0
TEST_STATE=stale add_rec 3 "Living Room" jellyfin 8096 0
add_rec 4 Jellyfin 192.168.1.5 8096 0
add_rec 5 Jellyfin jellyfin 8096 1
build_list
# When configuration re-runs
rerun
warn=$(grep '^WARN' "$LOG")
# Then the stale managed record is reported with the repair path
assert_contains "$warn" "'Jellyfin' (id 2) is MediaStack-created" "multi: stale managed record reported"
# And the stale user-managed record is reported as user-managed and left alone
assert_contains "$warn" "'Living Room' (id 3) is user-managed" "multi: stale user-managed record reported as such"
# And the record that would send a message is not tested
assert_contains "$warn" "(id 5) was not tested" "multi: notifying record reported, not tested"
assert_eq "4" "$(count_calls '^POST .*/notification/test$')" "multi: the four silent records are tested, the notifying one is not"
# And the good records are not reported
assert_not_contains "$warn" "(id 1)" "multi: good managed record is silent"
assert_not_contains "$warn" "(id 4)" "multi: good user-managed record is silent"
# And nothing is written
assert_eq "0" "$(write_calls)" "multi: no POST or PUT"

# --- A4: a masked key is never compared ---------------------------------------------
# Given a record whose key reads back as ********, which can never equal the real key
reset
add_rec 1 Jellyfin jellyfin 8096 0
build_list
# When configuration re-runs and Jellyfin accepts the stored key
rerun
# Then the record is not reported as stale
assert_eq "0" "$(count_log '^WARN')" "masked: a masked value is not read as a stale key"

# --- A4: failures fail closed ----------------------------------------------------------
# Given the notification list cannot be fetched
reset
LIST=FAIL
# When configuration re-runs
rerun
# Then it warns, skips and writes nothing
assert_contains "$(grep '^WARN' "$LOG")" "Could not fetch Sonarr notifications" "failed GET: warns"
assert_eq "0" "$(write_calls)" "failed GET: no POST or PUT"

# Given the list is not a list of records
for bad in 'not json' '{"message":"oops"}' '[{"implementation":"MediaBrowser","name":"Jellyfin"}]'; do
    reset
    LIST="$bad"
    # When configuration re-runs
    rerun
    # Then it warns and writes nothing, rather than adding a duplicate connection
    assert_contains "$(grep '^WARN' "$LOG")" "Could not read Sonarr notifications" "malformed list ($bad): warns"
    assert_eq "0" "$(write_calls)" "malformed list ($bad): no POST or PUT"
done

# Given a record that cannot be fetched by id, and one whose test cannot reach Jellyfin
reset
add_rec 1 Jellyfin jellyfin 8096 0
TEST_STATE=down add_rec 2 Jellyfin jellyfin 8096 0
build_list
unset REC_1
# When configuration re-runs
rerun
warn=$(grep '^WARN' "$LOG")
# Then both are reported as unverified, not as stale, and nothing is written
assert_contains "$warn" "(id 1) could not be verified" "failed GET by id: unverified"
assert_contains "$warn" "(id 2) could not be verified" "unreachable test: unverified, not stale"
assert_not_contains "$warn" "rejects" "unreachable test: not called stale"
assert_eq "0" "$(write_calls)" "unverified: no POST or PUT"

# --- No connection yet: the add path still runs ---------------------------------------
# Given Sonarr holds only a connection of another kind
reset
LIST='[{"id":1,"name":"Telegram","implementation":"Telegram","fields":[]}]'
# When configuration runs
rerun
# Then one connection is created
assert_eq "1" "$(count_calls '^POST .*/notification$')" "absent: one POST /notification"
assert_contains "$(cat "$LOG")" "Sonarr -> Jellyfin: library update on import" "absent: creation is logged"

# --- A5: the repair ----------------------------------------------------------------------
repair() { configure_arr_jellyfin_repair sonarr http://sonarr/api/v3 "$APP_KEY" >/dev/null 2>&1; }

# Given one stale managed record and the user declines
reset
add_rec 1 Jellyfin jellyfin 8096 0
set_test 1 stale
build_list
CONFIRM=no
# When the repair runs
repair
rc=$?
# Then it asked, with a default of no, and listed the record name as evidence first
assert_contains "$(cat "$LOG")" "CONFIRM(no): Replace the Jellyfin API key in 1 Sonarr connection(s)?" "repair: asks for confirmation, default no"
assert_contains "$(cat "$LOG")" "INFO: Sonarr record 'Jellyfin' (id 1) is MediaStack-created" "repair: shows the record name as evidence"
# And nothing is written
assert_eq "0" "$(write_calls)" "repair declined: no PUT"

# Given a stale managed record, a stale user-managed record and a good managed record
reset
add_rec 1 Jellyfin jellyfin 8096 0
TEST_STATE=stale add_rec 2 Jellyfin jellyfin 8096 0
TEST_STATE=stale add_rec 3 "Living Room" jellyfin 8096 0
build_list
ORIGINAL_2="$REC_2"
CONFIRM=yes
# When the repair runs and the user confirms
repair
rc=$?
# Then only the stale managed record is written
assert_eq "1" "$(write_calls)" "repair: exactly one write"
assert_eq "1" "$(count_calls '^PUT .*/notification/2$')" "repair: the write is a PUT to the stale managed record"
# And the user-managed record is reported and left unchanged
assert_contains "$(grep '^WARN' "$LOG")" "'Living Room' (id 3) is user-managed" "repair: user-managed stale record reported"
# And the PUT body is the fetched record with only the key replaced
same=$(
    python3 - "$PUT_BODY" "$ORIGINAL_2" "$SENTINEL" <<'PY'
import json, sys
put = json.load(open(sys.argv[1]))
want = json.loads(sys.argv[2])
for f in want["fields"]:
    if f["name"] == "apiKey":
        f["value"] = sys.argv[3]
print(put == want, put["id"], put["implementation"], put["onGrab"], put["onRename"], put["tags"], put["futureField"])
PY
)
assert_eq "True 2 MediaBrowser True True [3, 4] {'keep': 'me'}" "$same" "repair: PUT keeps id, implementation, events, tags and unknown fields; only the key changed"
# And the app's test endpoint ran after the write, and passed
assert_eq "ok" "$([[ "$(grep -nE '^PUT|/notification/test$' "$CALLS" | tail -1)" == *"/notification/test" ]] && echo ok)" "repair: the last call is the test endpoint"
assert_contains "$(cat "$LOG")" "OK: Sonarr Jellyfin connection 'Jellyfin' (id 2): Jellyfin API key replaced; connection test passed" "repair: success reported after the test"
assert_eq "0" "$rc" "repair: succeeds"

# Given a stale managed record and a save that does not make the connection work
reset
add_rec 1 Jellyfin jellyfin 8096 0
set_test 1 stale
build_list
CONFIRM=yes
PUT_FIXES=no
# When the repair runs
repair
rc=$?
# Then the failed test is a failure, not a success
assert_contains "$(grep '^ERROR' "$LOG")" "connection test failed" "failed test: reported as an error"
assert_eq "0" "$(count_log '^OK:.*replaced')" "failed test: no success line"
assert_eq "1" "$rc" "failed test: non-zero exit"

# Given a stale managed record and an app that rejects the save
reset
add_rec 1 Jellyfin jellyfin 8096 0
set_test 1 stale
build_list
CONFIRM=yes
PUT_RESULT=fail
# When the repair runs
repair
rc=$?
# Then it fails, retries without forcing, and claims no success
assert_eq "1" "$rc" "rejected save: non-zero exit"
assert_eq "0" "$(count_calls 'forceSave')" "rejected save: never force-saved"
assert_eq "0" "$(count_log '^OK:.*replaced')" "rejected save: no success line"

# Given only a good managed record and a stale user-managed record
reset
add_rec 1 Jellyfin jellyfin 8096 0
TEST_STATE=stale add_rec 2 "Living Room" jellyfin 8096 0
build_list
CONFIRM=yes
# When the repair runs
repair
# Then nothing is asked and nothing is written
assert_eq "0" "$(count_log '^CONFIRM')" "nothing managed to fix: no prompt"
assert_eq "0" "$(write_calls)" "nothing managed to fix: no PUT"

# Given no Jellyfin key
reset
add_rec 1 Jellyfin jellyfin 8096 0
build_list
unset JELLYFIN_API_KEY
# When the repair runs
repair
# Then it refuses
assert_eq "1" "$?" "no Jellyfin key: repair refuses"

# --- The CLI flag --------------------------------------------------------------------------
# Given a minimal install tree and the repair flag combined with --only
mkdir -p "$TMP/box"
ln -s "$REPO_ROOT/scripts" "$TMP/box/scripts"
echo "jellyfin: {}" >"$TMP/box/config.yml"
# When configure.sh parses its arguments
out=$(bash "$TMP/box/scripts/configure.sh" --repair-jellyfin-connections --only sonarr 2>&1)
rc=$?
# Then it exits 2 and says why
assert_eq "2" "$rc" "flag: --repair-jellyfin-connections with --only exits 2"
assert_contains "$out" "cannot be combined with --only" "flag: says why"

# --- The launcher entry ------------------------------------------------------------------
# Given the Features & settings menu
# When the user picks the repair entry
menu_out=$(MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  render_banner(){ :; }
  recovery_menu_remote_available(){ return 1; }
  ui_choose(){ shift; printf "%s\n" "$@" | grep "^Repair Jellyfin"; }
  action_repair_jellyfin_connections(){ echo DISPATCH_REPAIR; exit 0; }
  submenu_features 2>&1')
# Then the menu routes it to the repair handler
assert_contains "$menu_out" "DISPATCH_REPAIR" "menu: the repair entry reaches its handler"

# Given a configure.sh that records its arguments and exits with a chosen code
run_action() {
    MEDIASTACK_NONINTERACTIVE=1 REPO_ROOT="$REPO_ROOT" CONFIGURE_RC="$1" DOCKER_UP="$2" bash -c '
  source "$REPO_ROOT/mediastack" </dev/null
  tmp=$(mktemp -d); SCRIPT_DIR="$tmp"; mkdir "$tmp/scripts"
  printf "#!/usr/bin/env bash\necho \"CONFIGURE \$*\"\nexit %s\n" "$CONFIGURE_RC" >"$tmp/scripts/configure.sh"
  chmod +x "$tmp/scripts/configure.sh"
  _docker_reachable(){ [[ "$DOCKER_UP" == 1 ]]; }
  launcher_pause_for_menu(){ :; }
  _show_action_result(){ echo "RESULT rc=$1 $2"; }
  action_repair_jellyfin_connections 2>&1' 2>&1
}
# When the action runs with Docker up, then with the script failing, then with Docker down
act_ok=$(run_action 0 1)
act_fail=$(run_action 1 1)
act_down=$(run_action 0 0)
# Then it runs the repair flag and reports the script's result
assert_contains "$act_ok" "CONFIGURE --repair-jellyfin-connections" "action: runs the CLI repair"
assert_contains "$act_ok" "RESULT rc=0 Repair Jellyfin connections" "action: reports success"
assert_contains "$act_fail" "RESULT rc=1 Repair Jellyfin connections" "action: reports the script's failure"
# And it does nothing when Docker is not reachable
assert_not_contains "$act_down" "CONFIGURE" "action: no repair when Docker is down"

# --- A3: the key never reaches argv (real API helpers over a stubbed curl) ------------------
ARGV_LOG="$TMP/argv"
STDIN_LOG="$TMP/stdin"
: >"$ARGV_LOG"
: >"$STDIN_LOG"
rm -f "$TMP/put.done"
REC_1_JSON="$(mkrec 1 Jellyfin jellyfin 8096 0)"

# Record argv; read stdin only when curl would (-K -); answer by URL and method.
curl() {
    printf '%s\n' "$@" >>"$ARGV_LOG"
    local arg method=GET url="" prev="" body="" read_stdin=0
    for arg in "$@"; do
        [[ "$prev" == "-X" ]] && method="$arg"
        [[ "$arg" == "-K" ]] && read_stdin=1
        url="$arg"
        prev="$arg"
    done
    if ((read_stdin)); then
        body=$(cat)
        printf '%s\n' "$body" >>"$STDIN_LOG"
    fi
    case "$method $url" in
        "GET "*/notification) printf '[%s]\n200' "$REC_1_JSON" ;;
        "GET "*/notification/1) printf '%s\n200' "$REC_1_JSON" ;;
        "PUT "*/notification/1)
            : >"$TMP/put.done"
            printf '{}\n202'
            ;;
        "POST "*/notification/test)
            if [[ -e "$TMP/put.done" ]]; then
                printf '{}\n200'
            else
                printf '[{"isWarning": false, "propertyName": "ApiKey", "errorMessage": "API Key is invalid"}]\n400'
            fi
            ;;
        *) printf '{}\n404' ;;
    esac
}

# Given the real API helpers, a stale record, and a user who confirms the repair
eval "$REAL_API_FNS"
reset
CONFIRM=yes
# When a normal re-run and then the repair run
configure_arr_jellyfin_connection sonarr http://sonarr/api/v3 "$APP_KEY" >/dev/null 2>&1
configure_arr_jellyfin_repair sonarr http://sonarr/api/v3 "$APP_KEY" >/dev/null 2>&1
# Then neither the Jellyfin key nor the app key is on any argv
assert_file_not_contains "$ARGV_LOG" "$SENTINEL" "argv: Jellyfin key absent from curl argv"
assert_file_not_contains "$ARGV_LOG" "$APP_KEY" "argv: app key absent from curl argv"
# And the log never shows the Jellyfin key
assert_eq "0" "$(grep -c "$SENTINEL" "$LOG")" "argv: Jellyfin key absent from the log"
# And the repair did deliver the key, on stdin, in the PUT
assert_file_contains "$STDIN_LOG" "$SENTINEL" "argv: the PUT carried the key on stdin (positive control)"
# And the repair finished with a passing test
assert_contains "$(cat "$LOG")" "connection test passed" "argv: repair succeeded over the real helpers"

scenario_end "$CURRENT_SCENARIO"
summary
