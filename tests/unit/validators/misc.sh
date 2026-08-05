# Owns: Timezone and subtitle-language validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/misc.sh.

# ---------------------------------------------------------------------------
# Timezone validator
# ---------------------------------------------------------------------------
reset_warn
validate_timezone "Etc/UTC"
rc=$?
assert_eq "0" "$rc" "validate_timezone: accepts Etc/UTC"

reset_warn
validate_timezone "Not/A_Real_Timezone"
rc=$?
assert_eq "1" "$rc" "validate_timezone: rejects invalid timezone"
assert_eq "1" "$WARN_COUNT" "validate_timezone: invalid timezone warns once"

# tzdata metadata files (zone.tab, posixrules, ...) are -e but NOT
# valid TZ values. Glibc's tzset can't parse them and every timezone-aware
# container would silently misbehave. Validator must reject them with a
# useful "use a real zone like Etc/UTC" message.
if [[ -f /usr/share/zoneinfo/zone.tab ]]; then
    reset_warn
    validate_timezone "zone.tab"
    rc=$?
    assert_eq "1" "$rc" "validate_timezone: rejects zone.tab metadata file"
    assert_contains "$LAST_WARN" "metadata" "validate_timezone: metadata copy"
fi

# Directory leaf (e.g. 'Etc' on its own) is -e but is a directory,
# not a regular file. Switch to -f makes it fail with the standard
# "not found" message.
if [[ -d /usr/share/zoneinfo/Etc ]]; then
    reset_warn
    validate_timezone "Etc"
    rc=$?
    assert_eq "1" "$rc" "validate_timezone: rejects bare directory (Etc)"
fi

# ---------------------------------------------------------------------------
# Subtitle languages — reject typo'd / unsupported / empty input so
# Bazarr never silently ends up with zero languages. Validator lowercases each
# token internally to check, so capitalised input is accepted (the stage1 call
# site stores the lowercased value).
# ---------------------------------------------------------------------------
reset_warn
validate_subtitle_langs "english"
rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a single supported language"
assert_eq "0" "$WARN_COUNT" "validate_subtitle_langs: valid input emits no warn"

reset_warn
validate_subtitle_langs "english,spanish,french"
rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a comma list of supported languages"

reset_warn
validate_subtitle_langs "English, SPANISH"
rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts mixed-case (case-insensitive)"

reset_warn
validate_subtitle_langs "english,"
rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a trailing comma (empty token skipped)"

reset_warn
validate_subtitle_langs "klingon"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects an unsupported language"
assert_eq "1" "$WARN_COUNT" "validate_subtitle_langs: unsupported warns once"
assert_contains "$LAST_WARN" "klingon" "validate_subtitle_langs: warn names the bad token"
assert_contains "$LAST_WARN" "Supported" "validate_subtitle_langs: warn lists the supported set"

reset_warn
validate_subtitle_langs "englsih"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects a typo'd language"

reset_warn
validate_subtitle_langs "english,klingon"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects when one token of several is bad"
assert_contains "$LAST_WARN" "klingon" "validate_subtitle_langs: warn names only the bad token"

reset_warn
validate_subtitle_langs ""
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects empty input"
assert_eq "1" "$WARN_COUNT" "validate_subtitle_langs: empty warns once"

reset_warn
validate_subtitle_langs ",,,"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects commas-only (zero real tokens)"

reset_warn
validate_subtitle_langs "   "
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects whitespace-only input"

reset_warn
validate_subtitle_langs "english spanish"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects space-separated (one bad token, only comma splits)"

# Whole-word membership: a substring of a supported key must NOT pass.
reset_warn
validate_subtitle_langs "dan"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: 'dan' does not match 'danish'"

# Drift guard: the validator's supported set must equal Bazarr's LANG_MAP keys.
# Extract the 19 keys with an anchored grep (matches '    'english':    {'code2'),
# which avoids the unrelated quoted tokens elsewhere in the file (code2/code3/en).
LANG_MAP_KEYS=$(grep -oP "^\s+'\K[a-z]+(?=':\s+\{'code2')" \
    "$REPO_ROOT/scripts/services/bazarr/main.sh")
LANG_MAP_COUNT=$(printf '%s\n' "$LANG_MAP_KEYS" | grep -c .)
assert_eq "19" "$LANG_MAP_COUNT" "validate_subtitle_langs (drift): LANG_MAP has 19 keys"
while IFS= read -r _key; do
    [[ -z "$_key" ]] && continue
    reset_warn
    validate_subtitle_langs "$_key"
    rc=$?
    assert_eq "0" "$rc" "validate_subtitle_langs (drift): accepts LANG_MAP key '$_key'"
done <<<"$LANG_MAP_KEYS"

# Bidirectional set-equality: the validator's own `supported` set must equal the
# LANG_MAP keys exactly — both directions. The per-key loop above only proves the
# validator accepts every LANG_MAP key (superset); this also catches a future
# EXTRA entry in validators.sh that LANG_MAP lacks, which would silently
# reintroduce the zero-language drop for that word.
LANG_MAP_SET=$(printf '%s\n' "$LANG_MAP_KEYS" | sort -u | paste -sd, -)
VALIDATOR_SET=$(grep -oP 'local supported="\K[^"]+' \
    "$REPO_ROOT/scripts/lib/validators/misc.sh" | tr ' ' '\n' | sort -u | paste -sd, -)
assert_eq "$LANG_MAP_SET" "$VALIDATOR_SET" \
    "validate_subtitle_langs (drift): validator set == LANG_MAP keys exactly (both directions)"

reset_warn
validate_subtitle_langs "zzznotalang"
rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs (drift): rejects a non-LANG_MAP sentinel"

