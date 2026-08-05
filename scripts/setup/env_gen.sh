# =============================================================================
# MediaStack Setup — Environment detection and .env generation
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# detect_env()  — non-interactive auto-detection, sets shell variables.
# write_env()   — writes .env from globals set by detect_env + wizard.

# ddns_render_config_json (the DDNS config.json renderer used by write_env)
# lives in scripts/lib/ddns_providers.sh. Sourced here — not in wizard.sh —
# because env_gen.sh is the one lib every setup + stage entrypoint (and their
# unit tests) already source. Resolve from BASH_SOURCE, not $SCRIPT_DIR: some
# callers (and the ddns-seed / stage2-flow tests) set SCRIPT_DIR *after*
# sourcing this file.
_env_gen_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ddns_providers.sh
source "$_env_gen_dir/../lib/ddns_providers.sh"

# The wizard's collected DDNS credential fields (name -> value); the config.json
# writer below reads it. Declared here too (idempotent; `declare -gA` on an
# existing assoc preserves contents) so write_env sees a real associative array
# even when a test drives it without sourcing stage2.sh.
declare -gA _WIZ_DDNS_FIELDS

# Seed the live config.yml from its tracked template if absent. config.yml is
# gitignored and mutated in place by the wizard (quality preset, min_free_space,
# bitrate, wizard_completed), so it is seeded — not tracked — like the service
# pre-seeds. "only if absent": re-runs keep the user's edits; a fresh template
# has no wizard_completed key, so a reinstall runs the wizard fresh. Called at the
# top of run_wizard AND run_stage1/run_stage2 (the stages that read/mutate it) so
# the wizard-ui PTY fixtures — which invoke run_stageN directly, bypassing
# run_wizard — get a config.yml too. Defined here because env_gen.sh is the one
# lib every setup + stage entrypoint (and their unit tests) already source. No-op
# if the template is missing (minimal unit-test fixtures) so it never trips set -e.
seed_root_config() {
    [[ -f "$SCRIPT_DIR/config.yml" ]] && return 0
    [[ -f "$SCRIPT_DIR/config/examples/config.yml" ]] || return 0
    cp "$SCRIPT_DIR/config/examples/config.yml" "$SCRIPT_DIR/config.yml"
}

detect_env() {
    _ENV_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Etc/UTC")
    _ENV_PUID=$(id -u)
    _ENV_PGID=$(id -g)
    _ENV_HOST_ADDRESS=$(hostname -I 2>/dev/null | awk '{print $1}')
    _ENV_HOST_ADDRESS="${_ENV_HOST_ADDRESS:-localhost}"
}

_ddns_updater_owner() {
    printf '%s:%s' "${DDNS_UPDATER_UID:-1000}" "${DDNS_UPDATER_GID:-1000}"
}

_ddns_prepare_config_dir() {
    local ddns_dir="$1"
    local owner
    owner="$(_ddns_updater_owner)"
    local current_owner

    if [[ -L "$ddns_dir" ]]; then
        log_warn "Refusing to use symlinked DDNS config directory: $ddns_dir"
        return 1
    fi
    if ! mkdir -p "$ddns_dir" 2>/dev/null; then
        sudo mkdir -p "$ddns_dir" || return 1
    fi
    if [[ -L "$ddns_dir" || ! -d "$ddns_dir" ]]; then
        log_warn "Refusing to use unsafe DDNS config directory: $ddns_dir"
        return 1
    fi
    current_owner=$(stat -c '%u:%g' "$ddns_dir" 2>/dev/null || true)
    if [[ "$current_owner" != "$owner" ]]; then
        if ! chown "$owner" "$ddns_dir" 2>/dev/null; then
            sudo chown "$owner" "$ddns_dir" || return 1
        fi
    fi
    if ! chmod 755 "$ddns_dir" 2>/dev/null; then
        sudo chmod 755 "$ddns_dir" || return 1
    fi
}

_ddns_secure_config_file() {
    local config_file="$1"
    local owner
    owner="$(_ddns_updater_owner)"
    local current_owner

    if [[ -L "$config_file" ]]; then
        log_warn "Refusing to secure symlinked DDNS config path: $config_file"
        return 1
    fi
    current_owner=$(stat -c '%u:%g' "$config_file" 2>/dev/null || true)
    if [[ "$current_owner" != "$owner" ]]; then
        if ! chown "$owner" "$config_file" 2>/dev/null; then
            sudo chown "$owner" "$config_file" || return 1
        fi
    fi
    if ! chmod 600 "$config_file" 2>/dev/null; then
        sudo chmod 600 "$config_file" || return 1
    fi
}

repair_ddns_updater_config_permissions() {
    local ddns_dir="$SCRIPT_DIR/config/ddns-updater"
    local ddns_config="$ddns_dir/config.json"

    _ddns_prepare_config_dir "$ddns_dir" || return 1
    if [[ -e "$ddns_config" || -L "$ddns_config" ]]; then
        _ddns_secure_config_file "$ddns_config" || return 1
    fi
}

_env_quote_preserved_secret() {
    local out_var="$1" label="$2" value="$3"
    if [[ "$value" == *"'"* || "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        log_warn "Ignoring preserved ${label} with unsupported quote/newline characters."
        printf -v "$out_var" "''"
        return 0
    fi
    printf -v "$out_var" "'%s'" "$value"
}

# Resolve the persisted NVIDIA driver-management mode from prior state. Migrates
# the legacy NVIDIA_PATCH_ENABLED boolean (public shipped it before the mode var)
# to "unlock", validates the value, and echoes standard|unlock|existing or "".
# Fresh installs echo "" — the wizard sets "standard" only once a driver installs.
_nvidia_resolve_driver_mode() {
    local _mode="${1:-}" _legacy_patch="${2:-}"
    if [[ -z "$_mode" && "$_legacy_patch" == "true" ]]; then
        _mode="unlock"
    fi
    case "$_mode" in
        standard | unlock | existing) printf '%s' "$_mode" ;;
        *) printf '' ;;
    esac
}

# write_env (the .env writer) lives in env_write.sh — see its header for why.
# shellcheck source=scripts/setup/env_write.sh
source "$_env_gen_dir/env_write.sh"
