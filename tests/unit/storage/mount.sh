# Owns: storage_mount_nfs mismatched-mount repair and storage_probe_nas/
# storage_probe_opts non-destructive NAS verification. Sourced by
# tests/unit/storage.sh; inherits its preamble.

DATA_DIR="$TMP_DIR/mount-repair"
# shellcheck disable=SC2034 # consumed by storage_mode in storage/core.sh, sourced below
STORAGE_MODE=nas
# shellcheck disable=SC2034 # consumed by storage_mountpoint in storage/core.sh, sourced below
STORAGE_MOUNTPOINT="$DATA_DIR"
STORAGE_NFS_HOST=192.0.2.10
STORAGE_NFS_EXPORT=/exports/media
STORAGE_NFS_OPTS=vers=4.2
# shellcheck disable=SC2034 # consumed by storage_expected_source in storage/core.sh, sourced below
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/media"
# shellcheck disable=SC2034 # consumed by storage_expected_fstype in storage/core.sh, sourced below
STORAGE_EXPECTED_FSTYPE=nfs4
# shellcheck disable=SC2034 # consumed by storage_sentinel_path in storage/core.sh, sourced below
STORAGE_SENTINEL="$DATA_DIR/.mediastack-storage-ready"
mkdir -p "$DATA_DIR"
MOUNT_REPAIR_CALLS="$TMP_DIR/mount-repair-calls"
MOUNT_REPAIR_CONFIRM_PROMPTS=0
MOUNT_REPAIR_SOURCE="192.0.2.99:/exports/old"
MOUNT_REPAIR_FSTYPE=nfs4
findmnt() {
    case "$*" in
        *"-o SOURCE"*) [[ -n "$MOUNT_REPAIR_SOURCE" ]] && printf '%s\n' "$MOUNT_REPAIR_SOURCE" ;;
        *"-o FSTYPE"*) [[ -n "$MOUNT_REPAIR_FSTYPE" ]] && printf '%s\n' "$MOUNT_REPAIR_FSTYPE" ;;
        *) [[ -n "$MOUNT_REPAIR_SOURCE" ]] ;;
    esac
}
sudo() {
    printf '%s\n' "sudo $*" >>"$MOUNT_REPAIR_CALLS"
    case "${1:-}" in
        umount)
            MOUNT_REPAIR_SOURCE=""
            MOUNT_REPAIR_FSTYPE=""
            return 0
            ;;
        mkdir)
            command mkdir "$2" "$3"
            ;;
        mount)
            MOUNT_REPAIR_SOURCE="$6"
            MOUNT_REPAIR_FSTYPE="$3"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}
ui_confirm() {
    MOUNT_REPAIR_CONFIRM_PROMPTS=$((MOUNT_REPAIR_CONFIRM_PROMPTS + 1))
    return 0
}
log_warn() { :; }
log_info() { :; }
log_ok() { :; }
log_error() { :; }
if storage_mount_nfs; then
    pass "storage_mount_nfs: repairs mismatched live mount"
else
    fail "storage_mount_nfs: repairs mismatched live mount"
fi
assert_eq "192.0.2.10:/exports/media" "$MOUNT_REPAIR_SOURCE" "storage_mount_nfs: selected NAS source mounted after repair"
assert_eq "1" "$MOUNT_REPAIR_CONFIRM_PROMPTS" "storage_mount_nfs: asks before detaching mismatched mount when UI is available"
case "$(cat "$MOUNT_REPAIR_CALLS")" in
    *"sudo umount -l $DATA_DIR"*"sudo mount -t nfs4"*)
        pass "storage_mount_nfs: detaches mismatched mount before mounting NAS"
        ;;
    *)
        fail "storage_mount_nfs: detaches mismatched mount before mounting NAS" "$(cat "$MOUNT_REPAIR_CALLS")"
        ;;
esac

: >"$MOUNT_REPAIR_CALLS"
MOUNT_REPAIR_CONFIRM_PROMPTS=0
MOUNT_REPAIR_SOURCE="192.0.2.99:/exports/old"
MOUNT_REPAIR_FSTYPE=nfs4
ui_confirm() {
    MOUNT_REPAIR_CONFIRM_PROMPTS=$((MOUNT_REPAIR_CONFIRM_PROMPTS + 1))
    return 1
}
if storage_mount_nfs; then
    fail "storage_mount_nfs: declined mismatched mount repair aborts"
else
    pass "storage_mount_nfs: declined mismatched mount repair aborts"
fi
case "$(cat "$MOUNT_REPAIR_CALLS")" in
    *"sudo umount"* | *"sudo mount"*)
        fail "storage_mount_nfs: declined repair leaves existing mount untouched" "$(cat "$MOUNT_REPAIR_CALLS")"
        ;;
    *)
        pass "storage_mount_nfs: declined repair leaves existing mount untouched"
        ;;
esac
assert_eq "1" "$MOUNT_REPAIR_CONFIRM_PROMPTS" "storage_mount_nfs: declined repair still prompted once"
unset -f findmnt sudo ui_confirm log_warn log_info log_ok log_error
unset DATA_DIR STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT STORAGE_NFS_OPTS STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE STORAGE_SENTINEL
unset MOUNT_REPAIR_CALLS MOUNT_REPAIR_CONFIRM_PROMPTS MOUNT_REPAIR_SOURCE MOUNT_REPAIR_FSTYPE

# --- storage_probe_nas: non-destructive verification (never mounts the real
#     mountpoint; temp-mounts, checks, classifies, unmounts) ---
ui_spin() {
    shift
    "$@"
} # run the wrapped command, drop the label
log_ok() { :; }
log_info() { :; }
log_error() { :; }
log_warn() { :; }
# shellcheck disable=SC2034 # consumed by storage_probe_nas in storage/mount.sh, sourced below
STORAGE_NFS_HOST=192.0.2.10
# shellcheck disable=SC2034 # consumed by storage_probe_nas in storage/mount.sh, sourced below
STORAGE_NFS_EXPORT=/exports/mediastack
STORAGE_NFS_OPTS="vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"
PROBE_NC_RC=0 PROBE_MOUNT_RC=0
nc() { return "$PROBE_NC_RC"; }
sudo() { case "$1" in mount) return "$PROBE_MOUNT_RC" ;; *) return 0 ;; esac }

# probe_opts must fail-fast: no hard, forced soft + short timeo/retrans.
probe_opts_out="$(storage_probe_opts "$STORAGE_NFS_OPTS")"
case "$probe_opts_out" in
    *hard*) fail "storage_probe_opts: strips hard from probe options" "$probe_opts_out" ;;
    *soft,timeo=50,retrans=2) pass "storage_probe_opts: forces fail-fast soft mount" ;;
    *) fail "storage_probe_opts: forces fail-fast soft mount" "$probe_opts_out" ;;
esac

PROBE_NC_RC=0 PROBE_MOUNT_RC=0
if storage_probe_nas && [[ "$_STORAGE_PROBE_CLASS" == "empty" ]]; then
    pass "storage_probe_nas: all checks green returns 0 and classifies the share"
else
    fail "storage_probe_nas: all checks green returns 0 and classifies the share"
fi

PROBE_NC_RC=1 PROBE_MOUNT_RC=0
if storage_probe_nas; then
    fail "storage_probe_nas: unreachable NAS fails the probe"
else
    pass "storage_probe_nas: unreachable NAS fails the probe"
fi

PROBE_NC_RC=0 PROBE_MOUNT_RC=1
if storage_probe_nas; then
    fail "storage_probe_nas: unmountable export fails the probe"
else
    pass "storage_probe_nas: unmountable export fails the probe"
fi

unset -f ui_spin nc sudo log_ok log_info log_error log_warn
unset STORAGE_NFS_HOST STORAGE_NFS_EXPORT STORAGE_NFS_OPTS PROBE_NC_RC PROBE_MOUNT_RC _STORAGE_PROBE_CLASS
