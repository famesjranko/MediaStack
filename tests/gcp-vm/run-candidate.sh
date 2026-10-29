#!/usr/bin/env bash
# Run an operator-approved candidate on a disposable GCP VM.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case " ${*} " in
    *' --help '* | *' -h '*) exec python3 "$REPO_ROOT/tests/remote_image_preflight.py" --help ;;
esac
ENV_FILE="${GCP_ENV_FILE:-$REPO_ROOT/tests/.env.gcp}"
if [[ ! -f "$ENV_FILE" && " ${*} " == *' --preflight '* && -z "${GCP_ENV_FILE:-}" ]]; then
    ENV_FILE="$REPO_ROOT/tests/.env.gcp.example"
fi
[[ -f "$ENV_FILE" ]] || {
    echo 'Missing GCP_ENV_FILE (default tests/.env.gcp)' >&2
    exit 2
}
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
exec python3 "$REPO_ROOT/tests/remote_image_preflight.py" "$@"
