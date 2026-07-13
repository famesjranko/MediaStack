# The fail2ban-regex "N matched" parser is shared with the runtime day-2 health
# check (scripts/lib/health.sh:_fail2ban_matched_count) so the two can't drift.
# health.sh is source-safe (no side effects, own include guard).
# shellcheck source=../../scripts/lib/health.sh
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/health.sh"

assert_fail2ban_filter_matches() {
    local name="$1"
    local log_source="$2"
    local filter_path="$3"
    # Optional 4th arg: assert an EXACT match count (e.g. one per failure type). Omit for the
    # default "at least one match" check, so existing callers are unchanged.
    local expected_count="${4:-}"

    if svc_stripped fail2ban; then
        skip "fail2ban drift: ${name} filter" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local f2b_regex_out matched_count
    f2b_regex_out=$(dind_exec "docker exec fail2ban fail2ban-regex '$log_source' '$filter_path' 2>&1" | tr -d '\r')
    matched_count=$(_fail2ban_matched_count "$f2b_regex_out")

    if [[ -n "$expected_count" ]]; then
        if [[ "$matched_count" -eq "$expected_count" ]]; then
            pass "fail2ban drift: ${name} filter matches all $expected_count log shapes ($matched_count hits)"
        else
            fail "fail2ban drift: ${name} filter matches all $expected_count log shapes" \
                "filter=${name} matched=${matched_count} expected=${expected_count} log=${log_source} filter_path=${filter_path}"
        fi
    elif [[ "$matched_count" -ge 1 ]]; then
        pass "fail2ban drift: ${name} filter matches current log format ($matched_count hits)"
    else
        fail "fail2ban drift: ${name} filter matches current log format" \
            "filter=${name} matched=0 log=${log_source} filter_path=${filter_path}"
    fi
}

assert_fail2ban_configured() {
    if svc_stripped fail2ban; then
        skip "fail2ban: jail verification" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    # Tier 1 — verify all 3 jails are loaded
    F2B_STATUS=$(dind_exec "docker exec fail2ban fail2ban-client status" | tr -d '\r')
    assert_contains "$F2B_STATUS" "jellyfin" "fail2ban: jellyfin jail loaded"
    assert_contains "$F2B_STATUS" "npm" "fail2ban: npm jail loaded"
    assert_contains "$F2B_STATUS" "seerr" "fail2ban: seerr jail loaded"

    # Tier 1a — every jail has an iptables chain in DOCKER-USER.
    local du_rules jail missing_chains=()
    du_rules=$(dind_exec "iptables -S DOCKER-USER 2>/dev/null" | tr -d '\r')
    # npm-ratelimit ships disabled by default (config.yml rate_limiting.enabled=false,
    # ADR-35), so only 3 jails are active.
    for jail in jellyfin npm seerr; do
        if ! echo "$du_rules" | grep -q "f2b-${jail}"; then
            missing_chains+=("$jail")
        fi
    done
    if [[ ${#missing_chains[@]} -eq 0 ]]; then
        pass "fail2ban: all 3 jails have iptables chains in DOCKER-USER"
    else
        fail "fail2ban: all 3 jails have iptables chains in DOCKER-USER" \
            "missing: ${missing_chains[*]}"
    fi

    # Tier 1b — synthetic banip: jump rule lands in DOCKER-USER, not INPUT
    dind_exec "docker exec fail2ban fail2ban-client set npm banip 203.0.113.99" >/dev/null 2>&1
    local f2b_ipt_rules
    f2b_ipt_rules=$(dind_exec "iptables -S DOCKER-USER 2>/dev/null" | tr -d '\r')
    if echo "$f2b_ipt_rules" | grep -q "f2b-npm"; then
        pass "fail2ban: f2b-npm chain jumped from DOCKER-USER"
    else
        local f2b_input_rules
        f2b_input_rules=$(dind_exec "iptables -S INPUT 2>/dev/null" | tr -d '\r')
        if echo "$f2b_input_rules" | grep -q "f2b-npm"; then
            fail "fail2ban: f2b-npm chain jumped from DOCKER-USER" "f2b-npm jump is in INPUT, not DOCKER-USER"
        else
            fail "fail2ban: f2b-npm chain jumped from DOCKER-USER" "f2b-npm not found in any chain"
        fi
    fi
    local f2b_npm_rules
    f2b_npm_rules=$(dind_exec "iptables -S f2b-npm 2>/dev/null" | tr -d '\r')
    if echo "$f2b_npm_rules" | grep -q "203.0.113.99"; then
        pass "fail2ban: synthetic banip creates REJECT rule in f2b-npm"
    else
        fail "fail2ban: synthetic banip creates REJECT rule in f2b-npm" "203.0.113.99 not in f2b-npm chain"
    fi
    dind_exec "docker exec fail2ban fail2ban-client set npm unbanip 203.0.113.99" >/dev/null 2>&1

    # Tier 2 — trigger real auth failures and verify filter regex matches
    local _f2b_i jf_user
    jf_user=$(env_get JELLYFIN_ADMIN_USER)
    jf_user="${jf_user:-admin}"

    for _f2b_i in $(seq 1 6); do
        docker exec -e "JF_USER=$jf_user" "$DIND_NAME" python3 -c '
import json, os, urllib.request
body = json.dumps({"Username": os.environ["JF_USER"], "Pw": "wrong_f2b"}).encode()
req = urllib.request.Request(
    "http://localhost:8096/Users/AuthenticateByName",
    data=body,
    method="POST",
    headers={
        "Content-Type": "application/json",
        "Authorization": "MediaBrowser Client=\"Test\", Device=\"Test\", DeviceId=\"f2b-test\", Version=\"1.0\"",
    },
)
try:
    urllib.request.urlopen(req, timeout=5).read()
except Exception:
    pass
' >/dev/null 2>&1 || true
    done

    if ! svc_stripped seerr; then
        for _f2b_i in $(seq 1 6); do
            dind_exec "curl -s -o /dev/null -X POST http://localhost:5055/api/v1/auth/local \
                -H 'Content-Type: application/json' \
                -d '{\"email\":\"admin\",\"password\":\"wrong_f2b\"}'" 2>/dev/null || true
        done
    fi

    if ! svc_stripped npm; then
        for _f2b_i in $(seq 1 6); do
            dind_exec "curl -sk -o /dev/null --resolve 'jellyfin.fresh.test:443:127.0.0.1' https://jellyfin.fresh.test:443/Users" 2>/dev/null || true
        done
    fi

    sleep 5

    local f2b_regex_out matched_count

    f2b_regex_out=$(dind_exec "docker exec fail2ban sh -c 'cat /var/log/jellyfin/log_*.log > /tmp/f2b-test.log 2>/dev/null && fail2ban-regex /tmp/f2b-test.log /data/filter.d/jellyfin.conf 2>&1; rm -f /tmp/f2b-test.log'" | tr -d '\r')
    matched_count=$(_fail2ban_matched_count "$f2b_regex_out")
    if [[ "$matched_count" -ge 1 ]]; then
        pass "fail2ban: jellyfin filter matches current log format ($matched_count hits)"
    else
        fail "fail2ban: jellyfin filter matches current log format" "0 matched — log format may have changed"
    fi

    if ! svc_stripped seerr; then
        f2b_regex_out=$(dind_exec "docker exec fail2ban sh -c 'cat /var/log/seerr/*.log > /tmp/f2b-test.log 2>/dev/null && fail2ban-regex /tmp/f2b-test.log /data/filter.d/seerr.conf 2>&1; rm -f /tmp/f2b-test.log'" | tr -d '\r')
        matched_count=$(_fail2ban_matched_count "$f2b_regex_out")
        if [[ "$matched_count" -ge 1 ]]; then
            pass "fail2ban: seerr filter matches current log format ($matched_count hits)"
        else
            fail "fail2ban: seerr filter matches current log format" "0 matched — log format may have changed"
        fi
    fi

    if ! svc_stripped npm; then
        f2b_regex_out=$(dind_exec "docker exec fail2ban sh -c 'cat /var/log/npm/proxy-host-*_*.log /var/log/npm/default-host_*.log > /tmp/f2b-test.log 2>/dev/null && fail2ban-regex /tmp/f2b-test.log /data/filter.d/npm.conf 2>&1; rm -f /tmp/f2b-test.log'" | tr -d '\r')
        matched_count=$(_fail2ban_matched_count "$f2b_regex_out")
        if [[ "$matched_count" -ge 1 ]]; then
            pass "fail2ban: npm filter matches current log format ($matched_count hits)"
        else
            fail "fail2ban: npm filter matches current log format" "0 matched — log format may have changed"
        fi
    fi

    # Tier 3 — full ban pipeline: relax ignoreip, trigger ban, verify iptables
    dind_exec "cp config/fail2ban/jail.d/mediastack.conf /tmp/mediastack.conf.bak"
    dind_exec "sed -i 's|ignoreip = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16|ignoreip = 127.0.0.0/8|' config/fail2ban/jail.d/mediastack.conf"
    dind_exec "sed -i 's|maxretry = 5|maxretry = 3|' config/fail2ban/jail.d/mediastack.conf"
    dind_exec "docker exec fail2ban fail2ban-client reload" >/dev/null 2>&1
    sleep 2

    for _f2b_i in $(seq 1 5); do
        docker exec -e "JF_USER=$jf_user" "$DIND_NAME" python3 -c '
import json, os, urllib.request
body = json.dumps({"Username": os.environ["JF_USER"], "Pw": "trigger_ban_f2b"}).encode()
req = urllib.request.Request(
    "http://localhost:8096/Users/AuthenticateByName",
    data=body,
    method="POST",
    headers={
        "Content-Type": "application/json",
        "Authorization": "MediaBrowser Client=\"Test\", Device=\"Test\", DeviceId=\"f2b-ban\", Version=\"1.0\"",
    },
)
try:
    urllib.request.urlopen(req, timeout=5).read()
except Exception:
    pass
' >/dev/null 2>&1 || true
        sleep 0.5
    done

    local ban_waited=0 jf_ban_status=""
    while (( ban_waited < 30 )); do
        jf_ban_status=$(dind_exec "docker exec fail2ban fail2ban-client status jellyfin" | tr -d '\r')
        if echo "$jf_ban_status" | grep -qE "Currently banned:[[:space:]]*[1-9]"; then
            break
        fi
        sleep 3; ban_waited=$((ban_waited + 3))
    done

    if echo "$jf_ban_status" | grep -qE "Currently banned:[[:space:]]*[1-9]"; then
        pass "fail2ban: jellyfin jail banned IP after exceeding maxretry"
    else
        fail "fail2ban: jellyfin jail banned IP" "$(echo "$jf_ban_status" | grep -E 'Currently banned|Banned IP')"
    fi

    f2b_ipt_rules=$(dind_exec "iptables -S DOCKER-USER 2>/dev/null" | tr -d '\r')
    if echo "$f2b_ipt_rules" | grep -q "f2b-jellyfin"; then
        pass "fail2ban: f2b-jellyfin chain referenced from DOCKER-USER"
    else
        fail "fail2ban: f2b-jellyfin chain referenced from DOCKER-USER" \
            "f2b-jellyfin not jumped to from DOCKER-USER — bans may land in INPUT instead"
    fi

    # Restore original jail config for --keep debugging
    dind_exec "cp /tmp/mediastack.conf.bak config/fail2ban/jail.d/mediastack.conf"
    dind_exec "docker exec fail2ban fail2ban-client reload" >/dev/null 2>&1
}

# Issue #291: a service rolling to a NEW date-stamped log file must not silently
# stop being watched. Self-contained (does not assume assert_fail2ban_configured's
# relaxed state survives). Proves: (a) the bug — a new file is NOT in the live
# jail's File list until reload; (b) the mechanism — reload re-resolves the glob;
# (c) the shipped watcher — running it auto-reloads on a new file, no manual
# reload. Uses the live jail's `File list` (deterministic), not a synthetic ban.
assert_fail2ban_rotation() {
    if svc_stripped fail2ban; then
        skip "fail2ban: log-rotation watcher" "stripped via MS_TEST_STRIP_SERVICES"
        return
    fi

    local logdir="config/jellyfin/log"
    local f1="log_20991231.log" f2="log_20991230.log"   # future-dated → unambiguously newest
    local jf_files
    _f2b_jellyfin_files() {
        dind_exec "docker exec fail2ban fail2ban-client status jellyfin" \
            | tr -d '\r' | sed -n 's/.*File list:[[:space:]]*//p' | head -1
    }

    dind_exec "rm -f $logdir/$f1 $logdir/$f2"

    # (a) Rolled file appears, NO reload → the running jail must not be watching it.
    dind_exec "echo 'ms-rotation-test' > $logdir/$f1"
    sleep 1
    jf_files=$(_f2b_jellyfin_files)
    if echo "$jf_files" | grep -qF "$f1"; then
        fail "fail2ban rotation: rolled file unwatched until reload" \
            "jellyfin is already watching $f1 without a reload — the glob-rollover bug does not reproduce on this fail2ban build; re-evaluate whether the reload watcher is still needed (File list: $jf_files)"
    else
        pass "fail2ban rotation: rolled log file is unwatched until reload (bug reproduced)"
    fi

    # (b) Manual reload re-resolves the glob → now watched.
    dind_exec "docker exec fail2ban fail2ban-client reload" >/dev/null 2>&1
    sleep 2
    jf_files=$(_f2b_jellyfin_files)
    if echo "$jf_files" | grep -qF "$f1"; then
        pass "fail2ban rotation: reload re-resolves the glob to the new file"
    else
        fail "fail2ban rotation: reload re-resolves the glob to the new file" \
            "after reload, jellyfin File list still lacks $f1 (File list: $jf_files)"
    fi

    # (c) The shipped watcher auto-follows a NEW rolled file with NO manual reload.
    # Note: the watcher blocks until EVERY dir in its WATCH_DIRS (jellyfin + seerr
    # + npm log dirs) exists before arming inotifywait, so this jellyfin-only check
    # transitively depends on seerr+npm dirs being seeded — true in fresh-install
    # (create_config_dirs_in_dind seeds all three), the only caller of this assertion.
    # Start it DETACHED inside DinD (each dind_exec is its own docker exec session,
    # so a plain & job would die with it — setsid+nohup survives). Short settle.
    # setsid makes the watcher a session/group leader, so the captured $! is its
    # PGID — track it so teardown can kill the whole tree (bash pipeline + its
    # inotifywait child) by PID. The DinD image has no procps, so pkill/ps do not
    # exist (see tests/scenarios/ddns-verify.sh) — kill by tracked PID, not pkill.
    dind_exec "setsid env F2B_WATCH_SETTLE=1 nohup ./scripts/fail2ban-reload-watcher.sh >/tmp/f2b-watch.log 2>&1 </dev/null & echo \$! > /tmp/f2b-watch.pid" >/dev/null 2>&1
    # Wait for the watcher's readiness line (logged right before it arms inotifywait)
    # rather than a fixed sleep — the reconcile reload before arming can take a few
    # seconds under load, and a create that lands before inotifywait is armed would
    # be missed (flaky). Then re-create the rolled file each round (a fresh CREATE
    # event) until it is re-globbed in — robust to a single missed event.
    local r=0
    while (( r < 20 )); do
        dind_exec "cat /tmp/f2b-watch.log 2>/dev/null" | grep -q 'for log rotation' && break
        sleep 1; r=$((r + 1))
    done
    sleep 1
    local watched=0 i=0
    while (( i < 6 )); do
        dind_exec "rm -f $logdir/$f2; echo 'ms-rotation-test' > $logdir/$f2"
        sleep 3   # settle(1) + reload + margin
        if _f2b_jellyfin_files | grep -qF "$f2"; then watched=1; break; fi
        i=$((i + 1))
    done
    # Tear down the watcher by tracked PID (no pkill in the DinD image). Kill the
    # whole process group (-PID) so the bash pipeline AND its inotifywait child die
    # together; also signal the PID itself as a fallback. Both swallowed.
    dind_exec 'p=$(cat /tmp/f2b-watch.pid 2>/dev/null); [ -n "$p" ] && { kill -TERM -"$p" 2>/dev/null; kill -TERM "$p" 2>/dev/null; }; rm -f /tmp/f2b-watch.pid' >/dev/null 2>&1 || true
    if (( watched == 1 )); then
        pass "fail2ban rotation: reload watcher auto-followed the new file (no manual reload)"
    else
        fail "fail2ban rotation: reload watcher auto-followed the new file" \
            "watcher did not pick up $f2 within ~38s (20s readiness + 6×3s watch); log: $(dind_exec 'cat /tmp/f2b-watch.log 2>/dev/null' | tr -d '\r' | tail -5)"
    fi

    # Clean up injected files (before any later Tier-2 regex cat re-globs) + reload.
    dind_exec "rm -f $logdir/$f1 $logdir/$f2"
    dind_exec "docker exec fail2ban fail2ban-client reload" >/dev/null 2>&1
    unset -f _f2b_jellyfin_files
}
