#!/usr/bin/env bash
# tests/unit/image-drift-receipts.sh
#
# Unit test - scripts/image_drift.py receipt provenance (v2 rows): an accept takes
# only a receipt recorded from the commit it names (never a -dirty or unknown
# source) and, when run ids are given, from one of those runs; legacy rows never
# vouch; a `scenario:X+Y` token needs one receipt per scenario; a selective accept
# leaves every other lock row byte-identical; and --preflight-plan groups drifted
# services by the scenario each needs. The basic gate (no receipt, wrong scenario,
# bypass, non-scenario tiers) is in tests/unit/image-drift.sh.
# Pure bash + python3 - no Docker, no network, no git.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="image-drift-receipts"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

DRIFT="python3 $REPO_ROOT/scripts/image_drift.py"
SHA_A="sha256:$(printf 'a%.0s' {1..64})" # sonarr previous
SHA_B="sha256:$(printf 'b%.0s' {1..64})" # radarr previous
SHA_C="sha256:$(printf 'c%.0s' {1..64})" # sonarr current (drifted)
SHA_D="sha256:$(printf 'd%.0s' {1..64})" # radarr current (drifted)
SHA_E="sha256:$(printf 'e%.0s' {1..64})" # jackett (unchanged)
SHA_F="sha256:$(printf 'f%.0s' {1..64})" # autoheal previous
SHA_G="sha256:$(printf '9%.0s' {1..64})" # autoheal current (drifted)
SHA_H="sha256:$(printf '8%.0s' {1..64})" # demo previous
SHA_I="sha256:$(printf '7%.0s' {1..64})" # demo current (drifted)
SRC="$(printf '1%.0s' {1..40})"          # the commit the accept runs against
OTHER="$(printf '2%.0s' {1..40})"        # some other commit
RUN_OK="run-20260101T000000Z-0badcafe"
RUN_OTHER="run-20251231T000000Z-feedface"

{
    printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n'
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t2020-01-01T00:00:00Z\tscenario:fresh-install\n' "$SHA_A"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\t2020-02-02T00:00:00Z\tscenario:fresh-install\n' "$SHA_B"
    printf 'jackett\tlinuxserver/jackett:latest\t%s\t2020-03-03T00:00:00Z\tscenario:fresh-install\n' "$SHA_E"
    printf 'autoheal\twillfarrell/autoheal:latest\t%s\t2020-04-04T00:00:00Z\tscenario:fresh-install+autoheal\n' "$SHA_F"
    printf 'demo\texample/demo:latest\t%s\t2020-05-05T00:00:00Z\tcompose-only\n' "$SHA_H"
} >"$TMP_DIR/previous.tsv"
{
    printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n'
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_C"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_D"
    printf 'jackett\tlinuxserver/jackett:latest\t%s\t\tscenario:fresh-install\n' "$SHA_E"
    printf 'autoheal\twillfarrell/autoheal:latest\t%s\t\tscenario:fresh-install+autoheal\n' "$SHA_G"
    printf 'demo\texample/demo:latest\t%s\t\tcompose-only\n' "$SHA_I"
} >"$TMP_DIR/current.tsv"
cat >"$TMP_DIR/upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| sonarr | latest | stable | scenario:fresh-install | x |
| radarr | latest | stable | scenario:fresh-install | x |
| jackett | latest | stable | scenario:fresh-install | x |
| autoheal | latest | stable | scenario:fresh-install+autoheal | x |
| demo | latest | stable | compose-only | x |
<!-- upgrades-manifest:end -->
EOF
base=(--previous "$TMP_DIR/previous.tsv" --upgrades "$TMP_DIR/upgrades.md" --current-file "$TMP_DIR/current.tsv")
receipt="$TMP_DIR/receipt.tsv"

# receipt_row <service> <image> <digest> <scenario> [source] [run_id]: one v2 row.
receipt_row() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\tx86_64\t2026-01-01T00:00:00Z\n' "$1" "$2" "$3" "$4" "${5:-$SRC}" "${6:-$RUN_OK}"
}
# accept_sonarr <out-lock> [extra args...]: selective accept of the drifted sonarr row.
accept_sonarr() {
    local out="$1"
    shift
    $DRIFT "${base[@]}" --write-current "$out" --preflight-receipt "$receipt" \
        --accept-services sonarr --tested-at 2026-06-01T00:00:00Z "$@" 2>&1
}

# --- legacy rows -------------------------------------------------------------
# Given the receipt file holds only a legacy four-column row that matches the drifted digest
printf 'sonarr\tlinuxserver/sonarr:latest\t%s\tfresh-install\n' "$SHA_C" >"$receipt"

# When sonarr is accepted at the expected source
output=$(accept_sonarr "$TMP_DIR/legacy.tsv" --receipt-source "$SRC")
rc=$?

# Then the accept is refused as having no receipt, the lock is not written, and one line counts the ignored rows and names the file
assert_eq "1" "$rc" "image-drift-receipts: a legacy four-column row does not vouch"
assert_contains "$output" "sonarr: no passing preflight receipt" "image-drift-receipts: a legacy row reads as no receipt"
assert_file_absent "$TMP_DIR/legacy.tsv" "image-drift-receipts: a legacy row leaves the lock unwritten"
assert_contains "$output" "ignored 1 legacy or malformed receipt row(s) in $receipt" "image-drift-receipts: ignored legacy rows are counted and the file named"

# --- source binding ------------------------------------------------------------
# Given a matching v2 receipt recorded from another commit
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install "$OTHER" >"$receipt"

# When sonarr is accepted at the expected source
output=$(accept_sonarr "$TMP_DIR/other.tsv" --receipt-source "$SRC")
rc=$?

# Then the accept is refused and the message prints both short commits
assert_eq "1" "$rc" "image-drift-receipts: a receipt from another commit does not vouch"
assert_contains "$output" "receipt is from commit ${OTHER:0:12}, not ${SRC:0:12}" "image-drift-receipts: a source mismatch names both commits"
assert_file_absent "$TMP_DIR/other.tsv" "image-drift-receipts: a source mismatch leaves the lock unwritten"

# Given a matching v2 receipt recorded from a dirty tree at the expected commit
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install "$SRC-dirty" >"$receipt"

# When sonarr is accepted at the expected source
output=$(accept_sonarr "$TMP_DIR/dirty.tsv" --receipt-source "$SRC")
rc=$?

# Then the accept is refused and the message says the tree was dirty
assert_eq "1" "$rc" "image-drift-receipts: a receipt from a dirty tree does not vouch"
assert_contains "$output" "recorded from a dirty tree (${SRC:0:12}-dirty)" "image-drift-receipts: a dirty source is named as dirty"

# Given a matching v2 receipt whose source is unknown (recorded without git)
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install unknown >"$receipt"

# When sonarr is accepted at the expected source
output=$(accept_sonarr "$TMP_DIR/unknown.tsv" --receipt-source "$SRC")
rc=$?

# Then the accept is refused and the message says the source is unknown
assert_eq "1" "$rc" "image-drift-receipts: a receipt with an unknown source does not vouch"
assert_contains "$output" "receipt source is unknown" "image-drift-receipts: an unknown source is named as unknown"

# Given a matching v2 receipt from the expected commit, and a lock outside any git repository
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install >"$receipt"

# When sonarr is accepted without --receipt-source
output=$(cd / && accept_sonarr "$TMP_DIR/nosource.tsv")
rc=$?

# Then the accept is refused because the expected source cannot be resolved
assert_eq "1" "$rc" "image-drift-receipts: an unresolvable expected source refuses the accept"
assert_contains "$output" "cannot resolve the expected source commit (pass --receipt-source" "image-drift-receipts: an unresolvable source says what to pass"

# --- run-id binding -------------------------------------------------------------
# Given a matching v2 receipt from the expected commit but from run RUN_OTHER
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install "$SRC" "$RUN_OTHER" >"$receipt"

# When sonarr is accepted with only RUN_OK allowed
output=$(accept_sonarr "$TMP_DIR/run.tsv" --receipt-source "$SRC" --receipt-run-id "$RUN_OK")
rc=$?

# Then the accept is refused and the message names the receipt's run and the allowed set
assert_eq "1" "$rc" "image-drift-receipts: a receipt from a run outside --receipt-run-id does not vouch"
assert_contains "$output" "receipt is from run $RUN_OTHER, outside the allowed run id(s) $RUN_OK" "image-drift-receipts: a run mismatch names both runs"

# --- a qualifying receipt -------------------------------------------------------
# Given a matching v2 receipt from the expected commit and run, beside unrelated rows
{
    receipt_row radarr linuxserver/radarr:latest "$SHA_D" fresh-install "$OTHER"
    receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install "$SRC" "$RUN_OK"
} >"$receipt"

# When sonarr is accepted at that source with that run allowed
output=$(accept_sonarr "$TMP_DIR/ok.tsv" --receipt-source "$SRC" --receipt-run-id "$RUN_OTHER,$RUN_OK")
rc=$?

# Then the accept succeeds and writes the drifted sonarr row
assert_eq "0" "$rc" "image-drift-receipts: a matching v2 receipt vouches"
assert_contains "$output" "Selectively accepted drifted services: sonarr" "image-drift-receipts: a vouched accept reports the service"
assert_file_contains "$TMP_DIR/ok.tsv" "$(printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t2026-06-01T00:00:00Z\tscenario:fresh-install' "$SHA_C")" "image-drift-receipts: a vouched accept writes the drifted row"
# And every other lock row, timestamp included, is byte-identical to the previous lock
assert_eq "$(grep -v '^#' "$TMP_DIR/previous.tsv" | grep -v '^sonarr')" "$(grep -v '^#' "$TMP_DIR/ok.tsv" | grep -v '^sonarr')" "image-drift-receipts: unrelated rows and timestamps are byte-identical after a selective accept"

# --- scenario:X+Y needs every scenario -------------------------------------------
# Given autoheal (scenario:fresh-install+autoheal) has a receipt from fresh-install only
receipt_row autoheal willfarrell/autoheal:latest "$SHA_G" fresh-install >"$receipt"

# When autoheal is accepted at the expected source
output=$($DRIFT "${base[@]}" --write-current "$TMP_DIR/plus-x.tsv" --preflight-receipt "$receipt" \
    --receipt-source "$SRC" --accept-services autoheal 2>&1)
rc=$?

# Then the accept is refused, names the missing autoheal scenario and prints its run command
assert_eq "1" "$rc" "image-drift-receipts: a + token with one receipt of two is refused"
assert_contains "$output" "autoheal: receipt exists only for scenario fresh-install, not autoheal for willfarrell/autoheal:latest@$SHA_G (autoheal)" "image-drift-receipts: the missing scenario of a + token is named"
assert_contains "$output" "./tests/run.sh autoheal" "image-drift-receipts: the missing scenario's run command is printed"
assert_not_contains "$output" "./tests/run.sh fresh-install" "image-drift-receipts: the satisfied scenario of a + token is not reported"

# Given autoheal has a receipt from each of its two scenarios
{
    receipt_row autoheal willfarrell/autoheal:latest "$SHA_G" fresh-install
    receipt_row autoheal willfarrell/autoheal:latest "$SHA_G" autoheal
} >"$receipt"

# When autoheal is accepted at the expected source
output=$($DRIFT "${base[@]}" --write-current "$TMP_DIR/plus-ok.tsv" --preflight-receipt "$receipt" \
    --receipt-source "$SRC" --accept-services autoheal --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?

# Then the accept succeeds
assert_eq "0" "$rc" "image-drift-receipts: a + token with a receipt per scenario is accepted"
assert_file_contains "$TMP_DIR/plus-ok.tsv" "$(printf 'autoheal\twillfarrell/autoheal:latest\t%s\t2026-06-01T00:00:00Z\tscenario:fresh-install+autoheal' "$SHA_G")" "image-drift-receipts: a + token accept writes the drifted row with its token"

# Given the drift summary is requested for the same snapshot
# When the summary is rendered
output=$($DRIFT "${base[@]}" 2>&1)
rc=$?

# Then the autoheal row offers one preflight command per scenario
assert_eq "2" "$rc" "image-drift-receipts: the summary exits 2 on unaccepted drift"
assert_contains "$output" "\`MS_TEST_IMAGE_OVERRIDES=\"autoheal=willfarrell/autoheal:latest@$SHA_G\" ./tests/run.sh fresh-install\`<br>\`MS_TEST_IMAGE_OVERRIDES=\"autoheal=willfarrell/autoheal:latest@$SHA_G\" ./tests/run.sh autoheal\`" "image-drift-receipts: the summary prints one command per scenario of a + token"

# --- --preflight-plan --------------------------------------------------------------
# Given the frozen snapshot drifts sonarr, radarr and autoheal (fresh-install+autoheal) and the compose-only demo
# When the plan is written at the expected source
output=$($DRIFT "${base[@]}" --preflight-plan "$TMP_DIR/plan.json" --receipt-source "$SRC" 2>&1)
rc=$?
plan=$(
    python3 -I - "$TMP_DIR/plan.json" <<'PY' 2>&1
import json, sys
plan = json.load(open(sys.argv[1]))
print("source=" + plan["source"])
print("keys=" + ",".join(sorted(plan)))
for group in plan["scenarios"]:
    print(f"{group['scenario']}: services={','.join(group['services'])} overrides={group['overrides']}")
print("pending=" + ",".join(plan["pending_non_scenario"]))
PY
)

# Then the command exits 0 and says where the plan went
assert_eq "0" "$rc" "image-drift-receipts: --preflight-plan exits zero"
assert_contains "$output" "Preflight plan written to $TMP_DIR/plan.json" "image-drift-receipts: --preflight-plan names the file it wrote"
# And the plan carries the source, a generation time and both lists
assert_contains "$plan" "source=$SRC" "image-drift-receipts: the plan names the expected source"
assert_contains "$plan" "keys=generated_at_utc,pending_non_scenario,scenarios,source" "image-drift-receipts: the plan has the documented top-level keys"
# And the two fresh-install services and the + service share one group with every override
assert_contains "$plan" "fresh-install: services=autoheal,radarr,sonarr overrides=autoheal=willfarrell/autoheal:latest@$SHA_G,radarr=linuxserver/radarr:latest@$SHA_D,sonarr=linuxserver/sonarr:latest@$SHA_C" "image-drift-receipts: services sharing a scenario form one group with every override"
# And the + service also appears in its second scenario's group
assert_contains "$plan" "autoheal: services=autoheal overrides=autoheal=willfarrell/autoheal:latest@$SHA_G" "image-drift-receipts: a + token service appears in both of its groups"
# And the compose-only service is listed under pending_non_scenario, not in a group
assert_contains "$plan" "pending=demo" "image-drift-receipts: a compose-only service is pending_non_scenario"
assert_eq "0" "$(grep -c 'services=.*demo' <<<"$plan")" "image-drift-receipts: a compose-only service is in no scenario group"
assert_eq "autoheal
fresh-install" "$(grep -o '^[a-z-]*:' <<<"$plan" | tr -d ':' | grep -v '^$')" "image-drift-receipts: plan groups are sorted by scenario name"

# Given a snapshot with no drift
# When the plan is written
output=$($DRIFT --previous "$TMP_DIR/previous.tsv" --upgrades "$TMP_DIR/upgrades.md" --current-file "$TMP_DIR/previous.tsv" \
    --preflight-plan "$TMP_DIR/empty-plan.json" --receipt-source "$SRC" 2>&1)
rc=$?

# Then the command still exits 0 and writes a valid plan with empty lists
assert_eq "0" "$rc" "image-drift-receipts: an empty --preflight-plan exits zero"
assert_eq "[] []" "$(python3 -I -c 'import json,sys; p=json.load(open(sys.argv[1])); print(p["scenarios"], p["pending_non_scenario"])' "$TMP_DIR/empty-plan.json")" "image-drift-receipts: an empty plan is a valid file with empty lists"

# Given no frozen snapshot
# When the plan is requested without --current-file
output=$($DRIFT --previous "$TMP_DIR/previous.tsv" --upgrades "$TMP_DIR/upgrades.md" --preflight-plan "$TMP_DIR/x.json" 2>&1)
rc=$?

# Then the request is refused before any resolution
assert_eq "1" "$rc" "image-drift-receipts: --preflight-plan requires --current-file"
assert_contains "$output" "--preflight-plan requires --current-file" "image-drift-receipts: --preflight-plan explains the current-file requirement"

# Given a receipt from the correct commit and run on another architecture.
receipt_row sonarr linuxserver/sonarr:latest "$SHA_C" fresh-install | sed 's/x86_64/other-arch/' >"$receipt"

# When selective acceptance checks that receipt.
output=$(accept_sonarr "$TMP_DIR/architecture.tsv" --receipt-source "$SRC")
rc=$?

# Then it refuses the incompatible evidence before writing a lock.
assert_eq '1' "$rc" 'image-drift-receipts: architecture mismatch blocks acceptance'
assert_contains "$output" 'receipt architecture differs' 'image-drift-receipts: architecture mismatch is explained'
assert_file_absent "$TMP_DIR/architecture.tsv" 'image-drift-receipts: wrong architecture writes no lock'

# Given a manifest with an empty required scenario name.
sed 's/| sonarr | latest | stable | scenario:fresh-install |/| sonarr | latest | stable | scenario: |/' "$TMP_DIR/upgrades.md" >"$TMP_DIR/invalid.md"

# When acceptance reads the malformed requirement.
output=$(accept_sonarr "$TMP_DIR/empty-scenario.tsv" --upgrades "$TMP_DIR/invalid.md" --receipt-source "$SRC")
rc=$?

# Then the empty requirement cannot bypass every receipt check.
assert_eq '1' "$rc" 'image-drift-receipts: an empty scenario requirement blocks acceptance'
assert_contains "$output" 'invalid preflight scenario token' 'image-drift-receipts: an empty scenario is explained'
assert_file_absent "$TMP_DIR/empty-scenario.tsv" 'image-drift-receipts: an empty scenario writes no lock'

scenario_end "$CURRENT_SCENARIO"
summary
