# tests/unit/preflight-receipts/lib.sh
# Owns: the preflight-receipts fixture - the fake docker (DinD stand-in), the fake
# git (host checkout stand-in), the sourced library under test and the fixture,
# event and row helpers every topic file uses.
# Sourced by: tests/unit/preflight-receipts.sh, after tests/lib/assert.sh.

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

# --- fake git ---------------------------------------------------------------
# The source column comes from the host checkout; this stub stands in for it so the
# real repository is never read. Env knobs: STUB_GIT_SHA, STUB_GIT_DIRTY=1 (status
# lists a change), STUB_GIT_GONE=1 (no git / not a repository).
cat >"$TMP_DIR/bin/git" <<'STUB'
#!/usr/bin/env bash
[[ -n "${STUB_GIT_GONE:-}" ]] && { echo "fatal: not a git repository" >&2; exit 128; }
case "$1" in
    rev-parse) echo "$STUB_GIT_SHA" ;;
    status) [[ -n "${STUB_GIT_DIRTY:-}" ]] && echo " M tests/run.sh" ;;
    *) exit 64 ;;
esac
exit 0
STUB
chmod +x "$TMP_DIR/bin/git"
export PATH="$TMP_DIR/bin:$PATH"
export STUB_ALIVE_PID=$$
DIND_NAME=fake-dind
export RECEIPTS_EVENTS="$TMP_DIR/events.jsonl" RECEIPTS_PID="$TMP_DIR/recorder.pid"
export RECEIPTS_FILE="$TMP_DIR/receipts.tsv"
source "$REPO_ROOT/tests/lib/receipts.sh"

# shellcheck disable=SC2034 # fixture constants, read by every topic file sourced after this one
D1="sha256:$(printf '1%.0s' {1..64})"
# shellcheck disable=SC2034 # as above
D2="sha256:$(printf '2%.0s' {1..64})"
# shellcheck disable=SC2034 # as above
SEERR=ghcr.io/seerr-team/seerr
# shellcheck disable=SC2034 # as above
AUTOHEAL=willfarrell/autoheal:latest
SHA_F="$(printf 'f%.0s' {1..40})"
RUN_ID_FIXED="run-20260101T000000Z-0badcafe"
ARCH="$(uname -m)"
export STUB_GIT_SHA="$SHA_F"

# --- fixture helpers --------------------------------------------------------
new_fixture() { # new_fixture "<MS_TEST_IMAGE_OVERRIDES>"
    : >"$RECEIPTS_EVENTS"
    rm -f "$RECEIPTS_FILE"
    unset STUB_GONE STUB_INSPECT STUB_STALL STUB_GIT_DIRTY STUB_GIT_GONE
    RECEIPTS_TIMEOUT=3
    MS_TEST_IMAGE_OVERRIDES="$1"
    receipts_load_overrides 2>/dev/null
    MS_TEST_RUN_ID="$RUN_ID_FIXED" receipts_run_identity
    echo "$$" >"$RECEIPTS_PID"
    RECEIPTS_ACTIVE=1
}

ev() { # ev <id> <action> <service> <image> [signal] — the event shape of current Docker (no legacy id/status/from)
    local sig=""
    [[ -n "${5:-}" ]] && sig=",\"signal\":\"$5\""
    printf '{"Type":"container","Action":"%s","Actor":{"ID":"%s","Attributes":{"com.docker.compose.service":"%s","image":"%s","name":"%s"%s}},"scope":"local","timeNano":1}\n' \
        "$2" "$1" "$3" "$4" "$3" "$sig" >>"$RECEIPTS_EVENTS"
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

# rows: the evidence columns of every data row (recorded_at_utc is asserted on its own,
# in section 14, because its value is the wall clock). row: the expected evidence
# columns of one row written under the fixture's identity.
rows() { grep -v '^#' "$RECEIPTS_FILE" 2>/dev/null | cut -f1-7; }
row() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$SHA_F" "$RUN_ID_FIXED" "$ARCH"; }
