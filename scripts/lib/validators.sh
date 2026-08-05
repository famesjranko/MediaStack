# =============================================================================
# MediaStack validators — Stage 1 input contracts
# =============================================================================
# Sourced by wizard/setup flows. Each validate_* function returns 0 on valid
# input and non-zero on invalid input. Invalid input emits exactly one
# ui_log warn message before returning.

# Topic modules, split out of this file for size: account fields, DDNS
# credential fields, bandwidth fields, storage paths, network/port fields,
# and timezone/subtitle fields. Kept in this one place so every sourcer
# (wizard.sh, the launcher, and the unit/scenario tests) gets the full
# validators.sh surface from a single source.
_VALIDATORS_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validators/account.sh
source "$_VALIDATORS_MODULE_DIR/validators/account.sh"
# shellcheck source=validators/ddns.sh
source "$_VALIDATORS_MODULE_DIR/validators/ddns.sh"
# shellcheck source=validators/bandwidth.sh
source "$_VALIDATORS_MODULE_DIR/validators/bandwidth.sh"
# shellcheck source=validators/storage.sh
source "$_VALIDATORS_MODULE_DIR/validators/storage.sh"
# shellcheck source=validators/network.sh
source "$_VALIDATORS_MODULE_DIR/validators/network.sh"
# shellcheck source=validators/misc.sh
source "$_VALIDATORS_MODULE_DIR/validators/misc.sh"
unset _VALIDATORS_MODULE_DIR
