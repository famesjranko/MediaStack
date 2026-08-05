# Owns: Stage 2 DDNS provider selection, credential collection, and preflight.
# Sources: Stage 2 input helper and the DDNS provider registry/renderers.

# Trim leading/trailing whitespace (e.g. from a pasted credential).
_stage2_trim_ws() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    printf '%s' "${v%"${v##*[![:space:]]}"}"
}

# Title-case display name for a provider key (the registry key is lowercase, but
# user-facing copy reads better as "DuckDNS" than "duckdns"). Falls back to the
# raw key for an unknown provider.
_stage2_ddns_provider_label() {
    case "$1" in
        dynu) printf 'Dynu' ;;
        duckdns) printf 'DuckDNS' ;;
        desec) printf 'deSEC' ;;
        dynv6) printf 'dynv6' ;;
        cloudflare) printf 'Cloudflare' ;;
        porkbun) printf 'Porkbun' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Human prompt copy for a provider's credential field. Dynu keeps its exact
# PTY-tested strings; other providers get generic per-field copy.
_stage2_ddns_field_prompt() {
    local provider="$1" name="$2" label
    if [[ "$provider" == "dynu" ]]; then
        case "$name" in
            # Dynu no longer collects a username (Dynu ignores it; the
            # placeholder is auto-filled in ddns-providers.sh). Password only.
            password)
                printf 'Dynu account password (or IP Update Password if you set one)'
                return
                ;;
        esac
    fi
    label=$(_stage2_ddns_provider_label "$provider")
    case "$name" in
        token)
            # DuckDNS tokens are account UUIDs; hint the shape here (a strict
            # input validator would trap a user who can't produce one — the verify
            # step rejects a bad token and the retry menu is the escape).
            if [[ "$provider" == "duckdns" ]]; then
                printf '%s API token (the UUID from your DuckDNS account page)' "$label"
            else
                printf '%s API token' "$label"
            fi
            ;;
        api_key) printf '%s API key' "$label" ;;
        secret_api_key) printf '%s secret API key' "$label" ;;
        zone_identifier) printf '%s Zone ID (32 hex chars, from the domain Overview page)' "$label" ;;
        username) printf '%s account username' "$label" ;;
        password) printf '%s account password' "$label" ;;
        *) printf '%s %s' "$label" "$name" ;;
    esac
}

# True when DDNS is configured but the ephemeral verify did NOT accept
# the credentials this session — PREFLIGHT_OK is not "true" (a degrade, or verify not
# run). The caller uses this to skip the DNS-propagation loop and the live Let's
# Encrypt attempt, landing at the honest REMOTE_WEB_STATE=unchecked terminal
# instead of nagging or gambling a cert on an IP that isn't live yet. A verify
# ACCEPT for ANY provider sets PREFLIGHT_OK=true (and a real push already
# happened), so this is false and the caller proceeds to the DNS loop + LE gate.
_stage2_ddns_unverified() {
    [[ "${_WIZ_USES_DDNS:-false}" == "true" &&
        -n "${_WIZ_DDNS_PROVIDER:-}" &&
        "${_WIZ_DDNS_PREFLIGHT_OK:-false}" != "true" ]]
}

# Repopulate _WIZ_DDNS_FIELDS from the persisted config.json on a re-run so the
# field-loop prompts pre-fill (press Enter to keep) — the DDNS analogue of the
# admin _WIZ_PREV_* recall. Only fills when the assoc is empty; never fatal.
# ponytail: config.json is chmod-600 owned by the ddns-updater uid (1000 by
# default). On the common single-user box PUID==$(id -u)==1000 so a plain read
# works; a non-1000 invoking uid falls back to non-interactive `sudo -n cat`
# (never prompts). If both fail we degrade to empty and the user re-types —
# recall is convenience, not correctness.
_stage2_recall_ddns_from_config() {
    # ${arr[*]+x} is the set -u-safe "assoc has >=1 element" test: ${#arr[@]} on
    # an empty declared associative array trips `unbound variable` under nounset.
    [[ -n "${_WIZ_DDNS_FIELDS[*]+x}" ]] && return 0
    local provider="${_WIZ_DDNS_PROVIDER:-}"
    [[ -n "$provider" ]] || return 0
    local config="$SCRIPT_DIR/config/ddns-updater/config.json"
    [[ -f "$config" ]] || return 0

    local json field_names
    json=$(cat "$config" 2>/dev/null) || json=""
    [[ -n "$json" ]] || json=$(sudo -n cat "$config" 2>/dev/null || true)
    [[ -n "$json" ]] || return 0
    field_names=$(ddns_provider_fields "$provider" 2>/dev/null) || return 0
    # Strip the :validator half; keep just the field names for the python filter.
    local spec names=""
    for spec in $field_names; do names+=" ${spec%%:*}"; done

    local name val
    while IFS=$'\t' read -r name val; do
        [[ -n "$name" && -n "$val" ]] && _WIZ_DDNS_FIELDS["$name"]="$val"
    done < <(DDNS_JSON="$json" DDNS_NAMES="$names" python3 -c '
import os, json
try:
    s = json.loads(os.environ["DDNS_JSON"])["settings"][0]
except Exception:
    raise SystemExit(0)
for name in os.environ["DDNS_NAMES"].split():
    v = s.get(name)
    if isinstance(v, str) and v:
        print(f"{name}\t{v}")
')
    return 0
}

_stage2_offer_ddns() {
    # skip_offer=true skips the static/dynamic question (the walkthrough, or the
    # "Re-enter credentials"/"Change provider" re-entry). pick_mode="pick" forces
    # the provider picker even under skip_offer (the "Change provider" action).
    local skip_offer="${1:-false}"
    local pick_mode="${2:-}"
    if [[ "$skip_offer" != "true" ]]; then
        # DDNS is only needed when the home IP changes. Static-IP users (and
        # users who keep their own DNS updated) skip it entirely. Default to
        # dynamic/DDNS interactively (residential ISPs almost always change IP);
        # in demo/non-interactive mode default to skip so no live provider call
        # fires (mirrors _stage2_port_gate's demo-default idiom below).
        local di=1
        [[ "${UI_DEMO:-0}" == "1" || "${DEMO:-0}" == "1" ]] && di=2
        ui_log info "Most home connections have a changing (dynamic) IP - if unsure, pick the first option."
        local ip_kind
        ip_kind=$(UI_CHOOSE_DEFAULT_INDEX="$di" ui_choose \
            "Does your home internet have a static (unchanging) public IP?" \
            "No - my IP changes (set up DDNS to keep ${_WIZ_DOMAIN} updated)" \
            "Yes - static IP, or I keep my own DNS updated (skip DDNS)")
        if [[ "$ip_kind" == "Yes"* ]]; then
            # Neutralize ALL DDNS recall state. Leaving _WIZ_DDNS_FIELDS populated
            # lets a re-run resurrect it; setting INVALIDATED routes the seed into
            # its clear branch so the user's "skip DDNS" choice actually sticks.
            _WIZ_USES_DDNS="false"
            _WIZ_DDNS_PROVIDER=""
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            if [[ -n "${DDNS_PROVIDER:-}" ]]; then
                # A previous install's config.json is preserved (env_gen never
                # leaves a config-less dead remote), so the old updater keeps
                # running — be honest that "skip" doesn't turn it off here.
                ui_log info "Not changing DDNS: your existing $(_stage2_ddns_provider_label "$DDNS_PROVIDER") setup keeps running. (Changing or removing it is coming to Features & settings.)"
            else
                ui_log info "Skipping DDNS. Point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP."
            fi
            return 1
        fi
        pick_mode="pick" # the dynamic-IP path always chooses a provider
    fi
    _WIZ_USES_DDNS="true"

    # Choose the provider, or keep the current one. Under skip_offer the re-enter
    # path ("Re-enter credentials") keeps the already-set _WIZ_DDNS_PROVIDER;
    # "Change provider" forces pick_mode=pick. The :-duckdns fallback is defensive
    # only (that path always has a provider set) and tracks the picker default.
    local prev_provider="${_WIZ_DDNS_PROVIDER:-}"
    if [[ "$pick_mode" == "pick" ]]; then
        _WIZ_DDNS_PROVIDER=$(ddns_provider_pick "${_WIZ_DDNS_PROVIDER:-}")
    else
        _WIZ_DDNS_PROVIDER="${_WIZ_DDNS_PROVIDER:-duckdns}"
    fi

    # Escape hatch: the user chose "Skip for now" in the picker. Neutralize all
    # DDNS state (same as the static-IP path) so a re-run doesn't resurrect it,
    # and return 1 so the caller lands on the skip/retry menu, not the field loop.
    if [[ "$_WIZ_DDNS_PROVIDER" == "${_DDNS_SKIP:-__skip__}" ]]; then
        _WIZ_USES_DDNS="false"
        _WIZ_DDNS_PROVIDER=""
        _WIZ_DDNS_FIELDS=()
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        ui_log info "Skipping DDNS for now. If you're not setting up remote access yet, choose 'Skip HTTPS for now' at the next prompt — otherwise point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP yourself, then retry."
        return 1
    fi

    local fields_spec
    if ! fields_spec=$(ddns_provider_fields "$_WIZ_DDNS_PROVIDER"); then
        ui_log warn "Unknown DDNS provider '${_WIZ_DDNS_PROVIDER}'; skipping DDNS."
        _WIZ_USES_DDNS="false"
        _WIZ_DDNS_PROVIDER=""
        _WIZ_DDNS_FIELDS=()
        _WIZ_DDNS_PREFLIGHT_OK="false"
        _WIZ_DDNS_INVALIDATED="true"
        return 1
    fi

    # Snapshot prior field values for prompt defaults, then CLEAR-then-refill
    # _WIZ_DDNS_FIELDS. Only reuse the snapshot when the provider is unchanged —
    # a shared field name (e.g. `token`) must never carry one provider's value
    # into another provider's prompt.
    local -A _prev=()
    local k
    for k in "${!_WIZ_DDNS_FIELDS[@]}"; do _prev["$k"]="${_WIZ_DDNS_FIELDS[$k]}"; done
    _WIZ_DDNS_FIELDS=()
    local carry="false"
    [[ "$_WIZ_DDNS_PROVIDER" == "$prev_provider" ]] && carry="true"

    # Collect each field VISIBLE (a long pasted token is verifiable on screen)
    # and whitespace-trimmed (a stray trailing space silently fails auth on every
    # provider), through the escapable collector so a user who picked a provider
    # they aren't ready for can back out gracefully instead of being trapped.
    local spec name validator def val rc
    for spec in $fields_spec; do
        name="${spec%%:*}"
        validator="${spec#*:}"
        def=""
        [[ "$carry" == "true" ]] && def="${_prev[$name]:-}"
        val=$(_stage2_escapable_input "$(_stage2_ddns_field_prompt "$_WIZ_DDNS_PROVIDER" "$name")" "$def" "$validator" "Skip DDNS for now")
        rc=$?
        if ((rc == 130)); then
            return 130 # Ctrl-C: let the pending SIGINT trap abort cleanly
        elif ((rc != 0)); then
            # The user backed out of DDNS mid-collection. Neutralize all state
            # (same as the static-IP / picker skip) so a re-run doesn't resurrect it.
            _WIZ_USES_DDNS="false"
            _WIZ_DDNS_PROVIDER=""
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            ui_log info "Skipping DDNS for now. If you're not setting up remote access yet, choose 'Skip HTTPS for now' at the next prompt — otherwise point A records for jellyfin.${_WIZ_DOMAIN} and seerr.${_WIZ_DOMAIN} at your public IP yourself, then retry."
            return 1
        fi
        _WIZ_DDNS_FIELDS["$name"]="$val"
    done

    # Verify the credentials for ANY provider with the ephemeral blackhole
    # container: render the config to a throwaway path, run it through a one-shot
    # ddns-updater whose record resolver is blackholed so it does a REAL provider
    # push at the current IP, and map GET /update. This is a REJECTION channel:
    #   exit 0 = 202 accepted (or provider-masked) -> tiered message
    #   exit 1 = 500 rejected  -> clear fields, re-prompt (like Dynu badauth before)
    #   exit 2 = degrade (no docker / image unavailable) -> keep shape-valid creds,
    #            land the honest "unchecked" tier, never re-prompt good creds.
    # Build the render assoc = collected fields + the shared media domain (domain
    # is rendered as a reserved key, not a collected field), mirroring env_gen's
    # persist render so verify and persist agree.
    local -A _verify_fields=()
    local _vk
    for _vk in "${!_WIZ_DDNS_FIELDS[@]}"; do _verify_fields["$_vk"]="${_WIZ_DDNS_FIELDS[$_vk]}"; done
    _verify_fields[domain]="$_WIZ_DOMAIN"

    local pname
    pname=$(_stage2_ddns_provider_label "$_WIZ_DDNS_PROVIDER")

    local verify_config verify_body verify_rc=2
    verify_config=$(mktemp 2>/dev/null) || verify_config=""
    verify_body=$(mktemp 2>/dev/null) || verify_body=""
    if [[ -n "$verify_config" ]] \
        && ddns_render_config_json "$_WIZ_DDNS_PROVIDER" _verify_fields >"$verify_config" 2>/dev/null; then
        # The helper is exit-code-valued (writes the 500 body to a file, not
        # stdout), so it can ride ui_spin — which runs it in a background subshell,
        # so the body MUST be surfaced via the file, never a shell global.
        if type ui_spin >/dev/null 2>&1; then
            ui_spin "Checking your ${pname} login (this can take a minute)..." \
                ddns_verify_via_container "$verify_config" "$verify_body"
            verify_rc=$?
        else
            ddns_verify_via_container "$verify_config" "$verify_body"
            verify_rc=$?
        fi
    fi
    [[ -n "$verify_config" ]] && rm -f "$verify_config"

    case "$verify_rc" in
        0)
            # A real /update 202: credentials accepted (or the record already
            # matched the current IP). The push happened, so the caller can wait
            # for DNS to converge and attempt Let's Encrypt.
            _WIZ_DDNS_PREFLIGHT_OK="true"
            _WIZ_DDNS_INVALIDATED="false"
            local tier
            tier=$(ddns_provider_verify_tier "$_WIZ_DDNS_PROVIDER" 2>/dev/null || printf 'token')
            if [[ "$tier" == "token" ]]; then
                ui_log ok "Verified: ${pname} accepted your login and updated ${_WIZ_DOMAIN} to this IP."
            else
                ui_log ok "${pname} accepted the update. If the login turns out wrong, the day-2 Health check will flag it later."
            fi
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            return 0
            ;;
        1)
            # A real /update 500 OR a startup config fail-fast (bad token shape,
            # bad domain eTLD): the config is wrong. Clear the fields so the
            # shape-valid persist gate refuses them (config.json is not written)
            # and the user re-enters (or fixes the domain). Cap the raw provider /
            # validation body so a long regex message doesn't fill the screen.
            local vbody=""
            # ${v:0:160} is character-based (won't split a multibyte char, unlike head -c).
            [[ -n "$verify_body" ]] && vbody=$(tr '\n' ' ' <"$verify_body" 2>/dev/null) && vbody="${vbody:0:160}"
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            _WIZ_DDNS_FIELDS=()
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="true"
            ui_log warn "${pname} did not accept these details${vbody:+ — ${vbody}}. Check for a typo, a trailing space, or a hostname that doesn't match ${pname}, then choose 'Re-enter credentials' or 'Change domain' below."
            return 1
            ;;
        *)
            # Degrade: docker or the image was unavailable, or the container never
            # answered. Keep the shape-valid creds (they persist to config.json)
            # and land the honest "unchecked" tier — never re-prompt good creds. The
            # caller prints the "it will update once the stack starts" terminal line,
            # so keep this to just the verify outcome (no duplicate).
            [[ -n "$verify_body" ]] && rm -f "$verify_body"
            _WIZ_DDNS_PREFLIGHT_OK="false"
            _WIZ_DDNS_INVALIDATED="false"
            ui_log warn "Couldn't check your ${pname} login right now (Docker, the image, or a temporary network/provider hiccup) — your details will be saved and ddns-updater will push your IP when the stack starts."
            return 0
            ;;
    esac
}
