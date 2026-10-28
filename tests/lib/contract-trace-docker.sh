#!/usr/bin/env bash
# Installed as /usr/local/bin/docker inside DinD, ahead of /usr/bin in PATH and
# in sudo's secure_path. Without MS_CONTRACT_TRACE, and for every subcommand
# but exec, it is the real docker. With MS_CONTRACT_TRACE set to a directory,
# each product `docker exec` runs as a child that keeps stdin, stdout, stderr
# and the exit status, then writes one JSON record to <epoch-ns>-<pid>.exec
# there for tests/contracts/observe.py: the start time, the container, the
# argv after it and the exit status. Flags before the container, with any -e
# value, are not recorded. The argv can hold a secret (beszel's superuser
# password), so the records never leave DinD; observe.py reports no argument.
# The shim writes nothing to stdout or stderr: callers capture both.
if [[ "${1:-}" != exec || -z "${MS_CONTRACT_TRACE:-}" ]]; then
    exec /usr/bin/docker "$@"
fi

started=$(date +%s%N)
/usr/bin/docker "$@"
rc=$?

# The container is the first word after the exec flags; -u, -e and -w and their
# long forms take a value.
args=("${@:2}")
i=0
while ((i < ${#args[@]})); do
    case "${args[i]}" in
        -u | -e | -w | --user | --env | --workdir | --env-file) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
    esac
done
python3 -I -c '
import json, sys
t, rc, container, *argv = sys.argv[1:]
print(json.dumps({"t": int(t), "container": container, "argv": argv, "rc": int(rc)}))
' "$started" "$rc" "${args[@]:i}" >"$MS_CONTRACT_TRACE/$started-$$.exec" 2>/dev/null
exit "$rc"
