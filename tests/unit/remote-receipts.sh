#!/usr/bin/env bash
# The shared recorder can run against the guest's Docker daemon without DinD.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin remote-receipts
TMP_DIR=$(mktemp -d)
trap '[[ ! -f "$TMP_DIR/recorder.pid" ]] || kill "$(cat "$TMP_DIR/recorder.pid")" 2>/dev/null || true; rm -rf "$TMP_DIR"' EXIT
mkdir "$TMP_DIR/bin"
cat >"$TMP_DIR/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    'events --format') exec sleep 300 ;;
    'volume create')
        printf '{"Type":"volume","Actor":{"ID":"%s"}}\n' "$3" >>"$RECEIPTS_EVENTS"
        ;;
    'volume rm') ;;
    'image inspect') printf '["jc21/nginx-proxy-manager@%s"]\n' "${MS_TEST_IMAGE_OVERRIDES##*@}" ;;
    *) exit 64 ;;
esac
SH
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"
export RECEIPTS_EVENTS="$TMP_DIR/events" RECEIPTS_PID="$TMP_DIR/recorder.pid"
RECEIPTS_LOCAL=1
RECEIPTS_TIMEOUT=2
RECEIPTS_FILE="$TMP_DIR/receipts"
MS_TEST_IMAGE_OVERRIDES="npm=jc21/nginx-proxy-manager:2@sha256:$(printf '1%.0s' {1..64})"
export MS_TEST_IMAGE_OVERRIDES
MS_TEST_RUN_ID=run-20261029T120000Z-12345678
RECEIPTS_PLAN_HASH="$(printf 'e%.0s' {1..64})"
source "$REPO_ROOT/tests/lib/receipts.sh"

# Given a guest-local recorder and an exact candidate override.
receipts_recorder_start
receipts_scenario_begin
cat >>"$RECEIPTS_EVENTS" <<EOF
{"Type":"container","Action":"create","Actor":{"ID":"candidate","Attributes":{"com.docker.compose.service":"npm","image":"${MS_TEST_IMAGE_OVERRIDES#*=}"}}}
{"Type":"container","Action":"start","Actor":{"ID":"candidate","Attributes":{"com.docker.compose.service":"npm","image":"${MS_TEST_IMAGE_OVERRIDES#*=}"}}}
EOF

# When all required checks pass on the locally recorded candidate.
receipts_scenario_end remote-gcp

# Then the shared verdict writes one v3 row with the full reviewed hash.
assert_eq 1 "$RECEIPTS_ACTIVE" 'guest-local recorder starts without a DinD container'
assert_eq 1 "$RECEIPTS_ROWS_WRITTEN" 'guest-local events and image inspection qualify the candidate'
assert_eq 9 "$(awk -F '\t' '!/^#/ {print NF}' "$RECEIPTS_FILE")" 'remote receipt has nine fields'
assert_eq "$RECEIPTS_PLAN_HASH" "$(awk -F '\t' '!/^#/ {print $8}' "$RECEIPTS_FILE")" 'remote receipt carries the full plan hash'

# Given the recorder stops before a new run with otherwise qualifying events.
kill "$(cat "$RECEIPTS_PID")"
wait "$(cat "$RECEIPTS_PID")" 2>/dev/null || true
RECEIPTS_RUN_ID=run-20261029T120000Z-87654321

# When another scenario tries to produce evidence.
receipts_scenario_begin
cat >>"$RECEIPTS_EVENTS" <<EOF
{"Type":"container","Action":"create","Actor":{"ID":"candidate-2","Attributes":{"com.docker.compose.service":"npm","image":"${MS_TEST_IMAGE_OVERRIDES#*=}"}}}
{"Type":"container","Action":"start","Actor":{"ID":"candidate-2","Attributes":{"com.docker.compose.service":"npm","image":"${MS_TEST_IMAGE_OVERRIDES#*=}"}}}
EOF
receipts_scenario_end remote-gcp

# Then a lost recorder cannot produce another receipt.
assert_eq 1 "$RECEIPTS_ROWS_WRITTEN" 'dead guest recorder produces no additional evidence'
summary
