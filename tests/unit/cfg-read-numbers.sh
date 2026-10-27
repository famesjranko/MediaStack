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
nested:
  deep:
    limit: 25
YML

read_field() {
    CONFIG_FILE="$WORK/config.yml" bash -c 'source "$1/scripts/lib/common.sh"; cfg_field "$2"' _ "$REPO_ROOT" "$1"
}

# When each key is read through cfg_field
# Then 010 reads as 10, not octal 8
assert_eq "10" "$(read_field n.octal_like)" "010 reads as 10"
# And 0x10 and 1:30 stay literal text so consumers reject them
assert_eq "0x10" "$(read_field n.hex)" "0x10 stays text"
assert_eq "1:30" "$(read_field n.clock)" "1:30 stays text"
# And the unchanged forms read as before
assert_eq "10" "$(read_field n.quoted)" 'quoted "10" reads as 10'
assert_eq "7" "$(read_field n.plain)" "7 reads as 7"
assert_eq "-5" "$(read_field n.negative)" "-5 reads as -5"
assert_eq "1e1" "$(read_field n.sci)" "1e1 stays text"
assert_eq "True" "$(read_field n.flag)" "true reads as True"
assert_eq "None" "$(read_field n.nothing)" "null reads as None"
assert_eq "None" "$(read_field n.tilde)" "~ reads as None"
assert_eq "1.5" "$(read_field n.ratio)" "1.5 reads as 1.5"
assert_eq "25" "$(read_field nested.deep.limit)" "nested key reads through"
# And a missing key fails, or yields the default when one is given
read_field n.absent >/dev/null
assert_eq "1" "$?" "a missing key without a default exits 1"
assert_eq "fb" "$(CONFIG_FILE="$WORK/config.yml" bash -c 'source "$1/scripts/lib/common.sh"; cfg_read value n.absent fb' _ "$REPO_ROOT")" \
    "a missing key with a default yields the default"

scenario_end "$CURRENT_SCENARIO"
summary
