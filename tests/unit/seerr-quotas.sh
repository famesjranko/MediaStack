#!/usr/bin/env bash
# tests/unit/seerr-quotas.sh
# Seerr default permissions + quota reconcile against a fake Seerr that merges
# POST /settings/main into stored settings, as Seerr 3.5.1 does (lodash merge).

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="seerr-quotas"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
STATE="$TMP_DIR/state.json"
POSTS="$TMP_DIR/posts"
LOGS="$TMP_DIR/logs"

source "$REPO_ROOT/scripts/lib/http.sh"
source "$REPO_ROOT/scripts/services/seerr/quotas.sh"

declare -A CFG
cfg_field() { [[ -n "${CFG[$1]+x}" ]] && printf '%s\n' "${CFG[$1]}"; }
log_skip() { echo "skip: $*" >>"$LOGS"; }
log_ok() { echo "ok: $*" >>"$LOGS"; }
log_warn() { echo "warn: $*" >>"$LOGS"; }

# Fake Seerr: GET returns the stored settings; POST records the body and merges
# it into them unless FAKE_IGNORE_POST is set (a 200 that changes nothing).
api_fetch() {
    [[ -z "${FAKE_FAIL_GET:-}" ]] && cat "$STATE"
}
curl() {
    local body="" prev="" a
    for a in "$@"; do
        [[ "$prev" == "-d" ]] && body="$a"
        prev="$a"
    done
    printf '%s\n' "$body" >>"$POSTS"
    [[ -n "${FAKE_IGNORE_POST:-}" ]] && return 0
    if [[ -n "${FAKE_GARBLE_AFTER_POST:-}" ]]; then
        echo "not json" >"$STATE"
        return 0
    fi
    python3 -I - "$STATE" "$body" <<'PY'
import json, sys

def merge(dst, src):
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v

state = json.load(open(sys.argv[1]))
merge(state, json.loads(sys.argv[2]))
json.dump(state, open(sys.argv[1], "w"))
PY
}

# Args: movie_limit movie_days tv_limit tv_days (live state) -> writes $STATE
live() {
    python3 -I - "$@" >"$STATE" <<'PY'
import json, sys
ml, md, tl, td = sys.argv[1:5]
q = lambda l, d: {"quotaLimit": int(l), "quotaDays": int(d)}
print(json.dumps({"apiKey": "k", "defaultPermissions": 32,
                  "defaultQuotas": {"movie": q(ml, md), "tv": q(tl, td)}}))
PY
}

# Args: movie_limit movie_days tv_limit tv_days (desired config)
want() {
    CFG=(["seerr.quotas.movie.limit"]="$1" ["seerr.quotas.movie.days"]="$2"
        ["seerr.quotas.tv.limit"]="$3" ["seerr.quotas.tv.days"]="$4")
}

# Runs the reconcile with a clean record of POSTs and log lines.
run_reconcile() {
    : >"$POSTS"
    : >"$LOGS"
    reconcile_seerr_quotas "http://seerr" "$TMP_DIR/cookie" "$(api_fetch)"
}

posts() { tr -d '\n' <"$POSTS"; }
stored() {
    python3 -I -c '
import json, sys
q = json.load(open(sys.argv[1]))["defaultQuotas"]
print(json.dumps(q, sort_keys=True))' "$STATE"
}
logs() { tr '\n' '|' <"$LOGS"; }

# Given a missing quota block and unlimited live quotas.
live 0 7 0 7
CFG=()

# When the reconcile runs.
run_reconcile
post_result=$(posts)
log_result=$(logs)

# Then it sends no POST.
assert_eq "" "$post_result" "missing quotas keep unlimited settings without a POST"
assert_contains "$log_result" "already match" "missing quotas report the true no-change run"

# Given a missing movie limit and TV days with enabled live quotas.
live 10 7 5 3
want 10 7 5 3
unset 'CFG[seerr.quotas.movie.limit]' 'CFG[seerr.quotas.tv.days]'

# When the reconcile runs.
run_reconcile
post_result=$(posts)

# Then it clears the movie limit and uses seven days for TV.
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 0, "quotaDays": 7}, "tv": {"quotaLimit": 5, "quotaDays": 7}}}' "$post_result" "missing keys use template defaults"

# Given 10 per 7 days live for both, and a movie period of 14 wanted.
# When the reconcile runs.
# Then it posts both quotas with only the movie period changed, and reports success.
live 10 7 10 7
want 10 14 10 7
run_reconcile
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 10, "quotaDays": 14}, "tv": {"quotaLimit": 10, "quotaDays": 7}}}' "$(posts)" "movie-only period change posts the new period"
assert_contains "$(logs)" "ok: Seerr: admin-approval" "movie-only period change is reported as success"

# Given 10 per 7 days live for both, and a TV period of 14 wanted.
# When the reconcile runs.
# Then it posts both quotas with only the TV period changed.
live 10 7 10 7
want 10 7 10 14
run_reconcile
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 10, "quotaDays": 7}, "tv": {"quotaLimit": 10, "quotaDays": 14}}}' "$(posts)" "TV-only period change posts the new period"

# Given live settings equal to the wanted settings.
# When the reconcile runs.
# Then it sends no POST and says the settings already match.
live 10 7 5 3
want 10 7 5 3
run_reconcile
assert_eq "" "$(posts)" "a true no-change re-run sends no POST"
assert_contains "$(logs)" "already match" "a true no-change re-run says the settings match"

# Given both quotas unlimited live with a period of 7, and unlimited wanted with periods of 30 and 1.
# When the reconcile runs.
# Then it sends no POST, because a day value means nothing without a limit.
live 0 7 0 7
want 0 30 0 1
run_reconcile
assert_eq "" "$(posts)" "disabled quotas with differing day values send no POST"

# Given movie 10 per 7 days live, and movie limit 0 wanted.
# When the reconcile runs.
# Then it posts an explicit zero limit and the readback shows the quota cleared.
live 10 7 0 7
want 0 7 0 7
run_reconcile
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 0, "quotaDays": 7}, "tv": {"quotaLimit": 0, "quotaDays": 7}}}' "$(posts)" "enabled to unlimited posts an explicit zero limit"
assert_eq '{"movie": {"quotaDays": 7, "quotaLimit": 0}, "tv": {"quotaDays": 7, "quotaLimit": 0}}' "$(stored)" "enabled to unlimited leaves the quota cleared in the stored settings"
assert_contains "$(logs)" "ok: Seerr: admin-approval" "enabled to unlimited is reported as success"

# Given both quotas unlimited live, and 5 per 3 days wanted for movies.
# When the reconcile runs.
# Then it posts the new limit and period, leaves TV unlimited, and the readback matches.
live 0 7 0 7
want 5 3 0 7
run_reconcile
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 5, "quotaDays": 3}, "tv": {"quotaLimit": 0, "quotaDays": 7}}}' "$(posts)" "unlimited to enabled posts the limit and period"
assert_eq '{"movie": {"quotaDays": 3, "quotaLimit": 5}, "tv": {"quotaDays": 7, "quotaLimit": 0}}' "$(stored)" "unlimited to enabled is stored"

# Given both quotas at 10 per 7 days live, and only the TV quota cleared.
# When the reconcile runs.
# Then the movie quota stays as it was and only the TV quota is cleared.
live 10 7 10 7
want 10 7 0 7
run_reconcile
assert_eq '{"movie": {"quotaDays": 7, "quotaLimit": 10}, "tv": {"quotaDays": 7, "quotaLimit": 0}}' "$(stored)" "clearing one quota keeps the other"
assert_contains "$(posts)" '"tv": {"quotaLimit": 0, "quotaDays": 7}' "clearing the TV quota posts an explicit zero limit"

# Given a permission value other than 32 live, and quotas already matching.
# When the reconcile runs.
# Then it posts the permission and quotas.
live 0 7 0 7
python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1])); d["defaultPermissions"] = 0
json.dump(d, open(sys.argv[1], "w"))' "$STATE"
want 0 7 0 7
run_reconcile
assert_eq '{"defaultPermissions": 32, "defaultQuotas": {"movie": {"quotaLimit": 0, "quotaDays": 7}, "tv": {"quotaLimit": 0, "quotaDays": 7}}}' "$(posts)" "a permission drift is corrected"

# Given Seerr that answers 200 to the POST but keeps its old settings.
# When the reconcile runs.
# Then it warns and does not claim success.
live 10 7 10 7
want 0 7 0 7
FAKE_IGNORE_POST=1 run_reconcile
assert_contains "$(logs)" "warn: Seerr accepted the quota update but its settings do not match" "a 200 with unchanged settings is a warning"
assert_not_contains "$(logs)" "ok:" "a 200 with unchanged settings is not reported as success"

# Given Seerr that answers 200 to the POST but then returns an unreadable body.
# When the reconcile runs.
# Then it warns that it could not read the settings back, and does not claim success.
live 10 7 10 7
want 0 7 0 7
FAKE_GARBLE_AFTER_POST=1 run_reconcile
assert_contains "$(logs)" "warn: Could not read back Seerr settings after the update" "an unreadable readback is reported as unreadable"
assert_not_contains "$(logs)" "do not match" "an unreadable readback is not reported as a mismatch"
assert_not_contains "$(logs)" "ok:" "an unreadable readback is not reported as success"

# Given config values that are not non-negative whole numbers, or a period of 0 with a limit.
# When the reconcile runs against quotas that would otherwise need a change.
# Then it sends no POST and warns.
for bad in "abc" "-1" "1.5" "" "5; import os" "0x10" "٣"; do
    live 10 7 10 7
    want "$bad" 7 10 7
    run_reconcile
    assert_eq "" "$(posts)" "invalid movie limit '$bad' sends no POST"
    assert_contains "$(logs)" "warn: seerr.quotas in config.yml must be whole numbers" "invalid movie limit '$bad' warns"
    live 10 7 10 7
    want 10 7 10 "$bad"
    run_reconcile
    assert_eq "" "$(posts)" "invalid TV days '$bad' sends no POST"
done
live 10 7 10 7
want 5 0 5 7
run_reconcile
assert_eq "" "$(posts)" "a limit above 0 with a period of 0 sends no POST"

# Given config text that would run code if it were placed in Python source.
# When the reconcile runs.
# Then the code does not run.
live 10 7 10 7
want "1); open('$TMP_DIR/pwned','w').write('x" 7 10 7
run_reconcile
assert_file_absent "$TMP_DIR/pwned" "config values are not interpreted as Python"

# Given a GET response without defaultQuotas, with null defaultQuotas, and with a non-JSON body.
# When the reconcile runs.
# Then it sends no POST and warns.
want 5 7 5 7
for body in '{"apiKey":"k","defaultPermissions":32}' '{"defaultPermissions":32,"defaultQuotas":null}' 'not json' '[]' '{"defaultQuotas":{"movie":{"quotaLimit":"10"},"tv":{}}}'; do
    printf '%s\n' "$body" >"$STATE"
    run_reconcile
    assert_eq "" "$(posts)" "unusable settings response '$body' sends no POST"
    assert_contains "$(logs)" "warn: Could not read Seerr quota settings" "unusable settings response '$body' warns"
done

# Given a failed GET of the main settings.
# When the reconcile runs.
# Then it sends no POST and warns.
live 10 7 10 7
want 5 7 5 7
FAKE_FAIL_GET=1 run_reconcile
assert_eq "" "$(posts)" "a failed GET sends no POST"
assert_contains "$(logs)" "warn: Could not read Seerr quota settings" "a failed GET warns"

scenario_end "$CURRENT_SCENARIO"
summary
