# tests/assertions/jackett.sh — Jackett evidence after configure.sh.
#
# The indexer list comes from the DinD copy's config.yml (the scenario's own
# fixture). A fixture that cannot be read is a FAIL, never an empty list: an
# empty list is a deliberate SKIP and must stay distinguishable from a read that
# failed. Every configured indexer must serve Torznab caps with at least one
# category, which is what Sonarr and Radarr consume on registration.

# Print the fixture indexer ids space-separated, "NONE" for an empty fixture,
# or "ERR:<why>".
jackett_fixture_indexer_ids() {
    dind_python 2>&1 <<'PY' | tr -d '\r'
import sys

import yaml

try:
    with open("config.yml") as fh:
        cfg = yaml.safe_load(fh) or {}
except (OSError, yaml.YAMLError) as exc:
    print(f"ERR:config.yml unreadable: {exc}")
    sys.exit(0)
indexers = cfg.get("indexers") if isinstance(cfg, dict) else None
if not isinstance(indexers, list) or any(not isinstance(i, dict) for i in indexers):
    print("ERR:config.yml indexers must be a list of objects")
    sys.exit(0)
ids = [i.get("id") for i in indexers if isinstance(i, dict)]
if any(not isinstance(i, str) or not i for i in ids):
    print("ERR:an indexer entry has no string id")
    sys.exit(0)
print(" ".join(ids) if ids else "NONE")
PY
}

# Classify one Torznab caps document on stdin: "ok", "no-categories" or "no-caps".
jackett_caps_report() {
    python3 -I -c '
import sys
import xml.etree.ElementTree as ET

try:
    root = ET.fromstring(sys.stdin.read())
except ET.ParseError:
    print("no-caps")
    sys.exit(0)
if root.tag != "caps":
    print("no-caps")
elif not root.findall("./categories/category"):
    print("no-categories")
else:
    print("ok")
'
}

# Torznab caps verdict of one indexer through an API key: "ok",
# "no-categories", "no-caps" or "request-failed".
jackett_indexer_caps() { # <indexer id> <api key>
    local caps_resp
    if ! caps_resp=$(dind_exec "curl -sf --max-time 15 'http://localhost:9117/api/v2.0/indexers/$1/results/torznab/?apikey=$2&t=caps'" 2>/dev/null); then
        echo request-failed
        return 0
    fi
    printf '%s' "$caps_resp" | jackett_caps_report
}

assert_jackett_configured() {
    local jackett_key
    jackett_key=$(api_get_jackett_key)
    if [[ -n "$jackett_key" && ${#jackett_key} -ge 20 ]]; then
        pass "step 2 Jackett: API key present (${jackett_key:0:8}…)"
    else
        fail "step 2 Jackett: API key present" "got='${jackett_key}'"
    fi

    local ids_raw
    ids_raw=$(jackett_fixture_indexer_ids)
    case "$ids_raw" in
        ERR:* | "")
            fail "step 2 Jackett: indexer fixture (config.yml in DinD) readable" "${ids_raw:-no output}"
            return 0
            ;;
        NONE)
            skip "step 2 Jackett: indexer caps checks" "fixture config.yml lists no indexers"
            return 0
            ;;
    esac
    local indexers=()
    read -r -a indexers <<<"$ids_raw"

    local caps_ok=0 caps_fail=0 caps_fail_names="" idx verdict
    for idx in "${indexers[@]}"; do
        verdict=$(jackett_indexer_caps "$idx" "$jackett_key")
        if [[ "$verdict" == "ok" ]]; then
            caps_ok=$((caps_ok + 1))
        else
            caps_fail=$((caps_fail + 1))
            caps_fail_names="${caps_fail_names:+$caps_fail_names, }$idx ($verdict)"
        fi
    done
    if ((caps_fail == 0)); then
        pass "step 2 Jackett: all ${caps_ok} indexers serve Torznab caps with categories"
    else
        fail "step 2 Jackett: all indexers serve Torznab caps with categories" \
            "${caps_ok} ok, ${caps_fail} failed: ${caps_fail_names}"
    fi
}
