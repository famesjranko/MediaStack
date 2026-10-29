# Owns: http_* — bounded curl transport and HTTP status handling shared by service APIs.
# Sources: curl; logging and credential-on-stdin helpers from scripts/lib/common.sh.

# Caller limits override these defaults when a readiness probe needs less time.
# Mutating requests get one attempt because a lost reply can hide a committed write.
http_curl() {
    curl --connect-timeout 10 --max-time 45 --retry 0 "$@"
}

# Perform a curl request and enforce a 2xx status. On 2xx the response body
# goes to stdout (return 0). On non-2xx the HTTP code + first 300 chars of
# body go to stderr via the specified log function and the function returns 1.
# Both the *arr API wrappers and other service helpers use this transport.
# Pass curl args including -X, -H, -d after the credential arguments.
#
# <body> is the request payload, sent on stdin so a payload holding a secret
# never reaches argv; pass "" for requests that carry no body. <hdr_name>/
# <hdr_value> is an optional secret-bearing header (Authorization, X-Api-Key,
# ...), also kept off argv; pass "" for both when the call has no such header.
# When both a header and a body are secret they go over the SAME stdin config
# file (curl_header_data_stdin) rather than layering curl_header_stdin's -K -
# under curl_data_stdin's @- — curl only drains stdin once, so the second of
# the two would starve.
http_request() {
    local _log_fn="$1" label="$2" _body="$3" _hdr_name="$4" _hdr_value="$5"
    shift 5
    local out code rc=0
    if [[ -n "$_hdr_name" && -n "$_body" ]]; then
        out=$(curl_header_data_stdin "$_hdr_name" "$_hdr_value" "$_body" -sS -w "\n%{http_code}" "$@" 2>/dev/null) || rc=$?
    elif [[ -n "$_hdr_name" ]]; then
        out=$(curl_header_stdin "$_hdr_name" "$_hdr_value" -sS -w "\n%{http_code}" "$@" 2>/dev/null) || rc=$?
    elif [[ -n "$_body" ]]; then
        out=$(curl_data_stdin "$_body" -sS -w "\n%{http_code}" "$@" 2>/dev/null) || rc=$?
    else
        out=$(http_curl -sS -w "\n%{http_code}" "$@" 2>/dev/null) || rc=$?
    fi
    if ((rc != 0)); then
        "$_log_fn" "$label: connection failed"
        return 1
    fi
    code="${out##*$'\n'}"
    out="${out%$'\n'*}"
    if [[ "$code" =~ ^2 ]]; then
        printf '%s' "$out"
        return 0
    fi
    "$_log_fn" "$label: HTTP ${code} ${out:0:300}"
    return 1
}
