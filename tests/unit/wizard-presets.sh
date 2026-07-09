#!/usr/bin/env bash
# =============================================================================
# Unit test — wizard_apply.py resolution × size composition
# =============================================================================
# Verifies that each (resolution × size) cell correctly composes config.yml
# without damaging untouched sections, and that the idempotency marker is set.
# The composition mechanism lives in wizard_apply.py:compose_cell; the data is
# scripts/setup/presets.yml (quality_ids/resolutions/sizes).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-presets"
scenario_begin "$CURRENT_SCENARIO"

WIZARD="$REPO_ROOT/scripts/setup/wizard_apply.py"
CONFIG_SRC="$REPO_ROOT/config/examples/config.yml"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper: compose a (resolution × size) cell and return the rendered config path.
apply_and_parse() {
    local resolution="$1"
    local size="$2"
    local languages="${3:-english}"
    local public_indexers="${4:-false}"
    local config="$TMP_DIR/${resolution}-${size}.yml"
    cp "$CONFIG_SRC" "$config"
    python3 "$WIZARD" \
        --resolution "$resolution" --size "$size" \
        --languages "$languages" \
        --public-indexers "$public_indexers" \
        --config "$config" >/dev/null 2>&1
    echo "$config"
}

yaml_get() {
    local config="$1" expr="$2"
    python3 -c "
import yaml, json
with open('$config') as f:
    c = yaml.safe_load(f)
result = $expr
if isinstance(result, list):
    print(json.dumps(sorted(result)))
elif isinstance(result, bool):
    print('true' if result else 'false')
else:
    print(result)
" 2>/dev/null
}

# =========================================================================
# 720p Compact — smallest cell. Enabled set is the SD floor + all 720p sources
# (the size is source-agnostic: compact no longer means "WEB only").
# =========================================================================
config=$(apply_and_parse 720p compact "english,spanish")

assert_eq "720p Compact" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "720p compact: profile name"

assert_eq "1001" \
    "$(yaml_get "$config" "c['quality_profile']['cutoff_id']")" \
    "720p compact: cutoff_id (WEB 720p)"

# yaml_get sorts numerically, so this asserts the enabled SET (not file order, not
# upgrade path): SDTV1 DVD2 HDTV-720p4 WEBDL-720p5 Bluray-720p6 WEBDL-480p8 WEBRip-480p12 Bluray-480p13 WEBRip-720p14
assert_eq "[1, 2, 4, 5, 6, 8, 12, 13, 14]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "720p compact: sonarr qualities (SD floor → 720p, all sources)"

# Radarr differs from Sonarr only in Bluray-480p (20 not 13).
assert_eq "[1, 2, 4, 5, 6, 8, 12, 14, 20]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "720p compact: radarr qualities (Bluray-480p=20, differs from Sonarr's 13)"

assert_eq "20.0" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr']['WEBDL-720p']['preferred']")" \
    "720p compact: sonarr WEBDL-720p preferred (carried from old compact)"

# SD floor is present in the masked bounds table.
assert_eq "6.0" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr']['SDTV']['preferred']")" \
    "720p compact: SD floor bound present (SDTV)"

# Bounds masked to the resolution: no 1080p tiers in a 720p cell.
assert_eq "None" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr'].get('WEBDL-1080p')")" \
    "720p compact: 1080p bounds masked out"

assert_eq '["english", "spanish"]' \
    "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "720p compact: bazarr languages"

assert_eq "true" \
    "$(yaml_get "$config" "c['wizard_completed']")" \
    "720p compact: wizard_completed marker"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x264']")" \
    "compact size: x264 score is 0 (codec-neutral)"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "compact size: x265 score is 0 (codec-neutral)"

assert_eq "-10" \
    "$(yaml_get "$config" "c['custom_formats']['No-RlsGroup']")" \
    "compact size: No-RlsGroup light penalty"

# =========================================================================
# 1080p Balanced — the recommended cell (effect-equivalent of the old
# "balanced": carries ADR-25's 720p/1080p values, plus the SD floor).
# =========================================================================
config=$(apply_and_parse 1080p balanced)

assert_eq "1080p Balanced" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "1080p balanced: profile name"

assert_eq "1002" \
    "$(yaml_get "$config" "c['quality_profile']['cutoff_id']")" \
    "1080p balanced: cutoff_id (WEB 1080p)"

# Full ladder: SD floor + 720p + 1080p sources.
assert_eq "[1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "1080p balanced: sonarr qualities (SD floor → 1080p)"

assert_eq "[1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 14, 15, 20]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "1080p balanced: radarr qualities (no Remux — dropped for size control)"

assert_eq "30.0" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr']['HDTV-720p']['preferred']")" \
    "1080p balanced: sonarr HDTV-720p preferred carried from ADR-25"

assert_eq "50.0" \
    "$(yaml_get "$config" "c['quality_definitions']['radarr']['WEBDL-1080p']['preferred']")" \
    "1080p balanced: radarr WEBDL-1080p preferred carried from ADR-25"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x264']")" \
    "balanced size: x264 neutral (0)"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "balanced size: x265 neutral (0 — transcoding server, and smaller files)"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['BR-DISK']")" \
    "balanced size: BR-DISK not hard-blocked (size envelope gates it)"

assert_eq "-100" \
    "$(yaml_get "$config" "c['custom_formats']['LQ']")" \
    "balanced size: LQ is a soft penalty (-100), not a hard block"

assert_eq "-10" \
    "$(yaml_get "$config" "c['custom_formats']['No-RlsGroup']")" \
    "balanced size: No-RlsGroup slight nudge (-10)"

# =========================================================================
# 1080p Large — best non-Remux 1080p (the old "quality", renamed Large).
# =========================================================================
config=$(apply_and_parse 1080p large "english,french")

assert_eq "1080p Large" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "1080p large: profile name"

assert_eq "[1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "1080p large: sonarr qualities (same ladder as balanced, larger envelope)"

assert_eq "[1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 14, 15, 20]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "1080p large: radarr qualities"

assert_eq "55.0" \
    "$(yaml_get "$config" "c['quality_definitions']['radarr']['WEBDL-1080p']['preferred']")" \
    "1080p large: radarr WEBDL-1080p preferred carried from old quality"

assert_eq '["english", "french"]' \
    "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "1080p large: bazarr languages"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "large size: x265 neutral (0 — scores are size-uniform)"

assert_eq "-100" \
    "$(yaml_get "$config" "c['custom_formats']['LQ']")" \
    "large size: LQ soft penalty (-100), not a hard block"

assert_eq "5" \
    "$(yaml_get "$config" "c['custom_formats']['Repack/Proper']")" \
    "large size: Repack/Proper always 5"

# =========================================================================
# Untouched sections preserved across cells
# =========================================================================
config=$(apply_and_parse 720p compact)

assert_eq "0" \
    "$(yaml_get "$config" "len(c['indexers'])")" \
    "public defaults: indexer preset disabled"

config=$(apply_and_parse 720p compact english true)

assert_eq "13" \
    "$(yaml_get "$config" "len(c['indexers'])")" \
    "public opt-in: indexer preset applied"

assert_eq "1" \
    "$(yaml_get "$config" "c['qbittorrent']['max_ratio']")" \
    "untouched: qbittorrent max_ratio preserved"

assert_eq "/data/media/tv" \
    "$(yaml_get "$config" "c['sonarr']['root_folder']")" \
    "untouched: sonarr root_folder preserved"

assert_eq "/data/media/movies" \
    "$(yaml_get "$config" "c['radarr']['root_folder']")" \
    "untouched: radarr root_folder preserved"

assert_eq "0" \
    "$(yaml_get "$config" "c['seerr']['quotas']['movie']['limit']")" \
    "untouched: seerr quotas preserved"

assert_eq "2" \
    "$(yaml_get "$config" "len(c['jellyfin']['libraries'])")" \
    "untouched: jellyfin libraries preserved"

assert_eq "15" \
    "$(yaml_get "$config" "c['rate_limiting']['requests_per_second']")" \
    "untouched: rate_limiting preserved"

# =========================================================================
# Idempotency: re-running on already-applied config
# =========================================================================
config=$(apply_and_parse 720p compact)
python3 "$WIZARD" --resolution 1080p --size large --languages "english" --config "$config" >/dev/null 2>&1

assert_eq "1080p Large" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "idempotency: second apply overwrites first"

assert_eq "true" \
    "$(yaml_get "$config" "c['wizard_completed']")" \
    "idempotency: marker still true after re-apply"

# =========================================================================
# Invalid selections
# =========================================================================
cp "$CONFIG_SRC" "$TMP_DIR/invalid.yml"
if python3 "$WIZARD" --resolution nonexistent --size balanced --config "$TMP_DIR/invalid.yml" 2>/dev/null; then
    fail "invalid resolution: should exit non-zero"
else
    pass "invalid resolution: exits non-zero"
fi

if python3 "$WIZARD" --resolution 1080p --size nonexistent --config "$TMP_DIR/invalid.yml" 2>/dev/null; then
    fail "invalid size: should exit non-zero"
else
    pass "invalid size: exits non-zero"
fi

# --resolution without --size (and vice versa) is an error.
if python3 "$WIZARD" --resolution 1080p --config "$TMP_DIR/invalid.yml" 2>/dev/null; then
    fail "missing --size: should exit non-zero"
else
    pass "missing --size: exits non-zero"
fi

# =========================================================================
# apply_bitrate_limit — scoped to jellyfin section, preserves comments
# =========================================================================
config="$TMP_DIR/bitrate.yml"
cp "$CONFIG_SRC" "$config"
python3 "$WIZARD" --resolution 1080p --size balanced --languages english --bitrate-limit 8 --config "$config" >/dev/null 2>&1
assert_eq "8" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: limit set to 8"

if grep -q 'remote_bitrate_limit: 8' "$config" && grep -q '# Mbps per remote viewer' "$config"; then
    pass "bitrate: inline comment preserved"
else
    fail "bitrate: inline comment preserved" "comment stripped after apply"
fi

python3 "$WIZARD" --resolution 1080p --size balanced --languages english --bitrate-limit 20 --config "$config" >/dev/null 2>&1
assert_eq "20" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: re-apply changes value to 20"

python3 "$WIZARD" --resolution 1080p --size balanced --languages english --bitrate-limit 0 --config "$config" >/dev/null 2>&1
assert_eq "0" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: 0 means unlimited"

# Decimals: the wizard accepts them (validate_mbps_decimal), so --bitrate-limit
# must too — and re-applying over an existing decimal must still match.
python3 "$WIZARD" --resolution 1080p --size balanced --languages english --bitrate-limit 3.5 --config "$config" >/dev/null 2>&1
assert_eq "3.5" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: decimal 3.5 accepted"

python3 "$WIZARD" --resolution 1080p --size balanced --languages english --bitrate-limit 7 --config "$config" >/dev/null 2>&1
assert_eq "7" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: re-apply over a decimal returns to whole 7"

# =========================================================================
# Wizard GPU choice → GPU_TYPE mapping (mirrors wizard.sh lines 57-62)
# =========================================================================
wizard_gpu_mapping() {
    local gpu_choice="$1"
    case "$gpu_choice" in
        "NVIDIA GPU"*) echo "nvidia" ;;
        "AMD VAAPI"*)  echo "amd" ;;
        "Intel Quick"*) echo "intel" ;;
        *) echo "none" ;;
    esac
}

assert_eq "nvidia" "$(wizard_gpu_mapping 'NVIDIA GPU (recommended)')" \
    "wizard GPU: NVIDIA → nvidia"

assert_eq "amd" "$(wizard_gpu_mapping 'AMD VAAPI (recommended)')" \
    "wizard GPU: AMD → amd"

assert_eq "intel" "$(wizard_gpu_mapping 'Intel Quick Sync (recommended)')" \
    "wizard GPU: Intel → intel"

assert_eq "none" "$(wizard_gpu_mapping 'CPU only (software transcoding)')" \
    "wizard GPU: CPU only → none"

assert_eq "none" "$(wizard_gpu_mapping 'something unexpected')" \
    "wizard GPU: unknown → none"

# =========================================================================
# --indexers-only — day-2 Features toggle: rewrites ONLY the indexers section,
# leaving quality/subtitle/custom-format config byte-identical (no clobber).
# =========================================================================
# Start from a non-default state: 720p compact + spanish subtitles, indexers on.
config="$TMP_DIR/indexers-only.yml"
cp "$CONFIG_SRC" "$config"
python3 "$WIZARD" --resolution 720p --size compact --languages "english,spanish" \
    --public-indexers true --config "$config" >/dev/null 2>&1

# Snapshot the sections --indexers-only must NOT touch.
before_quality=$(yaml_get "$config" "c['quality_profile']['name']")
before_langs=$(yaml_get "$config" "c['bazarr']['languages']")
before_cf=$(yaml_get "$config" "c['custom_formats']['No-RlsGroup']")

# Disable indexers via the surgical mode.
python3 "$WIZARD" --indexers-only false --config "$config" >/dev/null 2>&1
assert_eq "0" "$(yaml_get "$config" "len(c['indexers'])")" \
    "indexers-only false: indexer list cleared"
assert_eq "$before_quality" "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "indexers-only false: quality profile untouched"
assert_eq "$before_langs" "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "indexers-only false: subtitle languages untouched"
assert_eq "$before_cf" "$(yaml_get "$config" "c['custom_formats']['No-RlsGroup']")" \
    "indexers-only false: custom formats untouched"

# Re-enable indexers via the surgical mode.
python3 "$WIZARD" --indexers-only true --config "$config" >/dev/null 2>&1
assert_eq "13" "$(yaml_get "$config" "len(c['indexers'])")" \
    "indexers-only true: indexer preset re-applied"
assert_eq "$before_quality" "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "indexers-only true: quality profile still untouched"
assert_eq "$before_langs" "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "indexers-only true: subtitle languages still untouched"

# --indexers-only ignores quality selection entirely (does not require it).
config="$TMP_DIR/indexers-only-noquality.yml"
cp "$CONFIG_SRC" "$config"
if python3 "$WIZARD" --indexers-only true --config "$config" >/dev/null 2>&1; then
    assert_eq "13" "$(yaml_get "$config" "len(c['indexers'])")" \
        "indexers-only: works with no resolution/size given"
else
    fail "indexers-only: works with no resolution/size given" "exited non-zero"
fi

# =========================================================================
# --quality-only — day-2 "Change quality profile": rewrites ONLY the three
# quality sections (quality_profile + quality_definitions + custom_formats),
# leaving indexers, subtitle languages and remote bitrate byte-identical.
# =========================================================================
# Raw byte text of a config.yml section, via the product's own span finder, so
# "untouched" means byte-identical (not just equal parsed values).
qonly_section_text() {
    REPO="$REPO_ROOT" python3 - "$1" "$2" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["REPO"], "scripts", "setup"))
import wizard_apply as w
text = open(sys.argv[1]).read()
span = w.find_section_span(text, sys.argv[2])
sys.stdout.write(text[span[0]:span[1]] if span else "<missing>")
PY
}

# Seed a non-default state: 1080p balanced, spanish subtitles, indexers ON,
# a custom remote bitrate — every axis --quality-only must NOT touch.
config="$TMP_DIR/quality-only.yml"
cp "$CONFIG_SRC" "$config"
python3 "$WIZARD" --resolution 1080p --size balanced --languages "english,spanish" \
    --public-indexers true --bitrate-limit 25 --config "$config" >/dev/null 2>&1

before_indexers_text=$(qonly_section_text "$config" "indexers")
before_bazarr_text=$(qonly_section_text "$config" "bazarr")
before_bitrate=$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")
before_qname=$(yaml_get "$config" "c['quality_profile']['name']")
# Custom-format scores are now size-independent, so prove the cell re-composed via
# a size-varying BOUND instead (SDTV is in every cell's SD floor: balanced 8.0 -> large 10.0).
before_sdtv=$(yaml_get "$config" "c['quality_definitions']['radarr']['SDTV']['preferred']")

# Change cell: 1080p balanced -> 720p large (resolution AND size both move).
python3 "$WIZARD" --quality-only --resolution 720p --size large --config "$config" >/dev/null 2>&1

# Quality sections changed to the new cell.
assert_eq "720p Large" "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "quality-only: profile name recomposed to '720p Large'"
assert_eq "1001" "$(yaml_get "$config" "c['quality_profile']['cutoff_id']")" \
    "quality-only: cutoff_id follows 720p ceiling (1001)"
assert_eq "10.0" "$(yaml_get "$config" "c['quality_definitions']['radarr']['SDTV']['preferred']")" \
    "quality-only: size-varying bounds follow the large size (radarr SDTV preferred 10.0)"
[[ "$before_qname" != "720p Large" ]] \
    && pass "quality-only: profile name actually changed (was '$before_qname')" \
    || fail "quality-only: profile name actually changed" "still '$before_qname'"
[[ "$before_sdtv" != "10.0" ]] \
    && pass "quality-only: size-varying bound actually changed (SDTV was '$before_sdtv')" \
    || fail "quality-only: size-varying bound actually changed" "still '$before_sdtv'"

# Everything else byte-identical.
assert_eq "$before_indexers_text" "$(qonly_section_text "$config" "indexers")" \
    "quality-only: indexers section byte-identical"
assert_eq "$before_bazarr_text" "$(qonly_section_text "$config" "bazarr")" \
    "quality-only: bazarr/subtitle section byte-identical"
assert_eq "$before_bitrate" "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "quality-only: remote bitrate (bandwidth) untouched"

# --quality-only requires both axes (errors without them, like the wizard).
config="$TMP_DIR/quality-only-missing.yml"
cp "$CONFIG_SRC" "$config"
if python3 "$WIZARD" --quality-only --config "$config" >/dev/null 2>&1; then
    fail "quality-only: errors without --resolution/--size" "exited zero"
else
    pass "quality-only: errors without --resolution/--size"
fi

scenario_end "$CURRENT_SCENARIO"
summary
