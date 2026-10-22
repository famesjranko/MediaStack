# Owns: setup_* uninstall_* — kernel sysctl hardening configuration and owned-value teardown.
# Sources: hardening.sh ledger paths and common.sh state/hash helpers.
# Globals: MEDIASTACK_SYSCTL_CONF, MEDIASTACK_UFW_SYSCTL_CONF.
# shellcheck source=../../lib/host-tools.sh
declare -F host_tool_path >/dev/null 2>&1 || source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/host-tools.sh"

# The exact file setup renders. Kept as a renderer so the teardown can
# recognise an unmodified MediaStack sysctl file by content when the
# ownership ledger is gone (see _uninstall_sysctl_by_content).
_setup_sysctl_conf_content() {
    cat <<'EOF'
# MediaStack — kernel hardening
# Does NOT touch ip_forward (Docker + WireGuard need it enabled)

# SYN flood protection
net.ipv4.tcp_syncookies = 1

# Disable ICMP redirects (MITM prevention)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Reverse path filtering (IP spoofing prevention)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore broadcast ICMP (smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Log impossible source addresses
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
EOF
}

# Where UFW keeps the sysctl values it re-applies on every reload. Overridable
# so tests never read the host's file.
MEDIASTACK_UFW_SYSCTL_CONF="${MEDIASTACK_UFW_SYSCTL_CONF:-/etc/ufw/sysctl.conf}"

# "key value" per line, read from the rendered file so the keys, the expected
# values and the file on disk cannot drift apart.
_setup_sysctl_owned_pairs() {
    _setup_sysctl_conf_content | sed -n 's/^\(net\.[a-z0-9_.]*\) *= *\(.*\)$/\1 \2/p'
}

# Owned keys that UFW's sysctl.conf sets to a different value, as "key ufw-value".
# UFW applies that file on each reload, so it silently wins over our drop-in.
# UFW writes keys with slashes (net/ipv4/...); the kernel and our file use dots.
_setup_sysctl_ufw_overrides() {
    [[ -r "$MEDIASTACK_UFW_SYSCTL_CONF" ]] || return 0
    awk '
        FNR == NR {
            sub(/#.*/, "")
            if (split($0, kv, "=") >= 2) {
                k = kv[1]; v = kv[2]
                gsub(/[[:space:]]/, "", k); gsub(/[[:space:]]/, "", v); gsub("/", ".", k)
                if (k != "") ufw[k] = v
            }
            next
        }
        ($1 in ufw) && ufw[$1] != $2 { print $1, ufw[$1] }
    ' "$MEDIASTACK_UFW_SYSCTL_CONF" <(_setup_sysctl_owned_pairs)
}

# Warn about each owned key UFW overrides.
_setup_sysctl_warn_ufw_overrides() {
    local key ufw_val
    while read -r key ufw_val; do
        [[ -n "$key" ]] || continue
        log_warn "UFW owns $key: $MEDIASTACK_UFW_SYSCTL_CONF sets it to $ufw_val and UFW re-applies that on every reload, so MediaStack's value does not hold while UFW is active. Edit that file to change it."
    done < <(_setup_sysctl_ufw_overrides)
}

# Forwarding keys MediaStack never writes but Docker needs; read on the same
# path the drop-in is applied so any change is attributable to this apply.
_SYSCTL_GUARDED_KEYS=(net.ipv4.ip_forward net.ipv6.conf.all.forwarding)

# Applies ONLY the MediaStack drop-in. `sysctl --system` would re-read every
# /etc/sysctl.d file and, on images that ship forwarding=0 there (GCE Debian),
# switch off the forwarding Docker enabled at runtime and cut container
# internet. After the apply, every owned key must read back its value and the
# guarded forwarding keys must be unchanged; anything else is a loud failure.
# $1 — the sysctl binary path.
_setup_sysctl_apply_own_file() {
    local bin="$1" conf="$MEDIASTACK_SYSCTL_CONF" key want got guard
    local -A guard_before=()

    if host_tool_installed docker; then
        for guard in "${_SYSCTL_GUARDED_KEYS[@]}"; do
            guard_before[$guard]=$("$bin" -n "$guard" 2>/dev/null || true)
        done
    fi

    if ! sudo "$bin" -p "$conf" >/dev/null; then
        log_error "sysctl could not apply $conf"
        return 1
    fi

    local failed=0
    while read -r key want; do
        got=$("$bin" -n "$key" 2>/dev/null || true)
        if [[ "$got" != "$want" ]]; then
            log_error "sysctl $key is '$got' after applying $conf; expected '$want'"
            failed=1
        fi
    done < <(_setup_sysctl_owned_pairs)

    for guard in "${!guard_before[@]}"; do
        got=$("$bin" -n "$guard" 2>/dev/null || true)
        if [[ "$got" != "${guard_before[$guard]}" ]]; then
            log_error "sysctl $guard changed from '${guard_before[$guard]}' to '$got' while applying hardening; Docker networking may be broken"
            failed=1
        fi
    done
    return "$failed"
}

# Owned keys whose live value differs from the file, for the already-applied path.
_setup_sysctl_drifted_keys() {
    local bin="$1" key want got
    while read -r key want; do
        got=$("$bin" -n "$key" 2>/dev/null || true)
        [[ "$got" == "$want" ]] || printf '%s=%s (want %s)\n' "$key" "$got" "$want"
    done < <(_setup_sysctl_owned_pairs)
}

setup_sysctl_hardening() {
    local conf="$MEDIASTACK_SYSCTL_CONF" bin
    # Read-only checks below need no root, but sysctl lives in /usr/sbin.
    if ! bin=$(host_tool_path sysctl); then
        log_error "sysctl is not installed; kernel hardening was not applied"
        return 1
    fi

    if [[ -f "$conf" ]]; then
        if [[ "$(_ms_state_get SYSCTL_FILE_CREATED 2>/dev/null || true)" == "true" ]] \
            && [[ "$(_ms_root_sha256 "$conf")" == "$(_ms_state_get SYSCTL_FILE_SHA256 2>/dev/null || true)" ]]; then
            log_skip "Sysctl hardening already applied"
            # Warn on drift, never reconcile: another sysctl.d file or UFW may have won since.
            local drift
            drift=$(_setup_sysctl_drifted_keys "$bin")
            if [[ -n "$drift" ]]; then
                log_warn "Live kernel values differ from $conf: $(tr '\n' ' ' <<<"$drift")"
                _setup_sysctl_warn_ufw_overrides
            fi
        else
            log_warn "Existing $conf is not owned by MediaStack; leaving it unchanged"
        fi
        return
    fi

    log_info "Applying kernel hardening (sysctl)..."

    local key want state_key
    while read -r key want; do
        state_key="SYSCTL_BEFORE_${key^^}"
        state_key="${state_key//./_}"
        _ms_state_set "$state_key" "$("$bin" -n "$key")"
    done < <(_setup_sysctl_owned_pairs)

    _ms_state_set SYSCTL_FILE_CREATED true
    _setup_sysctl_conf_content | sudo tee "$conf" >/dev/null

    _ms_state_set SYSCTL_FILE_SHA256 "$(_ms_root_sha256 "$conf")"
    _setup_sysctl_apply_own_file "$bin" || {
        log_error "Kernel hardening was NOT applied cleanly; $conf stays so uninstall can remove it"
        return 1
    }
    _setup_sysctl_warn_ufw_overrides

    log_ok "Kernel hardening applied"
}

# Ledger-less teardown: the recorded pre-install values are gone, so the only
# safe claim of ownership left is that the file on disk is byte-for-byte the one
# setup renders. Removing it is then unambiguous — but it reverts the kernel at
# the next boot rather than restoring the recorded values now, and the caller is
# told so. Anything that does not match is preserved and reported.
_uninstall_sysctl_by_content() {
    local conf="$MEDIASTACK_SYSCTL_CONF"
    sudo test -e "$conf" || return 0
    if [[ "$(_ms_root_sha256 "$conf")" != "$(_setup_sysctl_conf_content | _ms_stream_sha256)" ]]; then
        log_error "Sysctl file preserved: $conf (edited, or not recognisable as MediaStack's without the ownership ledger); delete it by hand if you did not edit it."
        return 1
    fi
    sudo rm -f "$conf" || return 1
    log_warn "Removed $conf by content match; the pre-install kernel values are not recorded, so the live settings revert at the next boot."
    return 0
}

# $1 — "true" when the ownership ledger is unusable and the content fallback
# above is the only thing left to try. Defaults to the recorded teardown.
_uninstall_sysctl() {
    local unledgered="${1:-false}"
    local conf="$MEDIASTACK_SYSCTL_CONF"
    if [[ "$(_ms_state_get SYSCTL_FILE_CREATED)" != "true" ]]; then
        [[ "$unledgered" == "true" ]] || return 0
        _uninstall_sysctl_by_content
        return
    fi
    sudo test -e "$conf" || return 0
    if [[ "$(_ms_root_sha256 "$conf")" != "$(_ms_state_get SYSCTL_FILE_SHA256)" ]]; then
        log_error "Edited MediaStack sysctl file preserved: $conf"
        return 1
    fi

    local bin key applied state_key current before ufw_note
    # Reading needs no root, but sysctl lives in /usr/sbin, off a user PATH.
    bin=$(host_tool_path sysctl) || {
        log_error "sysctl is not installed; cannot restore the recorded kernel values"
        return 1
    }
    while read -r key applied; do
        state_key="SYSCTL_BEFORE_${key^^}"
        state_key="${state_key//./_}"
        before=$(_ms_state_get "$state_key" 2>/dev/null || true)
        current=$("$bin" -n "$key" 2>/dev/null)
        if [[ "$current" == "$applied" ]]; then
            if [[ -n "$before" ]]; then
                sudo "$bin" -w "$key=$before" >/dev/null || return 1
            fi
            # Empty before = key was at kernel default; conf removal below reverts on reboot
        else
            ufw_note=""
            [[ -n "$(_setup_sysctl_ufw_overrides | awk -v k="$key" '$1 == k')" ]] \
                && ufw_note=" (UFW owns this key: $MEDIASTACK_UFW_SYSCTL_CONF overrides it on every UFW reload)"
            log_warn "sysctl $key changed after install; preserving '$current'$ufw_note"
        fi
    done < <(_setup_sysctl_owned_pairs)
    sudo rm -f "$conf" || return 1
    log_ok "MediaStack kernel hardening removed"
}
