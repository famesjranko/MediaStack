# Owns: validate_* — DDNS credential/token/API-key/zone-ID field validators.
# Sources: scripts/lib/validators.sh state; sourced by scripts/lib/validators.sh.

validate_ddns_credential() {
    local label="${1:-DDNS credential}"
    local value="${2:-}"
    # Reject empty AND all-whitespace: stage2 trims the stored value, so an
    # all-spaces entry would collapse to "" and fail Dynu auth without a prompt.
    if [[ -z "${value//[[:space:]]/}" ]]; then
        ui_log warn "$label is required."
        return 1
    fi
    if [[ "$value" == *\'* ]]; then
        ui_log warn "$label cannot contain a single quote (')."
        return 1
    fi
    return 0
}

validate_ddns_password() {
    validate_ddns_credential "Dynu password" "$1"
}

# Multi-provider DDNS field validators. Consumed by the wizard's per-provider
# field loop AND the day-2 change-provider action; the config renderer in
# scripts/lib/ddns-providers.sh emits JSON and does not itself validate. Tokens/keys are
# opaque, contiguous secrets. SURROUNDING whitespace from a dashboard paste
# (trailing newline/space) is trimmed here so it validates — both call sites store
# the trimmed value — while an INTERNAL space (almost always a copy error), the
# empty/whitespace-only paste, and the single quote that would break .env sourcing
# are still rejected.
_validate_ddns_opaque() {
    local label="${1:-value}"
    local value="${2:-}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" ]]; then
        ui_log warn "$label is required."
        return 1
    fi
    if [[ "$value" =~ [[:space:]] ]]; then
        ui_log warn "$label cannot contain spaces (check for a copy-paste error)."
        return 1
    fi
    if [[ "$value" == *\'* ]]; then
        ui_log warn "$label cannot contain a single quote (')."
        return 1
    fi
    return 0
}

validate_ddns_token() { _validate_ddns_opaque "API token" "$1"; }
validate_api_key() { _validate_ddns_opaque "API key" "$1"; }

# Cloudflare Zone ID — the 32-hex identifier from the domain's Overview page.
# Surrounding whitespace from a paste is trimmed (see _validate_ddns_opaque).
validate_zone_id() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ -z "$value" ]]; then
        ui_log warn "Cloudflare Zone ID is required."
        return 1
    fi
    if ! [[ "$value" =~ ^[0-9a-fA-F]{32}$ ]]; then
        ui_log warn "Cloudflare Zone ID must be 32 hexadecimal characters (from the domain's Overview page)."
        return 1
    fi
    return 0
}
