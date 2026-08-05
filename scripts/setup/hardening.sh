# Owns: hardening entry wiring, shared host paths/state helpers, and orchestration.
# Sources: common.sh plus scripts/setup/hardening/* concern modules.

# =============================================================================
# MediaStack Setup — OS hardening and optional SMB file share
# =============================================================================
# Sourced by setup.sh. Depends on $SCRIPT_DIR and scripts/lib/common.sh
# being loaded by the caller.
#
# setup_hardening() — UFW, unattended-upgrades, sysctl, GPU runtime check.
#                     No wizard dependencies; runs before the wizard.
# setup_samba()     — Optional SMB share. Needs credentials + DATA_DIR from
#                     .env; runs after the wizard.

# uninstall_system_cleanup dispatches host-artefact teardown to the owning
# modules (nvidia_driver_gpu_uninstall, storage_uninstall_watchdog, f2b_uninstall_reload_watcher);
# source them from a BASH_SOURCE-resolved path so the calls resolve without
# relying on setup.sh's source order. All are side-effect-free
# and re-source-safe.
_HARDENING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=gpu.sh
source "$_HARDENING_LIB_DIR/gpu.sh"
# shellcheck source=storage.sh
source "$_HARDENING_LIB_DIR/storage.sh"
# shellcheck source=fail2ban.sh
source "$_HARDENING_LIB_DIR/fail2ban.sh"
unset _HARDENING_LIB_DIR

MEDIASTACK_STATE_DIR=/etc/mediastack
MEDIASTACK_STATE_FILE="$MEDIASTACK_STATE_DIR/install-state"
# shellcheck disable=SC2034
MEDIASTACK_APT_AUTO_CONF=/etc/apt/apt.conf.d/21mediastack-auto-upgrades
# shellcheck disable=SC2034
MEDIASTACK_APT_POLICY_CONF=/etc/apt/apt.conf.d/51mediastack-unattended-upgrades
# shellcheck disable=SC2034
MEDIASTACK_SYSCTL_CONF=/etc/sysctl.d/90-mediastack-hardening.conf
# shellcheck disable=SC2034
MEDIASTACK_UFW_AFTER_RULES=/etc/ufw/after.rules
# shellcheck disable=SC2034
MEDIASTACK_UFW_AFTER_INIT=/etc/ufw/after.init

# RFC1918 private ranges — the LAN scope for ufw "allow from <cidr>" rules.
# The iptables after.rules heredoc keeps its own literals (interpolating an
# array into that generated block is net-positive LoC).
# shellcheck disable=SC2034
LAN_CIDRS=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16)

_ms_state_get() {
    local key="$1"
    sudo awk -F= -v key="$key" '$1 == key {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' \
        "$MEDIASTACK_STATE_FILE" 2>/dev/null
}

_ms_state_set() {
    local key="$1" value="$2" tmp
    [[ "$key" =~ ^[A-Z0-9_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    tmp=$(mktemp)
    if sudo test -f "$MEDIASTACK_STATE_FILE"; then
        # shellcheck disable=SC2024 # output intentionally goes to the user-owned temp file
        sudo awk -F= -v key="$key" '$1 != key' "$MEDIASTACK_STATE_FILE" >"$tmp" || {
            rm -f "$tmp"
            return 1
        }
    fi
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
    sudo install -d -m 0755 "$MEDIASTACK_STATE_DIR" \
        && sudo install -m 0600 "$tmp" "$MEDIASTACK_STATE_FILE"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

_ms_root_sha256() {
    sudo sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

_ms_stream_sha256() {
    sha256sum | awk '{print $1}'
}

_ufw_rule_hash() {
    LC_ALL=C sudo ufw show added 2>/dev/null | sed -n '/^ufw /p' | _ms_stream_sha256
}

_ufw_defaults() {
    LC_ALL=C sudo ufw status verbose 2>/dev/null \
        | sed -n 's/^Default: \([^ ]*\) (incoming), \([^ ]*\) (outgoing).*/\1 \2/p' \
        | head -1
}

# Source concern modules in the same setup.sh load event as the former inline
# definitions. They define functions only; all source-time state stays here.
_HARDENING_CONCERNS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/hardening" && pwd)"
# shellcheck source=hardening/ssh.sh
source "$_HARDENING_CONCERNS_DIR/ssh.sh"
# shellcheck source=hardening/firewall.sh
source "$_HARDENING_CONCERNS_DIR/firewall.sh"
# shellcheck source=hardening/updates.sh
source "$_HARDENING_CONCERNS_DIR/updates.sh"
# shellcheck source=hardening/sysctl.sh
source "$_HARDENING_CONCERNS_DIR/sysctl.sh"
# shellcheck source=hardening/gpu-runtime.sh
source "$_HARDENING_CONCERNS_DIR/gpu-runtime.sh"
# shellcheck source=hardening/ports.sh
source "$_HARDENING_CONCERNS_DIR/ports.sh"
# shellcheck source=hardening/samba.sh
source "$_HARDENING_CONCERNS_DIR/samba.sh"
unset _HARDENING_CONCERNS_DIR

# MediaStack writes its [Media] share to a dedicated include file rather than
# overwriting /etc/samba/smb.conf. The previous behavior `sudo tee smb.conf`
# (no -a) destroyed any pre-existing user samba config on the very first
# SMB_ENABLED=true install, and left orphaned MediaStack stanzas in the file
# on reinstall with SMB_ENABLED=false. The include-file layout:
#   • cleanup is just `rm` — no sed surgery on a shared host file
#   • the user's main smb.conf [global] is preserved (we don't define [global])
#   • the include = line in main smb.conf is left in place after cleanup;
#     samba logs a config-load warning if the file is missing but does not
#     abort — and a subsequent SMB_ENABLED=true install reuses the same path
# shellcheck disable=SC2034
SAMBA_INCLUDE_FILE="/etc/samba/smb.conf.d/mediastack.conf"
# shellcheck disable=SC2034
SAMBA_MAIN_CONF="/etc/samba/smb.conf"
# Idempotency keys off the functional `include = <path>` line — a filesystem
# path that is byte-stable and never reformatted — NOT a decorative comment
# marker, whose punctuation is a fragile grep target (an em-dash in the old
# marker silently broke detection when it was "tidied"). The include line is
# derived inline from SAMBA_INCLUDE_FILE at the point of use (so it tracks the
# current path); the comment below is written for humans only and is never matched.
# shellcheck disable=SC2034
SAMBA_INCLUDE_MARKER="# MEDIASTACK include - managed by setup.sh"

record_pre_install_state() {
    sudo test -f "$MEDIASTACK_STATE_FILE" && return 0
    if [[ "${STAGE_1_COMPLETE:-}" == "1" ]]; then
        log_error "Completed install has no ownership ledger; refusing to record already-modified host state"
        return 1
    fi

    local defaults="deny allow" incoming outgoing rules_hash tmp
    rules_hash=$(printf '' | _ms_stream_sha256)
    if command -v ufw >/dev/null 2>&1 || [[ -x /usr/sbin/ufw ]]; then
        # Only read live state when UFW is active — inactive UFW has no Default line
        # in `ufw status verbose`, so _ufw_defaults returns empty. Keep the "deny allow"
        # sentinel (nothing to restore on uninstall) when UFW is inactive.
        if sudo ufw status 2>/dev/null | grep -q 'Status: active'; then
            defaults=$(_ufw_defaults)
            rules_hash=$(_ufw_rule_hash)
        fi
    fi
    read -r incoming outgoing <<<"$defaults"
    [[ -n "$incoming" && -n "$outgoing" && "$rules_hash" =~ ^[0-9a-f]{64}$ ]] \
        || {
            log_error "Could not read UFW pre-install state"
            return 1
        }

    tmp=$(mktemp)
    cat >"$tmp" <<EOF
STATE_FORMAT=1
UFW_RULES_BEFORE_SHA256=$rules_hash
UFW_DEFAULT_INCOMING=$incoming
UFW_DEFAULT_OUTGOING=$outgoing
UFW_DEFAULTS_APPLIED=false
UFW_ENABLED_BY_MEDIASTACK=false
UFW_RULE_COUNT=0
SYSCTL_FILE_CREATED=false
SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK=false
SAMBA_OWNERSHIP_RECORDED=false
SAMBA_CONFIGURED=false
SAMBA_SETUP_PENDING=false
EOF
    sudo install -d -m 0755 "$MEDIASTACK_STATE_DIR" \
        && sudo install -m 0600 "$tmp" "$MEDIASTACK_STATE_FILE"
    local rc=$?
    rm -f "$tmp"
    return "$rc"
}

validate_install_state() {
    sudo test -f "$MEDIASTACK_STATE_FILE" \
        && [[ "$(_ms_state_get STATE_FORMAT 2>/dev/null || true)" == "1" ]] \
        && [[ "$(_ms_state_get UFW_RULES_BEFORE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] \
        && [[ -n "$(_ms_state_get UFW_DEFAULT_INCOMING 2>/dev/null || true)" ]] \
        && [[ -n "$(_ms_state_get UFW_DEFAULT_OUTGOING 2>/dev/null || true)" ]] \
        || return 1

    local key value count i
    for key in UFW_DEFAULTS_APPLIED UFW_ENABLED_BY_MEDIASTACK SYSCTL_FILE_CREATED \
        SAMBA_PACKAGE_INSTALLED_BY_MEDIASTACK SAMBA_OWNERSHIP_RECORDED SAMBA_CONFIGURED; do
        [[ "$(_ms_state_get "$key" 2>/dev/null || true)" =~ ^(true|false)$ ]] || return 1
    done
    count=$(_ms_state_get UFW_RULE_COUNT 2>/dev/null || true)
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    for ((i = 1; i <= count; i++)); do
        [[ "$(_ms_state_get "UFW_RULE_$i" 2>/dev/null || true)" == allow\ *MediaStack:* ]] || return 1
    done
    if [[ "$(_ms_state_get SYSCTL_FILE_CREATED)" == "true" ]]; then
        [[ "$(_ms_state_get SYSCTL_FILE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
        for key in TCP_SYNCOOKIES CONF_ALL_ACCEPT_REDIRECTS CONF_DEFAULT_ACCEPT_REDIRECTS \
            CONF_ALL_SEND_REDIRECTS CONF_DEFAULT_SEND_REDIRECTS CONF_ALL_RP_FILTER \
            CONF_DEFAULT_RP_FILTER ICMP_ECHO_IGNORE_BROADCASTS CONF_ALL_LOG_MARTIANS \
            CONF_DEFAULT_LOG_MARTIANS; do
            _ms_state_get "SYSCTL_BEFORE_NET_IPV4_$key" >/dev/null 2>&1 || return 1
        done
    fi
    for key in APT_AUTO_SHA256 APT_POLICY_SHA256; do
        value=$(_ms_state_get "$key" 2>/dev/null || true)
        [[ -z "$value" || "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
    done
    if [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED)" == "true" ]]; then
        for key in SAMBA_SERVICE_WAS_ENABLED SAMBA_SERVICE_WAS_ACTIVE SAMBA_USER_PREEXISTED \
            SAMBA_PASSDB_PREEXISTED SAMBA_GROUP_PREEXISTED SAMBA_SETUP_PENDING \
            SAMBA_PASSDB_CREATED_BY_MEDIASTACK SAMBA_GROUP_ADDED_BY_MEDIASTACK; do
            [[ "$(_ms_state_get "$key" 2>/dev/null || true)" =~ ^(true|false)$ ]] || return 1
        done
        [[ -n "$(_ms_state_get SAMBA_USER 2>/dev/null || true)" ]] || return 1
    fi
    if [[ "$(_ms_state_get SAMBA_CONFIGURED)" == "true" ]]; then
        [[ "$(_ms_state_get SAMBA_OWNERSHIP_RECORDED 2>/dev/null || true)" == "true" ]] || return 1
        [[ "$(_ms_state_get SAMBA_INCLUDE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
        [[ "$(_ms_state_get SAMBA_EFFECTIVE_SHA256 2>/dev/null || true)" =~ ^[0-9a-f]{64}$ ]] || return 1
    fi
}

# ---------------------------------------------------------------------------
# Public orchestrator — called before the wizard
# ---------------------------------------------------------------------------

setup_hardening() {
    log_info "Applying OS hardening..."
    echo ""

    # Both are user choices (wizard prompts / day-2 toggles). Absent flag =>
    # true so existing installs stay hardened after upgrade. verify_gpu_runtime
    # is intentionally NOT here — it is a GPU check, not security hardening, and
    # is called on its own in setup.sh regardless of these toggles.
    if [[ "${UFW_ENABLED:-true}" == "true" ]]; then
        setup_ufw
    else
        log_skip "UFW firewall disabled by user choice"
    fi

    if [[ "${HARDENING_ENABLED:-true}" == "true" ]]; then
        setup_unattended_upgrades
        setup_sysctl_hardening
    else
        log_skip "System hardening (auto-updates + kernel sysctl) disabled by user choice"
    fi

    log_ok "OS hardening step complete"
}

uninstall_system_cleanup() {
    validate_install_state || {
        log_error "Missing or invalid MediaStack ownership ledger; refusing host cleanup"
        return 1
    }
    local failed=0
    _uninstall_ufw || {
        log_error "UFW cleanup failed"
        failed=1
    }
    _uninstall_apt || {
        log_error "APT cleanup failed"
        failed=1
    }
    _uninstall_sysctl || {
        log_error "sysctl cleanup failed"
        failed=1
    }
    _uninstall_samba || {
        log_error "Samba cleanup failed"
        failed=1
    }
    storage_uninstall_watchdog || {
        log_error "Storage watchdog cleanup failed"
        failed=1
    }
    f2b_uninstall_reload_watcher || {
        log_error "fail2ban reload watcher cleanup failed"
        failed=1
    }

    # mediastack-setup unit + setup-result banner are stage/hardening-owned.
    if sudo test -f /etc/systemd/system/mediastack-setup.service; then
        sudo systemctl stop mediastack-setup.service 2>/dev/null || failed=1
        sudo systemctl disable mediastack-setup.service 2>/dev/null || failed=1
        sudo rm -f /etc/systemd/system/mediastack-setup.service || failed=1
    fi
    sudo rm -f /etc/profile.d/mediastack-setup-result.sh || failed=1
    sudo systemctl daemon-reload 2>/dev/null || failed=1

    ((failed == 0)) || {
        log_error "Host cleanup incomplete; ownership ledger retained for retry"
        return 1
    }
    log_ok "MediaStack system artefacts removed"
}
