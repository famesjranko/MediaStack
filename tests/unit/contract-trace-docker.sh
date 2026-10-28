#!/usr/bin/env bash
# tests/unit/contract-trace-docker.sh
#
# Proves tests/lib/contract-trace-docker.sh, the docker exec recorder installed
# in DinD: it passes stdin, stdout and the exit status through, records one
# exec only while MS_CONTRACT_TRACE is set, records the container and the argv
# after it past docker's global flags and the exec flags, never records an -e
# value, and adds nothing to stderr when it cannot write the record. The shim
# calls /usr/bin/docker by
# its absolute path, so each case runs against a copy whose real docker is a
# stub that runs the command locally. When Docker works, the same cases run
# again against the real /usr/bin/docker and a throwaway container.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="contract-trace-docker"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
CONTAINER="ms-unit-shim-$$-$RANDOM"
trap 'rm -rf "$TMP_DIR"; docker rm -f "$CONTAINER" >/dev/null 2>&1 || true' EXIT
SHIM="$REPO_ROOT/tests/lib/contract-trace-docker.sh"
SECRET="shim-secret-value-$RANDOM"

# A stand-in for /usr/bin/docker: `exec [flags] CONTAINER CMD...` runs CMD here.
cat >"$TMP_DIR/docker-stub" <<'STUB'
#!/usr/bin/env bash
while [[ "$1" == -* ]]; do
    case "$1" in -H | --context | -l) shift 2 ;; *) shift ;; esac
done
[[ "$1" == exec ]] || { echo "stub: $*"; exit 0; }
shift
while [[ "$1" == -* ]]; do
    case "$1" in -u | -e | -w | --workdir | --env-file) shift 2 ;; *) shift ;; esac
done
shift
exec "$@"
STUB
chmod 755 "$TMP_DIR/docker-stub"
sed "s#/usr/bin/docker#$TMP_DIR/docker-stub#g" "$SHIM" >"$TMP_DIR/shim-stub"
chmod 755 "$TMP_DIR/shim-stub"

# Runs one shim with a trace directory or without one.
traced() { MS_CONTRACT_TRACE="$TRACES" "$@"; }

# Runs every case against one shim and container; $1 labels the real docker.
shim_cases() {
    local label="$1" shim="$2" container="$3" out rc record
    TRACES="$TMP_DIR/traces-$label"
    mkdir -p "$TRACES"

    # Given the shim with a trace directory.
    # When an exec reads stdin and exits 3.
    out=$(printf 'from-stdin' | traced "$shim" exec -i "$container" sh -c 'cat; exit 3')
    rc=$?

    # Then the caller gets the output from stdin and the exit status 3.
    assert_eq "from-stdin" "$out" "$label: the shim passes stdin and stdout through"
    assert_eq "3" "$rc" "$label: the shim keeps the exit status"
    # And one record names the container, the argv after it and the status.
    record=$(cat "$TRACES"/*.exec)
    assert_eq "1" "$(find "$TRACES" -name '*.exec' | wc -l)" "$label: one exec writes one record"
    assert_eq "$container|sh,-c,cat; exit 3|3" \
        "$(python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r["container"], ",".join(r["argv"]), r["rc"], sep="|")' <<<"$record")" \
        "$label: the record holds the container, the argv and the status"

    # Given the shim with a trace directory.
    rm -f "$TRACES"/*.exec

    # When an exec passes a secret through -e and --env=.
    traced "$shim" exec -e "MS_SHIM_SECRET=$SECRET" --env="MS_SHIM_OTHER=$SECRET" -w / \
        "$container" true

    # Then the record holds no -e value and still finds the container.
    record=$(cat "$TRACES"/*.exec)
    assert_not_contains "$record" "$SECRET" "$label: the record never holds an -e value"
    assert_contains "$record" "\"container\": \"$container\"" "$label: the container follows the exec flags"

    # Given the shim with a trace directory.
    rm -f "$TRACES"/*.exec

    # When an exec sets its working directory with --workdir.
    traced "$shim" exec --workdir / "$container" true

    # Then the record names the container after the directory.
    assert_contains "$(cat "$TRACES"/*.exec)" "\"container\": \"$container\"" \
        "$label: --workdir takes a value"

    # Given the shim with a trace directory and an environment file.
    rm -f "$TRACES"/*.exec
    printf 'MS_SHIM_FILE=1\n' >"$TMP_DIR/shim.env"

    # When an exec reads the file with --env-file.
    traced "$shim" exec --env-file "$TMP_DIR/shim.env" "$container" true

    # Then the record names the container after the file.
    assert_contains "$(cat "$TRACES"/*.exec)" "\"container\": \"$container\"" \
        "$label: --env-file takes a value"

    # Given the shim with a trace directory.
    rm -f "$TRACES"/*.exec

    # When an exec follows docker's global flag -l with its value.
    traced "$shim" -l error exec "$container" true

    # Then the exec is recorded with its container.
    assert_contains "$(cat "$TRACES"/*.exec 2>/dev/null)" "\"container\": \"$container\"" \
        "$label: an exec after a global flag is recorded"

    # Given a trace directory that is missing, and one that is not writable.
    mkdir -p "$TMP_DIR/locked-$label"
    chmod 555 "$TMP_DIR/locked-$label"
    for trace in "$TMP_DIR/missing-$label" "$TMP_DIR/locked-$label"; do
        if [[ -d "$trace" && -w "$trace" ]]; then
            skip "$label: an unwritable trace directory adds no stderr" "the directory is writable (root?)"
            continue
        fi

        # When an exec prints to stdout and stderr and exits 5.
        out=$(MS_CONTRACT_TRACE="$trace" "$shim" exec "$container" sh -c 'echo out; echo err >&2; exit 5' \
            2>"$TMP_DIR/stderr")
        rc=$?

        # Then stdout, stderr and the exit status are exactly the child's.
        assert_eq "out|err|5" "$out|$(cat "$TMP_DIR/stderr")|$rc" \
            "$label: ${trace##*/}: the shim adds nothing when it cannot record"
    done

    # Given the shim without MS_CONTRACT_TRACE.
    rm -f "$TRACES"/*.exec

    # When an exec exits 4.
    "$shim" exec "$container" sh -c 'exit 4'
    rc=$?

    # Then the status passes through and nothing is recorded.
    assert_eq "4" "$rc" "$label: an untraced exec keeps the exit status"
    assert_eq "0" "$(find "$TRACES" -type f | wc -l)" "$label: an untraced exec records nothing"

    # Given the shim with a trace directory.
    # When a subcommand other than exec runs.
    traced "$shim" version >/dev/null 2>&1

    # Then nothing is recorded.
    assert_eq "0" "$(find "$TRACES" -type f | wc -l)" "$label: a subcommand other than exec records nothing"
}

shim_cases stub "$TMP_DIR/shim-stub" stub-container

# Given the stub shim with a trace directory.
TRACES="$TMP_DIR/traces-stub"
rm -f "$TRACES"/*.exec

# When an exec follows the global flags -H, --context, -l and --tlsverify.
traced "$TMP_DIR/shim-stub" -H unix:///run/x.sock --context remote -l error --tlsverify \
    exec stub-container true

# Then the exec is recorded with its container.
assert_contains "$(cat "$TRACES"/*.exec 2>/dev/null)" '"container": "stub-container"' \
    "stub: an exec after several global flags is recorded"

# Given the stub shim without MS_CONTRACT_TRACE.
# When an exec prints the parent of the command it runs, beside the caller's own pid.
read -r caller parent < <(
    echo "$BASHPID" "$("$TMP_DIR/shim-stub" exec stub-container sh -c 'echo $PPID')"
)

# Then the shim has replaced itself with docker, so no wrapper process stands between.
if [[ -n "$parent" ]]; then
    pass "stub: the untraced exec ran"
else
    fail "stub: the untraced exec ran" "no parent pid"
fi
assert_eq "$caller" "$parent" "stub: an untraced exec is the real docker, not a child of the shim"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || [[ ! -x /usr/bin/docker ]]; then
    skip "real docker: the shim against a running container" "Docker not available at /usr/bin/docker"
elif ! docker run -d --rm --network none --name "$CONTAINER" debian:bookworm-slim sleep 300 >/dev/null 2>&1; then
    skip "real docker: the shim against a running container" "cannot start debian:bookworm-slim (offline?)"
else
    shim_cases "real docker" "$SHIM" "$CONTAINER"
fi

scenario_end "$CURRENT_SCENARIO"
summary
