# tests/scenarios/ddns-verify.sh — behaviour-contract drift detector for
# ddns_verify_via_container (scripts/lib/network.sh).
#
# The multi-provider DDNS verify rests on an UNSTABLE behaviour contract, not a
# public API: a throwaway ddns-updater with a blackholed record
# resolver (RESOLVER_ADDRESS=127.0.0.1:1) must fail the hostname lookup and fall
# THROUGH to a REAL provider push at the current IP (upstream's "// update
# anyway"), and GET /update must map the provider response to 202 / 500.
#
# Hermetic: a local test-CA HTTPS stub impersonates BOTH the provider API
# (hardcoded https://) and the public-IP endpoint, so nothing leaves DinD and no
# real credentials are needed. The distroless image trusts the stub via
# SSL_CERT_FILE (a front-loaded spike confirmed the Go binary honours it).
# If a future digest breaks the fall-through or the RESOLVER_ADDRESS wiring, the
# stub stops receiving the push -> the force-verify assertion fails BEFORE the
# image ships, which is when to adapt or switch to upstream #780 (?force=true).
# See docs/operations/upgrades.md (ddns-updater preflight).
#
# The stub reads its response mode from /tmp/dv/mode per request, so one stub +
# one cert generation serves every case (avoids stale-cert-on-port races). The
# 202-accept path stays live-checked by GCP run-fresh.sh (real Dynu).
#
# Wall-time: ~40s warm (one ~20 MB image, a few one-shot containers).

# The stub serves HTTPS on :443 for the provider APIs AND the public-IP fetch.
# Root path (ipify) -> a fixed IP; any other path -> a provider update, logged
# (the drift-detector) and answered per /tmp/dv/mode.
_ddns_verify_stub_py() {
    cat <<'PY'
import http.server, ssl
def mode():
    try: return open("/tmp/dv/mode").read().strip()
    except OSError: return "good"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/" or self.path.startswith("/?"):
            body = b"203.0.113.42"
        else:
            with open("/tmp/dv/log/requests.log", "a") as f:
                f.write(self.command + " " + self.path.split("?", 1)[0] + "\n")
            body = {"good": b"good 203.0.113.42", "nochg": b"nochg 203.0.113.42",
                    "badauth": b"badauth", "ko": b"KO"}.get(mode(), b"good 203.0.113.42")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("0.0.0.0", 443), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("/tmp/dv/ca/server.crt", "/tmp/dv/ca/server.key")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
PY
}

# Run one verify against the stub in <mode>. Args: <mode> <provider> <domain>
# <field-args...>. The domain must satisfy the provider's own validation (e.g.
# DuckDNS enforces the duckdns.org eTLD, else the container fail-fasts at startup).
# Prints "<http_code> <stub_hits>". The render + one-shot container mirror
# ddns_verify_via_container (blackhole + ephemeral port) plus the test-only stub
# wiring (--add-host + SSL_CERT_FILE + a stubbed single public-IP provider).
_ddns_verify_run() {
    local mode="$1" provider="$2" domain="$3"
    shift 3
    dind_exec "printf '%s' '$mode' > /tmp/dv/mode; : > /tmp/dv/log/requests.log; rm -rf /tmp/dv/data && mkdir -p /tmp/dv/data && chown -R 1000:1000 /tmp/dv/data" >/dev/null

    # Render needs bash (assoc array + source); dind_exec is sh.
    if ! docker exec -w /root/MediaStack "$DIND_NAME" bash -c \
        "source scripts/lib/ddns-providers.sh; declare -A F=([domain]=$domain $*); ddns_render_config_json $provider F > /tmp/dv/data/config.json && chmod 644 /tmp/dv/data/config.json" >/dev/null 2>&1; then
        printf 'RENDER-FAIL 0\n'
        return
    fi

    dind_exec "docker rm -f dv-verify >/dev/null 2>&1 || true
      docker run -d --name dv-verify \
        --add-host api.dynu.com:$DV_GW --add-host www.duckdns.org:$DV_GW --add-host api.ipify.org:$DV_GW \
        -e RESOLVER_ADDRESS=127.0.0.1:1 -e SSL_CERT_FILE=/ca/ca.crt \
        -e PUBLICIP_FETCHERS=http -e PUBLICIPV4_HTTP_PROVIDERS=ipify -e PERIOD=0 \
        -p 127.0.0.1:0:8000 \
        -v /tmp/dv/data:/updater/data -v /tmp/dv/ca:/ca:ro \
        $DV_IMAGE >/dev/null" >/dev/null 2>&1

    local eph
    eph=$(dind_exec "docker port dv-verify 8000 2>/dev/null | head -1 | sed 's/.*://'" | tr -d '\r')
    if [[ -z "$eph" ]]; then
        dind_exec "docker rm -f dv-verify" >/dev/null 2>&1
        printf 'NO-PORT 0\n'
        return
    fi

    local code="000"
    for _ in $(seq 1 20); do
        code=$(dind_exec "curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1:${eph}/update 2>/dev/null" | tr -d '\r')
        [[ -n "$code" && "$code" != "000" ]] && break
        sleep 1
    done
    local hits
    hits=$(dind_exec "wc -l < /tmp/dv/log/requests.log 2>/dev/null" | tr -d '\r ')
    dind_exec "docker rm -f dv-verify" >/dev/null 2>&1 || true
    printf '%s %s\n' "$code" "${hits:-0}"
}

# Drive the REAL ddns_verify_via_container (scripts/lib/network.sh) end-to-end,
# with NO product seam: a shell `docker` function shadows the binary and, for
# `docker run`, injects the SAME stub wiring _ddns_verify_run uses above
# (--add-host + SSL_CERT_FILE + a stubbed public-IP provider); everything else
# passes straight through. The function is inherited by ddns_verify_via_container's
# inner ( … ) subshell, so its run / port / inspect / logs / rm calls all route
# through the stub. Overriding _DDNS_VERIFY_IMAGE avoids a real pull (reuse the
# already-loaded DV_IMAGE); _DDNS_VERIFY_RETRY_DELAY=1 keeps the mandatory
# second-500 re-poll fast. Args: <stub-mode> <publicipv4-http-provider>. Prints
# "rc=<rc> hits=<stub-hits> body=<one-line 500 body>". This is what lets cases 7-8
# exercise the /update-500 body classifier (network.sh case 500)) against the real
# function — the branch _ddns_verify_run's reimplementation never reached.
_ddns_verify_real() {
    local mode="$1" pubip="$2"
    dind_exec "printf '%s' '$mode' > /tmp/dv/mode; : > /tmp/dv/log/requests.log" >/dev/null
    docker exec -w /root/MediaStack "$DIND_NAME" bash -c '
        pubip="$1"; gw="$2"; img="$3"
        rm -rf /tmp/dvr && mkdir -p /tmp/dvr
        source scripts/lib/ddns-providers.sh
        declare -A F=([domain]=verify.test [password]=wrong)
        ddns_render_config_json dynu F > /tmp/dvr/config.json 2>/dev/null || { printf "rc=RENDER-FAIL hits=0 body=\n"; exit 0; }
        source scripts/lib/network.sh
        _DDNS_VERIFY_IMAGE="$img"
        _DDNS_VERIFY_RETRY_DELAY=1
        docker() {
            if [ "$1" = run ]; then
                shift
                command docker run \
                    --add-host api.dynu.com:"$gw" --add-host api.ipify.org:"$gw" \
                    -e SSL_CERT_FILE=/ca/ca.crt \
                    -e PUBLICIP_FETCHERS=http -e PUBLICIPV4_HTTP_PROVIDERS="$pubip" \
                    -v /tmp/dv/ca:/ca:ro \
                    "$@"
            else
                command docker "$@"
            fi
        }
        B=/tmp/dvr/body; : > "$B"
        ddns_verify_via_container /tmp/dvr/config.json "$B"; rc=$?
        hits=$(wc -l < /tmp/dv/log/requests.log 2>/dev/null | tr -d " ")
        printf "rc=%s hits=%s body=%s\n" "$rc" "${hits:-0}" "$(tr "\n" " " < "$B" 2>/dev/null)"
        rm -rf /tmp/dvr
    ' bash "$pubip" "$DV_GW" "$DV_IMAGE" 2>/dev/null | tr -d '\r'
}

# Kill the HTTPS stub (by tracked PID — the DinD has no pkill) and clear scratch.
# Called on EVERY _dv_run_scenario exit via the run_scenario wrapper below, so a
# mid-scenario failure can't leak the :443 stub into later scenarios.
_dv_teardown() {
    dind_exec '[ -f /tmp/dv-stub.pid ] && kill "$(cat /tmp/dv-stub.pid)" 2>/dev/null; rm -f /tmp/dv-stub.pid; docker rm -f dv-verify >/dev/null 2>&1 || true; rm -rf /tmp/dv' >/dev/null 2>&1 || true
}

# Wrapper so the stub teardown runs no matter which path _dv_run_scenario exits
# by (it has many early `return 1`s after the stub starts).
run_scenario() {
    _dv_run_scenario
    local _rc=$?
    _dv_teardown
    return "$_rc"
}

_dv_run_scenario() {
    DV_IMAGE=$(ms_test_image ddns-updater qmcgaw/ddns-updater:latest) || {
        fail "ddns-verify: resolve ddns-updater image"
        return 1
    }
    if ! dind_exec 'command -v openssl >/dev/null 2>&1' 2>/dev/null; then
        skip "ddns-verify: openssl unavailable in DinD"
        return 0
    fi

    # --- Setup: test CA + server cert (SAN covers the provider + ipify hosts),
    #     generated ONCE. The container trusts the CA via SSL_CERT_FILE=/ca/ca.crt. ---
    docker exec -w /root/MediaStack "$DIND_NAME" bash -c 'set -e
      rm -rf /tmp/dv && mkdir -p /tmp/dv/ca /tmp/dv/data /tmp/dv/log
      cd /tmp/dv/ca
      openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -subj "/CN=Verify Test CA" -days 1 >/dev/null 2>&1
      openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj "/CN=api.dynu.com" >/dev/null 2>&1
      printf "subjectAltName=DNS:api.dynu.com,DNS:www.duckdns.org,DNS:api.ipify.org\n" > san.cnf
      openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt -days 1 -extfile san.cnf >/dev/null 2>&1' \
        || {
            fail "ddns-verify: could not build test CA / cert in DinD"
            return 1
        }

    _ddns_verify_stub_py | docker exec -i "$DIND_NAME" bash -c 'cat > /tmp/dv/stub.py'
    # The DinD image has no procps, so `pkill`/`ps` do not exist — a `pkill`-based
    # teardown silently no-ops and the stub keeps squatting on :443 across every
    # dind_reset (which only clears containers, never loose processes), breaking
    # every later --profile proxy / NPM scenario. Track the stub's PID in a file
    # OUTSIDE /tmp/dv (which is rebuilt above) and kill it with the shell builtin.
    dind_exec '[ -f /tmp/dv-stub.pid ] && kill "$(cat /tmp/dv-stub.pid)" 2>/dev/null; sleep 1; : > /tmp/dv/stub.out; nohup python3 /tmp/dv/stub.py >/tmp/dv/stub.out 2>&1 & echo $! > /tmp/dv-stub.pid' >/dev/null 2>&1

    DV_GW=$(dind_exec "docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null" | tr -d '\r')
    [[ -n "$DV_GW" ]] || DV_GW=172.17.0.1

    # Wait for the stub to accept TLS, then guard that the cert on the wire matches
    # the cert on disk (a stale stub left on :443 from a prior run would silently
    # serve an old-generation cert and break trust — this guard catches that race).
    local ready=false
    for _ in $(seq 1 15); do
        if dind_exec "curl -sk --max-time 3 https://${DV_GW}:443/ 2>/dev/null | grep -q 203.0.113.42"; then
            ready=true
            break
        fi
        sleep 1
    done
    if ! $ready; then
        fail "ddns-verify: HTTPS stub did not come up"
        dind_exec "cat /tmp/dv/stub.out 2>&1 | head -5"
        return 1
    fi
    local wire disk
    wire=$(dind_exec "echo | openssl s_client -connect ${DV_GW}:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null" | tr -d '\r')
    disk=$(dind_exec "openssl x509 -in /tmp/dv/ca/server.crt -noout -fingerprint -sha256 2>/dev/null" | tr -d '\r')
    if [[ -n "$wire" && "$wire" == "$disk" ]]; then
        pass "HTTPS provider stub up (test-CA, wire cert matches disk — no stale stub)"
    else
        fail "ddns-verify: stub cert mismatch (stale stub?)" "wire=$wire disk=$disk"
        return 1
    fi

    # --- 1. Force-verify (the drift detector): blackhole on, stub-good → the push
    #        MUST reach the stub, and /update maps to 202. ---
    local r
    r=$(_ddns_verify_run good dynu verify.test '[password]=p')
    if [[ "$r" == "202 "* && "${r##* }" -ge 1 ]]; then
        pass "force-verify: blackhole forces a real push to the stub → /update 202 (fall-through OK)"
    else
        fail "force-verify" "expected '202 <hits≥1>'; got '$r'"
    fi

    # --- 2. Reject: stub-badauth → /update 500 (the rejection channel). Require a
    #        stub hit so a spurious 500 (e.g. a failed IP fetch, hits=0) can't pass. ---
    r=$(_ddns_verify_run badauth dynu verify.test '[password]=wrong')
    [[ "$r" == "500 "* && "${r##* }" -ge 1 ]] && pass "reject: bad dyndns2 credentials pushed to the stub → /update 500" \
        || fail "reject" "expected '500 <hits≥1>'; got '$r'"

    # --- 3. Layer-2 mask (pinned false green): a username/password provider
    #        server-side no-ops (nochg) on an unchanged IP without checking the
    #        password → /update 202 even though the creds may be wrong. The honest
    #        tiered messaging owns this caveat; this test keeps it from rotting. ---
    r=$(_ddns_verify_run nochg dynu verify.test '[password]=maybe-wrong')
    [[ "$r" == "202 "* && "${r##* }" -ge 1 ]] && pass "Layer-2 mask pinned: dyndns2 nochg → /update 202 (false green, tiered copy owns it)" \
        || fail "Layer-2 mask" "expected '202 <hits≥1>'; got '$r'"

    # --- 4. Token provider fails safe: a bad token cannot mask (the token IS the
    #        account key), so KO → /update 500 regardless of IP. DuckDNS enforces
    #        the duckdns.org eTLD AND a UUID-shaped token at startup, so use a
    #        conformant domain + a shape-valid-but-wrong (zero) token. ---
    r=$(_ddns_verify_run ko duckdns verify.duckdns.org '[token]=00000000-0000-0000-0000-000000000000')
    [[ "$r" == "500 "* && "${r##* }" -ge 1 ]] && pass "token provider fails safe: duckdns KO pushed to the stub → /update 500 (cannot Layer-2 mask)" \
        || fail "token fail-safe" "expected '500 <hits≥1>'; got '$r'"

    # --- 5. Malformed config is a REJECT, not a degrade. A bad token SHAPE passes
    #        the opaque field validator but fails ddns-updater's startup
    #        validation, so the container fail-fasts before serving. That MUST map
    #        to exit 1 (re-prompt), not exit 2 (which would persist the bad creds
    #        into a dead ddns-updater at install). Runs the REAL helper (the
    #        container fail-fasts before any network, so the stub is not involved). ---
    local fr
    fr=$(docker exec -w /root/MediaStack "$DIND_NAME" bash -c '
        rm -rf /tmp/dvf && mkdir -p /tmp/dvf && chown 1000:1000 /tmp/dvf
        source scripts/lib/ddns-providers.sh
        declare -A F=([domain]=verify.duckdns.org [token]=not-a-valid-uuid)
        ddns_render_config_json duckdns F > /tmp/dvf/config.json && chmod 644 /tmp/dvf/config.json
        source scripts/lib/network.sh
        B=/tmp/dvf/body; : > "$B"
        ddns_verify_via_container /tmp/dvf/config.json "$B"
        printf "rc=%s body=%s\n" "$?" "$(cat "$B" 2>/dev/null)"
        rm -rf /tmp/dvf' 2>/dev/null | tr -d '\r')
    if printf '%s' "$fr" | grep -q '^rc=1'; then
        pass "malformed token shape → fail-fast REJECT (exit 1, re-prompt), not a persisted degrade"
    else
        fail "malformed-token fail-fast reject" "expected rc=1; got '$fr'"
    fi

    # --- 6. A 500 from ddns-updater's OWN infrastructure failure (a failed
    #        public-IP fetch, ZERO provider contact) must map to DEGRADE (keep the
    #        creds), NOT reject (clear good creds on a blip — the flakiness root
    #        cause). ddns_verify_via_container distinguishes them by matching
    #        ddns-updater's infra-error WORDING. The grep below MIRRORS the product
    #        allowlist in network.sh (keep the two in sync); it asserts the image
    #        still emits wording that allowlist matches, so a digest that renames the
    #        error fails HERE — update BOTH regexes — instead of silently regressing
    #        to clearing good creds. Point the IP fetch at a dead port: the fetch
    #        fails before any provider is contacted, yielding the infra 500. ---
    dind_exec "rm -rf /tmp/dvi && mkdir -p /tmp/dvi && chown 1000:1000 /tmp/dvi" >/dev/null
    docker exec -w /root/MediaStack "$DIND_NAME" bash -c \
        'source scripts/lib/ddns-providers.sh; declare -A F=([domain]=verify.duckdns.org [token]=00000000-0000-0000-0000-000000000000); ddns_render_config_json duckdns F > /tmp/dvi/config.json && chmod 644 /tmp/dvi/config.json' >/dev/null 2>&1
    dind_exec "docker rm -f dv-infra >/dev/null 2>&1 || true
      docker run -d --name dv-infra \
        -e RESOLVER_ADDRESS=127.0.0.1:1 \
        -e PUBLICIP_FETCHERS=http -e PUBLICIPV4_HTTP_PROVIDERS=url:https://127.0.0.1:9/ip -e PERIOD=0 \
        -p 127.0.0.1:0:8000 -v /tmp/dvi:/updater/data \
        $DV_IMAGE >/dev/null" >/dev/null 2>&1
    local ieph icode="000" ibody=""
    ieph=$(dind_exec "docker port dv-infra 8000 2>/dev/null | head -1 | sed 's/.*://'" | tr -d '\r')
    if [[ -n "$ieph" ]]; then
        for _ in $(seq 1 20); do
            icode=$(dind_exec "curl -s -o /tmp/dvi/resp -w '%{http_code}' --max-time 15 http://127.0.0.1:${ieph}/update 2>/dev/null" | tr -d '\r')
            [[ -n "$icode" && "$icode" != "000" ]] && break
            sleep 1
        done
        ibody=$(dind_exec "cat /tmp/dvi/resp 2>/dev/null")
    fi
    dind_exec "docker rm -f dv-infra >/dev/null 2>&1 || true"
    if [[ "$icode" == "500" ]] && printf '%s' "$ibody" \
        | grep -qiE 'obtaining ip|dial tcp|no such host|i/o timeout|connection refused|connection reset|context deadline|too many requests'; then
        pass "infra 500 (failed IP fetch) matches the transient allowlist → DEGRADE not REJECT"
    else
        fail "infra-500 wording drift (update the allowlist in ddns_verify_via_container)" "code=$icode body=${ibody:0:160}"
    fi
    dind_exec "rm -rf /tmp/dvi" >/dev/null 2>&1

    # --- 7. Drive the REAL ddns_verify_via_container through a /update 500
    #        whose body is a genuine provider AUTH error (non-infra) and assert it
    #        REJECTS (exit 1). This is the branch no prior case exercised against
    #        the real function: case 2 used _ddns_verify_run's reimplemented poll
    #        (no exit-code assertion), case 5 reached exit 1 via the STARTUP
    #        fail-fast (config-validation grep), not the /update-500 body
    #        classifier. stub-badauth → real push → 500 "badauth" (no infra term)
    #        → network.sh case 500) falls past the allowlist grep → exit 1, with
    #        the 500 body surfaced to the body-file. Require a stub hit so a
    #        spurious 500 (hits=0) can't pass as a reject. ---
    r=$(_ddns_verify_real badauth ipify)
    local rrc rhits rbody
    rrc=$(printf '%s' "$r" | sed -n 's/^rc=\([A-Za-z0-9-]*\).*/\1/p')
    rhits=$(printf '%s' "$r" | sed -n 's/.* hits=\([0-9]*\).*/\1/p')
    rbody=$(printf '%s' "$r" | sed -n 's/.* body=//p')
    if [[ "$rrc" == "1" && "${rhits:-0}" -ge 1 && -n "$rbody" ]]; then
        pass "REAL ddns_verify_via_container — non-infra provider 500 pushed to the stub → exit 1 REJECT (body surfaced)"
    else
        fail "real reject path (non-infra /update 500 → exit 1)" "expected rc=1 hits>=1 body!=empty; got '$r'"
    fi

    # --- 8. Negative control: the SAME real function on an infra 500 (a
    #        failed public-IP fetch, ZERO provider contact) must DEGRADE (exit 2),
    #        not reject — proving exit 1 above is the body classifier deciding, not
    #        a constant. Point the IP fetch at a dead port (as case 6 does) so the
    #        fetch fails before any provider is contacted; the "connection refused"
    #        body matches the infra allowlist → exit 2. Assert the FULL classifier
    #        signature — rc=2 AND zero stub hits (the IP fetch failed before any
    #        provider push) AND an infra-term body — so this stands alone as the
    #        exit-2 body-classifier control (rc=2 has several other sources: no
    #        docker, pull fail, port never published, never-answered /update). ---
    r=$(_ddns_verify_real infra 'url:https://127.0.0.1:9/ip')
    rrc=$(printf '%s' "$r" | sed -n 's/^rc=\([A-Za-z0-9-]*\).*/\1/p')
    rhits=$(printf '%s' "$r" | sed -n 's/.* hits=\([0-9]*\).*/\1/p')
    rbody=$(printf '%s' "$r" | sed -n 's/.* body=//p')
    if [[ "$rrc" == "2" && "${rhits:-1}" -eq 0 ]] \
        && printf '%s' "$rbody" | grep -qiE 'obtaining ip|dial tcp|no such host|i/o timeout|connection refused|connection reset|context deadline|too many requests'; then
        pass "REAL ddns_verify_via_container — infra 500 (failed IP fetch, 0 pushes) → exit 2 DEGRADE (body classifier, not a constant)"
    else
        fail "real degrade path (infra /update 500 → exit 2)" "expected rc=2 hits=0 infra-body; got '$r'"
    fi
}
