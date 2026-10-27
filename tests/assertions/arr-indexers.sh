# tests/assertions/arr-indexers.sh — Sonarr/Radarr indexer assertions shared by
# tests/assertions/sonarr.sh and tests/assertions/radarr.sh.
#
# Expectations come from the DinD copy's config.yml, the scenario's own fixture,
# never from the host tree. Every read is fail-closed: an unreadable fixture, a
# failed API request or a malformed response is a FAIL, never a zero that an
# arithmetic comparison then passes. An intentionally empty fixture is reported
# as an explicit SKIP so it cannot be confused with a failed read.

# Count the fixture's indexers eligible for one app. Prints an integer, or
# "ERR:<why>". Args: <space-separated type list, e.g. "general tv">
arr_fixture_indexer_total() {
    dind_python "$1" 2>&1 <<'PY' | tr -d '\r'
import sys

import yaml

try:
    with open("config.yml") as fh:
        cfg = yaml.safe_load(fh) or {}
except (OSError, yaml.YAMLError) as exc:
    print(f"ERR:config.yml unreadable: {exc}")
    sys.exit(0)
indexers = cfg.get("indexers") if isinstance(cfg, dict) else None
if not isinstance(indexers, list) or any(
    not isinstance(i, dict)
    or not isinstance(i.get("id"), str)
    or not i["id"]
    or i.get("type", "general") not in ("general", "tv", "movies")
    for i in indexers
):
    print("ERR:config.yml indexers must be a list of entries with an id and a valid type")
    sys.exit(0)
types = set(sys.argv[1].split())
print(sum(1 for i in indexers if i.get("type", "general") in types))
PY
}

# Validate a GET /indexer body: a JSON list of objects. Prints the count, or
# "ERR:<why>". Reads the body on stdin.
arr_indexer_list_count() {
    python3 -I -c '
import json
import sys

try:
    items = json.load(sys.stdin)
except ValueError as exc:
    print(f"ERR:response is not JSON: {exc}")
    sys.exit(0)
if not isinstance(items, list) or not all(isinstance(i, dict) for i in items):
    print("ERR:response is not a list of indexer objects")
    sys.exit(0)
print(len(items))
'
}

# Check the seed criteria MediaStack writes on every registered indexer. Prints
# "OK|<n> indexers checked" or "FAIL|<detail>". Args: <season_pack 0|1>; body on stdin.
arr_indexer_seed_report() {
    ARR_SEASON_PACK="$1" python3 -I -c '
import json
import os
import sys

season_pack = os.environ["ARR_SEASON_PACK"] == "1"
try:
    indexers = json.load(sys.stdin)
except ValueError as exc:
    print(f"FAIL|response is not JSON: {exc}")
    sys.exit(0)
if not isinstance(indexers, list) or not indexers:
    print("FAIL|no indexers to check")
    sys.exit(0)
wrong = []
for ix in indexers:
    fields = {f.get("name"): f.get("value") for f in ix.get("fields", []) if isinstance(f, dict)}
    name = ix.get("name", "?")
    ratio = fields.get("seedCriteria.seedRatio")
    seed_time = fields.get("seedCriteria.seedTime")
    season = fields.get("seedCriteria.seasonPackSeedTime")
    if ratio != 1.0:
        wrong.append(f"{name}: seedRatio={ratio} want 1.0")
    if seed_time != 1440:
        wrong.append(f"{name}: seedTime={seed_time} want 1440")
    if season_pack and season != 2880:
        wrong.append(f"{name}: seasonPackSeedTime={season} want 2880")
print("FAIL|" + "; ".join(wrong[:3]) if wrong else f"OK|{len(indexers)} indexers checked")
'
}

# POST each registered indexer back to /indexer/test. Prints "OK|<n> tested" or
# "FAIL|<name>: HTTP <code> <body excerpt>; ...". Args: <api base> <api key>
arr_indexer_test_all() {
    local base="$1" key="$2" live
    live=$(dind_exec "curl -sf --max-time 20 -H 'X-Api-Key: $key' $base/indexer") || {
        printf 'FAIL|GET /indexer failed before testing\n'
        return 0
    }
    # The key rides a scratch file inside DinD: docker exec passes no host env,
    # and argv would show it in the DinD process list.
    printf '%s' "$live" | dind_write_file /tmp/arr-indexers.json
    printf '%s' "$key" | dind_write_file /tmp/arr-indexers.key
    dind_python "$base" <<'PY'
import json
import sys
import urllib.error
import urllib.request

base = sys.argv[1]
with open("/tmp/arr-indexers.key") as fh:
    key = fh.read().strip()
with open("/tmp/arr-indexers.json") as fh:
    indexers = json.load(fh)
if not indexers:
    print("FAIL|no indexers registered")
    sys.exit(0)
failed = []
for ix in indexers:
    req = urllib.request.Request(
        f"{base}/indexer/test",
        data=json.dumps(ix).encode(),
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            if resp.status != 200:
                failed.append(f"{ix.get('name')}: HTTP {resp.status}")
    except urllib.error.HTTPError as exc:
        failed.append(f"{ix.get('name')}: HTTP {exc.code} {exc.read()[:200].decode(errors='replace')}")
    except (urllib.error.URLError, OSError) as exc:
        failed.append(f"{ix.get('name')}: {exc}")
print("FAIL|" + "; ".join(failed) if failed else f"OK|{len(indexers)} tested")
PY
}

# Assert the app's live indexers match the fixture: count floor and seed criteria.
# Args: <label e.g. "step 3 Sonarr"> <app sonarr|radarr> <api base> <api key>
#       <configure log> <fixture types> <season_pack 0|1>
#
# Floor = fixture indexers eligible for the app minus the ones configure.sh
# reported unavailable in this run (public trackers come and go; a tracker that
# recovers between runs must not flip a count equality). The floor must stay at
# least one: a run where every fixture indexer was unavailable proves nothing
# about registration and fails rather than passing on an empty population.
arr_assert_indexers() {
    local label="$1" app="$2" base="$3" key="$4" configure_log="$5" types="$6" season_pack="$7"
    local app_name="${app^}"
    local total
    total=$(arr_fixture_indexer_total "$types")
    if [[ ! "$total" =~ ^[0-9]+$ ]]; then
        fail "$label: indexer fixture (config.yml in DinD) readable" "${total:-no output}"
        return 0
    fi
    local live
    if ! live=$(dind_exec "curl -sf --max-time 20 -H 'X-Api-Key: $key' $base/indexer"); then
        fail "$label: GET /indexer answers" "request failed"
        return 0
    fi
    local count
    count=$(printf '%s' "$live" | arr_indexer_list_count)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        fail "$label: GET /indexer returns an indexer list" "${count:-no output}"
        return 0
    fi
    if ((total == 0)); then
        if ((count == 0)); then
            skip "$label: indexer registration" "fixture config.yml lists no indexers for $app_name"
        else
            fail "$label: no indexers expected from an empty fixture" "live $app_name has $count"
        fi
        return 0
    fi
    local warned floor
    warned=$(sed -r 's/\x1b\[[0-9;]*m//g' "$configure_log" 2>/dev/null \
        | { grep -Ec "(Failed:.*-> $app_name|Indexer unavailable, skipped: .* -> $app_name)" || true; })
    [[ "$warned" =~ ^[0-9]+$ ]] || warned=0
    floor=$((total - warned))
    if ((floor < 1)); then
        fail "$label: at least one fixture indexer registers" \
            "all $total eligible fixture indexers were reported unavailable in this run"
        return 0
    fi
    if ((count >= floor)); then
        pass "$label: $count/$total indexers configured${warned:+ ($warned upstream-blocked, floor=$floor)}"
    else
        fail "$label: $floor indexers expected (floor)" "got $count (warned=$warned, total=$total)"
    fi
    if ((count == 0)); then
        fail "$label: indexer seed criteria" "no indexers registered to check"
        return 0
    fi
    # Real connection test: the app searches through each registered indexer
    # (Jackett -> tracker) with the stored settings. forceSave=true skipped this
    # at registration, so without it a stored indexer could be unusable.
    local test_report
    test_report=$(arr_indexer_test_all "$base" "$key")
    case "$test_report" in
        OK*) pass "$label: every registered indexer passes the app's connection test (${test_report#OK|})" ;;
        *) fail "$label: every registered indexer passes the app's connection test" "${test_report#FAIL|}" ;;
    esac
    local seed season_note=""
    [[ "$season_pack" == 1 ]] && season_note=", season=48h"
    seed=$(printf '%s' "$live" | arr_indexer_seed_report "$season_pack")
    case "$seed" in
        OK*) pass "$label: indexer seed criteria (ratio=1.0, time=24h${season_note}) (${seed#OK|})" ;;
        FAIL*) fail "$label: indexer seed criteria" "${seed#FAIL|}" ;;
        *) fail "$label: indexer seed criteria" "parse error: ${seed:-no output}" ;;
    esac
}
