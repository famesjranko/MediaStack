# tests/scenarios/ddns-offline.sh — ephemeral verify degrade path (epic #234, #237).
#
# When docker or the ddns-updater image is unavailable mid-wizard (an offline
# install), ddns_verify_via_container (scripts/lib/network.sh) must DEGRADE to
# exit 2 — never exit 1 — so the wizard lands the honest "configured, unverified"
# tier and NEVER re-prompts good credentials. The rejection channel (exit 1) is
# reserved for a real /update 500. This pins that a pull failure ≠ bad creds.
#
# Wall-time: ~5s (no image pulled — that is the point).

run_scenario() {
    # A shape-valid config the helper would happily verify if the image existed.
    dind_exec 'rm -rf /tmp/do && mkdir -p /tmp/do
      printf "%s" "{\"settings\":[{\"provider\":\"dynu\",\"domain\":\"offline.test\",\"username\":\"u\",\"password\":\"p\",\"ip_version\":\"ipv4\"}]}" > /tmp/do/config.json' >/dev/null 2>&1

    # Point the helper at an image tag that does not exist and cannot be pulled:
    # `docker image inspect` misses, the bounded `docker pull` fails (no such
    # manifest), and the helper degrades. Time it to prove there is no hang.
    # The helper needs bash (source + bash syntax); dind_exec is sh, so invoke bash.
    local out rc secs
    out=$(docker exec -w /root/MediaStack "$DIND_NAME" bash -c 'start=$(date +%s)
      source scripts/lib/network.sh
      _DDNS_VERIFY_IMAGE="qmcgaw/ddns-updater:mediastack-offline-nonexistent"
      ddns_verify_via_container /tmp/do/config.json
      rc=$?
      end=$(date +%s)
      printf "RC=%s SECS=%s\n" "$rc" "$((end - start))"' 2>/dev/null | tr -d '\r')
    rc=$(printf '%s' "$out" | sed -n 's/.*RC=\([0-9]*\).*/\1/p')
    secs=$(printf '%s' "$out" | sed -n 's/.*SECS=\([0-9]*\).*/\1/p')

    if [[ "$rc" == "2" ]]; then
        pass "offline degrade: image unavailable -> ddns_verify_via_container exits 2 (not 1)"
    else
        fail "offline degrade exits 2" "got rc='$rc' (out: $out)"
    fi

    # The bounded pull caps at 120s; a healthy degrade returns in a couple of
    # seconds. Guard against a regression that lets it hang toward that cap.
    if [[ -n "$secs" && "$secs" -lt 60 ]]; then
        pass "offline degrade returns promptly (${secs}s < 60s — no hang)"
    else
        fail "offline degrade no-hang" "took '${secs}'s"
    fi

    # Degrade must never re-prompt: it is exit 2, distinct from a real 500 reject
    # (exit 1). The caller (stage2-flow unit) turns exit 2 into REMOTE_WEB_STATE
    # =unchecked; this scenario pins the helper contract that feeds it.
    if [[ "$rc" != "1" ]]; then
        pass "offline degrade never returns the reject code (exit 1 reserved for real 500)"
    else
        fail "offline degrade is not a reject" "rc=$rc"
    fi

    dind_exec 'rm -rf /tmp/do' >/dev/null 2>&1 || true
}
