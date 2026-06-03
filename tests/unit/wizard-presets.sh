#!/usr/bin/env bash
# =============================================================================
# Unit test — wizard_apply.py preset application
# =============================================================================
# Verifies that each preset correctly modifies config.yml without damaging
# untouched sections, and that the idempotency marker is set.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-presets"
scenario_begin "$CURRENT_SCENARIO"

WIZARD="$REPO_ROOT/scripts/setup/wizard_apply.py"
CONFIG_SRC="$REPO_ROOT/config.yml"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Helper: apply preset and parse result
apply_and_parse() {
    local preset="$1"
    local languages="${2:-english}"
    local public_indexers="${3:-false}"
    local config="$TMP_DIR/${preset}.yml"
    cp "$CONFIG_SRC" "$config"
    python3 "$WIZARD" \
        --preset "$preset" \
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
# Compact preset
# =========================================================================
config=$(apply_and_parse compact "english,spanish")

assert_eq "WEB-720p/1080p" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "compact: profile name"

assert_eq "1001" \
    "$(yaml_get "$config" "c['quality_profile']['cutoff_id']")" \
    "compact: cutoff_id"

assert_eq "[5, 14]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "compact: sonarr qualities (WEB 720p only)"

assert_eq "[5, 14]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "compact: radarr qualities (WEB 720p only)"

assert_eq "20.0" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr']['WEBDL-720p']['preferred']")" \
    "compact: sonarr WEBDL-720p preferred tightened to ~1 GB/ep"

assert_eq '["english", "spanish"]' \
    "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "compact: bazarr languages"

assert_eq "true" \
    "$(yaml_get "$config" "c['wizard_completed']")" \
    "compact: wizard_completed marker"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x264']")" \
    "compact: x264 score is 0 (codec-neutral)"

assert_eq "0" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "compact: x265 score is 0 (codec-neutral)"

assert_eq "-10" \
    "$(yaml_get "$config" "c['custom_formats']['No-RlsGroup']")" \
    "compact: No-RlsGroup light penalty"

# =========================================================================
# Balanced preset — should match shipped defaults
# =========================================================================
config=$(apply_and_parse balanced)

assert_eq "HD-720p/1080p" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "balanced: profile name matches default"

assert_eq "1002" \
    "$(yaml_get "$config" "c['quality_profile']['cutoff_id']")" \
    "balanced: cutoff_id matches default"

assert_eq "[3, 4, 5, 6, 7, 9, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "balanced: sonarr qualities"

assert_eq "[3, 4, 5, 6, 7, 9, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "balanced: radarr qualities (no Remux — dropped for size control)"

assert_eq "30.0" \
    "$(yaml_get "$config" "c['quality_definitions']['sonarr']['HDTV-720p']['preferred']")" \
    "balanced: sonarr HDTV-720p preferred sized for ~1.4 GB/ep"

assert_eq "50.0" \
    "$(yaml_get "$config" "c['quality_definitions']['radarr']['WEBDL-1080p']['preferred']")" \
    "balanced: radarr WEBDL-1080p preferred sized for ~5.5 GB/movie"

assert_eq "10" \
    "$(yaml_get "$config" "c['custom_formats']['x264']")" \
    "balanced: x264 score is 10"

assert_eq "-25" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "balanced: x265 score is -25"

assert_eq "-10000" \
    "$(yaml_get "$config" "c['custom_formats']['BR-DISK']")" \
    "balanced: BR-DISK blocks"

# =========================================================================
# Quality preset
# =========================================================================
config=$(apply_and_parse quality "english,french")

assert_eq "HQ-1080p" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "quality: profile name"

assert_eq "[3, 4, 5, 6, 7, 9, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['sonarr_qualities']")" \
    "quality: sonarr qualities (1080p + 720p fallback, no Remux)"

assert_eq "[3, 4, 5, 6, 7, 9, 14, 15]" \
    "$(yaml_get "$config" "c['quality_profile']['radarr_qualities']")" \
    "quality: radarr qualities (1080p + 720p fallback, no Remux)"

assert_eq "55.0" \
    "$(yaml_get "$config" "c['quality_definitions']['radarr']['WEBDL-1080p']['preferred']")" \
    "quality: radarr WEBDL-1080p preferred sized for ~6 GB/movie (real 1080p WEB)"

assert_eq '["english", "french"]' \
    "$(yaml_get "$config" "c['bazarr']['languages']")" \
    "quality: bazarr languages"

assert_eq "-50" \
    "$(yaml_get "$config" "c['custom_formats']['x265 (HD)']")" \
    "quality: x265 strong penalty"

assert_eq "5" \
    "$(yaml_get "$config" "c['custom_formats']['Repack/Proper']")" \
    "quality: Repack/Proper always 5"

# =========================================================================
# Untouched sections preserved across all presets
# =========================================================================
config=$(apply_and_parse compact)

assert_eq "0" \
    "$(yaml_get "$config" "len(c['indexers'])")" \
    "public defaults: indexer preset disabled"

config=$(apply_and_parse compact english true)

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
    "$(yaml_get "$config" "c['jellyseerr']['quotas']['movie']['limit']")" \
    "untouched: jellyseerr quotas preserved"

assert_eq "2" \
    "$(yaml_get "$config" "len(c['jellyfin']['libraries'])")" \
    "untouched: jellyfin libraries preserved"

assert_eq "15" \
    "$(yaml_get "$config" "c['rate_limiting']['requests_per_second']")" \
    "untouched: rate_limiting preserved"

# =========================================================================
# Idempotency: re-running on already-applied config
# =========================================================================
config=$(apply_and_parse compact)
python3 "$WIZARD" --preset quality --languages "english" --config "$config" >/dev/null 2>&1

assert_eq "HQ-1080p" \
    "$(yaml_get "$config" "c['quality_profile']['name']")" \
    "idempotency: second apply overwrites first"

assert_eq "true" \
    "$(yaml_get "$config" "c['wizard_completed']")" \
    "idempotency: marker still true after re-apply"

# =========================================================================
# Invalid preset
# =========================================================================
cp "$CONFIG_SRC" "$TMP_DIR/invalid.yml"
if python3 "$WIZARD" --preset nonexistent --config "$TMP_DIR/invalid.yml" 2>/dev/null; then
    fail "invalid preset: should exit non-zero"
else
    pass "invalid preset: exits non-zero"
fi

# =========================================================================
# apply_bitrate_limit — scoped to jellyfin section, preserves comments
# =========================================================================
config="$TMP_DIR/bitrate.yml"
cp "$CONFIG_SRC" "$config"
python3 "$WIZARD" --preset balanced --languages english --bitrate-limit 8 --config "$config" >/dev/null 2>&1
assert_eq "8" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: limit set to 8"

if grep -q 'remote_bitrate_limit: 8' "$config" && grep -q '# Mbps per remote viewer' "$config"; then
    pass "bitrate: inline comment preserved"
else
    fail "bitrate: inline comment preserved" "comment stripped after apply"
fi

python3 "$WIZARD" --preset balanced --languages english --bitrate-limit 20 --config "$config" >/dev/null 2>&1
assert_eq "20" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: re-apply changes value to 20"

python3 "$WIZARD" --preset balanced --languages english --bitrate-limit 0 --config "$config" >/dev/null 2>&1
assert_eq "0" \
    "$(yaml_get "$config" "c['jellyfin']['remote_bitrate_limit']")" \
    "bitrate: 0 means unlimited"

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

scenario_end "$CURRENT_SCENARIO"
summary
