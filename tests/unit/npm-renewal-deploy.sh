#!/usr/bin/env bash
# The deploy hook must validate configuration and surface either command's failure.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin npm-renewal-deploy

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/nginx" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NPM_TEST_COMMAND_LOG"
if [[ "$1" == "-t" ]]; then
    exit "$NPM_TEST_VALIDATE_RC"
fi
exit "$NPM_TEST_RELOAD_RC"
SH
chmod +x "$TMP_DIR/bin/nginx"
export PATH="$TMP_DIR/bin:$PATH"
export NPM_TEST_COMMAND_LOG="$TMP_DIR/commands"
export NPM_TEST_VALIDATE_RC=0 NPM_TEST_RELOAD_RC=0
HOOK="$REPO_ROOT/scripts/services/npm/renewal-deploy.sh"

# Given nginx has a valid configuration.
: >"$NPM_TEST_COMMAND_LOG"

# When Certbot executes the deployed hook.
run_cmd "$HOOK"

# Then the hook validates nginx before reloading it and succeeds.
assert_rc 0 "a valid configuration reloads successfully"
assert_eq $'-t\n-s reload' "$(cat "$NPM_TEST_COMMAND_LOG")" "validation precedes reload"

# Given nginx configuration validation fails.
export NPM_TEST_VALIDATE_RC=1
: >"$NPM_TEST_COMMAND_LOG"

# When Certbot executes the deployed hook.
run_cmd "$HOOK"

# Then the hook fails without signalling nginx to reload.
assert_rc 1 "invalid nginx configuration fails the hook"
assert_eq '-t' "$(cat "$NPM_TEST_COMMAND_LOG")" "invalid configuration prevents reload"

# Given configuration is valid but nginx refuses the reload.
export NPM_TEST_VALIDATE_RC=0 NPM_TEST_RELOAD_RC=1
: >"$NPM_TEST_COMMAND_LOG"

# When Certbot executes the deployed hook.
run_cmd "$HOOK"

# Then the hook reports failure after attempting the reload.
assert_rc 1 "reload failure fails the hook"
assert_eq $'-t\n-s reload' "$(cat "$NPM_TEST_COMMAND_LOG")" "reload was attempted after validation"

summary
