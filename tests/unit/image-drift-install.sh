#!/usr/bin/env bash
# Install records preserve the running digest and form valid Revert targets.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin image-drift-install
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
rec_out=$(
    python3 -I - "$REPO_ROOT" "$TMP_DIR" <<'PYTEST' 2>&1
import importlib.util
import pathlib
import sys

repo, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("image_drift", f"{repo}/scripts/image_drift.py")
m = importlib.util.module_from_spec(spec)
sys.modules["image_drift"] = m
spec.loader.exec_module(m)

# record_install writes service<TAB>image<TAB>digest for each running service (skips
# services with no resolvable local digest).
m.load_compose_images = lambda _p: [("sonarr", "lscr.io/x/sonarr:latest"),
                                     ("radarr", "lscr.io/x/radarr:latest"),
                                     ("ghost", "lscr.io/x/ghost:latest")]
m.container_image_id = lambda s: None if s == "ghost" else "img-" + s
m.image_repo_digest = lambda i, img: "sha256:" + "b" * 64
out = tmp / "image-install.tsv"
m.record_install(pathlib.Path("docker-compose.yml"), out)
rows = [l for l in out.read_text().splitlines() if l and not l.startswith("#")]
ok = (len(rows) == 2
      and all(len(r.split("\t")) == 3 for r in rows)
      and rows[0].startswith("sonarr\tlscr.io/x/sonarr:latest\tsha256:")
      and not any(r.startswith("ghost") for r in rows))
print("RECORD_OK" if ok else "RECORD_BAD:" + repr(rows))

# Given compose is already pinned to a candidate while Stable runs the accepted digest.
m.load_compose_images = lambda _p: [("sonarr", "lscr.io/x/sonarr:latest@sha256:" + "a" * 64)]

# When the install record is written from the actual running digest.
m.record_install(pathlib.Path("docker-compose.yml"), out)
data = [line.split("\t") for line in out.read_text().splitlines() if not line.startswith("#")]

# Then appending its digest for Revert creates exactly one valid digest separator.
expected = [["sonarr", "lscr.io/x/sonarr:latest", "sha256:" + "b" * 64]]
print("PINNED_IMAGE_NORMALIZED" if data == expected else "PINNED_IMAGE_INVALID")
PYTEST
)
assert_contains "$rec_out" "RECORD_OK" "install record writes running services and skips absent services"
assert_contains "$rec_out" "PINNED_IMAGE_NORMALIZED" "install record forms one valid Revert digest pin"
summary
