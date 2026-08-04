#!/usr/bin/env bash
# tests/ci-scenarios.sh — the image-free scenario set run on remote CI.
#
# The remote-CI jobs that drive DinD set MS_TEST_SKIP_PRELOAD=1, so they sideload
# no service images and can only run scenarios that need none. This is the single
# source of truth for that set, consumed by the wizard-ui job in BOTH workflows
# so the selection lives in one place, not duplicated in two YAMLs (same pattern
# as tests/unit.sh). Adding a future image-free scenario is a one-line edit to
# extra_image_free below.
#
# Self-adapting: wizard-ui-* is matched by glob, and any extra scenario is emitted
# only if its file exists in this checkout — so a scenario absent here is silently
# skipped instead of being named to tests/run.sh, which rejects an unknown
# scenario with a non-zero exit (that would turn CI red).
#
# Prints the scenario names space-separated on one line. Exits non-zero if the set
# is empty, so a caller can't fall back to run.sh's image-pulling default (smoke).
#
# Only scenarios with NO service-image pulls AND no extra handling belong here.
# Image-free scenarios deliberately NOT included, and why:
#   - nas-storage             needs kernel NFS (a real mount inside DinD) —
#                             unreliable on hosted runners; runs in the local battery.
#   - image-override          needs MS_TEST_IMAGE_OVERRIDES and its own DinD (it
#                             rewrites the whole compose) — cannot share a run.
#   - demo-lan,               run a stubbed `main --full` that rewrites config.yml
#     existing-install-nuke   and .env; the shared CI run has no reset between
#                             scenarios, so they would bleed into the others.
# See tests/README.md for the full scenario classification.

set -uo pipefail
shopt -s nullglob

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Additional image-free scenarios beyond the wizard-ui-* family. Add a bare
# scenario name (no path, no .sh); it is emitted only if its file exists.
extra_image_free=(contract-mock)

names=()
for f in tests/scenarios/wizard-ui-*.sh; do
    [[ -f "$f" ]] || continue
    names+=("$(basename "$f" .sh)")
done
if ((${#extra_image_free[@]} > 0)); then
    for s in "${extra_image_free[@]}"; do
        [[ -f "tests/scenarios/$s.sh" ]] && names+=("$s")
    done
fi

if ((${#names[@]} == 0)); then
    echo "ci-scenarios: no image-free scenarios found under tests/scenarios/" >&2
    exit 2
fi

printf '%s\n' "${names[*]}"
