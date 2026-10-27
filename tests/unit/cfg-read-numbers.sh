#!/usr/bin/env bash
# tests/unit/cfg-read-numbers.sh
#
# cfg_field (scripts/lib/common.sh) must not read YAML 1.1 number forms as other
# integers (#129): `010` is not 8, `0x10` is not 16, `1:30` is not 90. Forms that
# are not plain decimal stay text, so the consumer's digit check rejects them.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="cfg-read-numbers"
scenario_begin "$CURRENT_SCENARIO"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Given a config holding each number form under one key
cat >"$WORK/config.yml" <<'YML'
n:
  octal_like: 010
  hex: 0x10
  clock: 1:30
  quoted: "10"
  plain: 7
  negative: -5
  sci: 1e1
  flag: true
  nothing: null
  tilde: ~
  ratio: 1.5
custom_formats: {x264: 1_000}
quality_profile: {sonarr_qualities: [010, 0x10]}
nested:
  deep:
    limit: 25
YML

read_field() {
    CONFIG_FILE="$WORK/config.yml" bash -c 'source "$1/scripts/lib/common.sh"; cfg_field "$2"' _ "$REPO_ROOT" "$1"
}

declare -A values

# When each key is read through cfg_field.
for key in octal_like hex clock quoted plain negative sci flag nothing tilde ratio; do
    values[$key]=$(read_field "n.$key")
done
nested=$(read_field nested.deep.limit)
read_field n.absent >/dev/null
missing_rc=$?
default=$(CONFIG_FILE="$WORK/config.yml" bash -c 'source "$1/scripts/lib/common.sh"; cfg_read value n.absent fb' _ "$REPO_ROOT")

# Then decimal-like and non-decimal forms have the expected values.
assert_eq "10" "${values[octal_like]}" "010 reads as 10"
assert_eq "0x10" "${values[hex]}" "0x10 stays text"
assert_eq "1:30" "${values[clock]}" "1:30 stays text"
assert_eq "10" "${values[quoted]}" 'quoted "10" reads as 10'
assert_eq "7" "${values[plain]}" "7 reads as 7"
assert_eq "-5" "${values[negative]}" "-5 reads as -5"
assert_eq "1e1" "${values[sci]}" "1e1 stays text"
assert_eq "True" "${values[flag]}" "true reads as True"
assert_eq "None" "${values[nothing]}" "null reads as None"
assert_eq "None" "${values[tilde]}" "~ reads as None"
assert_eq "1.5" "${values[ratio]}" "1.5 reads as 1.5"
assert_eq "25" "$nested" "nested key reads through"
assert_eq "1" "$missing_rc" "a missing key without a default exits 1"
assert_eq "fb" "$default" "a missing key with a default yields the default"

# Given YAML 1.1 numbers used by the JSON adapters.
CONFIG_FILE="$WORK/config.yml"
source "$REPO_ROOT/scripts/lib/config-read.sh"

# When the adapters read the scores and quality IDs and the renderer compares scores.
scores=$(cfg_custom_format_scores)
ids=$(cfg_quality_ids sonarr)
rendered=$(printf '%s\n' '{"id":1,"formatItems":[{"format":1,"score":1000}]}' |
    SCORES="$scores" FORMAT_MAP='{"x264":1}' python3 "$REPO_ROOT/scripts/lib/arr/render/format_scores.py")

# Then their JSON retains safe_load numeric values and the live score matches.
assert_eq '{"x264": 1000}' "$scores" "format scores preserve YAML numeric resolution"
assert_eq '[8, 16]' "$ids" "quality IDs preserve YAML numeric resolution"
assert_eq 'match' "$rendered" "equivalent format score does not drift"

scenario_end "$CURRENT_SCENARIO"
summary
