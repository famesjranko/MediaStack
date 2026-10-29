#!/usr/bin/env bash
# The accepted-to-candidate NPM proof. Runs only on the disposable guest.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
source tests/lib/receipts.sh
trap '[[ ! -f "$RECEIPTS_PID" ]] || kill "$(cat "$RECEIPTS_PID")" 2>/dev/null || true' EXIT
RECEIPTS_LOCAL=1
RECEIPTS_FILE=/tmp/ms-remote-receipts.tsv
MS_TEST_IMAGE_OVERRIDES="npm=$1"
MS_TEST_RUN_ID="$3"
RECEIPTS_PLAN_HASH="$4"
receipts_recorder_start
[[ "$RECEIPTS_ACTIVE" == 1 ]]
# The operator exported this exact clean commit with git archive. The guest
# intentionally has no .git directory or credentials for repository access.
RECEIPTS_SOURCE="$2"
receipts_scenario_begin
printf '%s\n' candidate-lock >/tmp/ms-remote-check
python3 - "$1" <<'PY'
import pathlib
import sys
p = pathlib.Path('docs/operations/image-digests.lock')
image, digest = sys.argv[1].rsplit('@', 1)
lines = p.read_text().splitlines()
for i, line in enumerate(lines):
    if line.startswith('npm\t'):
        fields = line.split('\t')
        fields[1:3] = [image, digest]
        lines[i] = '\t'.join(fields)
p.write_text('\n'.join(lines) + '\n')
PY
printf '%s\n' update >/tmp/ms-remote-check
timeout 900 ./scripts/update.sh >/tmp/ms-candidate-update.log 2>&1
for ((attempt = 0; attempt < 90; attempt++)); do
    if [[ "$(docker inspect --format '{{.State.Health.Status}}' npm)" == healthy ]]; then break; fi
    sleep 2
done
[[ "$(docker inspect --format '{{.State.Health.Status}}' npm)" == healthy ]]
[[ "$(docker inspect --format '{{.Config.Image}}' npm)" == "$1" ]]
# Check before configure.sh can repair a lost managed row.
printf '%s\n' application-state >/tmp/ms-remote-check
python3 tests/fixtures/upgrade_state.py check --settings-only >/tmp/ms-candidate-state.log 2>&1
printf '%s\n' npm-state >/tmp/ms-remote-check
python3 tests/fixtures/npm_state.py check >>/tmp/ms-candidate-state.log 2>&1
printf '%s\n' reconfigure >/tmp/ms-remote-check
timeout 600 ./scripts/configure.sh --only npm >/tmp/ms-candidate-configure.log 2>&1
printf '%s\n' npm-state-after-reconfigure >/tmp/ms-remote-check
python3 tests/fixtures/npm_state.py check >>/tmp/ms-candidate-state.log 2>&1
printf '%s\n' staging-renewal >/tmp/ms-remote-check
python3 tests/fixtures/npm_state.py renew >>/tmp/ms-candidate-state.log 2>&1
printf '%s\n' receipt >/tmp/ms-remote-check
receipts_scenario_end remote-gcp
[[ "$RECEIPTS_ROWS_WRITTEN" == 1 ]]
