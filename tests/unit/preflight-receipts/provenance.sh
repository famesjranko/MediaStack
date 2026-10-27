# tests/unit/preflight-receipts/provenance.sh
# Owns: the v2 row shape and provenance - header, eight columns, the source commit
# with its -dirty and unknown forms, and the run id (generated or MS_TEST_RUN_ID).
# Sourced by: tests/unit/preflight-receipts.sh, after evidence.sh.

# --- 14. provenance: every row names its source commit, run and host -------------------------
emit() { container s1 seerr "$SEERR@$D1" healthy; }
TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
RUN_ID_RE='^run-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'

# Given a clean checkout at a known commit, a fixed run id and Seerr run from the candidate
new_fixture "seerr=$SEERR@$D1"

# When the scenario passes
play fresh-install emit

# Then the new file opens with the v2 header
assert_eq "# MediaStack image preflight receipts v2" "$(head -1 "$RECEIPTS_FILE")" "receipts: a new file opens with the v2 header"
assert_eq "$(printf '# service\timage\tdigest\tscenario\tsource\trun_id\tarch\trecorded_at_utc')" "$(sed -n 2p "$RECEIPTS_FILE")" "receipts: a new file names its columns"
# And the row carries service, image, digest, scenario, source, run id and arch, in that order
assert_eq "$(row seerr "$SEERR" "$D1" fresh-install)" "$(rows)" "receipts: a row carries service, image, digest, scenario, source, run id and arch"
# And its eighth column is an ISO-8601 UTC timestamp
assert_eq "1" "$(grep -v '^#' "$RECEIPTS_FILE" | cut -f8 | grep -cE "$TS_RE")" "receipts: the eighth column is an ISO-8601 UTC timestamp"

# Given the checkout has an uncommitted or untracked change
new_fixture "seerr=$SEERR@$D1"
export STUB_GIT_DIRTY=1
MS_TEST_RUN_ID="$RUN_ID_FIXED" receipts_run_identity

# When the scenario passes
play fresh-install emit

# Then the source column is the commit with a -dirty suffix
assert_eq "$SHA_F-dirty" "$(rows | cut -f5)" "receipts: a dirty tree is recorded as <sha>-dirty"

# Given git is unavailable or the tree is not a repository
new_fixture "seerr=$SEERR@$D1"
export STUB_GIT_GONE=1
MS_TEST_RUN_ID="$RUN_ID_FIXED" receipts_run_identity

# When the scenario passes
play fresh-install emit

# Then the row is still written and its source column is unknown
assert_eq "unknown" "$(rows | cut -f5)" "receipts: no git records the source as unknown"

# Given a well-formed MS_TEST_RUN_ID in the environment and no recorder yet
new_fixture "seerr=$SEERR@$D1"
RECEIPTS_ACTIVE=0
RECEIPTS_RUN_ID=""

# When the run starts the recorder (in this shell, so the id it sets is visible; output via a file)
MS_TEST_RUN_ID="run-20260202T030405Z-deadbeef" receipts_recorder_start >"$TMP_DIR/out" 2>&1
OUT="$(cat "$TMP_DIR/out")"

# Then that id is the run's id and the run prints it
assert_eq "run-20260202T030405Z-deadbeef" "$RECEIPTS_RUN_ID" "receipts: a well-formed MS_TEST_RUN_ID overrides the generated run id"
assert_contains "$OUT" "[receipts] run id: run-20260202T030405Z-deadbeef" "receipts: the run prints its run id at start"

# Given a malformed MS_TEST_RUN_ID and no recorder yet
new_fixture "seerr=$SEERR@$D1"
RECEIPTS_ACTIVE=0

# When the run starts the recorder and a scenario passes
MS_TEST_RUN_ID="build 42" receipts_recorder_start >"$TMP_DIR/out" 2>&1
OUT="$(cat "$TMP_DIR/out")"
play fresh-install emit

# Then evidence stays off, the run says the id is malformed and no row is written
assert_eq "0" "$RECEIPTS_ACTIVE" "receipts: a malformed MS_TEST_RUN_ID earns no receipts"
assert_contains "$OUT" "MS_TEST_RUN_ID 'build 42' is malformed" "receipts: a malformed MS_TEST_RUN_ID is reported"
assert_eq "" "$(rows)" "receipts: a malformed MS_TEST_RUN_ID writes no row"

# Given no MS_TEST_RUN_ID and no recorder yet
new_fixture "seerr=$SEERR@$D1"
RECEIPTS_ACTIVE=0
RECEIPTS_RUN_ID=""
unset MS_TEST_RUN_ID

# When the run starts the recorder
receipts_recorder_start 2>/dev/null

# Then it generates an id of the documented shape
assert_eq "1" "$(grep -cE "$RUN_ID_RE" <<<"$RECEIPTS_RUN_ID")" "receipts: a generated run id has the documented shape"

# Given a candidate ran but one required assertion was skipped.
new_fixture "seerr=$SEERR@$D1"
receipts_scenario_begin
emit
saved_skips=$SKIP_COUNT
SKIP_COUNT=$((SKIP_COUNT + 1))

# When the scenario's evidence is recorded.
OUT=$(receipts_scenario_end fresh-install 2>&1)
SKIP_COUNT=$saved_skips

# Then a successful scenario exit cannot turn the skip into accepted evidence.
assert_eq '' "$(rows)" 'receipts: skipped assertions earn no receipt'
assert_contains "$OUT" 'required assertions skipped' 'receipts: skipped assertions are reported'
