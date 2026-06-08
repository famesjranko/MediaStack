#!/usr/bin/env bash
# =============================================================================
# Unit test — data-only resolution add (the epic's acceptance proof)
# =============================================================================
# Proves the resolution × size abstraction: adding a NEW resolution (2160p/4K)
# is a PURE DATA change to presets.yml — a new `resolutions` block, its
# `quality_ids`, and (optionally) its size `bounds` rows — with ZERO edits to
# wizard_apply.py, stage1.sh, or render/*.py. This test composes (2160p ×
# balanced) through the UNMODIFIED, committed wizard_apply.py; the fact that it
# renders correctly IS the proof that the mechanism is data-driven.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-composition"
scenario_begin "$CURRENT_SCENARIO"

WIZARD="$REPO_ROOT/scripts/setup/wizard_apply.py"
PRESETS_SRC="$REPO_ROOT/scripts/setup/presets.yml"
CONFIG_SRC="$REPO_ROOT/config.yml"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

FIXTURE="$TMP_DIR/presets-2160.yml"
CONFIG="$TMP_DIR/cfg.yml"
cp "$CONFIG_SRC" "$CONFIG"

# --- Build the fixture: add 2160p as DATA ONLY (no code touched) -------------
python3 - "$PRESETS_SRC" "$FIXTURE" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
m = yaml.safe_load(open(src))

# New 2160p quality ids (same numbers in Sonarr and Radarr at 2160p).
for app in ("sonarr", "radarr"):
    m["quality_ids"][app].update({
        "HDTV-2160p": 16, "WEBRip-2160p": 17,
        "WEBDL-2160p": 18, "Bluray-2160p": 19,
    })

# New resolution: ceiling 2160p, cutoff group 1003 — pure data.
m["resolutions"]["2160p"] = {
    "display_name": "2160p",
    "description": "4K Ultra HD.",
    "cutoff_group": 1003,
    "tiers": list(m["resolutions"]["1080p"]["tiers"]) + [
        "HDTV-2160p", "WEBDL-2160p", "WEBRip-2160p", "Bluray-2160p",
    ],
}

# New 2160p size bounds in the balanced table (also pure data) — proves the
# bounds mask picks up the new tiers without a code change.
m["sizes"]["balanced"]["bounds"]["sonarr"].update({
    "HDTV-2160p":   {"min": 30.0, "preferred": 90.0,  "max": 150.0},
    "WEBDL-2160p":  {"min": 35.0, "preferred": 100.0, "max": 160.0},
    "WEBRip-2160p": {"min": 35.0, "preferred": 100.0, "max": 160.0},
    "Bluray-2160p": {"min": 50.0, "preferred": 130.0, "max": 200.0},
})
m["sizes"]["balanced"]["bounds"]["radarr"].update({
    "HDTV-2160p":   {"min": 30.0, "preferred": 90.0,  "max": 150.0},
    "WEBDL-2160p":  {"min": 35.0, "preferred": 100.0, "max": 160.0},
    "WEBRip-2160p": {"min": 35.0, "preferred": 100.0, "max": 160.0},
    "Bluray-2160p": {"min": 50.0, "preferred": 130.0, "max": 200.0},
})

yaml.safe_dump(m, open(dst, "w"), sort_keys=False)
PY

# --- Compose (2160p × balanced) with the UNMODIFIED wizard_apply.py ----------
python3 "$WIZARD" --resolution 2160p --size balanced \
    --presets-file "$FIXTURE" --config "$CONFIG" >/dev/null 2>&1

yaml_get() {
    python3 -c "
import yaml, json
c = yaml.safe_load(open('$CONFIG'))
r = $1
print(json.dumps(sorted(r)) if isinstance(r, list) else r)
" 2>/dev/null
}

assert_eq "2160p Balanced" "$(yaml_get "c['quality_profile']['name']")" \
    "data-only 2160p: composed profile name"

assert_eq "1003" "$(yaml_get "c['quality_profile']['cutoff_id']")" \
    "data-only 2160p: cutoff group 1003 (WEB 2160p)"

# Enabled set = the full 1080p ladder PLUS the four new 2160p ids (16,17,18,19).
assert_eq "[1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16, 17, 18, 19]" \
    "$(yaml_get "c['quality_profile']['sonarr_qualities']")" \
    "data-only 2160p: sonarr ladder gains 2160p ids"

# The new 2160p bounds rows compose into quality_definitions (masked in).
assert_eq "100.0" \
    "$(yaml_get "c['quality_definitions']['sonarr']['WEBDL-2160p']['preferred']")" \
    "data-only 2160p: new WEBDL-2160p bound present"

# Sanity: a config.yml composed from the SHIPPED presets.yml has no 2160p, so
# the only thing that added it was data in the fixture — not a code path.
cp "$CONFIG_SRC" "$TMP_DIR/shipped.yml"
python3 "$WIZARD" --resolution 1080p --size balanced --config "$TMP_DIR/shipped.yml" >/dev/null 2>&1
if python3 -c "
import yaml
c = yaml.safe_load(open('$TMP_DIR/shipped.yml'))
ids = c['quality_profile']['sonarr_qualities']
exit(0 if not (set(ids) & {16,17,18,19}) else 1)
"; then
    pass "data-only 2160p: shipped presets carry no 2160p (proof it was data, not code)"
else
    fail "data-only 2160p: shipped presets carry no 2160p" "found 2160p ids without the fixture"
fi

scenario_end "$CURRENT_SCENARIO"
summary
