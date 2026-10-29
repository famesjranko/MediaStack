# tests/lib/receipts.sh — evidence-backed image preflight receipts.
# Sourced by tests/run.sh after dind.sh and assert.sh. No side effects at source time.
#
# A receipt row in tests/.image-preflight-passed.tsv lets scripts/image_drift.py accept
# a digest. Format v2, tab separated:
#   service image digest scenario source run_id arch recorded_at_utc
# Operator-run remote v3 adds plan_hash before recorded_at_utc. RECEIPTS_LOCAL=1
# uses the host Docker daemon through the same event verdict and image inspection.
# `source` is the host checkout's HEAD at run start, with a `-dirty` suffix when the
# tree had uncommitted or untracked changes, or `unknown` without git; `run_id` is one
# id per tests/run.sh invocation. Both bind the evidence to a revision and a run, so an
# old row cannot vouch for a later tree (image_drift.py accepts only rows whose source
# equals the commit it is run against). A row is written only when ALL hold for that
# one scenario:
#   1. the scenario added no failed assertion;
#   2. the DinD event log shows a compose container of that service, started inside
#      the scenario's window, created from exactly the candidate ref, and neither
#      stopped, crashed nor unhealthy at its last observed state;
#   3. the candidate image is present in DinD with the candidate digest in RepoDigests.
# The override text and an aggregate fail count are never evidence. Anything that
# cannot be read counts as "no evidence": no row, and a [receipts] line says why.
#
# Why an event log and not a snapshot at scenario end: scenarios such as autoheal and
# npm-heal remove their own containers before they return. A recorder started once
# per run keeps what ran; each scenario reads only its own window of the log.

: "${RECEIPTS_FILE:=tests/.image-preflight-passed.tsv}"
: "${RECEIPTS_EVENTS:=/tmp/ms-receipt-events.jsonl}" # inside DinD
: "${RECEIPTS_PID:=/tmp/ms-receipt-recorder.pid}"    # inside DinD
: "${RECEIPTS_TIMEOUT:=20}"                          # seconds per DinD call or sync wait
RECEIPTS_ACTIVE=0
declare -A RECEIPTS_REF=() RECEIPTS_IMAGE=() RECEIPTS_DIGEST=() # keyed by service
RECEIPTS_OFFSET=""
RECEIPTS_FAIL_BASE=0
RECEIPTS_SKIP_BASE=0
RECEIPTS_SOURCE="" RECEIPTS_RUN_ID="" RECEIPTS_ARCH="" # one identity per run
RECEIPTS_ROWS_WRITTEN=0
_RCPT_SEQ=0
_RCPT_RUN_ID_RE='^run-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$'

_rcpt_say() { echo -e "${BLUE:-}[receipts]${NC:-} $*" >&2; }

_rcpt_dind() {
    if [[ "${RECEIPTS_LOCAL:-0}" == 1 ]]; then
        timeout "$RECEIPTS_TIMEOUT" "$@"
    else
        timeout "$RECEIPTS_TIMEOUT" docker exec "$DIND_NAME" "$@"
    fi
}

_rcpt_recorder_spawn() {
    local cmd="echo \$\$ >'$RECEIPTS_PID'; exec docker events --format '{{json .}}' --filter type=container --filter type=volume >>'$RECEIPTS_EVENTS' 2>&1"
    if [[ "${RECEIPTS_LOCAL:-0}" == 1 ]]; then
        sh -c "$cmd" </dev/null >/dev/null 2>&1 &
    else
        docker exec -d "$DIND_NAME" sh -c "$cmd"
    fi
}

# Parse MS_TEST_IMAGE_OVERRIDES into the RECEIPTS_* maps. Tag-only refs carry no digest
# to vouch for and are skipped. Commas, tabs and newlines separate tokens. A token with no
# '=', bad characters, a bad digest or a duplicate service voids the whole list (return 1).
receipts_load_overrides() {
    local tok svc ref
    RECEIPTS_REF=() RECEIPTS_IMAGE=() RECEIPTS_DIGEST=()
    for tok in $(echo "${MS_TEST_IMAGE_OVERRIDES:-}" | tr ',' ' '); do
        svc="${tok%%=*}"
        ref="${tok#*=}"
        if [[ "$tok" != *=* || ! "$svc" =~ ^[A-Za-z0-9._-]+$ || ! "$ref" =~ ^[A-Za-z0-9._:/@-]+$ ]] \
            || [[ -n "${RECEIPTS_REF[$svc]+x}" ]] \
            || [[ "$ref" == *@* && ! "${ref##*@}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            _rcpt_say "unusable override token '$tok'; no receipts this run"
            RECEIPTS_REF=() RECEIPTS_IMAGE=() RECEIPTS_DIGEST=()
            return 1
        fi
        [[ "$ref" == *@* ]] || continue
        RECEIPTS_REF[$svc]="$ref"
        RECEIPTS_IMAGE[$svc]="${ref%@*}"
        RECEIPTS_DIGEST[$svc]="${ref##*@}"
    done
    return 0
}

# The run identity every row of this invocation carries. Source is HEAD of the host
# checkout (the cwd; tests/run.sh sets it to the repo root). Any uncommitted or
# untracked change (ignored files excluded, as git does by default) makes it `-dirty`;
# no git or no repository makes it `unknown`. image_drift.py accepts neither.
# MS_TEST_RUN_ID lets a hosted workflow stamp its own id; a malformed one returns 1.
receipts_run_identity() {
    local sha status
    if sha=$(git rev-parse HEAD 2>/dev/null) && [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
        && status=$(git status --porcelain --untracked-files=normal 2>/dev/null); then
        RECEIPTS_SOURCE="$sha"
        [[ -n "$status" ]] && RECEIPTS_SOURCE="$sha-dirty"
    else
        RECEIPTS_SOURCE="unknown"
    fi
    RECEIPTS_ARCH="$(uname -m)"
    if [[ -n "${MS_TEST_RUN_ID:-}" ]]; then
        if [[ ! "$MS_TEST_RUN_ID" =~ $_RCPT_RUN_ID_RE ]]; then
            _rcpt_say "MS_TEST_RUN_ID '$MS_TEST_RUN_ID' is malformed (expected run-<yyyymmddThhmmssZ>-<8 hex>); no receipts this run"
            return 1
        fi
        RECEIPTS_RUN_ID="$MS_TEST_RUN_ID"
    else
        RECEIPTS_RUN_ID="run-$(date -u +%Y%m%dT%H%M%SZ)-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi
    return 0
}

# Barrier: create a uniquely named volume and wait until the recorder has logged it.
# Docker delivers events in order, so every earlier container event is then in the log.
_rcpt_sync() {
    local name="ms-receipt-sync-$$-$((++_RCPT_SEQ))" waited=0
    if ! _rcpt_dind sh -c "kill -0 \"\$(cat '$RECEIPTS_PID')\"" >/dev/null 2>&1; then
        _rcpt_say "event recorder is not running in ${DIND_NAME:-local host}"
        return 1
    fi
    if ! _rcpt_dind docker volume create "$name" >/dev/null 2>&1; then
        _rcpt_say "cannot create the sync marker in ${DIND_NAME:-local host}"
        return 1
    fi
    while ((waited < RECEIPTS_TIMEOUT)); do
        if _rcpt_dind grep -qF "$name" "$RECEIPTS_EVENTS" >/dev/null 2>&1; then
            _rcpt_dind docker volume rm -f "$name" >/dev/null 2>&1 || true
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    _rcpt_say "event recorder did not catch up within ${RECEIPTS_TIMEOUT}s"
    return 1
}

# Start the DinD-side event recorder once per run when any override carries a digest.
receipts_recorder_start() {
    RECEIPTS_ACTIVE=0
    receipts_load_overrides || return 0
    ((${#RECEIPTS_REF[@]})) || return 0
    receipts_run_identity || return 0
    if _rcpt_dind sh -c ": >'$RECEIPTS_EVENTS'" \
        && _rcpt_recorder_spawn \
        && sleep 1 && _rcpt_sync; then
        RECEIPTS_ACTIVE=1
        _rcpt_say "run id: $RECEIPTS_RUN_ID (source $RECEIPTS_SOURCE, $RECEIPTS_ARCH)"
    else
        _rcpt_say "cannot start the evidence recorder; no receipts this run"
    fi
    return 0
}

# Final receipt output of the run: the id a maintainer or workflow passes to
# image_drift.py --receipt-run-id, and how many rows this invocation added.
receipts_run_end() {
    ((RECEIPTS_ACTIVE)) || return 0
    _rcpt_say "run id: $RECEIPTS_RUN_ID; $RECEIPTS_ROWS_WRITTEN new row(s) in $RECEIPTS_FILE"
}

# Mark where this scenario's events begin. Call after any reset, before the scenario.
receipts_scenario_begin() {
    ((RECEIPTS_ACTIVE)) || return 0
    RECEIPTS_FAIL_BASE=${FAIL_COUNT:-0}
    RECEIPTS_SKIP_BASE=${SKIP_COUNT:-0}
    RECEIPTS_OFFSET=""
    _rcpt_sync || return 0
    local size
    size=$(_rcpt_dind sh -c "wc -c <'$RECEIPTS_EVENTS'" 2>/dev/null | tr -d '[:space:]')
    [[ "$size" =~ ^[0-9]+$ ]] && RECEIPTS_OFFSET="$size"
    return 0
}

# Verdict per override from the scenario's events. Args: events-file svc=ref...
# Prints "ok|no<TAB>service<TAB>why". The latest instance of a service (by creation)
# decides; it must have started, run the candidate ref and end running or healthy. A
# stop or removal after it ran counts as teardown. A die with no stop or kill before it
# is a crash that a later restart-policy start does not clear.
_rcpt_verdicts() {
    python3 -I - "$@" <<'PY'
import json
import sys

events_path, specs = sys.argv[1], sys.argv[2:]
LIVE = ("running", "healthy", "unhealthy")
insts = {}
try:
    with open(events_path) as fh:
        lines = [ln for ln in fh.read().splitlines() if ln.strip()]
    for line in lines:
        ev = json.loads(line)
        if ev.get("Type") != "container":
            continue
        attrs = ev["Actor"]["Attributes"]
        # Newer Docker drops the legacy top-level id/status/from fields; Actor.ID stays.
        i = insts.setdefault(ev["Actor"]["ID"], {
            "svc": attrs.get("com.docker.compose.service"), "image": attrs.get("image"),
            "started": False, "state": "created", "prior": None, "stopping": False,
            "crashed": False, "destroyed": False})
        act = ev["Action"]
        if act == "start":
            i.update(started=True, state="running", prior=None, stopping=False)
        elif act.startswith("health_status:") and i["state"] in LIVE:
            i["state"] = {"healthy": "healthy", "unhealthy": "unhealthy"}.get(
                act.split(":", 1)[1].strip(), i["state"])
        elif act == "stop":
            i["stopping"] = True
        elif act == "kill":
            # Only a terminating signal is a stop; HUP, USR1 and the like leave a running
            # container running, so a die after them is still a crash. Docker reports the
            # signal as a number string or a name; an absent attribute counts as a stop.
            sig = attrs.get("signal", "").strip().upper().removeprefix("SIG")
            if sig in ("", "2", "3", "9", "15", "INT", "QUIT", "KILL", "TERM"):
                i["stopping"] = True
        elif act == "die":
            i["prior"] = i["state"] if i["state"] in LIVE else i["prior"]
            i["state"] = "stopped" if i["stopping"] else "crashed"
            i["crashed"] = i["crashed"] or not i["stopping"]
        elif act == "destroy":
            i["destroyed"] = True
except (OSError, ValueError, KeyError, TypeError) as exc:
    for spec in specs:
        print(f"no\t{spec.split('=', 1)[0]}\tunreadable event log ({exc})")
    sys.exit(0)

for spec in specs:
    svc, ref = spec.split("=", 1)
    all_i = [i for i in insts.values() if i["svc"] == svc]
    if not any(i["started"] for i in all_i):
        print(f"no\t{svc}\tno container of this service started in the scenario")
        continue
    i = all_i[-1]
    if not i["started"]:
        print(f"no\t{svc}\tlatest container of this service never started")
        continue
    if i["crashed"]:
        print(f"no\t{svc}\tcontainer ended crashed (died without a stop or kill in the scenario)")
        continue
    final = i["prior"] if i["destroyed"] and i["state"] == "stopped" else i["state"]
    if i["image"] != ref:
        print(f"no\t{svc}\tcontainer ran {i['image']}, not the candidate {ref}")
    elif final not in ("running", "healthy"):
        print(f"no\t{svc}\tcontainer ended {final}")
    else:
        print(f"ok\t{svc}\t")
PY
}

# Append one v2 row unless an identical one exists, so separate runs accumulate. Rows
# are identical when their evidence columns (everything but recorded_at_utc) match;
# the timestamp only says when. A new or empty file gets the v2 header first.
receipts_append_row() {
    local tab=$'\t' evidence columns=7
    evidence="$1${tab}$2${tab}$3${tab}$4${tab}$RECEIPTS_SOURCE${tab}$RECEIPTS_RUN_ID${tab}$RECEIPTS_ARCH"
    if [[ -n "${RECEIPTS_PLAN_HASH:-}" ]]; then
        [[ "$RECEIPTS_PLAN_HASH" =~ ^[0-9a-f]{64}$ ]] || return 1
        evidence+="${tab}$RECEIPTS_PLAN_HASH"
        columns=8
    fi
    if [[ -f "$RECEIPTS_FILE" ]] && cut -f1-"$columns" "$RECEIPTS_FILE" | grep -qxF -- "$evidence"; then
        return 0
    fi
    if [[ ! -s "$RECEIPTS_FILE" ]]; then
        local version=2
        [[ "$columns" == 8 ]] && version=3
        printf '# MediaStack image preflight receipts v%s\n# service\timage\tdigest\tscenario\tsource\trun_id\tarch' "$version" >"$RECEIPTS_FILE"
        [[ "$columns" == 8 ]] && printf '\tplan_hash' >>"$RECEIPTS_FILE"
        printf '\trecorded_at_utc\n' >>"$RECEIPTS_FILE"
    fi
    printf '%s\t%s\n' "$evidence" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$RECEIPTS_FILE"
    RECEIPTS_ROWS_WRITTEN=$((RECEIPTS_ROWS_WRITTEN + 1))
}

# Decide and write rows for the scenario that just ended. Never changes the run's exit.
receipts_scenario_end() {
    local scn="$1" win svc verdict why digests pairs=() tab=$'\t'
    ((RECEIPTS_ACTIVE)) || return 0
    if ((${FAIL_COUNT:-0} > RECEIPTS_FAIL_BASE)); then
        _rcpt_say "$scn: assertions failed; no receipt rows"
        return 0
    fi
    if ((${SKIP_COUNT:-0} > RECEIPTS_SKIP_BASE)); then
        _rcpt_say "$scn: required assertions skipped; no receipt rows"
        return 0
    fi
    if [[ -z "$RECEIPTS_OFFSET" ]]; then
        _rcpt_say "$scn: the start of its event window was never read; no receipt rows"
        return 0
    fi
    win=$(mktemp) || return 0
    if ! _rcpt_sync || ! _rcpt_dind tail -c "+$((RECEIPTS_OFFSET + 1))" "$RECEIPTS_EVENTS" >"$win" 2>/dev/null; then
        _rcpt_say "$scn: evidence read failed; no receipt rows"
        rm -f "$win"
        return 0
    fi
    for svc in "${!RECEIPTS_REF[@]}"; do
        pairs+=("$svc=${RECEIPTS_REF[$svc]}")
    done
    while IFS="$tab" read -r verdict svc why; do
        if [[ "$verdict" != "ok" ]]; then
            _rcpt_say "$scn/$svc: no row ($why)"
        elif ! digests=$(_rcpt_dind docker image inspect --format '{{json .RepoDigests}}' "${RECEIPTS_REF[$svc]}" 2>/dev/null); then
            _rcpt_say "$scn/$svc: no row (image inspect failed or timed out)"
        elif [[ "$digests" != *"@${RECEIPTS_DIGEST[$svc]}\""* ]]; then
            _rcpt_say "$scn/$svc: no row (RepoDigests ${digests:-empty} lacks ${RECEIPTS_DIGEST[$svc]})"
        else
            receipts_append_row "$svc" "${RECEIPTS_IMAGE[$svc]}" "${RECEIPTS_DIGEST[$svc]}" "$scn"
            _rcpt_say "$scn/$svc: receipt row written"
        fi
    done < <(_rcpt_verdicts "$win" "${pairs[@]}")
    rm -f "$win"
}
