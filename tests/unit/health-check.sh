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
net_dns_classify() {
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
# DOCKER-USER itself, in the order iptables -S prints it: one jump, no RETURN ahead of it.
DU_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT'
# systemd unit state for the UFW-off path (the unit docker.service Requires=).
SC_ACTIVE=1
SC_FAILED=0
systemctl() {
    case "$1" in
        is-failed) return $((1 - SC_FAILED)) ;;
        is-active) return $((1 - SC_ACTIVE)) ;;
    esac
}
# IPv6 defaults to "Docker has no v6 DOCKER-USER chain", the state of a host
# whose Docker is v4-only: the v6 arm must stay silent there.
DU6_PRESENT=0
DU6_JUMP=1
DU6_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
ufw_installed() { return $((1 - UFW_INSTALLED)); }
sudo() {
    [[ "${1:-}" == "-n" ]] && shift
    case "${1:-}" in
        true) return $((1 - SUDO_OK)) ;;
        sh)
            return 0
            ;;
        ufw) printf '%s\n' "$UFW_STATUS" ;;
        grep) printf '%s\n' "$CERT_BOUND" ;;
        openssl) printf 'notAfter=%s\n' "$CERT_END" ;;
        iptables)
            case "$*" in
                *"-C DOCKER-USER"*) return $((1 - DU_JUMP)) ;;
                *"-S DOCKER-USER"*) printf '%s\n' "$DU_USER_RULES" ;;
                *"-S "*) printf '%s\n' "$DU_RULES" ;;
            esac
            ;;
        ip6tables)
            case "$*" in
                *"-S DOCKER-USER"*) return $((1 - DU6_PRESENT)) ;;
                *"-C DOCKER-USER"*) return $((1 - DU6_JUMP)) ;;
                *"-S "*) printf '%s\n' "$DU6_RULES" ;;
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

# --- fail2ban down: not installed vs installed but stopped ------------------
# Given: fail2ban is not running and the .env names a real domain (proxy profile)
_f2b_root=$(mktemp -d)
_saved_root="$_HEALTH_REPO_ROOT"
_HEALTH_REPO_ROOT="$_f2b_root"
F2B_RUNNING=0
printf "DOMAIN='media.example.org'\n" >"$_f2b_root/.env"
# When: each fail2ban check runs
installed_out=$(
    health_fail2ban_jails
    health_fail2ban_regex jellyfin
    health_fail2ban_watching jellyfin
)
# Then: every verdict says fail2ban is installed but stopped and how to start it, never "LAN-only"
assert_eq "3" "$(grep -c 'installed but not running - start it from Manage stack > Start a service' <<<"$installed_out")" "f2b down on a remote host: all three checks say installed but not running"
assert_not_contains "$installed_out" "LAN-only" "f2b down on a remote host: not reported as LAN-only"

# Given: fail2ban is not running and the .env has no real domain (LAN-only)
printf 'DOMAIN=example.com\n' >"$_f2b_root/.env"
# When: each fail2ban check runs
lan_out=$(
    health_fail2ban_jails
    health_fail2ban_regex jellyfin
    health_fail2ban_watching jellyfin
)
# Then: every verdict says fail2ban is not installed (LAN-only)
assert_eq "3" "$(grep -c 'not installed (LAN-only install)' <<<"$lan_out")" "f2b down on a LAN-only host: all three checks say not installed"
assert_not_contains "$lan_out" "installed but not running" "f2b down on a LAN-only host: not reported as stopped"
_HEALTH_REPO_ROOT="$_saved_root"
rm -rf "$_f2b_root"
F2B_RUNNING=1

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
# The unit and drop-in the chain comes from exist in every case below unless a case removes them.
AF_DIR=$(mktemp -d)
export MEDIASTACK_ADMIN_FILTER_DROPIN="$AF_DIR/mediastack-admin-filter.conf"
export MEDIASTACK_ADMIN_FILTER_UNIT="$AF_DIR/mediastack-admin-filter.service"
touch "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_UNIT"
_v ok "docker-user: jump + DROP rules => ok" health_docker_user_restrict
DU_JUMP=0
_v fail "docker-user: jump missing => fail" health_docker_user_restrict
DU_JUMP=1
DU_RULES="-A X -j RETURN"
_v fail "docker-user: chain empty (Docker flushed) => fail" health_docker_user_restrict
DU_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
_v ok "docker-user: no v6 DOCKER-USER chain => v6 not reported" health_docker_user_restrict
DU6_PRESENT=1
_v ok "docker-user: v6 chain jumped => ok" health_docker_user_restrict
DU6_JUMP=0
_v fail "docker-user: v6 chain present but jump missing => fail" health_docker_user_restrict
DU6_JUMP=1
# Given IPv6 is enabled in Docker and the v6 jump exists but the v6 chain was flushed
# When the port lock is checked
# Then the verdict is a failure naming IPv6
DU6_RULES="-A X -j RETURN"
_v fail "docker-user: v6 chain jumped but EMPTY => fail" health_docker_user_restrict
assert_contains "$(health_docker_user_restrict)" "IPv6 port-restriction chain is EMPTY" "docker-user: empty v6 chain is named as IPv6"
DU6_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
DU6_PRESENT=0
SUDO_OK=0
_v skip "docker-user: no sudo => skip" health_docker_user_restrict
SUDO_OK=1

# Given a jump that sits behind Docker's own RETURN rule
# When the port-lock check runs
# Then it fails, because rules behind a RETURN never run
DU_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j RETURN\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT'
_v fail "docker-user: jump behind a RETURN => fail" health_docker_user_restrict
DU_USER_RULES=$'-N DOCKER-USER\n-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT\n-A DOCKER-USER -j RETURN'
_v ok "docker-user: jump ahead of RETURN => ok" health_docker_user_restrict

# --- admin-port filter: unit + drop-in + chain, with UFW on or off -----------
# Given the unit path is the only install path
# When the port-lock check runs with UFW on, then off
# Then every unit-path failure is reported in both cases
for UFW_ENABLED in true false; do
    _v ok "filter UFW=$UFW_ENABLED: unit, drop-in and chain all present => ok" health_docker_user_restrict
    rm "$MEDIASTACK_ADMIN_FILTER_DROPIN"
    _v fail "filter UFW=$UFW_ENABLED: drop-in missing => fail" health_docker_user_restrict
    touch "$MEDIASTACK_ADMIN_FILTER_DROPIN"
    rm "$MEDIASTACK_ADMIN_FILTER_UNIT"
    _v fail "filter UFW=$UFW_ENABLED: unit file missing => fail" health_docker_user_restrict
    touch "$MEDIASTACK_ADMIN_FILTER_UNIT"
    SC_FAILED=1
    _v fail "filter UFW=$UFW_ENABLED: unit failed => fail" health_docker_user_restrict
    SC_FAILED=0
    SC_ACTIVE=0
    _v fail "filter UFW=$UFW_ENABLED: unit not active => fail" health_docker_user_restrict
    SC_ACTIVE=1
    DU_JUMP=0
    _v fail "filter UFW=$UFW_ENABLED: jump missing => fail" health_docker_user_restrict
    DU_JUMP=1
    DU_RULES="-A X -j RETURN"
    _v fail "filter UFW=$UFW_ENABLED: chain empty => fail" health_docker_user_restrict
    DU_RULES="-A X -p tcp -m multiport --dports 80 -j DROP"
    SUDO_OK=0
    SC_FAILED=1
    _v fail "filter UFW=$UFW_ENABLED: a failed unit is reported even without sudo" health_docker_user_restrict
    SC_FAILED=0
    SUDO_OK=1
done
# Given UFW is on and the unit path is missing entirely (a host that kept only an after.rules block)
# When the port-lock check runs
# Then it fails: that block is not a working filter
UFW_ENABLED=true
rm "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_UNIT"
_v fail "filter with UFW: no unit path installed => fail" health_docker_user_restrict
DU_JUMP=0
ADMIN_PORT_FILTER=false
_v skip "filter opted out: reported as the user's choice, not a failure" health_docker_user_restrict
assert_contains "$(health_docker_user_restrict)" "OFF by your choice" "filter opted out: message says it is the user's choice"
DU_JUMP=1
# Given a value that is not exactly false (TRUE, yes, 1, "true ", off)
# When the port-lock check runs
# Then the filter still counts as wanted, so a missing drop-in fails instead of skipping
for v in TRUE FALSE False yes 1 "true " off; do
    ADMIN_PORT_FILTER="$v"
    rm -f "$MEDIASTACK_ADMIN_FILTER_DROPIN"
    _v fail "filter value [$v]: fails closed, not an opt-out" health_docker_user_restrict
done
unset ADMIN_PORT_FILTER

# --- ./mediastack status warning -------------------------------------------
source "$REPO_ROOT/scripts/launcher/status-admin-filter.sh"
launcher_is_installed() { return 0; }
WARN_OUT=""
ui_log() { WARN_OUT+="$1:$2;"; }
UFW_ENABLED=false
# Given the filter is wanted (the key is absent) but its unit has failed
# When the main menu draws
# Then a warning line appears
SC_FAILED=1
launcher_admin_filter_warning
assert_contains "$WARN_OUT" "warn:Admin-port filter NOT active" "status line: warns when the filter is wanted but inactive (key absent => wanted)"
# Given the same failed unit with UFW on
# When the main menu draws
# Then the warning appears there too
WARN_OUT=""
UFW_ENABLED=true
launcher_admin_filter_warning
assert_contains "$WARN_OUT" "warn:Admin-port filter NOT active" "status line: warns with UFW on as well"
UFW_ENABLED=false
# Given the user turned the filter off and the unit is not there
# When the main menu draws
# Then there is no warning
WARN_OUT=""
ADMIN_PORT_FILTER=false
launcher_admin_filter_warning
assert_eq "" "$WARN_OUT" "status line: no warning when the user turned the filter off"
# Given an unrecognised value and a failed unit
# When the main menu draws
# Then the warning appears, because only the exact value false is an opt-out
WARN_OUT=""
export ADMIN_PORT_FILTER=TRUE
SC_FAILED=1
launcher_admin_filter_warning
assert_contains "$WARN_OUT" "warn:Admin-port filter NOT active" "status line: warns for ADMIN_PORT_FILTER=TRUE"
# Given a working filter
# When the main menu draws
# Then there is no warning
WARN_OUT=""
unset ADMIN_PORT_FILTER
SC_FAILED=0
touch "$MEDIASTACK_ADMIN_FILTER_DROPIN" "$MEDIASTACK_ADMIN_FILTER_UNIT"
launcher_admin_filter_warning
assert_eq "" "$WARN_OUT" "status line: no warning while the filter is active"
# Given a check that cannot run (no passwordless sudo to read iptables)
# When the main menu draws
# Then there is no warning, because nothing is shown to be broken
WARN_OUT=""
SUDO_OK=0
launcher_admin_filter_warning
assert_eq "" "$WARN_OUT" "status line: no warning when the check is skipped"
SUDO_OK=1
UFW_ENABLED=true
rm -rf "$AF_DIR"
unset MEDIASTACK_ADMIN_FILTER_DROPIN MEDIASTACK_ADMIN_FILTER_UNIT

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

# --- containers: every service listed, dead ones fail -----------------------
# Given: three compose services, one exited (128), one unhealthy, one running
# When: the container check runs
# Then: each is listed; the exited and unhealthy ones are failures with their state
profiles_build_args() {
    local -n _o=$1
    _o=()
}
docker() {
    case "$*" in
        *"config --services"*) printf 'jellyfin\nsonarr\nradarr\nbazarr\n' ;;
        *"ps -a"*) printf 'jellyfin|exited|\|Exited (128) 3 minutes ago\nsonarr|running|unhealthy|Up 2 hours (unhealthy)\nradarr|running|healthy|Up 2 hours (healthy)\n' ;;
    esac
}
cont=$(health_containers)
assert_contains "$cont" "fail|jellyfin: Exited (128) 3 minutes ago" "containers: exited container is a failure with its state"
assert_contains "$cont" "fail|sonarr: Up 2 hours (unhealthy) (unhealthy)" "containers: unhealthy container is a failure"
assert_contains "$cont" "ok|radarr: Up 2 hours (healthy)" "containers: healthy container is ok"
assert_contains "$cont" "warn|bazarr: no container" "containers: a service with no container is still listed"
_LOG_COUNTS_ERROR=0
while IFS= read -r l; do
    log_error() { _LOG_COUNTS_ERROR=$((_LOG_COUNTS_ERROR + 1)); }
    health_present "$l"
done <<<"$cont"
assert_eq "2" "$_LOG_COUNTS_ERROR" "containers: the summary counts both failures"

# --- containers: a deliberate stop warns, it does not fail -------------------
# Given: one service stopped cleanly (Exited 0) and one stopped by SIGTERM (Exited 143)
# When: the container check runs
# Then: both are warnings that say the service is stopped, not failures
docker() {
    case "$*" in
        *"config --services"*) printf 'lidarr\nprowlarr\n' ;;
        *"ps -a"*) printf 'lidarr|exited||Exited (0) 5 minutes ago\nprowlarr|exited||Exited (143) 1 minute ago\n' ;;
    esac
}
cont=$(health_containers)
assert_contains "$cont" "warn|lidarr: stopped (Exited (0) 5 minutes ago)" "containers: a clean stop is a warning"
assert_contains "$cont" "warn|prowlarr: stopped (Exited (143) 1 minute ago)" "containers: a SIGTERM stop is a warning"
assert_not_contains "$cont" "fail|" "containers: a deliberate stop is not a failure"
unset -f docker profiles_build_args

# --- GPU: configured NVIDIA with a dead driver warns ------------------------
# Given: JELLYFIN_GPU=nvidia and nvidia-smi exits non-zero
# When: the GPU health line runs
# Then: it warns that the driver is not loaded, not "no software fallback recorded"
nvidia-smi() {
    echo "NVIDIA-SMI has failed"
    return 9
}
gpu_out=$(JELLYFIN_GPU=nvidia STAGE_3_GPU_STATE=complete gpu_fallback_health)
assert_eq "warn|NVIDIA driver not loaded — repair from Manage hardware transcoding" "$gpu_out" "gpu health: dead NVIDIA driver warns"
# And: with a working driver the line is not that warning
nvidia-smi() { echo "550.163.01"; }
gpu_ok=$(JELLYFIN_GPU=nvidia STAGE_3_GPU_STATE=complete gpu_fallback_health)
assert_not_contains "$gpu_ok" "driver not loaded" "gpu health: working driver does not warn"
unset -f nvidia-smi

scenario_end "$CURRENT_SCENARIO"
summary
