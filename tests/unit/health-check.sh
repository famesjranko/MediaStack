#!/usr/bin/env bash
# tests/unit/health-check.sh
#
# Pure-bash unit tests for scripts/lib/health.sh verdict logic. All externals
# (docker, sudo, df, curl, DNS, the fail2ban regex count) are shimmed, so the
# real container-side plumbing is NOT exercised here — that is validated live on
# a real stack. These tests pin the LOGIC: gate → skip, the fail2ban delta, the
# disk/cert thresholds, the STATUS token contract, and set -e safety.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="health-check"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/common.sh"
source "$REPO_ROOT/scripts/lib/health.sh"

# Run health.sh's checks under the same strict mode as the update.sh consumer, so
# any unguarded non-zero (the set -e safety contract) fails loudly here.
set -eo pipefail

# --- shims -----------------------------------------------------------------
sleep() { :; }
# fail2ban / service gates (return-code fixtures)
F2B_RUNNING=1
SVC_HEALTHY=1
SUDO_OK=1
_health_f2b_running() { return $((1 - F2B_RUNNING)); }
_health_svc_healthy() { return $((1 - SVC_HEALTHY)); }
_health_sudo_ok() { return $((1 - SUDO_OK)); }
_health_f2b_probe() { :; }
# fail2ban-regex match count. File-backed so it survives the command-substitution
# subshells the checks run in ($(...)): pop the first line, repeat the last once drained.
RQ_FILE=$(mktemp)
RQ_LAST=$(mktemp)
setq() {
    printf '%s\n' "$@" >"$RQ_FILE"
    : >"$RQ_LAST"
}
_health_f2b_regex_count() {
    local n
    if [[ -s "$RQ_FILE" ]]; then
        n=$(head -1 "$RQ_FILE")
        sed -i '1d' "$RQ_FILE"
        printf '%s' "$n" >"$RQ_LAST"
    else n=$(cat "$RQ_LAST" 2>/dev/null); fi
    printf '%s' "${n:-0}"
}

# jails status via docker exec; dns; disk; cert/ufw/iptables via sudo
JAILS="Jail list:	jellyfin, npm, seerr"
# Watching probe fixtures: `status jellyfin` -> File list; the `sh -c` newest-file
# scan -> F2B_WATCH_NEWEST directly. This pins the verdict LOGIC only; the real
# container-side busybox scan (health.sh:_f2b_watch_stale) is NOT run here — it is
# verified against the live crazymax/fail2ban image separately. Note the metric
# fails OPEN: if that scan ever errors, `newest` is empty -> verdict "ok".
F2B_WATCH_FILES="/var/log/jellyfin/log_now.log"
F2B_WATCH_NEWEST="/var/log/jellyfin/log_now.log"
F2B_CLIENT_OK=1 # 0 = `fail2ban-client status jellyfin` errors (socket busy mid-reload)
docker() {
    local a=" $* "
    [[ "$a" == *"fail2ban-client status jellyfin"* ]] && {
        ((F2B_CLIENT_OK)) || return 1
        printf 'File list:\t%s\n' "$F2B_WATCH_FILES"
        return 0
    }
    [[ "$a" == *"fail2ban-client status"* ]] && {
        printf '%s\n' "$JAILS"
        return 0
    }
    [[ "$a" == *" sh -c "* ]] && {
        printf '%s\n' "$F2B_WATCH_NEWEST"
        return 0
    }
    return 0
}
DNS_TOKEN="ok"
net_detect_public_ip() {
    _NET_PUBLIC_IP="203.0.113.9"
    return 0
}
stage2_dns_classify() {
    printf '%s' "$DNS_TOKEN"
    [[ "$DNS_TOKEN" == "ok" ]]
}
DF_PCT=40
df() { printf 'Filesystem blk used avail cap mount\nfs 1 1 1 %s%% /data\n' "$DF_PCT"; } # NR==2, col5 = used%
timeout() {
    shift
    "$@"
}
openssl() { :; } # presence for `command -v openssl`
UFW_INSTALLED=1
UFW_STATUS="Status: active"
CERT_BOUND="live/npm-1"
CERT_END="Jan  1 00:00:00 2099 GMT"
DU_JUMP=1
DU_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return $((1 - SUDO_OK)) ;;
        sh)
            [[ "$*" == *ufw* ]] && return $((1 - UFW_INSTALLED))
            return 0
            ;;
        ufw) printf '%s\n' "$UFW_STATUS" ;;
        grep) printf '%s\n' "$CERT_BOUND" ;;
        openssl) printf 'notAfter=%s\n' "$CERT_END" ;;
        iptables)
            case "$*" in
                *"-C DOCKER-USER"*) return $((1 - DU_JUMP)) ;;
                *"-S "*) printf '%s\n' "$DU_RULES" ;;
            esac
            ;;
        *) return 0 ;;
    esac
}

# --- helper ----------------------------------------------------------------
# _v <expected-status> <label> <check-fn> [args...]
_v() {
    local exp="$1" label="$2"
    shift 2
    local out st
    out=$("$@")
    st="${out%%|*}"
    assert_eq "$exp" "$st" "$label -> $out"
}

# --- fail2ban regex (delta) -----------------------------------------------
setq 0 1
_v ok "regex: fresh line increments count => ok" health_fail2ban_regex jellyfin
setq 3 3
_v fail "regex: count flat despite history => fail (no false-pass)" health_fail2ban_regex jellyfin
F2B_RUNNING=0
_v skip "regex: fail2ban down => skip" health_fail2ban_regex jellyfin
F2B_RUNNING=1
SVC_HEALTHY=0
_v skip "regex: service not ready => skip" health_fail2ban_regex jellyfin
SVC_HEALTHY=1

# --- fail2ban jails --------------------------------------------------------
_v ok "jails: all present => ok" health_fail2ban_jails
JAILS="Jail list:	jellyfin, seerr"
_v fail "jails: npm missing => fail" health_fail2ban_jails
JAILS="Jail list:	jellyfin, npm, seerr"
F2B_RUNNING=0
_v skip "jails: fail2ban down => skip" health_fail2ban_jails
F2B_RUNNING=1

# --- fail2ban watching (rotation / stale-file) -----------------------------
F2B_HEALTH_SETTLE_GRACE=0 # re-check is instant under the sleep shim
F2B_WATCH_FILES="/var/log/jellyfin/log_now.log"
F2B_WATCH_NEWEST="/var/log/jellyfin/log_now.log"
_v ok "watching: newest file is watched => ok" health_fail2ban_watching jellyfin
F2B_WATCH_NEWEST="/var/log/jellyfin/log_next.log"
_v fail "watching: jail stuck on stale file => fail" health_fail2ban_watching jellyfin
F2B_CLIENT_OK=0
_v skip "watching: fail2ban-client error => skip (no false stale)" health_fail2ban_watching jellyfin
F2B_CLIENT_OK=1
F2B_WATCH_NEWEST=""
_v ok "watching: no recent activity => ok" health_fail2ban_watching jellyfin
F2B_WATCH_NEWEST="/var/log/jellyfin/log_next.log"
F2B_RUNNING=0
_v skip "watching: fail2ban down => skip" health_fail2ban_watching jellyfin
F2B_RUNNING=1
SVC_HEALTHY=0
_v skip "watching: service not ready => skip" health_fail2ban_watching jellyfin
SVC_HEALTHY=1

# --- dns drift -------------------------------------------------------------
DOMAIN="example.org"
DNS_TOKEN="ok"
_v ok "dns: match => ok" health_dns_drift
DNS_TOKEN="mismatch:1.2.3.4"
_v fail "dns: mismatch => fail" health_dns_drift
DNS_TOKEN="no-a"
_v warn "dns: missing A-records => warn" health_dns_drift
DOMAIN=""
_v skip "dns: no domain => skip" health_dns_drift
DOMAIN="example.org"

# --- disk % ----------------------------------------------------------------
DF_PCT=40
_v ok "disk: 40% => ok" health_disk_pct
DF_PCT=88
_v warn "disk: 88% => warn" health_disk_pct
DF_PCT=97
_v fail "disk: 97% => fail" health_disk_pct

# --- cert expiry -----------------------------------------------------------
CERT_END="Jan  1 00:00:00 2099 GMT"
_v ok "cert: far future => ok" health_cert_expiry
CERT_END="$(date -d '+5 days' '+%b %e %H:%M:%S %Y GMT')"
_v warn "cert: <14d => warn" health_cert_expiry
CERT_END="$(date -d '-2 days' '+%b %e %H:%M:%S %Y GMT')"
_v fail "cert: expired => fail" health_cert_expiry
CERT_BOUND=""
_v skip "cert: no proxy hosts => skip" health_cert_expiry
CERT_BOUND="live/npm-1"
SUDO_OK=0
_v skip "cert: no sudo => skip" health_cert_expiry
SUDO_OK=1
DOMAIN=""
_v skip "cert: no domain => skip" health_cert_expiry
DOMAIN="example.org"

# --- ufw -------------------------------------------------------------------
UFW_STATUS="Status: active"
_v ok "ufw: active => ok" health_ufw_active
UFW_STATUS="Status: inactive"
_v fail "ufw: inactive => fail" health_ufw_active
UFW_INSTALLED=0
_v skip "ufw: not installed => skip" health_ufw_active
UFW_INSTALLED=1
SUDO_OK=0
_v skip "ufw: no sudo => skip" health_ufw_active
SUDO_OK=1

# --- docker-user restrict --------------------------------------------------
_v ok "docker-user: jump + DROP rules => ok" health_docker_user_restrict
DU_JUMP=0
_v fail "docker-user: jump missing => fail" health_docker_user_restrict
DU_JUMP=1
DU_RULES="-A X -j RETURN"
_v fail "docker-user: chain empty (Docker flushed) => fail" health_docker_user_restrict
DU_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
SUDO_OK=0
_v skip "docker-user: no sudo => skip" health_docker_user_restrict
SUDO_OK=1

# --- health_present maps STATUS -> log_* -----------------------------------
LP=""
log_ok() { LP="ok:$*"; }
log_warn() { LP="warn:$*"; }
log_error() { LP="err:$*"; }
log_skip() { LP="skip:$*"; }
health_present "ok|good"
assert_eq "ok:good" "$LP" "present: ok => log_ok"
health_present "fail|bad"
assert_eq "err:bad" "$LP" "present: fail => log_error"
health_present "skip|n/a"
assert_eq "skip:n/a" "$LP" "present: skip => log_skip"

scenario_end "$CURRENT_SCENARIO"
summary
