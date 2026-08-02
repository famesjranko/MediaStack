#!/usr/bin/env bash
# scripts/lib/health.sh — day-2 health checks (silent-failure detection).
#
# Each check surfaces a failure that Docker's per-service healthcheck and normal
# operation do NOT reveal (a fail2ban filter that stopped matching after an image
# bump, a cert quietly past renewal, DDNS drift, a full disk, UFW off, or Docker
# having flushed the port-restriction chain).
#
# Design: one classifier, many presenters (models stage2_dns_classify). Each
# health_<name> echoes ONE line "STATUS|message" (STATUS ∈ ok|warn|fail|skip),
# self-gates to "skip|..." when its profile/tooling/sudo is absent, and does NO
# presentation — callers (menu, update flow, tests) present via health_present.
#
# Consumers: mediastack (set -uo pipefail), scripts/update.sh (set -euo pipefail),
# and unit tests. It MUST stay set -e safe: every external call is guarded with
# `|| true` / `if ! cmd`, classifiers are captured with `local x=$(...) || true`,
# and pipefail-prone pipes are capture-then-grep. Sourcing has no side effects.

# Idempotent include guard.
[[ -n "${_MS_HEALTH_SH:-}" ]] && return 0
_MS_HEALTH_SH=1

_HEALTH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# health.sh lives at scripts/lib/ — repo root is two levels up.
_HEALTH_REPO_ROOT="$(cd "$_HEALTH_LIB_DIR/../.." && pwd)"

# Source our own lib deps: update.sh/tests source only common.sh, so a check
# calling stage2_dns_classify/net_detect_public_ip would otherwise be undefined.
# common.sh (log_*) is assumed already sourced by every consumer.
if ! declare -F stage2_dns_classify >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    source "$_HEALTH_LIB_DIR/network.sh"
fi

# =============================================================================
# internals
# =============================================================================

# fail2ban container present + running. Works in every consumer (no reliance on
# mediastack's _service_is_running). Capture-then-grep: piping docker into grep
# would SIGPIPE under pipefail.
_health_f2b_running() {
    local names
    names=$(docker ps --format '{{.Names}}' 2>/dev/null) || return 1
    grep -qx fail2ban <<<"$names"
}

# A named container is running AND (has no healthcheck OR is healthy). Guards the
# probe against a stopped or still-starting service: right after an update the
# container may be up but not ready, and probing it then would write no log line
# → 0 matched → a false "drift". Not-ready ⇒ the caller skips, never fails.
_health_svc_healthy() {
    local state health
    state=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "")
    [[ "$state" == "running" ]] || return 1
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null || echo "")
    [[ -z "$health" || "$health" == "healthy" ]]
}

# Passwordless sudo available? Checks that read root-owned state (cert / ufw /
# iptables) call this first and skip cleanly when it fails — the diag_readiness
# `sudo -n true` precedent (mediastack).
_health_sudo_ok() { sudo -n true 2>/dev/null; }

# Parse the "N matched" count out of fail2ban-regex output. THE shared core with
# tests/assertions/fail2ban.sh (keep the sed in exactly one place).
_fail2ban_matched_count() {
    local n
    n=$(sed -n 's/.*[[:space:]]\([0-9]*\) matched.*/\1/p' <<<"$1" | head -1)
    [[ -z "$n" ]] && n=0
    printf '%s' "$n"
}

# Run fail2ban-regex on a jail's (glob) logpath inside the container; echo the
# match count. The glob is expanded container-side (cat into one tmpfile) —
# fail2ban-regex takes a single LOG positional, so a host-side glob would
# mis-expand. Used repeatedly by the delta+poll in health_fail2ban_regex.
_health_f2b_regex_count() {
    local out
    out=$(docker exec fail2ban sh -c \
        "cat $1 > /tmp/f2b-health.log 2>/dev/null && fail2ban-regex /tmp/f2b-health.log $2 2>&1; rm -f /tmp/f2b-health.log" \
        2>/dev/null) || true
    _fail2ban_matched_count "$out"
}

# Active probe: one benign failed auth so the jail's log gains a current-format
# denial line to regex. Source is localhost → the gateway IP fail2ban records is
# inside ignoreip (all-RFC1918), so this never self-bans. JSON built with python3
# json.dumps per the repo invariant (safe escaping).
_health_f2b_probe() {
    case "$1" in
        jellyfin)
            local body
            body=$(JF_USER="${JELLYFIN_ADMIN_USER:-admin}" python3 -c \
                'import json,os; print(json.dumps({"Username": os.environ["JF_USER"], "Pw": "ms-healthcheck-wrong-pw"}))' 2>/dev/null) || return 0
            curl -s -o /dev/null -m 5 -X POST http://localhost:8096/Users/authenticatebyname \
                -H 'Content-Type: application/json' \
                -H 'Authorization: MediaBrowser Client="healthcheck", Device="healthcheck", DeviceId="ms-health", Version="1"' \
                -d "$body" 2>/dev/null || true
            ;;
        seerr)
            curl -s -o /dev/null -m 5 -X POST http://localhost:5055/api/v1/auth/local \
                -H 'Content-Type: application/json' \
                -d '{"email":"ms-healthcheck@example.invalid","password":"ms-healthcheck-wrong-pw"}' 2>/dev/null || true
            ;;
    esac
}

# =============================================================================
# checks — each echoes "STATUS|message"
# =============================================================================

# Prove a jail's filter still matches the current log format. svc ∈ jellyfin|seerr
# (npm's log format is nginx/MediaStack-controlled, covered by health_fail2ban_jails).
health_fail2ban_regex() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && {
        echo "skip|fail2ban regex: no service given"
        return 0
    }
    _health_f2b_running || {
        echo "skip|fail2ban ${svc}: fail2ban not running (LAN-only install)"
        return 0
    }
    _health_svc_healthy "$svc" || {
        echo "skip|fail2ban ${svc}: ${svc} not running/ready"
        return 0
    }

    local logpath filter
    case "$svc" in
        jellyfin)
            logpath='/var/log/jellyfin/log_*.log'
            filter='/data/filter.d/jellyfin.conf'
            ;;
        seerr)
            logpath='/var/log/seerr/*.log'
            filter='/data/filter.d/seerr.conf'
            ;;
        *)
            echo "skip|fail2ban ${svc}: no active-probe defined"
            return 0
            ;;
    esac

    # Delta + poll — NOT a fixed sleep, NOT a bare "matched≥1". Count matches
    # BEFORE the probe, fire one benign failure, then poll until the count
    # INCREASES, proving the fresh current-format line matched. Two flakes this
    # avoids: (1) historical old-format lines that the pre-drift filter still
    # matches would mask a real drift under a bare count — the delta isolates the
    # probe's own line; (2) Serilog buffers the write, so rather than guess a
    # flush delay we poll (catch it the moment it lands) and only fail on a real
    # timeout. Rare attacker traffic in the window can only make it pass sooner.
    local before after
    before=$(_health_f2b_regex_count "$logpath" "$filter")
    _health_f2b_probe "$svc"
    for _ in $(seq 1 15); do
        after=$(_health_f2b_regex_count "$logpath" "$filter")
        if [[ "$after" -gt "$before" ]]; then
            echo "ok|fail2ban ${svc} filter matches the current log format"
            return 0
        fi
        sleep 1
    done
    echo "fail|fail2ban ${svc} filter did NOT match a fresh ${svc} auth failure — log format changed, brute-force bans NOT firing"
    return 0
}

# The 3 default jails are loaded. Membership, not an exact count (npm-ratelimit
# can flip on → 4; a stripped service → fewer).
health_fail2ban_jails() {
    _health_f2b_running || {
        echo "skip|fail2ban jails: fail2ban not running (LAN-only install)"
        return 0
    }
    local status missing=() j
    status=$(docker exec fail2ban fail2ban-client status 2>/dev/null | tr -d '\r') || true
    for j in jellyfin npm seerr; do
        grep -qw "$j" <<<"$status" || missing+=("$j")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "ok|fail2ban jails loaded (jellyfin, npm, seerr)"
    else
        echo "fail|fail2ban jails missing: ${missing[*]}"
    fi
    return 0
}

# True (0) when a currently-active log file (written within findtime, non-empty)
# is NOT among the files the live jail has open — i.e. the jail is tailing a
# stale rotated file. False (1) = watching the active file, or no recent activity
# to miss. 2 = fail2ban-client did not respond (e.g. socket busy mid-reload) —
# the caller reports skip, not stale, so a transient never reads as a stuck jail.
# The size filter skips the empty placeholder touchfiles from setup.
# $3 = the jail's own logpath basename glob (e.g. log_*.log) so the scan matches
# exactly what the jail watches — a stray *.log the jail does not glob must not be
# read as "the active file".
_f2b_watch_stale() {
    local svc="$1" logdir="$2" pat="$3" raw files newest
    raw=$(docker exec fail2ban fail2ban-client status "$svc" 2>/dev/null) || return 2
    files=$(tr -d '\r' <<<"$raw" | sed -n 's/.*File list:[[:space:]]*//p' | head -1)
    # Newest non-empty file modified within findtime (1800s). busybox-safe
    # (crazymax/fail2ban is Alpine — no GNU `find -printf`); dir+glob via argv.
    newest=$(docker exec fail2ban sh -c '
        d="$1"; now=$(date +%s); best=""; best_t=0
        for f in "$d"/$2; do
            [ -s "$f" ] || continue
            t=$(stat -c %Y "$f" 2>/dev/null) || continue
            [ "$t" -gt "$best_t" ] && { best_t=$t; best=$f; }
        done
        [ -n "$best" ] && [ $((now - best_t)) -lt 1800 ] && printf "%s\n" "$best"
    ' _ "$logdir" "$pat" 2>/dev/null)
    [[ -z "$newest" ]] && return 1
    grep -qF "$newest" <<<"$files" && return 1
    return 0
}

# Prove the live jail is actually tailing the CURRENT dated log file, not a stale
# rotated one. Complements health_fail2ban_regex (which re-globs fresh, so it
# cannot see a jail stuck on yesterday's file after a daily rollover). The inotify
# reload watcher (mediastack-fail2ban-reload.service) keeps these aligned;
# this is the safety net for the watcher silently failing. svc = jellyfin (seerr's
# on-disk filename is not yet confirmed to land in a *.log the jail watches).
health_fail2ban_watching() {
    local svc="${1:-}"
    [[ -z "$svc" ]] && {
        echo "skip|fail2ban watching: no service given"
        return 0
    }
    _health_f2b_running || {
        echo "skip|fail2ban ${svc} watching: fail2ban not running (LAN-only install)"
        return 0
    }
    _health_svc_healthy "$svc" || {
        echo "skip|fail2ban ${svc} watching: ${svc} not running/ready"
        return 0
    }

    local logdir pat
    case "$svc" in
        jellyfin)
            logdir='/var/log/jellyfin'
            pat='log_*.log'
            ;;
        *)
            echo "skip|fail2ban ${svc} watching: no watch-probe defined"
            return 0
            ;;
    esac

    # A mismatch right at rollover is benign — the watcher reloads within its
    # settle window. Re-check once after a short grace and only fail on a
    # PERSISTENT mismatch (a genuinely stuck watcher). Grace overridable for tests.
    local rc=0
    _f2b_watch_stale "$svc" "$logdir" "$pat" || rc=$?
    [[ $rc -eq 1 ]] && {
        echo "ok|fail2ban ${svc} is watching the current log file"
        return 0
    }
    [[ $rc -eq 2 ]] && {
        echo "skip|fail2ban ${svc} watching: fail2ban-client not responding (likely mid-reload)"
        return 0
    }
    sleep "${F2B_HEALTH_SETTLE_GRACE:-20}"
    rc=0
    _f2b_watch_stale "$svc" "$logdir" "$pat" || rc=$?
    case $rc in
        0) echo "fail|fail2ban ${svc} jail is watching a STALE log file after rotation — brute-force bans NOT firing (reload watcher stuck?)" ;;
        2) echo "skip|fail2ban ${svc} watching: fail2ban-client not responding (likely mid-reload)" ;;
        *) echo "ok|fail2ban ${svc} log file re-followed after rotation" ;;
    esac
    return 0
}

# Days until the Let's Encrypt cert expires. Only certs bound to live proxy hosts
# (a stale/superseded npm-<N> dir would false-fail). Root-owned → sudo -n.
health_cert_expiry() {
    [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]] || {
        echo "skip|cert expiry: no domain configured"
        return 0
    }
    command -v openssl >/dev/null 2>&1 || {
        echo "skip|cert expiry: openssl not installed"
        return 0
    }
    _health_sudo_ok || {
        echo "skip|cert expiry: needs passwordless sudo to read certs"
        return 0
    }

    local confdir="$_HEALTH_REPO_ROOT/config/npm/data/nginx/proxy_host"
    local ledir="$_HEALTH_REPO_ROOT/config/npm/letsencrypt"
    # grep -r under sudo (root does the traversal): the proxy_host dir is
    # root-owned, so a user-side shell glob (`$confdir/*.conf`) can't expand it.
    # Keep the "live/" component — certs live at letsencrypt/live/npm-<N>/fullchain.pem.
    local bound
    bound=$(sudo -n grep -rho --include='*.conf' 'live/npm-[0-9][0-9]*' "$confdir" 2>/dev/null | sort -u) || true
    [[ -z "$bound" ]] && {
        echo "skip|cert expiry: no proxy hosts configured yet"
        return 0
    }

    local now min_days="" id
    now=$(date +%s)
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local end ee days
        end=$(sudo -n openssl x509 -enddate -noout -in "${ledir}/${id}/fullchain.pem" 2>/dev/null | cut -d= -f2) || true
        [[ -z "$end" ]] && continue
        ee=$(date -d "$end" +%s 2>/dev/null) || continue
        days=$(((ee - now) / 86400))
        { [[ -z "$min_days" ]] || [[ "$days" -lt "$min_days" ]]; } && min_days="$days"
    done <<<"$bound"

    [[ -z "$min_days" ]] && {
        echo "skip|cert expiry: no readable certs"
        return 0
    }
    # ponytail: 14d warn threshold; LE renews at 30d, so <14d means renewal has stalled.
    if [[ "$min_days" -lt 0 ]]; then
        echo "fail|TLS certificate EXPIRED (${min_days}d) — remote access is down"
    elif [[ "$min_days" -lt 14 ]]; then
        echo "warn|TLS certificate expires in ${min_days}d — auto-renewal may have stalled"
    else
        echo "ok|TLS certificate valid for ${min_days} more days"
    fi
    return 0
}

# Domain A-record vs the box's current public IP. DDNS drift silently breaks remote.
health_dns_drift() {
    [[ -n "${DOMAIN:-}" && "${DOMAIN:-}" != "example.com" ]] || {
        echo "skip|DNS drift: no domain configured"
        return 0
    }
    net_detect_public_ip 2>/dev/null || {
        echo "skip|DNS drift: could not detect public IP (offline?)"
        return 0
    }
    local pip="$_NET_PUBLIC_IP" result
    result=$(stage2_dns_classify "$DOMAIN" "$pip" 2>/dev/null) || true
    case "$result" in
        ok) echo "ok|DNS points at this box (${pip})" ;;
        mismatch:*) echo "fail|DNS drift: ${DOMAIN} resolves to ${result#mismatch:}, box is ${pip} — remote access broken (DDNS not updating?)" ;;
        no-a | apex-only) echo "warn|DNS: jellyfin/seerr A-records missing or incomplete for ${DOMAIN}" ;;
        cloudflare) echo "warn|DNS points at Cloudflare, not this box's IP (${pip}) — disable proxying" ;;
        *) echo "skip|DNS drift: could not classify (dig unavailable or network down)" ;;
    esac
    return 0
}

# Data volume filling up — the #1 silent media-server failure. timeout guards a
# dead NFS mount; df resolves the mount itself (no _resolve_data_partition walk).
health_disk_pct() {
    local dir="${DATA_DIR:-/data}" out pct
    out=$(timeout 5 df -P "$dir" 2>/dev/null) || {
        echo "skip|disk: ${dir} unreadable (mount unreachable?)"
        return 0
    }
    pct=$(awk 'NR==2{gsub(/%/,"",$5); print $5}' <<<"$out")
    [[ "$pct" =~ ^[0-9]+$ ]] || {
        echo "skip|disk: could not parse usage for ${dir}"
        return 0
    }
    # ponytail: 85% warn / 95% fail — calibration knobs.
    if [[ "$pct" -ge 95 ]]; then
        echo "fail|Disk ${dir} is ${pct}% full — downloads will start failing"
    elif [[ "$pct" -ge 85 ]]; then
        echo "warn|Disk ${dir} is ${pct}% full — running low"
    else
        echo "ok|Disk ${dir} is ${pct}% used"
    fi
    return 0
}

# Host firewall default-deny is actually on.
health_ufw_active() {
    _health_sudo_ok || {
        echo "skip|UFW: needs passwordless sudo to read status"
        return 0
    }
    # ufw lives in /usr/sbin (often not in a non-root PATH) — check via root's PATH.
    sudo -n sh -c 'command -v ufw' >/dev/null 2>&1 || {
        echo "skip|UFW: not installed"
        return 0
    }
    local status
    status=$(sudo -n ufw status 2>/dev/null) || true
    if grep -qi 'Status: active' <<<"$status"; then
        echo "ok|UFW firewall active (host default-deny)"
    else
        echo "fail|UFW firewall is INACTIVE — host default-deny is off"
    fi
    return 0
}

# The DOCKER-USER → MEDIASTACK-DOCKER-RESTRICT jump AND its DROP rules are what
# hide LAN-only admin ports. Docker flushes DOCKER-USER on daemon restart; a jump
# with an emptied chain still re-exposes everything, so check both.
health_docker_user_restrict() {
    _health_sudo_ok || {
        echo "skip|firewall chain: needs passwordless sudo to read iptables"
        return 0
    }
    if ! sudo -n iptables -C DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT 2>/dev/null; then
        echo "fail|LAN-only port protection MISSING from DOCKER-USER — admin ports exposed to the internet"
        return 0
    fi
    local rules ndrop
    rules=$(sudo -n iptables -S MEDIASTACK-DOCKER-RESTRICT 2>/dev/null) || true
    ndrop=$(grep -c 'multiport.*DROP' <<<"$rules") || true
    if [[ "${ndrop:-0}" -ge 1 ]]; then
        echo "ok|LAN-only port protection active (${ndrop} DROP rules in DOCKER-USER)"
    else
        echo "fail|Port-restriction chain is EMPTY (Docker flushed it) — LAN-only ports exposed"
    fi
    return 0
}

# =============================================================================
# presenter + aggregate
# =============================================================================

# Map a "STATUS|msg" verdict to the shared log_* vocabulary (bumps _LOG_COUNTS_*).
health_present() {
    local status="${1%%|*}" msg="${1#*|}"
    case "$status" in
        ok) log_ok "$msg" ;;
        warn) log_warn "$msg" ;;
        fail) log_error "$msg" ;;
        skip) log_skip "$msg" ;;
        *) log_info "$1" ;;
    esac
}

# Batch helper for the update paths: present the fail2ban regex verdict for each
# jellyfin/seerr in the arg list (their log format may have shifted with the new
# image). Silent no-op when fail2ban isn't running. No confirm — batch callers
# ("Update all", update.sh) already gathered consent upfront.
health_present_fail2ban_updates() {
    _health_f2b_running || return 0
    local svc
    for svc in "$@"; do
        case "$svc" in
            jellyfin | seerr) health_present "$(health_fail2ban_regex "$svc")" ;;
        esac
    done
}

# The ordered run-all checks, one per line: "label<TAB>function<TAB>arg" (arg may
# be empty). Single source of the set + order for the menu's per-check spinner
# runner (mediastack:_health_run_all_spin), so the set can't drift.
_health_each() {
    printf '%s\t%s\t%s\n' \
        "fail2ban jails" health_fail2ban_jails "" \
        "fail2ban jellyfin filter" health_fail2ban_regex jellyfin \
        "fail2ban seerr filter" health_fail2ban_regex seerr \
        "fail2ban jellyfin watch" health_fail2ban_watching jellyfin \
        "TLS certificate" health_cert_expiry "" \
        "DNS / public IP" health_dns_drift "" \
        "disk space" health_disk_pct "" \
        "UFW firewall" health_ufw_active "" \
        "Docker port lock" health_docker_user_restrict ""
}
