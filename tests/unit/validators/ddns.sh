# Owns: DDNS credential/token/zone-ID validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/ddns.sh.

# ---------------------------------------------------------------------------
# DDNS credential validator
# ---------------------------------------------------------------------------
reset_warn
validate_ddns_credential "Dynu password" "dynu-secret"
rc=$?
assert_eq "0" "$rc" "validate_ddns_credential: accepts a normal DDNS credential"

reset_warn
validate_ddns_credential "Dynu password" 'secret with $ and \ and " chars'
rc=$?
assert_eq "0" "$rc" "validate_ddns_credential: accepts shell-special chars except single quote"

reset_warn
validate_ddns_credential "Dynu password" "bad'quote"
rc=$?
assert_eq "1" "$rc" "validate_ddns_credential: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_ddns_credential: single-quote copy"

# ---------------------------------------------------------------------------
# Multi-provider DDNS field validators
# ---------------------------------------------------------------------------
# Opaque secret validators (token / api_key): required, contiguous, .env-safe.
for v in validate_ddns_token validate_api_key; do
    reset_warn
    "$v" "abc123_TOKEN-value"
    rc=$?
    assert_eq "0" "$rc" "$v: accepts a normal opaque secret"
    assert_eq "0" "$WARN_COUNT" "$v: valid secret emits no warn"

    reset_warn
    "$v" $'  abc123_TOKEN-value \n'
    rc=$?
    assert_eq "0" "$rc" "$v: trims surrounding whitespace from a dashboard paste"
    assert_eq "0" "$WARN_COUNT" "$v: pasted surrounding whitespace emits no warn"

    reset_warn
    "$v" ""
    rc=$?
    assert_eq "1" "$rc" "$v: rejects empty"

    reset_warn
    "$v" "   "
    rc=$?
    assert_eq "1" "$rc" "$v: rejects whitespace-only"

    reset_warn
    "$v" "has space"
    rc=$?
    assert_eq "1" "$rc" "$v: rejects internal space (paste error)"
    assert_contains "$LAST_WARN" "space" "$v: space copy"

    reset_warn
    "$v" "bad'quote"
    rc=$?
    assert_eq "1" "$rc" "$v: rejects single quote"
    assert_contains "$LAST_WARN" "single quote" "$v: single-quote copy"
done

# Cloudflare Zone ID: exactly 32 hex chars.
reset_warn
validate_zone_id "0123456789abcdef0123456789abcdef"
rc=$?
assert_eq "0" "$rc" "validate_zone_id: accepts 32 lowercase hex"

reset_warn
validate_zone_id "0123456789ABCDEF0123456789ABCDEF"
rc=$?
assert_eq "0" "$rc" "validate_zone_id: accepts 32 uppercase hex"

reset_warn
validate_zone_id $'  0123456789abcdef0123456789abcdef \n'
rc=$?
assert_eq "0" "$rc" "validate_zone_id: trims surrounding whitespace from a paste"

reset_warn
validate_zone_id ""
rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects empty"

reset_warn
validate_zone_id "0123456789abcdef"
rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects too-short (16 hex)"
assert_contains "$LAST_WARN" "32 hex" "validate_zone_id: length copy"

reset_warn
validate_zone_id "0123456789abcdef0123456789abcdeg"
rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects non-hex character"

