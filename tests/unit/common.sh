#!/usr/bin/env bash
# tests/unit/common.sh
#
# Focused unit coverage for shared helpers in scripts/lib/common.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="common"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

SCRIPT_DIR="$TMP_DIR"
CONFIG_FILE="$TMP_DIR/config.yml"
touch "$CONFIG_FILE"

source "$REPO_ROOT/scripts/lib/common.sh"

LAST_WARN=""
log_ok() { :; }
log_info() { :; }
log_warn() { LAST_WARN="$1"; }
log_skip() { :; }
log_error() { :; }

assert_eq "8096" "$(service_http_port jellyfin)" "service_http_port: Jellyfin HTTP port"
assert_eq "http://localhost:8096" "$(service_local_url jellyfin)" "service_local_url: Jellyfin local URL"
assert_eq "http://jellyfin:8096" "$(service_internal_url jellyfin)" "service_internal_url: Jellyfin internal URL"
assert_eq "81" "$(service_http_port npm)" "service_http_port: NPM admin API port"
if service_http_port unpackerr >/dev/null 2>&1; then
    fail "service_http_port: non-HTTP service returns non-zero"
else
    pass "service_http_port: non-HTTP service returns non-zero"
fi
ports_json=$(service_http_ports_json)
assert_eq "8989" "$(printf '%s' "$ports_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sonarr"])')" \
    "service_http_ports_json: includes Sonarr port"
urls_json=$(service_internal_urls_json)
assert_eq "http://uptime-kuma:3001" "$(printf '%s' "$urls_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["uptime-kuma"])')" \
    "service_internal_urls_json: includes Uptime Kuma URL"

reset_env() {
    printf '%s\n' \
        "TEST_API_KEY=old" \
        "OTHER_KEY=keep" \
        >"$SCRIPT_DIR/.env"
    chmod 600 "$SCRIPT_DIR/.env"
    unset TEST_API_KEY NEW_API_KEY
    LAST_WARN=""
}

source_env_value() {
    local env_path="$1" key="$2"
    (
        set -a
        # shellcheck source=/dev/null
        source "$env_path"
        set +a
        printf '%s' "${!key:-}"
    )
}

reset_env
special_value='abc&def|ghi/jkl'
env_save_api_key TEST_API_KEY "$special_value"
rc=$?
assert_eq "0" "$rc" "env_save_api_key: special value write succeeds"
assert_eq "TEST_API_KEY='$special_value'" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "env_save_api_key: quotes ampersand pipe and slash value"
assert_eq "$special_value" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "env_save_api_key: written special value is sourceable"
assert_eq "$special_value" "${TEST_API_KEY:-}" "env_save_api_key: exports updated value"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "env_save_api_key: preserves unrelated lines"

append_value='https://jellyfin.example.test/a/b?x=1&y=2'
env_save_api_key NEW_API_KEY "$append_value"
rc=$?
assert_eq "0" "$rc" "env_save_api_key: append succeeds"
assert_eq "NEW_API_KEY='$append_value'" "$(grep '^NEW_API_KEY=' "$SCRIPT_DIR/.env")" "env_save_api_key: appends quoted missing key"
assert_eq "$append_value" "$(source_env_value "$SCRIPT_DIR/.env" NEW_API_KEY)" "env_save_api_key: appended value is sourceable"

reset_env
same_value='abc&def|ghi/jkl'
printf '%s\n' "TEST_API_KEY=$same_value" "OTHER_KEY=keep" >"$SCRIPT_DIR/.env"
env_save_api_key TEST_API_KEY "$same_value"
rc=$?
assert_eq "0" "$rc" "env_save_api_key: canonicalizes existing unquoted value"
assert_eq "TEST_API_KEY='$same_value'" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "env_save_api_key: rewrites existing match as quoted"

reset_env
before=$(<"$SCRIPT_DIR/.env")
env_save_api_key TEST_API_KEY $'bad\nvalue' >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "env_save_api_key: rejects newline values"
assert_eq "$before" "$after" "env_save_api_key: preserves .env on newline rejection"
assert_eq "" "${TEST_API_KEY:-}" "env_save_api_key: rejected newline value is not exported"
assert_contains "$LAST_WARN" "contains a newline" "env_save_api_key: newline rejection warns"

reset_env
before=$(<"$SCRIPT_DIR/.env")
env_save_api_key TEST_API_KEY "bad'value" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "env_save_api_key: rejects single quote values"
assert_eq "$before" "$after" "env_save_api_key: preserves .env on single quote rejection"
assert_eq "" "${TEST_API_KEY:-}" "env_save_api_key: rejected quote value is not exported"
assert_contains "$LAST_WARN" "single quote" "env_save_api_key: single quote rejection warns"

# ---------------------------------------------------------------------------
# _set_env_var (the launcher's .env writer) — must round-trip nasty values
# byte-exact through a re-source and never disturb unrelated keys. It shares
# the one hardened writer with env_save_api_key, so the same quoting/atomic
# guarantees apply.
# ---------------------------------------------------------------------------
# Stand in the launcher's shoes: it defines _set_env_var inline, so mirror the
# exact current body here pointed at the same shared writer, then exercise it.
_set_env_var() {
    local key="$1" val="$2" file="$SCRIPT_DIR/.env" status
    [[ -f "$file" ]] || return 1
    if ! status=$(_env_write_kv "$file" "$key" "$val"); then
        _env_write_kv_warn "$key" "$status"
        return 1
    fi
}

# A battery of values that an unquoted writer would corrupt or mis-parse.
declare -a NASTY_VALUES=(
    'plain'
    'has spaces here'
    'with"double'
    'dollar$VAR and ${BRACE}'
    'back\slash'
    'hash # mark'
    'equals=sign=here'
    '  leading and trailing  '
    'mix "q" $x \\ # = end'
)
for nasty in "${NASTY_VALUES[@]}"; do
    reset_env
    _set_env_var ROUND_TRIP "$nasty"
    rc=$?
    assert_eq "0" "$rc" "_set_env_var: write succeeds [$nasty]"
    got=$(source_env_value "$SCRIPT_DIR/.env" ROUND_TRIP)
    assert_eq "$nasty" "$got" "_set_env_var: round-trips byte-exact [$nasty]"
    # The pre-existing, unrelated key must survive every write untouched.
    assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: leaves OTHER_KEY untouched [$nasty]"
    assert_eq "TEST_API_KEY=old" "$(grep '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: leaves TEST_API_KEY untouched [$nasty]"
done

# Replace-in-place: re-writing an existing key updates only that line.
reset_env
_set_env_var TEST_API_KEY 'a b $c'
assert_eq "a b \$c" "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "_set_env_var: replaces an existing key's value"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: replace leaves unrelated key untouched"
assert_eq "1" "$(grep -c '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: replace does not duplicate the key"

# Append-if-absent: a missing key is added without touching existing lines.
reset_env
_set_env_var BRAND_NEW 'appended value'
assert_eq "appended value" "$(source_env_value "$SCRIPT_DIR/.env" BRAND_NEW)" "_set_env_var: appends a missing key"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_set_env_var: append leaves unrelated key untouched"

# Refusal path: a single quote / newline is rejected and the file is untouched.
reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_var BAD_VAL "has'quote" >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_var: rejects single-quote value"
assert_eq "$before" "$after" "_set_env_var: preserves .env on single-quote rejection"

reset_env
before=$(<"$SCRIPT_DIR/.env")
_set_env_var BAD_VAL $'has\nnewline' >/dev/null 2>&1
rc=$?
after=$(<"$SCRIPT_DIR/.env")
assert_eq "1" "$rc" "_set_env_var: rejects newline value"
assert_eq "$before" "$after" "_set_env_var: preserves .env on newline rejection"

# Missing .env: write is a no-op failure, not a crash.
reset_env
rm -f "$SCRIPT_DIR/.env"
_set_env_var ANY value >/dev/null 2>&1
assert_eq "1" "$?" "_set_env_var: returns non-zero when .env is absent"

# ---------------------------------------------------------------------------
# _env_write_kv MAP mode — several key->value pairs applied in ONE atomic
# write. Backs storage_env_set + the stage2/stage3 .env rewriters:
# one replace + two appends, idempotence, mode preservation, and all-or-nothing
# refusal when any pair is bad.
# ---------------------------------------------------------------------------
reset_env
chmod 640 "$SCRIPT_DIR/.env" # non-default mode must survive the write
map_status=$(_env_write_kv "$SCRIPT_DIR/.env" \
    TEST_API_KEY 'a b $c' \
    BRAND_NEW 'appended #1' \
    THIRD_KEY 'x=y')
map_rc=$?
assert_eq "0" "$map_rc" "_env_write_kv map: write succeeds"
assert_eq "changed" "$map_status" "_env_write_kv map: reports changed"
assert_eq 'a b $c' "$(source_env_value "$SCRIPT_DIR/.env" TEST_API_KEY)" "_env_write_kv map: replaces existing key"
assert_eq 'appended #1' "$(source_env_value "$SCRIPT_DIR/.env" BRAND_NEW)" "_env_write_kv map: appends first missing key"
assert_eq 'x=y' "$(source_env_value "$SCRIPT_DIR/.env" THIRD_KEY)" "_env_write_kv map: appends second missing key"
assert_eq "OTHER_KEY=keep" "$(grep '^OTHER_KEY=' "$SCRIPT_DIR/.env")" "_env_write_kv map: leaves unrelated key untouched"
assert_eq "1" "$(grep -c '^TEST_API_KEY=' "$SCRIPT_DIR/.env")" "_env_write_kv map: does not duplicate the replaced key"
assert_eq "640" "$(stat -c '%a' "$SCRIPT_DIR/.env")" "_env_write_kv map: preserves the file mode"

# Idempotence: re-applying the same map changes nothing.
map_status=$(_env_write_kv "$SCRIPT_DIR/.env" \
    TEST_API_KEY 'a b $c' \
    BRAND_NEW 'appended #1' \
    THIRD_KEY 'x=y')
assert_eq "0" "$?" "_env_write_kv map: idempotent re-run succeeds"
assert_eq "unchanged" "$map_status" "_env_write_kv map: idempotent re-run reports unchanged"

# Atomicity: one bad value in the batch refuses the WHOLE write.
reset_env
map_before=$(<"$SCRIPT_DIR/.env")
map_status=$(_env_write_kv "$SCRIPT_DIR/.env" GOOD_KEY good BAD_KEY "has'quote")
map_rc=$?
if [[ "$map_rc" -ne 0 ]]; then
    pass "_env_write_kv map: non-zero rc when any pair is bad"
else
    fail "_env_write_kv map: non-zero rc when any pair is bad" "rc=$map_rc"
fi
assert_eq "invalid-quote" "$map_status" "_env_write_kv map: reports invalid-quote"
assert_eq "$map_before" "$(<"$SCRIPT_DIR/.env")" "_env_write_kv map: leaves .env untouched when a pair is refused"
assert_eq "" "$(grep '^GOOD_KEY=' "$SCRIPT_DIR/.env" || true)" "_env_write_kv map: the valid pair is NOT written when the batch is refused"

# ---------------------------------------------------------------------------
# cfg_read + the cfg_* adapters — one parametrised YAML reader. The service
# unit suites STUB these by name, so the real reader python is only exercised
# here (and in the live api-matrix tier). Assert every mode byte-exact against
# a fixture, plus the absent-key / empty-config edges.
# ---------------------------------------------------------------------------
CFG_FIXTURE="$TMP_DIR/cfg-fixture.yml"
cat >"$CFG_FIXTURE" <<'YAML'
categories:
  tv: "5000,5030,5040"
min_free_space_gb: 20
quality_profile:
  upgrade_allowed: true
  sonarr_qualities:
    - 1
    - 2
    - 3
quality_definitions:
  sonarr:
    SDTV: { min: 1.0, preferred: 8.0, max: 25.0 }
custom_formats:
  "Repack/Proper": 5
  "x264": 0
qbittorrent:
  categories:
    tv-sonarr: "/data/torrents/tv"
    radarr: "/data/torrents/movies"
bazarr:
  languages:
    - english
    - spanish
jellyfin:
  libraries:
    - name: "Movies"
      type: "movies"
      path: "/data/media/movies"
    - name: "TV Shows"
      type: "tvshows"
      path: "/data/media/tv"
indexers:
  - id: "1234"
    type: tv
  - id: "5678"
YAML

CONFIG_FILE="$CFG_FIXTURE"

assert_eq "5000,5030,5040" "$(cfg_field categories.tv)" "cfg_field: scalar string leaf"
assert_eq "True" "$(cfg_field quality_profile.upgrade_allowed)" "cfg_field: YAML bool prints Python True"
assert_eq "20" "$(cfg_field min_free_space_gb)" "cfg_field: integer leaf"
assert_eq "[1, 2, 3]" "$(cfg_quality_ids sonarr)" "cfg_quality_ids: JSON array"
assert_eq '{"SDTV": {"min": 1.0, "preferred": 8.0, "max": 25.0}}' "$(cfg_quality_definitions sonarr)" "cfg_quality_definitions: nested JSON object"
assert_eq "{}" "$(cfg_quality_definitions radarr)" "cfg_quality_definitions: absent app -> {}"
assert_eq '{"Repack/Proper": 5, "x264": 0}' "$(cfg_custom_format_scores)" "cfg_custom_format_scores: name->score JSON"
assert_eq $'tv-sonarr:/data/torrents/tv\nradarr:/data/torrents/movies' "$(cfg_qbt_categories)" "cfg_qbt_categories: name:path pairs"
assert_eq $'english\nspanish' "$(cfg_bazarr_languages)" "cfg_bazarr_languages: one per line (list value)"
assert_eq $'Movies:movies:/data/media/movies\nTV Shows:tvshows:/data/media/tv' "$(cfg_jf_libraries)" "cfg_jf_libraries: name:type:path"
assert_eq $'1234:tv\n5678:general' "$(cfg_indexers)" "cfg_indexers: id:type, missing type -> general"

# Absent key: non-zero rc so `cfg_field ... || echo DEFAULT` fallbacks fire.
missing=$(cfg_field no.such.key 2>/dev/null || echo "FELLBACK")
assert_eq "FELLBACK" "$missing" "cfg_field: absent key returns non-zero (fallback fires)"

# Empty config: the json-default readers still yield {} (not a crash / empty).
: >"$TMP_DIR/empty.yml"
assert_eq "{}" "$(CONFIG_FILE="$TMP_DIR/empty.yml" cfg_custom_format_scores)" "cfg_custom_format_scores: empty config -> {}"
assert_eq "{}" "$(CONFIG_FILE="$TMP_DIR/empty.yml" cfg_quality_definitions sonarr)" "cfg_quality_definitions: empty config -> {}"

# Absent bazarr.languages: empty output + rc 0 (the old .get-chain contract).
if bl=$(CONFIG_FILE="$TMP_DIR/empty.yml" cfg_bazarr_languages 2>/dev/null); then
    assert_eq "" "$bl" "cfg_bazarr_languages: absent key -> empty, rc 0"
else
    fail "cfg_bazarr_languages: absent key -> empty, rc 0" "returned non-zero rc"
fi

# Present-but-null languages key (user deleted all list items): same
# empty + rc 0 contract, never a literal "None" for the profile builder.
printf 'bazarr:\n  languages:\n' >"$TMP_DIR/null-langs.yml"
if bl=$(CONFIG_FILE="$TMP_DIR/null-langs.yml" cfg_bazarr_languages 2>/dev/null); then
    assert_eq "" "$bl" "cfg_bazarr_languages: present-but-null key -> empty, rc 0"
else
    fail "cfg_bazarr_languages: present-but-null key -> empty, rc 0" "returned non-zero rc"
fi

# A null/non-string category path fails the whole pairs read (rc 1, matching
# the old reader's TypeError) instead of emitting "name:None".
cat >"$TMP_DIR/bad-cats.yml" <<'YAML'
qbittorrent:
  categories:
    tv-sonarr:
    radarr: "/data/torrents/movies"
YAML
if bad_pairs=$(CONFIG_FILE="$TMP_DIR/bad-cats.yml" cfg_qbt_categories 2>/dev/null); then
    fail "cfg_qbt_categories: null path -> rc 1 (never name:None)" "rc 0, output: $bad_pairs"
else
    pass "cfg_qbt_categories: null path -> rc 1 (never name:None)"
fi

scenario_end "$CURRENT_SCENARIO"
summary
