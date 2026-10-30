#!/usr/bin/env bash
# Lock absence must be distinguishable from a failed container exec.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/scripts/services/npm/certs.sh"
scenario_begin npm-certbot-busy
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mode=running
docker() {
    [[ "$1" == exec && "$2" == npm ]] || return 2
    [[ "$mode" == running ]] || return 1
    shift 2
    # Match NPM's configured work directory independently of the probe.
    if [[ "$1" == sh && "$2" == -c ]]; then
        sh -c "${3//\/tmp\/letsencrypt-lib\/.certbot.lock/$scratch/lock}"
    else
        "$1" "$2" "$scratch/lock"
    fi
}

# Given a running container with no Certbot lock.
# When the production probe checks the lock.
run_cmd _npm_certbot_busy

# Then a distinct nonzero status proves that the command ran and found no lock.
assert_rc 10 'absent Certbot lock is distinct from container failure'

# Given Certbot has created its lock.
touch "$scratch/lock"

# When the production probe runs again.
run_cmd _npm_certbot_busy

# Then the busy status remains true for existing callers.
assert_rc 0 'existing Certbot lock reports busy'

# Given the container cannot execute commands.
mode=unavailable

# When the production probe tries to check the lock.
run_cmd _npm_certbot_busy

# Then that failure cannot count as proof of an absent lock.
assert_rc 1 'failed container execution keeps its failure status'
summary
