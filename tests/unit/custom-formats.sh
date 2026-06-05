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
empty_status=$(echo '{"id":1,"name":"HD-720p/1080p","formatItems":[]}' | \
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

scenario_end "$CURRENT_SCENARIO"
summary
