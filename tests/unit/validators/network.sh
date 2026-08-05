# Owns: Port and single-IP validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/network.sh.

# ---------------------------------------------------------------------------
# Port validators
# ---------------------------------------------------------------------------
reset_warn
ss() { printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'; }
validate_torrent_port "6881"
rc=$?
assert_eq "0" "$rc" "validate_torrent_port: accepts default port"
unset -f ss

reset_warn
validate_torrent_port "notaport"
rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects non-numeric"

reset_warn
validate_torrent_port "70000"
rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects out-of-range"

reset_warn
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    printf 'LISTEN 0      128          0.0.0.0:6881      0.0.0.0:*    users:(("qbittorrent",pid=1234,fd=5))\n'
}
validate_torrent_port "6881"
rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects local collision"
assert_contains "$LAST_WARN" "qbittorrent" "validate_torrent_port: collision names process"
unset -f ss

reset_warn
# Non-smbd listener (e.g. a custom user-installed SMB server) → real conflict.
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    printf 'LISTEN 0      128          0.0.0.0:445       0.0.0.0:*    users:(("custom-smb",pid=222,fd=9))\n'
}
validate_smb_port 445
rc=$?
assert_eq "1" "$rc" "validate_smb_port: rejects occupied port 445 (non-smbd listener)"
assert_contains "$LAST_WARN" "custom-smb" "validate_smb_port: collision names non-smbd process"
unset -f ss

# smbd listener IS MediaStack's SMB share — not a conflict, must pass.
# This makes wizard re-runs idempotent after SMB has been enabled once.
reset_warn
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    printf 'LISTEN 0      128          0.0.0.0:445       0.0.0.0:*    users:(("smbd",pid=222,fd=9))\n'
}
validate_smb_port 445
rc=$?
assert_eq "0" "$rc" "validate_smb_port: accepts smbd on 445 (MediaStack-managed SMB)"
unset -f ss

reset_warn
ss() { printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'; }
validate_smb_port 445
rc=$?
assert_eq "0" "$rc" "validate_smb_port: accepts free port 445"
unset -f ss


# ---------------------------------------------------------------------------
# Single-IP validator (fail2ban whitelist manual-entry path). Accepts one
# IPv4/IPv6 host; rejects CIDR / range / hostname / empty.
# ---------------------------------------------------------------------------
for ok in "203.0.113.45" "::1" "2001:db8::1"; do
    reset_warn
    validate_ip "$ok"
    rc=$?
    assert_eq "0" "$rc" "validate_ip: accepts '$ok'"
    assert_eq "0" "$WARN_COUNT" "validate_ip: '$ok' emits no warn"
done

for bad in "1.2.3.4/32" "999.1.1.1" "nope" ""; do
    reset_warn
    validate_ip "$bad"
    rc=$?
    assert_eq "1" "$rc" "validate_ip: rejects '$bad'"
    assert_eq "1" "$WARN_COUNT" "validate_ip: '$bad' warns once"
done

