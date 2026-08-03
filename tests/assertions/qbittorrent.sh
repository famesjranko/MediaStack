assert_qbittorrent_configured() {
    local live_out live_rc=0 parsed=0 saw_fail=0 kind label detail
    live_out=$(dind_exec "bash tests/assertions/qbittorrent-live.sh --url http://localhost:8080" 2>&1) || live_rc=$?

    while IFS=$'\t' read -r kind label detail; do
        case "$kind" in
            PASS)
                pass "$label"
                parsed=1
                ;;
            FAIL)
                fail "$label" "$detail"
                parsed=1
                saw_fail=1
                ;;
            SKIP)
                skip "$label" "$detail"
                parsed=1
                ;;
        esac
    done <<<"$live_out"

    if ((parsed == 0)); then
        fail "step 1 qBittorrent: live assertion script produced structured output" "$live_out"
    elif ((live_rc != 0 && saw_fail == 0)); then
        fail "step 1 qBittorrent: live assertion script exited cleanly" "exit $live_rc"
    fi
}
