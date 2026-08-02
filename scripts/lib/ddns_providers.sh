#!/usr/bin/env bash
# scripts/lib/ddns_providers.sh
# =============================================================================
# MediaStack DDNS provider registry + config.json renderer
# =============================================================================
# Pure data + rendering. No docker, no network, no side effects. The single
# source of provider knowledge shared by the install wizard (stage2) and the
# day-2 "Update DDNS provider / credentials" action, so adding a provider is registry cells +
# a validator + a test fixture + docs — never flow-code edits.
#
# Flat parallel arrays indexed together (model scripts/lib/quality_select.sh),
# not a TAB-record declare -gA blob. Sourced by scripts/setup/env_gen.sh (the
# universal setup source-point); safe to source anywhere — nothing runs at
# source time except the array literals, and the functions reach for ui/log
# helpers only when called.

[[ -n "${_MS_DDNS_PROVIDERS_SH_LOADED:-}" ]] && return 0
_MS_DDNS_PROVIDERS_SH_LOADED=1

# Provider keys — the index that ties every parallel array together. Order is the
# picker order AND the default (first row is the pre-selected default). DuckDNS
# leads deliberately: it is a token provider, so its verify cannot be
# Layer-2-masked — a wrong token is rejected even on an unchanged IP — which makes
# it the one free provider whose setup is genuinely verified end-to-end. Dynu's
# dyndns2 verify can only ever be "accepted or masked", so it is offered but not
# the default. (No "recommended" copy — the tell-me-more list stays neutral;
# leading with the verifiable provider is the nudge.)
_DDNS_KEY=(duckdns dynu desec dynv6 cloudflare porkbun)

# ui_choose display labels, category-prefixed (ui_choose has no native grouping).
_DDNS_LABEL=(
    "Free hostname · DuckDNS"
    "Free hostname · Dynu"
    "Free hostname · deSEC"
    "Free hostname · dynv6"
    "Your own domain · Cloudflare"
    "Your own domain · Porkbun"
)

# free = provider hands out a hostname; byo = bring your own domain.
_DDNS_CATEGORY=(free free free free byo byo)

# Space-separated "name:validator" field specs — drives both the wizard input
# loop and validator dispatch. `domain` is deliberately NOT here: it is
# the shared media host, collected separately, and rendered as a reserved key.
# Dynu collects password only: its dyndns2 /nic/update authenticates on
# hostname-ownership + password and IGNORES the username entirely — confirmed on a
# live account (a wrong username + right password successfully repointed the
# record; a right password to an unowned hostname is still rejected). Asking for a
# username only invites a fat-finger on a field that is never checked, so we drop
# the prompt and auto-fill a constant placeholder in _DDNS_CONST_JSON below
# (ddns-updater requires the key present but never sends its value anywhere that
# matters). The remaining wrong-password-on-unchanged-IP mask is Dynu's own API
# ceiling, handled by the tiered verify message + day-2 Health, not here.
_DDNS_FIELDS=(
    "token:validate_ddns_token"
    "password:validate_ddns_password"
    "token:validate_ddns_token"
    "token:validate_ddns_token"
    "zone_identifier:validate_zone_id token:validate_ddns_token"
    "api_key:validate_api_key secret_api_key:validate_api_key"
)

# The mask axis, NOT the wire protocol: username/password
# dyndns2 providers can server-side no-op ("nochg") without checking the password
# when the IP is unchanged, so their /update 202 is "accepted OR masked"; token
# providers cannot mask (the token IS the account key) so their 202 is a true
# verify. Consumed by the tiered verify messaging.
# ponytail: deSEC is conservatively grouped dyndns2; upgrading it to token is a
# cheap follow-up once someone confirms on a free account that it does not
# no-op-before-auth on an unchanged IP.
_DDNS_VERIFY_TIER=(token dyndns2 dyndns2 token token token)

# Per-provider constant JSON skeleton, merged into the rendered settings block
# via json.loads (so ttl/proxied stay native int/bool — no :int/:bool sigil
# parser). Cloudflare carries ttl/proxied defaults. All are IPv4-only
# (MediaStack uses HTTP-01, so the DDNS requirement is IPv4 resolution, not
# wildcard TLS). NB: dynv6 takes only token+ip_version here —
# ddns-updater detects and sends the public IP itself, so the native dynv6
# `ipv4=auto` param has no place in the container config; the
# container silently ignores an `ipv4` key (verified against qdm12/ddns-updater
# docs + the pinned image).
# Dynu carries a constant "username" placeholder: ddns-updater's Dynu provider
# requires the field to be present, but Dynu ignores its value (see _DDNS_FIELDS),
# so we render a fixed non-empty string rather than prompt for it. The renderer
# merges this via json.loads AFTER the collected fields, so Dynu's rendered order
# becomes provider, domain, password, username, ip_version — order is irrelevant
# to ddns-updater but the golden fixtures encode it.
_DDNS_CONST_JSON=(
    '{"ip_version":"ipv4"}'
    '{"username":"mediastack","ip_version":"ipv4"}'
    '{"ip_version":"ipv4"}'
    '{"ip_version":"ipv4"}'
    '{"ip_version":"ipv4","ttl":1,"proxied":false}'
    '{"ip_version":"ipv4","ttl":600}'
)

# Print the array index for <key>, or return 1 if unknown.
_ddns_index_of() {
    local key="$1" i
    for i in "${!_DDNS_KEY[@]}"; do
        if [[ "${_DDNS_KEY[$i]}" == "$key" ]]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

# Escape-hatch label appended to the provider list so a user who isn't ready can
# back out of DDNS without picking a provider (the field loop that follows a real
# pick is only escapable via re-prompt-until-valid otherwise). ddns_provider_pick
# maps it to the sentinel _DDNS_SKIP so the caller can treat it as "skip DDNS".
_DDNS_SKIP_LABEL="Skip for now — I'll set up DDNS later"
_DDNS_SKIP="__skip__"

# ddns_provider_pick [default_key] — interactive provider chooser. Prints the
# selected key to stdout, or _DDNS_SKIP if the user chose the skip escape hatch.
# Sets a deterministic default index so a non-TTY/DEMO run returns without
# re-prompting (the non-TTY-determinism invariant) — the skip option is last, so
# it never becomes the default; mirrors quality_select_pick's default handling.
ddns_provider_pick() {
    local default_key="${1:-}" idx=1 i chosen
    if [[ -n "$default_key" ]]; then
        for i in "${!_DDNS_KEY[@]}"; do
            [[ "${_DDNS_KEY[$i]}" == "$default_key" ]] && idx=$((i + 1))
        done
    fi
    chosen=$(UI_CHOOSE_DEFAULT_INDEX=$idx ui_choose \
        "Choose your DDNS provider:" "${_DDNS_LABEL[@]}" "$_DDNS_SKIP_LABEL")
    if [[ "$chosen" == "$_DDNS_SKIP_LABEL" ]]; then
        printf '%s\n' "$_DDNS_SKIP"
        return 0
    fi
    # Map the chosen label back to its key (fall back to the first provider).
    local out="${_DDNS_KEY[0]}"
    for i in "${!_DDNS_LABEL[@]}"; do
        [[ "${_DDNS_LABEL[$i]}" == "$chosen" ]] && out="${_DDNS_KEY[$i]}"
    done
    printf '%s\n' "$out"
    return 0
}

# ddns_category_names <free|byo> — print the display name (the ui_choose label
# minus its "Category · " prefix) of every provider in <category>, one per line.
# Lets the wizard describe the free / bring-your-own provider sets from the
# registry instead of a second hardcoded list. Trailing `return 0` because
# the final loop iteration's [[ ]] test is false whenever <category> isn't the
# last row, which would otherwise return 1 and trip the wizard's `set -e`.
ddns_category_names() {
    local want="$1" i
    for i in "${!_DDNS_KEY[@]}"; do
        [[ "${_DDNS_CATEGORY[$i]}" == "$want" ]] && printf '%s\n' "${_DDNS_LABEL[$i]##* · }"
    done
    return 0
}

# ddns_provider_fields <key> — print the space-separated "name:validator" specs.
ddns_provider_fields() {
    local idx
    idx=$(_ddns_index_of "$1") || return 1
    printf '%s\n' "${_DDNS_FIELDS[$idx]}"
}

# ddns_provider_verify_tier <key> — print "dyndns2" or "token".
ddns_provider_verify_tier() {
    local idx
    idx=$(_ddns_index_of "$1") || return 1
    printf '%s\n' "${_DDNS_VERIFY_TIER[$idx]}"
}

# ddns_provider_category <key> — print "free" (provider hands out a hostname) or
# "byo" (bring your own domain); return 1 on unknown key. Lets a caller decide
# whether a provider switch can keep the current domain (same provider, or byo↔byo)
# or needs a new hostname (any switch involving a free provider) — used by the
# day-2 action to route domain-changing switches to "Add remote access".
ddns_provider_category() {
    local idx
    idx=$(_ddns_index_of "$1") || return 1
    printf '%s\n' "${_DDNS_CATEGORY[$idx]}"
}

# ddns_render_config_json <key> <fields_assoc_name>
#
# Render the ddns-updater config.json for <key> from the caller's associative
# array (passed by NAME, so the wizard and day-2 share one renderer without a
# branded global). The assoc must hold `domain` plus every field named in
# _DDNS_FIELDS[key]. Emits {"settings":[{...}]} on stdout via python json.dumps
# (never string-templated), key order: provider, domain, <fields in spec order>, then the
# provider's constant skeleton. Any required field missing or empty → non-zero +
# a stderr message and nothing on stdout. Values pass to python as env vars
# (never interpolated into the source), so any character is JSON-escaped safely.
ddns_render_config_json() {
    local key="$1"
    local -n _ddns_fields=$2
    local idx
    if ! idx=$(_ddns_index_of "$key"); then
        printf 'ddns_render_config_json: unknown provider %q\n' "$key" >&2
        return 1
    fi

    # domain is required for every provider.
    if [[ -z "${_ddns_fields[domain]:-}" ]]; then
        printf 'ddns_render_config_json: %s: missing required field %q\n' "$key" domain >&2
        return 1
    fi

    # Ordered credential field names for this provider (strip the :validator half).
    local -a order=()
    local spec name
    for spec in ${_DDNS_FIELDS[$idx]}; do
        name="${spec%%:*}"
        if [[ -z "${_ddns_fields[$name]:-}" ]]; then
            printf 'ddns_render_config_json: %s: missing required field %q\n' "$key" "$name" >&2
            return 1
        fi
        order+=("$name")
    done

    # Assemble the python env: the key, domain, the ordered field-name list, one
    # DDNS_F_<name> per field value, and the constant JSON skeleton.
    local -a env_prefix=(
        "DDNS_KEY=$key"
        "DDNS_DOMAIN=${_ddns_fields[domain]}"
        "DDNS_ORDER=${order[*]}"
        "DDNS_CONST=${_DDNS_CONST_JSON[$idx]}"
    )
    for name in "${order[@]}"; do
        env_prefix+=("DDNS_F_${name}=${_ddns_fields[$name]}")
    done

    env "${env_prefix[@]}" python3 -c '
import os, json
d = {"provider": os.environ["DDNS_KEY"], "domain": os.environ["DDNS_DOMAIN"]}
for name in os.environ["DDNS_ORDER"].split():
    d[name] = os.environ["DDNS_F_" + name]
d.update(json.loads(os.environ["DDNS_CONST"]))
print(json.dumps({"settings": [d]}, indent=2))
'
}
