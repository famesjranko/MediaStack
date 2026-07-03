#!/usr/bin/env bash
# tests/unit/quality-profile-render.sh
#
# Regression guard for the quality-profile renderer language field.
# render/quality_profile.py builds the custom Sonarr/Radarr quality profile from
# a template profile. It once dropped the `language` field entirely, so the apps
# stored the profile with a null language: Radarr then rejected EVERY release
# with a blank " is wanted, but found <lang>" message, and Sonarr filtered on no
# language at all (grabbed any language, e.g. a French release for an English
# show). The renderer must always emit a valid language:
#   - carry the template's language when it has one (Radarr stock = Original),
#   - fall back to Original when the template has none (Sonarr stock ships null).

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
RENDER="$REPO_ROOT/scripts/lib/arr/render/quality_profile.py"
CURRENT_SCENARIO="quality-profile-render"
scenario_begin "$CURRENT_SCENARIO"

render() {
    # $1 = template profile JSON on stdin source
    PROFILE_NAME="1080p Balanced" ENABLED_IDS="[5]" CUTOFF_ID="1002" \
        UPGRADE_ALLOWED="true" python3 "$RENDER"
}

# language() extracts .language.name (empty string if null/absent) from the
# rendered output — mirrors what Radarr/Sonarr persist and reject against.
language() { python3 -c 'import json,sys; print((json.load(sys.stdin).get("language") or {}).get("name",""))'; }

# 1. Template WITH a language (Radarr stock "Any" = Original) -> carried through.
out=$(printf '%s' '{"name":"Any","language":{"id":-2,"name":"Original"},"items":[{"quality":{"id":5},"allowed":false}],"formatItems":[]}' | render)
assert_eq "Original" "$(printf '%s' "$out" | language)" \
    "renderer carries the template profile's language (Radarr Original)"
# ...and adding language did not disturb the rest of the payload: name/cutoff are
# taken from env, and the enabled id (5) is flipped allowed=true on its item.
assert_eq "1080p Balanced|1002|True" \
    "$(printf '%s' "$out" | python3 -c 'import json,sys
d=json.load(sys.stdin)
i=[x for x in d["items"] if x.get("quality",{}).get("id")==5][0]
print(d["name"] + "|" + str(d["cutoff"]) + "|" + str(i["allowed"]))')" \
    "renderer still renders name/cutoff/items alongside language"
# Reject floor must sit below any realistic penalty stack but above -10000, so
# custom-format scores STEER and never hidden-hard-block (only a deliberate
# -10000 blocks; none is set by default).
minfmt=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["minFormatScore"])')
assert_eq "-1000" "$minfmt" "renderer minFormatScore floor lets all default scores through"
[[ "$minfmt" -gt -10000 ]] && pass "floor stays above the -10000 hard-block value" \
    || fail "floor stays above the -10000 hard-block value" "minFormatScore=$minfmt not > -10000"

# 2. Template with an explicit English language -> carried, not clobbered.
out=$(printf '%s' '{"name":"HD","language":{"id":1,"name":"English"},"items":[{"quality":{"id":5},"allowed":false}],"formatItems":[]}' | render)
assert_eq "English" "$(printf '%s' "$out" | language)" \
    "renderer preserves a non-Original template language"

# 3. Template with NULL language (Sonarr stock) -> falls back to Original,
#    never null (the bug: null -> reject-all in Radarr / no-filter in Sonarr).
out=$(printf '%s' '{"name":"Any","language":null,"items":[{"quality":{"id":5},"allowed":false}],"formatItems":[]}' | render)
assert_eq "Original" "$(printf '%s' "$out" | language)" \
    "renderer falls back to Original when template language is null"

# 4. Template with NO language key at all -> also falls back to Original.
out=$(printf '%s' '{"name":"Any","items":[{"quality":{"id":5},"allowed":false}],"formatItems":[]}' | render)
assert_eq "Original" "$(printf '%s' "$out" | language)" \
    "renderer falls back to Original when template omits language"

scenario_end "$CURRENT_SCENARIO"
summary
