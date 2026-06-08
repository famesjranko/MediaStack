#!/usr/bin/env bash
# =============================================================================
# Unit test — custom_formats.yml validity + render helpers
# =============================================================================
# Validates that custom_formats.yml is valid YAML and each format has the
# required fields for the Sonarr/Radarr custom format API.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="custom-formats"
scenario_begin "$CURRENT_SCENARIO"

FORMATS_FILE="$REPO_ROOT/scripts/lib/arr/custom_formats.yml"
CF_RENDER="$REPO_ROOT/scripts/lib/arr/render/custom_formats.py"
FS_RENDER="$REPO_ROOT/scripts/lib/arr/render/format_scores.py"

# =========================================================================
# custom_formats.yml structure validation
# =========================================================================
format_check=$(python3 -c "
import yaml, json, sys
with open('$FORMATS_FILE') as f:
    data = yaml.safe_load(f)
formats = data.get('formats', [])
if not formats:
    print('ERROR: no formats defined')
    sys.exit(1)
errors = []
for i, fmt in enumerate(formats):
    if 'name' not in fmt:
        errors.append(f'format[{i}]: missing name')
    if 'specifications' not in fmt:
        errors.append(f'format[{i}] ({fmt.get(\"name\",\"?\")}): missing specifications')
    else:
        for j, spec in enumerate(fmt['specifications']):
            for field in ('name', 'implementation', 'fields'):
                if field not in spec:
                    errors.append(f'format[{i}].spec[{j}]: missing {field}')
            if 'negate' not in spec:
                errors.append(f'format[{i}].spec[{j}]: missing negate')
            if 'required' not in spec:
                errors.append(f'format[{i}].spec[{j}]: missing required')
if errors:
    print('ERRORS: ' + '; '.join(errors))
    sys.exit(1)
print(f'OK:{len(formats)}')
" 2>&1)

if [[ "$format_check" == OK:* ]]; then
    count="${format_check#OK:}"
    pass "custom_formats.yml valid ($count formats)"
else
    fail "custom_formats.yml valid" "$format_check"
fi

# =========================================================================
# All 7 expected formats present
# =========================================================================
found_names=$(python3 -c "
import yaml
with open('$FORMATS_FILE') as f:
    data = yaml.safe_load(f)
for fmt in data['formats']:
    print(fmt['name'])
" 2>/dev/null)

for name in "Repack/Proper" "x264" "x265 (HD)" "BR-DISK" "LQ" "No-RlsGroup" "Obfuscated"; do
    if echo "$found_names" | grep -qF "$name"; then
        pass "format '$name' defined"
    else
        fail "format '$name' defined" "not found in custom_formats.yml"
    fi
done

# =========================================================================
# Only Repack/Proper has includeCustomFormatWhenRenaming=true
# =========================================================================
rename_check=$(python3 -c "
import yaml
with open('$FORMATS_FILE') as f:
    data = yaml.safe_load(f)
for fmt in data['formats']:
    if fmt.get('includeCustomFormatWhenRenaming', False) and fmt['name'] != 'Repack/Proper':
        print(fmt['name'])
" 2>/dev/null)

if [[ -z "$rename_check" ]]; then
    pass "only Repack/Proper has includeCustomFormatWhenRenaming"
else
    fail "only Repack/Proper has includeCustomFormatWhenRenaming" "also set on: $rename_check"
fi

# =========================================================================
# All specifications use ReleaseTitleSpecification
# =========================================================================
impl_check=$(python3 -c "
import yaml
with open('$FORMATS_FILE') as f:
    data = yaml.safe_load(f)
non_rt = []
for fmt in data['formats']:
    for spec in fmt['specifications']:
        if spec['implementation'] != 'ReleaseTitleSpecification':
            non_rt.append(f\"{fmt['name']}/{spec['name']}: {spec['implementation']}\")
if non_rt:
    print('; '.join(non_rt))
" 2>/dev/null)

if [[ -z "$impl_check" ]]; then
    pass "all specifications use ReleaseTitleSpecification"
else
    fail "all specifications use ReleaseTitleSpecification" "$impl_check"
fi

# =========================================================================
# custom_formats.py — skips existing, emits new
# =========================================================================
create_plan=$(echo '[{"name":"Repack/Proper","id":1}]' | \
    FORMATS_FILE="$FORMATS_FILE" \
    SCORES='{"Repack/Proper":5,"x264":10,"BR-DISK":-10000}' \
    python3 "$CF_RENDER" 2>/dev/null)

if echo "$create_plan" | grep -q "x264"; then
    pass "custom_formats.py emits x264 (not existing)"
else
    fail "custom_formats.py emits x264" "not in output"
fi

if echo "$create_plan" | grep -q "BR-DISK"; then
    pass "custom_formats.py emits BR-DISK (not existing)"
else
    fail "custom_formats.py emits BR-DISK" "not in output"
fi

if echo "$create_plan" | grep -q "Repack/Proper"; then
    fail "custom_formats.py skips existing Repack/Proper" "still in output"
else
    pass "custom_formats.py skips existing Repack/Proper"
fi

# Formats not in scores are excluded
if echo "$create_plan" | grep -q "Obfuscated"; then
    fail "custom_formats.py excludes formats not in scores" "Obfuscated in output"
else
    pass "custom_formats.py excludes formats not in scores"
fi

# =========================================================================
# format_scores.py — empty formatItems → empty status with put body
# =========================================================================
empty_status=$(echo '{"id":1,"name":"1080p Balanced","formatItems":[]}' | \
    SCORES='{"Repack/Proper":5,"x264":10}' \
    FORMAT_MAP='{"Repack/Proper":1,"x264":2}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "empty" "${empty_status%%$'\t'*}" "format_scores.py: empty formatItems → empty status"

# Verify the put body has formatItems populated
put_body="${empty_status#*$'\t'}"
fi_count=$(echo "$put_body" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('formatItems',[])))" 2>/dev/null)
assert_eq "2" "$fi_count" "format_scores.py: put body has 2 formatItems"

# =========================================================================
# format_scores.py — matching formatItems → match
# =========================================================================
match_status=$(echo '{"id":1,"name":"test","formatItems":[{"format":1,"name":"Repack/Proper","score":5},{"format":2,"name":"x264","score":10}]}' | \
    SCORES='{"Repack/Proper":5,"x264":10}' \
    FORMAT_MAP='{"Repack/Proper":1,"x264":2}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "match" "$match_status" "format_scores.py: matching scores → match"

# =========================================================================
# format_scores.py — differing formatItems → drift
# =========================================================================
drift_status=$(echo '{"id":1,"name":"test","formatItems":[{"format":1,"name":"Repack/Proper","score":99}]}' | \
    SCORES='{"Repack/Proper":5}' \
    FORMAT_MAP='{"Repack/Proper":1}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "drift" "${drift_status%%$'\t'*}" "format_scores.py: different scores → drift"

# =========================================================================
# format_scores.py — sizes with a desired 0 score (e.g. compact) match on
# re-run. Regression for #75: a live formatItem correctly scored 0 must not
# read as drift, and the app's auto-added 0-score formats must be ignored.
# =========================================================================
zero_match=$(echo '{"id":1,"name":"720p Compact","formatItems":[{"format":1,"name":"Repack/Proper","score":5},{"format":2,"name":"x264","score":0},{"format":3,"name":"x265 (HD)","score":0},{"format":4,"name":"BR-DISK","score":-10000},{"format":99,"name":"App-Other","score":0}]}' | \
    SCORES='{"Repack/Proper":5,"x264":0,"x265 (HD)":0,"BR-DISK":-10000}' \
    FORMAT_MAP='{"Repack/Proper":1,"x264":2,"x265 (HD)":3,"BR-DISK":4}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "match" "$zero_match" "format_scores.py: correctly-applied 0 scores → match (not drift) [#75]"

# =========================================================================
# format_scores.py — a genuine deviation on a 0-desired format is still drift,
# carrying a non-empty diff. (The empty-diff false WARN itself is locked out by
# the match-on-correctly-applied-0 cases — on the old code those drifted with an
# empty detail; here we confirm a real deviation still reports its diff.)
# =========================================================================
zero_drift=$(echo '{"id":1,"name":"720p Compact","formatItems":[{"format":1,"name":"Repack/Proper","score":5},{"format":2,"name":"x264","score":50}]}' | \
    SCORES='{"Repack/Proper":5,"x264":0}' \
    FORMAT_MAP='{"Repack/Proper":1,"x264":2}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "drift" "${zero_drift%%$'\t'*}" "format_scores.py: live non-zero vs desired 0 → drift [#75]"

zero_drift_detail="${zero_drift#*$'\t'}"
if [[ -n "$zero_drift_detail" ]]; then
    pass "format_scores.py: drift carries a non-empty diff [#75]"
else
    fail "format_scores.py: drift carries a non-empty diff [#75]" "empty diff (the false-WARN bug)"
fi

# =========================================================================
# format_scores.py — only the formats config.yml manages are compared. A live
# format scored non-zero that config.yml does NOT manage (e.g. a user- or
# app-scored LQ left on the profile) must be ignored, not read as drift —
# configure.sh manages only the formats in SCORES/FORMAT_MAP. Pre-fix this
# emitted a false drift WARN. Regression for #75.
# =========================================================================
unmanaged_live=$(echo '{"id":1,"name":"720p Compact","formatItems":[{"format":1,"name":"Repack/Proper","score":5},{"format":7,"name":"LQ","score":-30}]}' | \
    SCORES='{"Repack/Proper":5}' \
    FORMAT_MAP='{"Repack/Proper":1}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "match" "$unmanaged_live" "format_scores.py: unmanaged live non-zero format ignored → match (not drift) [#75]"

# =========================================================================
# format_scores.py — a managed format with a desired 0 that is absent from the
# live formatItems entirely (custom format not yet added to this profile) still
# satisfies the desired 0 → match, not an empty-diff drift. Distinct from the
# present-but-0 case above (absent → treated as 0). Regression for #75.
# =========================================================================
zero_absent=$(echo '{"id":1,"name":"720p Compact","formatItems":[{"format":1,"name":"Repack/Proper","score":5}]}' | \
    SCORES='{"Repack/Proper":5,"x264":0}' \
    FORMAT_MAP='{"Repack/Proper":1,"x264":2}' \
    python3 "$FS_RENDER" 2>/dev/null)

assert_eq "match" "$zero_absent" "format_scores.py: desired-0 format absent from live → match [#75]"

scenario_end "$CURRENT_SCENARIO"
summary
