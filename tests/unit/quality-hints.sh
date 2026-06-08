#!/usr/bin/env bash
# tests/unit/quality-hints.sh
#
# Regression for #96: the shared two-axis quality picker
# (scripts/lib/quality_select.sh, used by BOTH the install wizard and the day-2
# launcher) must show size-menu GB hints that match the resolution just chosen —
# 720p shows 720p sizes, 1080p shows 1080p sizes — NOT always the 1080p column
# with a contradictory "at 1080p" suffix.
#
# It drives the REAL quality_select_pick against the REAL presets.yml /
# wizard_apply.py, stubbing only the UI (ui_choose) and the logger (log_error,
# which lives in common.sh and isn't sourced here), and captures the size-menu
# option labels the picker builds for a forced resolution.
#
# It also locks the "adding a resolution is data-only" contract from the other
# direction: list_axes must not crash on a resolution that has NO size_hints
# block — the hint just degrades to absent.
#
# Run directly: ./tests/unit/quality-hints.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="quality-hints"
scenario_begin "$CURRENT_SCENARIO"

# ---------------------------------------------------------------------------
# Drive the REAL picker for one resolution and print the size-menu labels it
# builds (one per line). The ui_choose stub returns the resolution option whose
# label starts with WANT_RES on the resolution prompt, and on the size prompt
# writes every option label to a capture file (then returns one — the picked
# size is irrelevant; we assert on the LABELS, not the choice).
# ---------------------------------------------------------------------------
pick_size_labels() {
  WANT_RES="$1" PICK_SCRIPT_DIR="$REPO_ROOT" bash -c '
    set -uo pipefail
    log_error(){ echo "ERR: $*" >&2; }
    SCRIPT_DIR="$PICK_SCRIPT_DIR"
    CAP=$(mktemp)
    ui_choose(){
      local prompt="$1"; shift
      if [[ "$prompt" == *"video resolution"* ]]; then
        local o
        for o in "$@"; do [[ "$o" == "$WANT_RES"* ]] && { printf "%s" "$o"; return 0; }; done
        printf "%s" "$1"; return 0
      fi
      printf "%s\n" "$@" > "$CAP"
      printf "%s" "$1"; return 0
    }
    source "$SCRIPT_DIR/scripts/lib/quality_select.sh"
    _r=""; _s=""
    if ! quality_select_pick _r _s >/dev/null 2>&1; then
      echo "PICKER_FAILED"; rm -f "$CAP"; exit 0
    fi
    cat "$CAP"; rm -f "$CAP"
  '
}

labels_720="$(pick_size_labels 720p)"
labels_1080="$(pick_size_labels 1080p)"

# Non-vacuity guard: the capture must be non-empty AND carry a GB hint at all.
# Without this, the negative assertions below would pass even if the fix had
# made the hint vanish entirely (the exact failure mode being guarded).
assert_contains "$labels_720"  "GB/movie" "720p: size menu carries a GB hint (capture non-empty)"
assert_contains "$labels_1080" "GB/movie" "1080p: size menu carries a GB hint (capture non-empty)"

# Positive, per resolution — these FAIL on pre-#96 code (which renders the 1080p
# column "~N GB/movie at 1080p" for EVERY resolution). Source of truth:
# docs/reference/quality-bounds.md "Cells at a glance".
assert_contains "$labels_720"  "~1.5-3 GB/movie" "720p Compact hint is the 720p number (~1.5-3)"
assert_contains "$labels_720"  "~2-4 GB/movie"   "720p Balanced hint is the 720p number (~2-4)"
assert_contains "$labels_720"  "~3-5 GB/movie"   "720p Large hint is the 720p number (~3-5)"
assert_contains "$labels_1080" "~2-4 GB/movie"   "1080p Compact hint is the 1080p number (~2-4)"
assert_contains "$labels_1080" "~4-8 GB/movie"   "1080p Balanced hint is the 1080p number (~4-8)"
assert_contains "$labels_1080" "~6-15 GB/movie"  "1080p Large hint is the 1080p number (~6-15)"

# Negative — proves resolution-awareness, not merely "a hint exists". 720p must
# not show the 1080p-Large number, and the contradictory "at 1080p" anchor (the
# whole bug) must be gone. (assert.sh has no assert_not_contains; herestring,
# not a pipe, to avoid the SIGPIPE-under-pipefail race.)
if grep -qF "~6-15 GB/movie" <<<"$labels_720"; then
  fail "720p does not show the 1080p-Large size" "720p menu contained '~6-15 GB/movie'"
else
  pass "720p does not show the 1080p-Large size (~6-15 GB/movie)"
fi
if grep -qF "at 1080p" <<<"$labels_720"; then
  fail "size hints no longer say 'at 1080p'" "720p menu still contained 'at 1080p'"
else
  pass "size hints no longer say 'at 1080p'"
fi

# ---------------------------------------------------------------------------
# Data-only contract (other direction): a resolution with NO size_hints block
# must not crash list_axes (--list-axes). It just emits no HINT rows for that
# resolution, so the picker degrades to a hint-less size menu rather than aborting
# the wizard. (tests/unit/wizard-composition.sh proves the COMPOSE side of the
# same data-only add; this locks the MENU-source side.)
# ---------------------------------------------------------------------------
degrade="$(MS_DIR="$REPO_ROOT" python3 -c '
import os, sys
sys.path.insert(0, os.path.join(os.environ["MS_DIR"], "scripts", "setup"))
import wizard_apply as w
m = w.load_quality_model(os.path.join(os.environ["MS_DIR"], "scripts", "setup", "presets.yml"))
m["resolutions"]["2160p"] = {"display_name": "2160p", "description": "4K",
                             "cutoff_group": 1003, "tiers": ["SDTV"]}  # no size_hints
tsv = w.list_axes(m)  # must NOT raise
assert "RESOLUTION\t2160p" in tsv, "2160p resolution row missing"
assert "HINT\tcompact\t2160p" not in tsv, "hint-less 2160p should emit no HINT rows"
print("OK")
' 2>&1)"
assert_eq "OK" "$degrade" "list_axes survives a hint-less resolution (data-only add stays safe)"

scenario_end "$CURRENT_SCENARIO"
summary
