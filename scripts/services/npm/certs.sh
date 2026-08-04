# Owns: NPM certificate identity, material, and issuance wait helpers.
# Sources: main.sh for NPM_* timing globals and npm_remote.sh for remote reads; no hidden inputs.
# shellcheck disable=SC2154
# --- Cert identity vs cert usability -------------------------------------
#
# NPM's certificate table can list a row whose certbot run failed mid-flight,
# leaving "issued in NPM but never on disk." Publishing a proxy host with
# such a cert_id returns 2xx from the API but produces no `proxy_host/N.conf`
# and no nginx vhost — surfacing as "TLS unrecognized name" on the public
# hostname. So "what NPM knows about" and "what we can actually serve" are
# different questions, and we keep them as separate helpers.
#
#   _npm_api_cert_id_by_fqdn    — pure NPM/API view (highest non-deleted id)
#   _npm_cert_material_ready    — disk truth (key + chain present?)
#   _npm_usable_cert_id_by_fqdn — composition (use this for target_cert_id)
#
# Anywhere we pick `target_cert_id`, prefer the composition. The narrower
# helpers are reserved for places that genuinely need only one view, and
# named loudly so future readers don't accidentally trust DB-only state.

# ALL non-deleted cert ids matching this FQDN, NEWEST FIRST. Used by
# _npm_usable_cert_id_by_fqdn to iterate from newest down to oldest. The
# max-id-only variant masks a usable older cert when a newer not-yet-on-disk
# row has been allocated — i.e. exactly the "first POST is still finishing,
# someone POSTed again, NPM allocated a new id, our adopt-newest-only
# helper now hides the ready cert and we POST a third time" amplifier.
#
# Returns:
#   0 + ids on stdout (one per line, may be empty)
#   2 if the API call itself failed (timeout / connection / 5xx) — caller
#     MUST distinguish this from "no matching certs" and not assume the
#     fqdn has no certs in flight.
_npm_api_cert_ids_by_fqdn() {
    npm_remote_api_cert_ids_by_fqdn "$@"
}

# Highest cert id NPM knows about for this FQDN, regardless of whether the
# key+chain are on disk yet. Used to detect "a cert request is in flight"
# when we have to decide whether to POST another one.
# Same return convention as _npm_api_cert_ids_by_fqdn (rc=2 on API error).
_npm_latest_cert_id_by_fqdn() {
    local _ids _rc
    _ids=$(_npm_api_cert_ids_by_fqdn "$@")
    _rc=$?
    ((_rc == 2)) && return 2
    echo "$_ids" | head -n1
}

_npm_cert_material_ready() {
    npm_remote_cert_material_ready "$@"
}

# Highest-id cert for this FQDN whose key+chain are on disk. Iterates newest
# first; never masks an older usable cert behind a newer in-flight one.
# Returns rc=2 on API error so callers can refuse to POST while blind.
_npm_usable_cert_id_by_fqdn() {
    npm_remote_usable_cert_id_by_fqdn "$@"
}

# Is certbot currently running inside the NPM container? Used to refuse
# starting a second issuance for the same FQDN while one is in flight.
# We check the global certbot lock (/var/lib/letsencrypt/.certbot.lock).
# Stale lock files would be a false-positive risk, but on the NPM image
# the lock is opened with flock() and released on process exit, so a
# leftover file that's not actually locked is treated as "busy" too —
# which is the safe default for our use case (we'd rather wait an extra
# poll than burn an LE cert).
_npm_certbot_busy() {
    docker exec npm test -e /var/lib/letsencrypt/.certbot.lock >/dev/null 2>&1
}

# Long poll: wait up to ~max_polls × interval seconds for a cert with
# disk material to appear for FQDN.
# Returns 0 + cert_id on stdout when found; rc=1 on timeout.
# Critically, rc=2 means the API was unreachable for the entire window,
# so caller knows nothing about whether a cert is in flight.
_npm_wait_usable_cert() {
    local _token="$1" _api="$2" _fqdn="$3"
    local _max="${4:-$NPM_CERT_WAIT_MAX_POLLS}" _interval="${5:-$NPM_CERT_WAIT_INTERVAL_SECONDS}"
    local _i _id _rc _api_ok=0
    for _i in $(seq 1 "$_max"); do
        _id=$(_npm_usable_cert_id_by_fqdn "$_token" "$_api" "$_fqdn")
        _rc=$?
        if ((_rc == 0)); then
            _api_ok=1
            if [[ -n "$_id" && "$_id" != "0" ]]; then
                echo "$_id"
                return 0
            fi
        fi
        sleep "$_interval"
    done
    ((_api_ok == 0)) && return 2
    return 1
}
