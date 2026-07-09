#!/usr/bin/env bash
# tests/unit/ddns-config.sh
#
# Contract tests for the shared DDNS provider registry + config.json renderer
# (scripts/lib/ddns_providers.sh, epic #234). No live credentials — fixture
# values only. Proves all 6 providers render valid typed JSON, dynv6 carries
# no inert ipv4 key (ddns-updater detects and sends the IP itself), missing/
# unknown inputs fail, and the Dynu render is byte-identical to the inline
# writer it replaces in env_gen.sh.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ddns-config"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/ddns_providers.sh"

set +e
set +u

# ---------------------------------------------------------------------------
# Golden Dynu render. Dynu collects password ONLY (#248: it ignores the username,
# so we drop the prompt and auto-fill a constant "mediastack" placeholder via the
# const-JSON cell). dynu_golden encodes the exact expected bytes — key order and
# the placeholder included — so any renderer drift or accidental username-prompt
# reintroduction is caught here. Order = provider, domain, password, username,
# ip_version (const JSON merges after the collected fields).
# ---------------------------------------------------------------------------
dynu_golden() {
    DDNS_DOMAIN="$1" DDNS_PASSWORD="$2" python3 -c '
import os, json
print(json.dumps({"settings": [{
    "provider": "dynu",
    "domain": os.environ["DDNS_DOMAIN"],
    "password": os.environ["DDNS_PASSWORD"],
    "username": "mediastack",
    "ip_version": "ipv4",
}]}, indent=2))
'
}

golden_case() {
    local name="$1" d="$2" p="$3"
    local -A f=([domain]="$d" [password]="$p")
    local expected actual
    expected=$(dynu_golden "$d" "$p")
    actual=$(ddns_render_config_json dynu f)
    assert_eq "$expected" "$actual" "ddns_render dynu golden: $name"
}

golden_case "ascii"         "media.example.com"  "s3cret"
golden_case "shell-special" "media.example.com"  'p@ss"w\rd$#!'
golden_case "unicode"       "münchen.example.de" "pä ss"

# ---------------------------------------------------------------------------
# All 6 providers render valid JSON with the right provider tag + required
# fields. render_provider fills every credential field with a dummy value
# (the renderer does not validate — that is #236's field loop).
# ---------------------------------------------------------------------------
render_provider() {
    local key="$1" spec name
    local -A f=([domain]="host.example.com")
    for spec in $(ddns_provider_fields "$key"); do
        name="${spec%%:*}"
        # shellcheck disable=SC2034  # f is read via nameref in ddns_render_config_json
        f["$name"]="dummy-${name}"
    done
    ddns_render_config_json "$key" f
}

for key in dynu duckdns desec dynv6 cloudflare porkbun; do
    json=$(render_provider "$key"); rc=$?
    assert_eq "0" "$rc" "ddns_render $key: exits 0"
    prov=$(printf '%s' "$json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["settings"][0]["provider"])' 2>/dev/null)
    assert_eq "$key" "$prov" "ddns_render $key: provider tag is $key"
done

# dynv6: ddns-updater sends the detected IP itself, so the config carries only
# token + ip_version — no inert `ipv4` key (verified vs qdm12/ddns-updater docs).
dynv6_json=$(render_provider dynv6)
dynv6_ipv4=$(printf '%s' "$dynv6_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["settings"][0].get("ipv4", "ABSENT"))')
assert_eq "ABSENT" "$dynv6_ipv4" "ddns_render dynv6: no inert ipv4 key (ddns-updater sends the IP)"
dynv6_tok=$(printf '%s' "$dynv6_json" | python3 -c 'import sys,json; print(json.load(sys.stdin)["settings"][0]["token"])')
assert_eq "dummy-token" "$dynv6_tok" "ddns_render dynv6: token field present"

# Typed JSON: Cloudflare ttl is int + proxied is bool (unquoted), Porkbun ttl int.
cf_types=$(render_provider cloudflare | python3 -c 'import sys,json; s=json.load(sys.stdin)["settings"][0]; print(type(s["ttl"]).__name__, type(s["proxied"]).__name__)')
assert_eq "int bool" "$cf_types" "ddns_render cloudflare: ttl int + proxied bool (typed, unquoted)"
pb_ttl_type=$(render_provider porkbun | python3 -c 'import sys,json; print(type(json.load(sys.stdin)["settings"][0]["ttl"]).__name__)')
assert_eq "int" "$pb_ttl_type" "ddns_render porkbun: ttl int (typed, unquoted)"

# ---------------------------------------------------------------------------
# Missing / unknown inputs fail non-zero (and print nothing usable to stdout).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # assocs below are read via nameref in the renderer
declare -A miss_pw=([domain]="host.example.com")
if ddns_render_config_json dynu miss_pw >/dev/null 2>&1; then
    fail "ddns_render dynu: missing password must fail"
else
    pass "ddns_render dynu: missing password fails non-zero"
fi

# shellcheck disable=SC2034
declare -A miss_dom=([password]="p")
if ddns_render_config_json dynu miss_dom >/dev/null 2>&1; then
    fail "ddns_render dynu: missing domain must fail"
else
    pass "ddns_render dynu: missing domain fails non-zero"
fi

# shellcheck disable=SC2034
declare -A empty_tok=([domain]="host.example.com" [token]="")
if ddns_render_config_json duckdns empty_tok >/dev/null 2>&1; then
    fail "ddns_render duckdns: empty token must fail"
else
    pass "ddns_render duckdns: empty token fails non-zero"
fi

# shellcheck disable=SC2034
declare -A anyf=([domain]="host.example.com")
if ddns_render_config_json bogusprovider anyf >/dev/null 2>&1; then
    fail "ddns_render: unknown provider must fail"
else
    pass "ddns_render: unknown provider fails non-zero"
fi

# ---------------------------------------------------------------------------
# Registry accessor smoke (pick / fields / verify_tier / category). pick is not
# wired into the wizard until #236, so this is its only exercise: stub ui_choose to
# return a label and assert the label→key mapping.
# ---------------------------------------------------------------------------
assert_eq "password:validate_ddns_password" \
    "$(ddns_provider_fields dynu)" "ddns_provider_fields: dynu specs (password only, #248)"
assert_eq "token:validate_ddns_token" \
    "$(ddns_provider_fields duckdns)" "ddns_provider_fields: duckdns specs"

assert_eq "dyndns2" "$(ddns_provider_verify_tier dynu)"   "ddns_provider_verify_tier: dynu = dyndns2"
assert_eq "dyndns2" "$(ddns_provider_verify_tier desec)"  "ddns_provider_verify_tier: deSEC = dyndns2 (conservative)"
assert_eq "token"   "$(ddns_provider_verify_tier dynv6)"  "ddns_provider_verify_tier: dynv6 = token"
assert_eq "token"   "$(ddns_provider_verify_tier porkbun)" "ddns_provider_verify_tier: porkbun = token"

assert_eq "free" "$(ddns_provider_category duckdns)"    "ddns_provider_category: duckdns = free"
assert_eq "byo"  "$(ddns_provider_category cloudflare)" "ddns_provider_category: cloudflare = byo"
if ddns_provider_category nope >/dev/null 2>&1; then
    fail "ddns_provider_category: unknown key returns non-zero"
else
    pass "ddns_provider_category: unknown key returns non-zero"
fi

ui_choose() { printf '%s\n' "${STUB_CHOICE:-}"; }
STUB_CHOICE="${_DDNS_LABEL[0]}"   # DuckDNS (index 0 — the default free pick, #248)
assert_eq "duckdns" "$(ddns_provider_pick)" "ddns_provider_pick: maps free label to key"
STUB_CHOICE="${_DDNS_LABEL[4]}"   # Cloudflare
assert_eq "cloudflare" "$(ddns_provider_pick)" "ddns_provider_pick: maps BYO label to key"
STUB_CHOICE="$_DDNS_SKIP_LABEL"   # escape hatch
assert_eq "$_DDNS_SKIP" "$(ddns_provider_pick)" "ddns_provider_pick: skip escape hatch maps to the skip sentinel"

scenario_end "$CURRENT_SCENARIO"
summary
