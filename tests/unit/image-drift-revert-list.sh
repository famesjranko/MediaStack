#!/usr/bin/env bash
# Unit test - the Revert list offers only services that differ from their install image.
#
# image_drift.py scan_status is run in-process with the docker/registry readers
# monkeypatched; its real TSV output then feeds the real launcher menu helper, so the
# contract checked is "what the user sees listed", not an internal flag.
#
# Run directly: ./tests/unit/image-drift-revert-list.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="image-drift-revert-list"
scenario_begin "$CURRENT_SCENARIO"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Given sonarr reverted to its install digest (a pin row), radarr floated to its tag
#   (latest row) and jellyfin untouched (no row), all behind upstream
# When the status TSV feeds the Revert menu
# Then only radarr is offered, and the table still shows sonarr as pinned
TSV=$(
    python3 - "$REPO_ROOT" "$TMP_DIR" <<'PY'
import sys, pathlib, importlib.util
repo, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("idrift", f"{repo}/scripts/image_drift.py")
m = importlib.util.module_from_spec(spec)
sys.modules["idrift"] = m
spec.loader.exec_module(m)

pin = "lscr.io/x/sonarr:latest@sha256:" + "a" * 64
(tmp / "policy.tsv").write_text(f"sonarr\t{pin}\nradarr\tlatest\n")
m.load_compose_images = lambda _p: [("sonarr", "lscr.io/x/sonarr:latest"),
                                     ("radarr", "lscr.io/x/radarr:latest"),
                                     ("jellyfin", "lscr.io/x/jellyfin:latest")]
m.container_image_id = lambda s: "img-" + s
m.image_repo_digest = lambda i, img: "sha256:" + "b" * 64
m.resolve_digest = lambda img: "sha256:" + "c" * 64
rows = m.scan_status(pathlib.Path("docker-compose.yml"), None, tmp / "policy.tsv", "stable")
print(m.format_status_tsv(rows))
PY
)
OUT=$(
    TSV="$TSV" MEDIASTACK_NONINTERACTIVE=1 bash -c '
    source "$REPO_ROOT/mediastack" </dev/null
    ui_log(){ :; }
    launcher_pause_for_menu(){ :; }
    ui_choose(){ shift; printf "OFFERED:%s\n" "$@" >&2; echo Back; }
    _menu_reset_default "$TSV"
' 2>&1
)
assert_contains "$OUT" "OFFERED:radarr" "revert list: a floated service is offered"
assert_not_contains "$OUT" "OFFERED:sonarr" "revert list: a service already on its install digest is not offered"
assert_not_contains "$OUT" "OFFERED:jellyfin" "revert list: a service with no override is not offered"
assert_contains "$TSV" "sonarr	pinned	default" "revert list: the table keeps showing the pin as 'pinned'"

scenario_end "$CURRENT_SCENARIO"
summary
