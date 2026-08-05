# Owns: Stage 2 remote-access flow ordering and completion-state routing.
# Sources: stage2/* concern modules, shared remote helpers, and setup globals.
# =============================================================================
# MediaStack Setup -- Stage 2 controller (Remote Access)
# =============================================================================
# Sourced by scripts/setup/wizard.sh.

if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fi

source "$SCRIPT_DIR/scripts/lib/npm-remote.sh"
source "$SCRIPT_DIR/scripts/lib/ddns-providers.sh"

: "${STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS:=12}"
: "${STAGE2_DNS_PROPAGATION_SLEEP_SECONDS:=10}"
: "${STAGE2_PORT_PROBE_MAX_ATTEMPTS:=3}"
: "${STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS:=5}"
readonly STAGE2_DNS_PROPAGATION_MAX_ATTEMPTS STAGE2_DNS_PROPAGATION_SLEEP_SECONDS
readonly STAGE2_PORT_PROBE_MAX_ATTEMPTS STAGE2_PORT_PROBE_RETRY_SLEEP_SECONDS

# DDNS credential fields for the chosen provider (name -> value). MUST be a real
# associative array: assigning arr[key]=val to an undeclared name creates a plain
# indexed array (key -> arithmetic 0) and silently drops every field. Declared
# here (the always-sourced module) so both production and the flow units get an
# assoc; `declare -gA` on an existing assoc preserves its contents (idempotent).
declare -gA _WIZ_DDNS_FIELDS

_STAGE2_CONCERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stage2" && pwd)"
# shellcheck source=../stage2/common.sh
source "$_STAGE2_CONCERNS_DIR/common.sh"
# shellcheck source=../stage2/input.sh
source "$_STAGE2_CONCERNS_DIR/input.sh"
# shellcheck source=../stage2/le.sh
source "$_STAGE2_CONCERNS_DIR/le.sh"
# shellcheck disable=SC2034 # Stage 2 LE modules read and update these globals.
STAGE2_LE_CLASSIFICATION="unknown"
# shellcheck disable=SC2034
STAGE2_LE_READY_HOSTS=""
# shellcheck disable=SC2034
STAGE2_LE_FAILED_HOSTS=""
# shellcheck source=../stage2/ddns.sh
source "$_STAGE2_CONCERNS_DIR/ddns.sh"
# shellcheck source=../stage2/domain.sh
source "$_STAGE2_CONCERNS_DIR/domain.sh"
# shellcheck source=../stage2/ports.sh
source "$_STAGE2_CONCERNS_DIR/ports.sh"
# shellcheck source=../stage2/wireguard.sh
source "$_STAGE2_CONCERNS_DIR/wireguard.sh"
# shellcheck source=../stage2/bitrate.sh
source "$_STAGE2_CONCERNS_DIR/bitrate.sh"
# shellcheck source=../stage2/confirm.sh
source "$_STAGE2_CONCERNS_DIR/confirm.sh"
# shellcheck source=../stage2/skip.sh
source "$_STAGE2_CONCERNS_DIR/skip.sh"
# shellcheck source=../stage2/install.sh
source "$_STAGE2_CONCERNS_DIR/install.sh"
unset _STAGE2_CONCERNS_DIR

run_stage2() {
    seed_root_config # ensure live config.yml exists before the bitrate write (env-gen.sh)
    if [[ "${DEMO:-0}" == "1" ]]; then
        return 0
    fi

    _stage2_seed_wizard_defaults

    ui_banner "MediaStack - Remote Access" "HTTPS + WireGuard in a few minutes (longer on first DNS setup)"

    while true; do
        local offer_action
        # _stage2_offer prints explanatory UI to stderr and only the selected
        # answer to stdout, so command substitution does not swallow the copy.
        offer_action=$(_stage2_offer)
        case "$offer_action" in
            *"Enable remote access")
                ;;
            *"Skip for now")
                _stage2_skip_https
                return 0
                ;;
            *"Tell me more")
                _stage2_tell_me_more
                continue
                ;;
        esac

        if ! _stage2_collect_domain; then
            return 0
        fi
        if ! _stage2_port_gate; then
            return 0
        fi
        _stage2_collect_wireguard
        _stage2_collect_jellyfin_remote_bitrate

        local confirm_action
        _stage2_confirm
        confirm_action="${_STAGE2_CONFIRM_ACTION:-Back}"
        case "$confirm_action" in
            Install)
                _stage2_install
                return $?
                ;;
            Back)
                continue
                ;;
            "Skip remote access")
                _stage2_skip_https
                return 0
                ;;
        esac
    done
}
