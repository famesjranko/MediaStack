#!/usr/bin/env bash
# tests/unit/ratelimit-toggle.sh
#
# Guards the NPM rate-limiting master switch (config.yml rate_limiting.enabled):
#   - the shipped default must be OFF (turnkey safety — the whole point of the
#     switch),
#   - the opt-in flip must normalize to a usable boolean,
#   - a missing key must fall back to OFF,
#   - the companion fail2ban jail must ship disabled.
# cfg_field() prints YAML bools as Python "False"/"True", so configure_npm reads
# then lowercases before comparing. This test exercises the real cfg_field reader
# and locks that contract (a naive "== true" against "False"/"True" silently
# breaks the opt-in path).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="ratelimit-toggle"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Source common.sh for the product's cfg_field reader (reads $CONFIG_FILE).
# common.sh sets no shell options and resolves its own deps via BASH_SOURCE.
# Export CONFIG_FILE per common.sh's caller contract (it reads the exported var);
# the export attribute persists across the per-case reassignments below.
SCRIPT_DIR="$TMP_DIR"
export CONFIG_FILE="$REPO_ROOT/config/examples/config.yml"
# shellcheck source=/dev/null
source "$REPO_ROOT/scripts/lib/common.sh"

# Mirror configure_npm's gate exactly: read via cfg_field, lowercase-normalize.
rate_gate() {
    local v
    v="$(cfg_field "rate_limiting.enabled" 2>/dev/null || echo "false")"
    printf '%s' "${v,,}"
}

# Rewrite a copy of the shipped config.yml with a python mutation, echo its path.
mutate_config() {
    local out="$1" code="$2"
    python3 - "$REPO_ROOT/config/examples/config.yml" "$out" <<EOF
import sys, yaml
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f)
$code
with open(sys.argv[2], "w") as f:
    yaml.safe_dump(c, f)
EOF
}

# 1. Shipped default must be OFF.
CONFIG_FILE="$REPO_ROOT/config/examples/config.yml"
assert_eq "false" "$(rate_gate)" "shipped config.yml: rate_limiting.enabled normalizes to false"

# 2. Opt-in flip must normalize to a usable "true" (guards the Python "True" bug).
ENABLED_CFG="$TMP_DIR/enabled.yml"
mutate_config "$ENABLED_CFG" "c['rate_limiting']['enabled'] = True"
CONFIG_FILE="$ENABLED_CFG"
assert_eq "true" "$(rate_gate)" "rate_limiting.enabled: true normalizes to true (cfg_field returns Python 'True')"

# 3. Missing key falls back to off (graceful default).
MISSING_CFG="$TMP_DIR/missing.yml"
mutate_config "$MISSING_CFG" "del c['rate_limiting']['enabled']"
CONFIG_FILE="$MISSING_CFG"
assert_eq "false" "$(rate_gate)" "missing rate_limiting.enabled falls back to off"

# 4. Companion fail2ban jail ships disabled alongside the master switch.
JAIL="$REPO_ROOT/config/examples/defaults/fail2ban/jail.d/mediastack.conf"
jail_enabled=$(sed -n '/^\[npm-ratelimit\]/,/^\[/{s/^enabled = //p}' "$JAIL")
assert_eq "false" "$jail_enabled" "config: [npm-ratelimit] jail ships enabled = false"

scenario_end "$CURRENT_SCENARIO"
summary
