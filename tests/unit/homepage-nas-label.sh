#!/usr/bin/env bash
# tests/unit/homepage-nas-label.sh
#
# Guards _homepage_apply_nas_label (scripts/services/homepage/main.sh): on
# NAS+watchdog installs the header /data disk readout moves into its own labeled
# "NAS" resources block; otherwise it stays folded into the main resources
# widget. The transform must be idempotent and must always leave valid YAML — a
# malformed widgets.yaml breaks Homepage's entire header. This path has no DinD
# coverage (the NAS branch is gated on a live systemd watchdog service), so it is
# tested directly here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/scripts/lib/common.sh" # log_skip/log_ok used by the fn
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/services/homepage/main.sh" # _homepage_apply_nas_label

CURRENT_SCENARIO="homepage-nas-label"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
W="$TMP_DIR/widgets.yaml"

# shape: "<main_disk> <nas_block> <valid>" — whether the main (cpu/memory)
# resources widget still carries disk, whether a label:NAS disk block exists,
# and whether the file parses as YAML.
shape() {
    WF="$1" python3 -c '
import os, yaml
try:
    w = yaml.safe_load(open(os.environ["WF"])) or []
except Exception:
    print("? ? no"); raise SystemExit
main_disk = nas = "no"
for it in w:
    if not isinstance(it, dict) or "resources" not in it:
        continue
    r = it["resources"] or {}
    if r.get("label") == "NAS" and "disk" in r:
        nas = "yes"
    elif ("cpu" in r or "memory" in r) and "disk" in r:
        main_disk = "yes"
print(main_disk, nas, "yes")
'
}

# Start from the real shipped pre-seed.
cp "$REPO_ROOT/config/examples/defaults/homepage/widgets.yaml" "$W"

# 1. Local (want=false) on the pristine pre-seed: disk stays in main, no NAS block.
_homepage_apply_nas_label "$W" false >/dev/null
assert_eq "yes no yes" "$(shape "$W")" "local: disk stays in main resources widget, valid YAML"

# 2. NAS (want=true): disk splits into a labeled NAS block, gone from main.
_homepage_apply_nas_label "$W" true >/dev/null
assert_eq "no yes yes" "$(shape "$W")" "NAS: disk moved to labeled NAS block, valid YAML"

# 3. Idempotent: a second want=true leaves the file byte-identical.
before=$(md5sum "$W" | awk '{print $1}')
_homepage_apply_nas_label "$W" true >/dev/null
after=$(md5sum "$W" | awk '{print $1}')
assert_eq "$before" "$after" "NAS: re-run is a no-op (idempotent)"

# 4. Reset (want=false): disk folds back into main, NAS block removed.
_homepage_apply_nas_label "$W" false >/dev/null
assert_eq "yes no yes" "$(shape "$W")" "reset: disk folded back to main, NAS block removed"

scenario_end "$CURRENT_SCENARIO"
summary
