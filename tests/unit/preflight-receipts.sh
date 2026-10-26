#!/usr/bin/env bash
# Unit test - tests/lib/receipts.sh: an image preflight receipt row exists only when
# that scenario passed on its own AND its container events show the service ran from
# the candidate digest. A fake `docker` on PATH stands in for DinD: `exec` runs the
# command against local files, so the event log, offsets and barrier are the real code.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="preflight-receipts"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"

# --- fake docker ------------------------------------------------------------
# Env knobs: STUB_GONE=1 (DinD gone), STUB_INSPECT=ok|fail|empty|wrong|hang,
# STUB_STALL=1 (recorder never logs the barrier volume).
cat >"$TMP_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "exec" ]] || exit 64
shift
if [[ "$1" == "-d" ]]; then
    [[ -n "${STUB_GONE:-}" ]] && exit 1
    echo "$STUB_ALIVE_PID" >"$RECEIPTS_PID"
    exit 0
fi
[[ -n "${STUB_GONE:-}" ]] && { echo "Error: No such container: $1" >&2; exit 1; }
shift
if [[ "$1" != "docker" ]]; then
    exec "$@"
fi
shift
case "$1 $2" in
    "volume create")
        [[ -n "${STUB_STALL:-}" ]] || printf '{"Type":"volume","Action":"create","Actor":{"ID":"%s","Attributes":{}}}\n' "$3" >>"$RECEIPTS_EVENTS"
        ;;
    "volume rm") ;;
    "image inspect")
        ref="${@: -1}"
        repo="$(sed 's/:[^/]*@/@/' <<<"$ref")"
        case "${STUB_INSPECT:-ok}" in
            ok) printf '["%s"]\n' "$repo" ;;
            wrong) printf '["%s@sha256:%064d"]\n' "${repo%@*}" 9 ;;
            empty) echo '[]' ;;
            fail) echo "Error: No such image" >&2; exit 1 ;;
            hang) sleep 5 ;;
        esac
        ;;
    *) exit 64 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/docker"
export PATH="$TMP_DIR/bin:$PATH"
export STUB_ALIVE_PID=$$
DIND_NAME=fake-dind
export RECEIPTS_EVENTS="$TMP_DIR/events.jsonl" RECEIPTS_PID="$TMP_DIR/recorder.pid"
export RECEIPTS_FILE="$TMP_DIR/receipts.tsv"
source "$REPO_ROOT/tests/lib/receipts.sh"

D1="sha256:$(printf '1%.0s' {1..64})"
D2="sha256:$(printf '2%.0s' {1..64})"
SEERR=ghcr.io/seerr-team/seerr
AUTOHEAL=willfarrell/autoheal:latest

# --- fixture helpers --------------------------------------------------------
new_fixture() { # new_fixture "<MS_TEST_IMAGE_OVERRIDES>"
    : >"$RECEIPTS_EVENTS"
    rm -f "$RECEIPTS_FILE"
    unset STUB_GONE STUB_INSPECT STUB_STALL
    RECEIPTS_TIMEOUT=3
    MS_TEST_IMAGE_OVERRIDES="$1"
    receipts_load_overrides 2>/dev/null
    echo "$$" >"$RECEIPTS_PID"
    RECEIPTS_ACTIVE=1
}

ev() { # ev <id> <action> <service> <image> — the event shape of current Docker (no legacy id/status/from)
    printf '{"Type":"container","Action":"%s","Actor":{"ID":"%s","Attributes":{"com.docker.compose.service":"%s","image":"%s","name":"%s"}},"scope":"local","timeNano":1}\n' \
        "$2" "$1" "$3" "$4" "$3" >>"$RECEIPTS_EVENTS"
}

container() { # container <id> <service> <image> <how it ends>
    local id="$1" svc="$2" img="$3" end="$4"
    ev "$id" create "$svc" "$img"
    [[ "$end" == never-started ]] && return 0
    ev "$id" start "$svc" "$img"
    case "$end" in
        running) ;;
        healthy) ev "$id" "health_status: healthy" "$svc" "$img" ;;
        unhealthy) ev "$id" "health_status: unhealthy" "$svc" "$img" ;;
        torn-down) # healthy, then `docker rm -f` as the autoheal scenario does
            ev "$id" "health_status: healthy" "$svc" "$img"
            ev "$id" kill "$svc" "$img"
            ev "$id" die "$svc" "$img"
            ev "$id" destroy "$svc" "$img"
            ;;
        stopped) # healthy, then `docker stop`, container left in place
            ev "$id" "health_status: healthy" "$svc" "$img"
            ev "$id" kill "$svc" "$img"
            ev "$id" die "$svc" "$img"
            ev "$id" stop "$svc" "$img"
            ;;
        crashed) ev "$id" die "$svc" "$img" ;;
    esac
}

# play <scenario> <emit function> [failed assertions]: one scenario's lifecycle as run.sh drives it.
# The harness shares FAIL_COUNT with the code under test, so it is restored afterwards.
play() {
    local scn="$1" emit="$2" fails="${3:-0}" saved=$FAIL_COUNT
    receipts_scenario_begin
    "$emit"
    FAIL_COUNT=$((FAIL_COUNT + fails))
    MSG+="$(receipts_scenario_end "$scn" 2>&1)"$'\n'
    FAIL_COUNT=$saved
}

rows() { cat "$RECEIPTS_FILE" 2>/dev/null; }
row() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"; }

# --- 1. a service that ran from the candidate digest earns its row -----------
new_fixture "autoheal=$AUTOHEAL@$D1"
emit() { container a1 autoheal "$AUTOHEAL@$D1" torn-down; }
MSG=""
play autoheal emit
# Given Autoheal ran healthy from the candidate digest and the scenario removed it itself
# When the scenario ends with no failed assertion
# Then exactly the autoheal/autoheal row exists
assert_eq "$(row autoheal "$AUTOHEAL" "$D1" autoheal)" "$(rows)" "receipts: a service run from the candidate earns its row"

# --- 2. unrelated scenario ----------------------------------------------------
new_fixture "seerr=$SEERR@$D1"
emit() {
    container a1 autoheal "$AUTOHEAL@$D1" healthy
    container a2 socket-proxy wollomatic/socket-proxy:1 healthy
}
MSG=""
play autoheal emit
# Given a seerr override and a scenario that only starts autoheal and its socket proxy
# When the scenario passes
# Then no receipt row exists and the run says seerr never started
assert_eq "" "$(rows)" "receipts: an unrelated scenario earns no row"
assert_contains "$MSG" "seerr: no row (no container of this service started" "receipts: the run says the service never started"

# --- 3. inactive profile ------------------------------------------------------
new_fixture "wireguard=ghcr.io/wg-easy/wg-easy@$D1"
emit() {
    container j1 jellyfin jellyfin/jellyfin:latest healthy
    container s1 sonarr lscr.io/linuxserver/sonarr:latest healthy
}
MSG=""
play fresh-install emit
# Given a wireguard override and a fresh-install that leaves the remote profile off
# When the scenario passes
# Then no receipt row exists
assert_eq "" "$(rows)" "receipts: an inactive profile earns no row"

# --- 4. created but never started ----------------------------------------------
new_fixture "seerr=$SEERR@$D1"
emit() { container a1 seerr "$SEERR@$D1" never-started; }
MSG=""
play fresh-install emit
# Given seerr was created from the candidate but never started
# When the scenario passes
# Then no receipt row exists
assert_eq "" "$(rows)" "receipts: a service that was created but never started earns no row"

# --- 5. stopped, crashed or unhealthy at the end ---------------------------------
for end in stopped crashed unhealthy; do
    new_fixture "seerr=$SEERR@$D1"
    emit() { container a1 seerr "$SEERR@$D1" "$end"; }
    MSG=""
    play fresh-install emit
    # Given the candidate container ended $end
    # When the scenario passes
    # Then no receipt row exists and the run names the final state
    assert_eq "" "$(rows)" "receipts: a container that ended $end earns no row"
    assert_contains "$MSG" "container ended $end" "receipts: the run names the $end state"
done

# --- 6. wrong running digest --------------------------------------------------------
new_fixture "seerr=$SEERR@$D1"
emit() { container a1 seerr "$SEERR@$D2" healthy; }
MSG=""
play fresh-install emit
# Given seerr ran healthy but from a different digest than the candidate
# When the scenario passes
# Then no receipt row exists and the run names the image that ran
assert_eq "" "$(rows)" "receipts: a container from another digest earns no row"
assert_contains "$MSG" "not the candidate" "receipts: the run says the digest differed"

# --- 7. events from before the scenario do not count -----------------------------------
new_fixture "seerr=$SEERR@$D1"
container old1 seerr "$SEERR@$D1" healthy
emit() { :; }
MSG=""
play smoke emit
# Given seerr ran from the candidate during an earlier scenario on the same DinD
# When a later scenario starts nothing and passes
# Then that later scenario gets no row
assert_eq "" "$(rows)" "receipts: only the scenario's own window counts"

# --- 8. multi-scenario: the failing scenario withholds only its own rows -------------------
new_fixture "seerr=$SEERR@$D1,autoheal=$AUTOHEAL@$D1"
emit_a() { container s1 seerr "$SEERR@$D1" healthy; }
emit_b() { container h1 autoheal "$AUTOHEAL@$D1" healthy; }
MSG=""
play fresh-install emit_a 1
play autoheal emit_b 0
# Given fresh-install ran seerr but failed an assertion, and autoheal ran autoheal and passed
# When both scenarios end in one run
# Then only the autoheal scenario's row exists and it names the autoheal scenario
assert_eq "$(row autoheal "$AUTOHEAL" "$D1" autoheal)" "$(rows)" "receipts: a failed scenario withholds only its own rows"

new_fixture "seerr=$SEERR@$D1,autoheal=$AUTOHEAL@$D1"
emit_none() { :; }
MSG=""
play fresh-install emit_a 0
play autoheal emit_none 0
# Given seerr ran only in fresh-install, and autoheal ran nothing
# When both scenarios pass
# Then the seerr row names fresh-install, not autoheal, and autoheal gets no row
assert_eq "$(row seerr "$SEERR" "$D1" fresh-install)" "$(rows)" "receipts: a row names the scenario whose own events produced it"

# --- 9. several overrides: each is judged on its own ------------------------------------
new_fixture "seerr=$SEERR@$D1,autoheal=$AUTOHEAL@$D1,wireguard=wg:16"
emit() {
    container s1 seerr "$SEERR@$D1" healthy
    container h1 autoheal "$AUTOHEAL@$D2" healthy
}
MSG=""
play fresh-install emit
# Given three overrides: seerr ran the candidate, autoheal ran another digest, wireguard is tag-only
# When the scenario passes
# Then only the seerr row exists
assert_eq "$(row seerr "$SEERR" "$D1" fresh-install)" "$(rows)" "receipts: several overrides are judged one by one"

# --- 10. the fail-closed trust boundary ---------------------------------------------------
emit() { container s1 seerr "$SEERR@$D1" healthy; }
declare -A WHY=([fail]="image inspect failed" [empty]="RepoDigests [] lacks" [wrong]="lacks $D1")
for mode in fail empty wrong; do
    new_fixture "seerr=$SEERR@$D1"
    export STUB_INSPECT=$mode
    MSG=""
    play fresh-install emit
    # Given the candidate image cannot be confirmed in DinD (inspect $mode)
    # When the scenario passes
    # Then no receipt row exists and the run says the image check failed
    assert_eq "" "$(rows)" "receipts: image inspect '$mode' writes no row"
    assert_contains "$MSG" "${WHY[$mode]}" "receipts: image inspect '$mode' is reported with its cause"
done

new_fixture "seerr=$SEERR@$D1"
export STUB_INSPECT=hang
RECEIPTS_TIMEOUT=1
MSG=""
play fresh-install emit
# Given the image inspect call hangs past the timeout
# When the scenario passes
# Then no receipt row exists and the run says the inspect failed or timed out
assert_eq "" "$(rows)" "receipts: an image inspect timeout writes no row"
assert_contains "$MSG" "image inspect failed or timed out" "receipts: the timeout is reported"

new_fixture "seerr=$SEERR@$D1"
receipts_scenario_begin
emit
export STUB_GONE=1
MSG="$(receipts_scenario_end fresh-install 2>&1)"
# Given the DinD went away after the scenario ran
# When the evidence is read
# Then no receipt row exists and the run says the read failed
assert_eq "" "$(rows)" "receipts: DinD gone writes no row"
assert_contains "$MSG" "evidence read failed" "receipts: a failed read is reported as a failed read"

new_fixture "seerr=$SEERR@$D1"
receipts_scenario_begin
emit
export STUB_STALL=1
RECEIPTS_TIMEOUT=1
MSG="$(receipts_scenario_end fresh-install 2>&1)"
# Given the recorder never logs the end-of-scenario barrier
# When the evidence is read
# Then no receipt row exists, because the log may be missing the last events
assert_eq "" "$(rows)" "receipts: a recorder that falls behind writes no row"

new_fixture "seerr=$SEERR@$D1"
receipts_scenario_begin
printf 'not json\n' >>"$RECEIPTS_EVENTS"
MSG="$(receipts_scenario_end fresh-install 2>&1)"
# Given the event log holds a line that is not JSON
# When the evidence is read
# Then no row exists and the run says the log is unreadable
assert_eq "" "$(rows)" "receipts: an unparseable event log writes no row"
assert_contains "$MSG" "unreadable event log" "receipts: an unparseable log is reported as unreadable"

new_fixture "seerr=$SEERR@$D1"
MSG=""
emit() { :; }
play fresh-install emit
# Given a valid, empty result (seerr was simply not present)
# When the scenario passes
# Then the run reports the service was absent, not a failed read
assert_contains "$MSG" "no container of this service started" "receipts: an absent service is reported as absent"
assert_not_contains "$MSG" "evidence read failed" "receipts: an absent service is not reported as a failed read"

# --- 11. recorder start and input forms ---------------------------------------------------------
new_fixture "seerr=$SEERR@$D1"
RECEIPTS_ACTIVE=0
rm -f "$RECEIPTS_PID"
receipts_recorder_start
# Given a digest override and a DinD that accepts the recorder
# When the run starts the recorder
# Then evidence is active
assert_eq "1" "$RECEIPTS_ACTIVE" "receipts: the recorder starts when an override carries a digest"

new_fixture "seerr=$SEERR@$D1"
RECEIPTS_ACTIVE=0
export STUB_GONE=1
OUT="$(receipts_recorder_start 2>&1)"
# Given a digest override and a DinD that is gone
# When the run starts the recorder
# Then evidence stays off and the run says why
assert_eq "0" "$RECEIPTS_ACTIVE" "receipts: no recorder means no evidence"
assert_contains "$OUT" "cannot start the evidence recorder" "receipts: a recorder failure is reported"

new_fixture "wireguard=ghcr.io/wg-easy/wg-easy:16"
RECEIPTS_ACTIVE=0
receipts_recorder_start
# Given only a tag-only override, which carries no digest to vouch for
# When the run starts the recorder
# Then evidence stays off
assert_eq "0" "$RECEIPTS_ACTIVE" "receipts: a tag-only override earns no receipt"

TAB=$'\t'
NL=$'\n'
bad_n=0
for bad in "seerr=$SEERR@${D1}${TAB}x" "seerr=$SEERR${NL}@$D1" "seerr=$SEERR@sha256:abc" "seerr=$SEERR@$D1,seerr=$SEERR@$D2"; do
    new_fixture "$bad"
    MS_TEST_IMAGE_OVERRIDES="$bad"
    RECEIPTS_ACTIVE=0
    receipts_recorder_start 2>/dev/null
    # Given an override list with a tab, a newline, a short digest or a duplicate service
    # When the run starts the recorder
    # Then evidence stays off, so no row can carry that value
    assert_eq "0" "$RECEIPTS_ACTIVE" "receipts: an unusable override list earns no row (form $((++bad_n)) of 4)"
done

new_fixture "seerr=$SEERR@$D1${NL}autoheal=$AUTOHEAL@$D1"
emit() {
    container s1 seerr "$SEERR@$D1" healthy
    container h1 autoheal "$AUTOHEAL@$D1" healthy
}
MSG=""
play fresh-install emit
# Given two valid overrides separated by a newline, as the documented whitespace separator allows
# When the scenario passes
# Then both rows exist and every row has exactly four tab-separated fields
assert_eq "2:4" "$(rows | wc -l | tr -d ' '):$(rows | awk -F'\t' '{print NF}' | sort -u | tr -d ' \n')" "receipts: newline-separated overrides give well-formed rows"

# --- 12. the receipt file keeps its append and dedup behaviour ----------------------------------------
new_fixture "seerr=$SEERR@$D1"
emit() { container s1 seerr "$SEERR@$D1" healthy; }
printf 'sonarr\tlscr.io/linuxserver/sonarr:latest\t%s\tfresh-install\n' "$D2" >"$RECEIPTS_FILE"
MSG=""
play fresh-install emit
: >"$RECEIPTS_EVENTS"
play fresh-install emit
# Given an earlier run left a sonarr row in the file
# When the same seerr scenario passes twice
# Then the sonarr row stays and the seerr row appears once
assert_eq "2" "$(rows | wc -l | tr -d ' ')" "receipts: earlier rows are kept and a repeated row is not duplicated"

# --- 13. a crash that the restart policy hid, and a recreate that never started ---------------------
new_fixture "seerr=$SEERR@$D1"
emit() {
    ev c1 create seerr "$SEERR@$D1"
    ev c1 start seerr "$SEERR@$D1"
    ev c1 die seerr "$SEERR@$D1"
    ev c1 start seerr "$SEERR@$D1"
}
MSG=""
play fresh-install emit
# Given Seerr died with no stop or kill and the restart policy started it again
# When the scenario passes
# Then no row exists, because the crash is not cleared by the later start
assert_eq "" "$(rows)" "receipts: a crash followed by a restart-policy start earns no row"

new_fixture "seerr=$SEERR@$D1"
emit() {
    container a1 seerr "$SEERR@$D1" torn-down
    ev b1 create seerr "$SEERR@$D1"
}
MSG=""
play fresh-install emit
# Given Seerr ran healthy and was torn down, and its replacement was created but never started
# When the scenario passes
# Then no row exists and the log says the latest container never started
assert_eq "|latest container of this service never started" "$(rows)|$(grep -o 'latest container of this service never started' <<<"$MSG" | head -1)" "receipts: a recreated service that never started earns no row"

summary
