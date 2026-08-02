# tests/scenarios/wizard-ui-fail2ban.sh — day-2 Manage-fail2ban menu smoke.
#
# Sources the `mediastack` launcher (guarded main -> sourcing only exposes
# helpers), stubs the two entry guards (_docker_reachable / _health_f2b_running)
# and `docker` (canned fail2ban-client status + banned lists), then drives the
# reshaped fail2ban submenu through: a Whitelist read leg (locked defaults render
# -> Back), the Banned-IPs HUB (pick the multi-jail IP -> context screen -> Unban),
# and Jail stats & history (-> a jail's detail screen, which translates every raw
# status field). This is the only layer that catches set -u / empty-assoc
# (${#arr[@]}) regressions in the new list-building code; the offline unit test
# (tests/unit/launcher-fail2ban.sh) covers the parse + whitelist-write logic. The
# live grep/sed against real crazymax/fail2ban STDOUT is a /verify gate. The
# whitelist read path needs a real jail file, so the fixture seeds the live
# config/fail2ban/jail.d/mediastack.conf from the tracked template.

run_scenario() {
    local fixture="/tmp/wizard-fail2ban.sh"
    local steps="/tmp/wizard-fail2ban.steps.json"
    local plain_log="/tmp/wizard-fail2ban.plain.log"

    dind_exec "cat >$fixture <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
cd /root/MediaStack

# The launcher refuses to run as root (EUID guard); DinD runs as root and the repo
# lives under /root, so we source a same-directory copy with only that guard
# stripped to drive the menu. SCRIPT_DIR derives from the copy's path, so it still
# resolves to the repo (and the lazy 'source health.sh'). The guard is intentional
# and unchanged in the repo.
sed '/if \[\[ \$EUID -eq 0 \]\]; then/,/^fi$/d' mediastack > .ms-launcher-f2b-test.sh
source ./.ms-launcher-f2b-test.sh

# Entry guards pass; fail2ban 'runs'. 203.0.113.5 is banned in BOTH jails (drives
# the hub one-row-per-IP collapse), 198.51.100.9 in jellyfin only. Each per-jail
# status also carries Currently failed / Total failed / File list so the jail-detail
# screen can render its 'Failed logins' composite and the raw 'Watching' log path.
_docker_reachable() { return 0; }
_health_f2b_running() { return 0; }
docker() {
  case \"\$*\" in
    exec\ fail2ban\ fail2ban-client\ status)
        printf 'Status\n|- Jail list:\tjellyfin, npm\n' ;;
    exec\ fail2ban\ fail2ban-client\ status\ jellyfin)
        printf 'Status for jellyfin\n|- Currently failed:\t1\n|- Total failed:\t34\n|- File list:\t/var/log/jellyfin/log_.log\n|- Currently banned:\t2\n|- Total banned:\t5\n|- Banned IP list:\t203.0.113.5 198.51.100.9\n' ;;
    exec\ fail2ban\ fail2ban-client\ status\ npm)
        printf 'Status for npm\n|- Currently failed:\t0\n|- Total failed:\t12\n|- File list:\t/data/logs/npm/access.log\n|- Currently banned:\t1\n|- Total banned:\t3\n|- Banned IP list:\t203.0.113.5\n' ;;
    exec\ fail2ban\ fail2ban-client\ unban\ *)
        return 0 ;;
    exec\ fail2ban\ fail2ban-client\ reload)
        return 0 ;;
    *) return 0 ;;
  esac
}

# The Whitelist read path reads SCRIPT_DIR/config/fail2ban/jail.d/mediastack.conf
# (a real file, not docker). That live copy is gitignored/unseeded in a fresh
# checkout, so seed it from the tracked template.
mkdir -p config/fail2ban/jail.d
cp config/examples/defaults/fail2ban/jail.d/mediastack.conf config/fail2ban/jail.d/mediastack.conf

submenu_fail2ban
BASH
chmod +x $fixture"

    # Numeric indices map to the fallback ui_choose menus (gum absent in DinD ->
    # numbered list). Main menu: 1=Banned IPs 2=Whitelist 3=Jail stats & history
    # 4=Back. Whitelist menu (no user-added tokens): 1=Add an IP 2=Back. Hub (IPs
    # sorted lexically, 2 banned so the bulk item renders): 1=198.51.100.9
    # 2=203.0.113.5 3=Unban all (2 IPs) 4=Back. Context actions: 1=Unban
    # 2=Unban + always allow 3=Back. Stats menu: 1=jellyfin 2=npm 3=Recent
    # ban history 4=Back. Jail detail (jellyfin's banned IPs): 1=203.0.113.5
    # 2=198.51.100.9 3=Back.
    dind_exec 'cat >/tmp/wizard-fail2ban.steps.json <<"JSON"
[
  {"expect": "fail2ban:"},
  {"send": "2\n"},
  {"expect": "default - locked"},
  {"expect": "Whitelist:"},
  {"send": "2\n"},
  {"expect": "fail2ban:"},
  {"send": "1\n"},
  {"expect": "Pick an IP to act on:"},
  {"send": "2\n"},
  {"expect": "What would you like to do?"},
  {"send": "1\n"},
  {"expect": "completed successfully"},
  {"expect": "Press Enter"},
  {"send": "\n"},
  {"expect": "Pick an IP to act on:"},
  {"send": "4\n"},
  {"expect": "fail2ban:"},
  {"send": "3\n"},
  {"expect": "View a jail in detail?"},
  {"send": "1\n"},
  {"expect": "Jail detail: jellyfin"},
  {"expect": "jellyfin:"},
  {"send": "3\n"},
  {"expect": "View a jail in detail?"},
  {"send": "4\n"},
  {"expect": "fail2ban:"},
  {"send": "4\n"}
]
JSON'

    if dind_exec "timeout 120 python3 tests/lib/wizard_pty.py \
        --command $fixture \
        --steps $steps \
        --raw-log ${plain_log%.plain.log}.raw.log \
        --plain-log $plain_log \
        --exit-timeout 20"; then
        pass "wizard-ui fail2ban: PTY flow exits 0"
    else
        fail "wizard-ui fail2ban: PTY flow exits 0"
        dind_exec "tail -160 $plain_log 2>/dev/null || true"
        return 1
    fi

    local transcript
    transcript="$(dind_exec "cat $plain_log")"
    assert_contains "$transcript" "fail2ban:" "wizard-ui fail2ban: submenu shown"
    assert_contains "$transcript" "Banned IPs" "wizard-ui fail2ban: Banned IPs label rendered"
    assert_contains "$transcript" "Whitelist (always-allow IPs)" "wizard-ui fail2ban: Whitelist label rendered"
    assert_contains "$transcript" "Jail stats & history" "wizard-ui fail2ban: Jail stats & history label rendered"
    assert_contains "$transcript" "2 IPs  (jellyfin 2, npm 1)" "wizard-ui fail2ban: main banner distinct count + per-jail tally"
    assert_contains "$transcript" "default - locked" "wizard-ui fail2ban: whitelist renders the locked default ranges"
    assert_contains "$transcript" "203.0.113.5  (jellyfin, npm)" "wizard-ui fail2ban: hub collapses an IP to one row, jails joined"
    assert_contains "$transcript" "Unban all (2 IPs)" "wizard-ui fail2ban: hub offers the bulk unban item"
    assert_contains "$transcript" "Banned IP 203.0.113.5" "wizard-ui fail2ban: context screen names the picked IP"
    assert_contains "$transcript" "Unban + always allow" "wizard-ui fail2ban: context screen offers Unban + always allow"
    assert_contains "$transcript" "completed successfully" "wizard-ui fail2ban: unban result plumbing reports success"
    assert_contains "$transcript" "Jail detail: jellyfin" "wizard-ui fail2ban: jail-detail screen reached"
    assert_contains "$transcript" "Banned total" "wizard-ui fail2ban: jail-detail translates Total banned"
    assert_contains "$transcript" "Failed logins" "wizard-ui fail2ban: jail-detail translates the failed-login counts"
    assert_contains "$transcript" "1 recent (34 total)" "wizard-ui fail2ban: jail-detail Failed logins composite (Currently/Total failed)"
    assert_contains "$transcript" "Watching" "wizard-ui fail2ban: jail-detail translates File list to Watching"
    assert_contains "$transcript" "/var/log/jellyfin/log_.log" "wizard-ui fail2ban: jail-detail Watching shows the raw log path"
}
