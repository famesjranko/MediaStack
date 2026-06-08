# tests/api-matrix/quality.sh — api-matrix test-1: Sonarr/Radarr quality profiles.
#
# Loops the six (resolution x size) cells against a LIVE *arr instance, applying
# each IN PLACE (apply_cell.py PUTs the same profile id, renaming across cells)
# via the product renderers, then asserts the live API reflects the cell:
# profile name, enabled leaf-quality set, cutoff group, and a global size bound.
#
# Expected values come from the product's compose_cell too (not hardcoded), so
# this proves "composed cell -> render -> live API" round-trips faithfully and
# in place — the contract the day-2 change-quality action (#71) wraps.
#
#   matrix_quality APP BASE_URL API_KEY

API_MATRIX_CELLS=(
    "720p compact"  "720p balanced"  "720p large"
    "1080p compact" "1080p balanced" "1080p large"
)

# Echo "name|sorted_enabled|cutoff|WEBDL-720p_pref(.1f)" for a cell, from presets.yml.
_qm_expected() {
    local app="$1" res="$2" size="$3"
    python3 - "$app" "$res" "$size" <<'PY'
import sys
sys.path.insert(0, "scripts/setup")
import wizard_apply
app, res, size = sys.argv[1:4]
m = wizard_apply.load_quality_model("scripts/setup/presets.yml")
c = wizard_apply.compose_cell(m, res, size)
enabled = ",".join(str(i) for i in sorted(c[f"{app}_qualities"]))
pref = c["quality_definitions"][app].get("WEBDL-720p", {}).get("preferred")
pref = format(float(pref), ".1f") if pref is not None else ""
print("|".join([c["profile_name"], enabled, str(c["cutoff_id"]), pref]))
PY
}

# Echo "name|sorted_enabled_leaf_ids|cutoff" for a live profile id.
_qm_live_profile() {
    local base="$1" key="$2" pid="$3"
    dind_exec "curl -sf -H 'X-Api-Key: $key' $base/qualityprofile/$pid" | python3 -c '
import sys, json
p = json.load(sys.stdin)
ids = set()
for it in p.get("items", []):
    if it.get("allowed") and it.get("quality"): ids.add(it["quality"]["id"])
    for s in it.get("items", []):
        if s.get("allowed") and s.get("quality"): ids.add(s["quality"]["id"])
print("|".join([p.get("name",""), ",".join(str(i) for i in sorted(ids)), str(p.get("cutoff",""))]))
' 2>/dev/null
}

# Echo the live WEBDL-720p preferredSize (.1f).
_qm_live_pref() {
    local base="$1" key="$2"
    dind_exec "curl -sf -H 'X-Api-Key: $key' $base/qualitydefinition" | python3 -c '
import sys, json
for d in json.load(sys.stdin):
    if d.get("quality",{}).get("name") == "WEBDL-720p":
        print(format(float(d.get("preferredSize",0)), ".1f")); break
' 2>/dev/null
}

matrix_quality() {
    local app="$1" base="$2" key="$3"
    local label="${app^}"
    local pid="" cell res size exp live
    local exp_name exp_ids exp_cut exp_pref lv_name lv_ids lv_cut

    for cell in "${API_MATRIX_CELLS[@]}"; do
        res="${cell%% *}"; size="${cell##* }"

        # Apply the cell via the product renderers: POST the first, PUT the rest
        # to the SAME id (in-place rename + repush — the #71 mechanism).
        if [[ -z "$pid" ]]; then
            pid=$(dind_exec "python3 tests/api-matrix/apply_cell.py $app $base $key $res $size")
        else
            dind_exec "python3 tests/api-matrix/apply_cell.py $app $base $key $res $size $pid" >/dev/null
        fi
        if [[ -z "$pid" ]]; then
            fail "$label api-matrix: $res $size apply returned no profile id"
            continue
        fi

        exp=$(_qm_expected "$app" "$res" "$size")
        exp_name="${exp%%|*}"; exp="${exp#*|}"
        exp_ids="${exp%%|*}";  exp="${exp#*|}"
        exp_cut="${exp%%|*}";  exp_pref="${exp##*|}"

        live=$(_qm_live_profile "$base" "$key" "$pid")
        lv_name="${live%%|*}"; live="${live#*|}"
        lv_ids="${live%%|*}";  lv_cut="${live##*|}"

        assert_eq "$exp_name" "$lv_name" "$label api-matrix: $res $size profile name (in-place id=$pid)"
        assert_eq "$exp_ids"  "$lv_ids"  "$label api-matrix: $res $size enabled set landed via API"
        assert_eq "$exp_cut"  "$lv_cut"  "$label api-matrix: $res $size cutoff landed via API"
        assert_eq "$exp_pref" "$(_qm_live_pref "$base" "$key")" \
            "$label api-matrix: $res $size WEBDL-720p preferred bound landed (global def)"
    done
}
