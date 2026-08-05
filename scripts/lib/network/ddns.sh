# Owns: ddns_* — Disposable DDNS credential verification through the updater container.
# Sources: scripts/lib/network.sh state plus Docker, curl, and standard host utilities.
ddns_verify_via_container() {
    local config_json="$1" body_file="${2:-}"
    command -v docker >/dev/null 2>&1 || return 2
    [[ -f "$config_json" ]] || return 2

    # The verify runs during Stage-2 collection, BEFORE pull_images, so on a fresh
    # box the image may be absent. Pull it bounded (never an unbounded implicit
    # pull that could hang the wizard); a pull failure degrades, never rejects.
    if ! docker image inspect "$_DDNS_VERIFY_IMAGE" >/dev/null 2>&1; then
        timeout "$DDNS_VERIFY_PULL_TIMEOUT_SECONDS" docker pull "$_DDNS_VERIFY_IMAGE" >/dev/null 2>&1 || return 2
    fi

    # Inner subshell so the cleanup trap is scoped here — it fires on the
    # subshell's exit (return path OR a signal it converts to exit) without
    # clobbering the caller's traps, and works whether we are invoked directly or
    # inside ui_spin's background subshell. --rm does NOT reap a detached daemon on
    # SIGTERM, so the trap removes the container explicitly.
    (
        local scratch cid=""
        scratch=$(mktemp -d) || exit 2
        local rc
        trap 'rc=$?; [[ -n "$cid" ]] && docker rm -f "$cid" >/dev/null 2>&1; rm -rf "$scratch"; exit $rc' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM

        # The container runs as uid 1000. On the common single-user box the invoking
        # uid is 1000, so a 600 copy is readable; widen to 644 so a non-1000
        # installer box can still verify. The file is a throwaway that lives for
        # seconds and holds the user's own creds on their own host.
        # ponytail: if that brief world-read matters on a shared box, chown 1000
        # under `sudo -n` instead; on failure the container just degrades to exit 2.
        cp "$config_json" "$scratch/config.json" 2>/dev/null || exit 2
        chmod 755 "$scratch" && chmod 644 "$scratch/config.json" || exit 2

        # -p 127.0.0.1:0:8000 = ephemeral host port; the real ddns-updater service
        # holds 8000:8000, so a fixed publish would collide during a day-2 verify.
        cid=$(docker run -d -p 127.0.0.1:0:8000 \
            -e RESOLVER_ADDRESS=127.0.0.1:1 -e PERIOD=0 \
            -v "$scratch":/updater/data \
            "$_DDNS_VERIFY_IMAGE" 2>/dev/null) || exit 2

        # Wait for the HTTP server to publish its port. If the container EXITS
        # before it appears, it fail-fasted on the config. An invalid config — a
        # malformed token shape, a domain that fails the provider's eTLD check —
        # is a REJECT (re-prompt), NOT a degrade: otherwise a fat-fingered
        # credential would persist and the real ddns-updater would die at install.
        # A container that is up but simply slow keeps the loop going.
        local port=""
        for _ in $(seq 1 "$DDNS_VERIFY_PORT_PUBLISH_ATTEMPTS"); do
            port=$(docker port "$cid" 8000 2>/dev/null | head -1 | sed 's/.*://')
            [[ -n "$port" ]] && break
            if [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null)" != "true" ]]; then
                local ferr
                # Anchor on ddns-updater's config-validation phase wording only
                # ("validating provider specific settings: <field> is not valid: …"),
                # so an unrelated non-cred startup exit that merely happens to log
                # "invalid" degrades (exit 2) instead of being misread as a
                # bad-cred reject (exit 1) that clears good creds. A real cred/shape
                # error always carries this phrasing.
                ferr=$(docker logs "$cid" 2>&1 \
                    | grep -iE 'validating .* settings|is not valid' \
                    | tail -1)
                if [[ -n "$ferr" ]]; then
                    [[ -n "$body_file" ]] && printf '%s\n' "$ferr" >"$body_file"
                    exit 1
                fi
                exit 2
            fi
            sleep "$DDNS_VERIFY_PORT_PUBLISH_SLEEP_SECONDS"
        done
        [[ -n "$port" ]] || exit 2

        # Bounded poll: --max-time bounds ONE request; this caps the LOOP. The
        # first /update runs a full synchronous cycle (fetch IP + push, ~5s), so
        # give each request a generous timeout and break on the first real
        # response. Capture the body inline (-o). A container that is up but never
        # answers stays at 000 across the loop and degrades rather than spinning.
        local resp="$scratch/resp"
        _ddns_poll_update() {
            local c="000" _i
            for _i in $(seq 1 "$DDNS_VERIFY_UPDATE_POLL_ATTEMPTS"); do
                c=$(curl -s -o "$resp" -w '%{http_code}' --max-time "$DDNS_VERIFY_UPDATE_REQUEST_TIMEOUT_SECONDS" \
                    "http://127.0.0.1:${port}/update" 2>/dev/null)
                [[ -n "$c" && "$c" != "000" ]] && break
                sleep "$DDNS_VERIFY_UPDATE_POLL_SLEEP_SECONDS"
            done
            printf '%s' "$c"
        }

        # A 500 is NOT proof of bad credentials. ddns-updater returns 500 for its
        # OWN transient failures too — a failed public-IP fetch alone yields
        # 500 {"errors":["obtaining ipv4 address: ... connection refused"]} with
        # ZERO provider contact, and a provider-side blip surfaces the same way.
        # The flakiness this guards: identical creds rejected on attempt 1, accepted
        # on attempt 2, because attempt 1 cleared good creds on a transient 500. So
        # a single 500 never decides — wait for the transient to clear and re-poll
        # once (one extra push on a genuine badauth is bounded and harmless).
        local code
        code=$(_ddns_poll_update)
        if [[ "$code" == "500" ]]; then
            sleep "$_DDNS_VERIFY_RETRY_DELAY"
            code=$(_ddns_poll_update)
        fi

        case "$code" in
            202) exit 0 ;;
            500)
                [[ -n "$body_file" ]] && cp "$resp" "$body_file" 2>/dev/null
                # A second 500, 8s apart. If the body is ddns-updater's OWN
                # infrastructure vocabulary (IP-fetch / DNS / connection / deadline /
                # throttle), this is an environment failure, NOT a credential
                # rejection -> DEGRADE (exit 2): keep the shape-valid creds and land
                # the honest "unchecked" tier instead of clearing good creds on a
                # blip. Any other body (a real provider auth error) -> REJECT.
                # Unknown text defaults to reject = the historical fail-safe.
                if grep -qiE 'obtaining ip|dial tcp|no such host|i/o timeout|connection refused|connection reset|context deadline|too many requests' "$resp" 2>/dev/null; then
                    exit 2
                fi
                exit 1
                ;;
            *) exit 2 ;;
        esac
    )
}
