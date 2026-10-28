#!/usr/bin/env bash
# tests/unit/contract-trace-docker.sh
#
# Proves tests/lib/contract-trace-docker.sh, the docker exec recorder installed
# in DinD: it passes stdin, stdout and the exit status through, records one
# exec only while MS_CONTRACT_TRACE is set, records the container and the argv
# after it, and never records an -e value. The shim calls /usr/bin/docker by
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
[[ "$1" == exec ]] || { echo "stub: $*"; exit 0; }
shift
while [[ "$1" == -* ]]; do
    case "$1" in -u | -e | -w) shift 2 ;; *) shift ;; esac
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
