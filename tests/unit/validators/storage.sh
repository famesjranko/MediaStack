# Owns: Data dir and NAS storage validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/storage.sh.

# ---------------------------------------------------------------------------
# Data directory validator
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$TMP_DIR"
rc=$?
assert_eq "0" "$rc" "validate_data_dir: accepts writable path with free space"
unset -f findmnt df

reset_warn
validate_data_dir "/media/usb"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects /media path"
assert_eq "1" "$WARN_COUNT" "validate_data_dir: /media warns once"

# Defense in depth — characters that would either escape the
# quoted DATA_DIR line on .env source, run as code, or silently corrupt
# downstream parsers (awk -F=, df, [[ -d ]] equality).
reset_warn
validate_data_dir "/data'foo"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects single quote"

reset_warn
validate_data_dir "/data\$HOME"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects \$"

reset_warn
validate_data_dir '/data;rm -rf /tmp'
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects ;"

reset_warn
validate_data_dir '/data`whoami`'
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects backticks"

# Structural footguns
reset_warn
validate_data_dir "data"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects relative path"
assert_contains "$LAST_WARN" "absolute" "validate_data_dir: relative-path copy"

reset_warn
validate_data_dir "/data with space"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects whitespace"

reset_warn
validate_data_dir "/data=evil"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects = (breaks awk -F=)"

reset_warn
validate_data_dir "/data
newline"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects newline"

reset_warn
validate_data_dir "/data "
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects trailing whitespace"

reset_warn
UI_CONFIRM_RESPONSE="no"
validate_data_dir "$TMP_DIR/missing-denied"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: missing path respects refused mkdir"
assert_contains "$LAST_WARN" "not created" "validate_data_dir: refused mkdir copy"

reset_warn
UI_CONFIRM_RESPONSE="yes"
mkdir() { return 1; }
validate_data_dir "$TMP_DIR/missing-create-fails"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: mkdir failure rejects path"
unset -f mkdir

reset_warn
findmnt() { echo "rw,relatime,ro"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$TMP_DIR"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: rejects read-only mount"
unset -f findmnt df

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 180G 20G 90%% %s\n' "${@: -1}"; }
UI_CONFIRM_RESPONSE="no"
validate_data_dir "$TMP_DIR"
rc=$?
assert_eq "1" "$rc" "validate_data_dir: under-30GB free rejected when user declines to continue"
unset -f findmnt df

reset_warn
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 180G 20G 90%% %s\n' "${@: -1}"; }
# Consumed by ui_confirm() in the parent tests/unit/validators.sh.
# shellcheck disable=SC2034
UI_CONFIRM_RESPONSE="yes"
validate_data_dir "$TMP_DIR"
rc=$?
assert_eq "0" "$rc" "validate_data_dir: under-30GB free accepted when user confirms continue"
unset -f findmnt df

# ---------------------------------------------------------------------------
# NAS storage validators
# ---------------------------------------------------------------------------
reset_warn
validate_nfs_host "nas01.local"
rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts DNS name"

reset_warn
ROOT_OWNED_MOUNTPOINT="$TMP_DIR/root-owned-mountpoint"
mkdir -p "$ROOT_OWNED_MOUNTPOINT"
chmod 0555 "$ROOT_OWNED_MOUNTPOINT"
findmnt() { echo "rw,relatime"; }
df() { printf 'Filesystem 1G-blocks Used Avail Use%% Mounted\n/dev/sda1 200G 50G 150G 25%% %s\n' "${@: -1}"; }
validate_data_dir "$ROOT_OWNED_MOUNTPOINT"
data_dir_rc=$?
validate_nas_mountpoint "$ROOT_OWNED_MOUNTPOINT"
nas_mount_rc=$?
chmod 0755 "$ROOT_OWNED_MOUNTPOINT"
assert_eq "1" "$data_dir_rc" "validate_data_dir: rejects non-writable root-owned path"
assert_eq "0" "$nas_mount_rc" "validate_nas_mountpoint: accepts existing non-writable mountpoint before mount"
unset -f findmnt df

reset_warn
validate_nfs_host "192.168.1.20"
rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts IPv4"

reset_warn
validate_nfs_host "nas host"
rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects whitespace"

reset_warn
validate_nfs_host "999.999.999.999"
rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects IPv4 octet over 255"

reset_warn
validate_nfs_host "192.168.1"
rc=$?
assert_eq "1" "$rc" "validate_nfs_host: rejects incomplete IPv4"

reset_warn
validate_nfs_host "synology"
rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts single-label hostname"

reset_warn
validate_nfs_host "10.0.08.5"
rc=$?
assert_eq "0" "$rc" "validate_nfs_host: accepts leading-zero octet (base-10, not octal)"

reset_warn
validate_nfs_export "/exports/mediastack"
rc=$?
assert_eq "0" "$rc" "validate_nfs_export: accepts absolute export path"

reset_warn
validate_nfs_export "exports/mediastack"
rc=$?
assert_eq "1" "$rc" "validate_nfs_export: rejects relative export path"
assert_contains "$LAST_WARN" "absolute" "validate_nfs_export: relative-path copy"

reset_warn
validate_nfs_export "/exports/bad path"
rc=$?
assert_eq "1" "$rc" "validate_nfs_export: rejects whitespace"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"
rc=$?
assert_eq "0" "$rc" "validate_nfs_options: accepts default hard NFS options"

reset_warn
validate_nfs_options "vers=3,proto=tcp,rw,soft,timeo=10,retrans=1,nolock,nosuid,nodev,noexec"
rc=$?
assert_eq "0" "$rc" "validate_nfs_options: accepts NFSv3 test options"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw bad"
rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects whitespace"

reset_warn
validate_nfs_options "vers=4.2,proto=tcp,rw,'bad'"
rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects quotes"

reset_warn
validate_nfs_options "vers=4.2;rm"
rc=$?
assert_eq "1" "$rc" "validate_nfs_options: rejects shell separator"

reset_warn
validate_storage_sentinel "/data/.mediastack-storage-ready"
rc=$?
assert_eq "0" "$rc" "validate_storage_sentinel: accepts absolute sentinel path"

reset_warn
validate_storage_sentinel ".mediastack-storage-ready"
rc=$?
assert_eq "1" "$rc" "validate_storage_sentinel: rejects relative sentinel path"
assert_contains "$LAST_WARN" "absolute" "validate_storage_sentinel: relative-path copy"

reset_warn
validate_storage_sentinel "/data/bad sentinel"
rc=$?
assert_eq "1" "$rc" "validate_storage_sentinel: rejects whitespace"
