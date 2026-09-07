# Owns: watchdog host-artefact rendering (config/unit/sudoers/mount-helper
# content) and install/uninstall of the NAS storage watchdog. Sourced by
# scripts/setup/storage.sh; depends on storage/core.sh helpers and
# MEDIASTACK_STORAGE_* paths defined by the parent.

storage_shell_quote() {
    python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

storage_root_config_content() {
    local key value
    for key in \
        STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT \
        STORAGE_NFS_OPTS STORAGE_SENTINEL STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE; do
        value="${!key:-}"
        printf '%s=%s\n' "$key" "$(storage_shell_quote "$value")"
    done
}

storage_mount_helper_content() {
    cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/mediastack/storage.env"
[[ "${1:-}" == "repair" ]] || { echo "usage: $0 repair" >&2; exit 2; }
[[ -f "$CONFIG_FILE" ]] || { echo "missing $CONFIG_FILE" >&2; exit 1; }

set -a
# Root-owned, setup-generated config. Do not source the user-writable .env here.
source "$CONFIG_FILE"
set +a

[[ "${STORAGE_MODE:-local}" == "nas" ]] || exit 0

MOUNTPOINT="${STORAGE_MOUNTPOINT:-}"
HOST="${STORAGE_NFS_HOST:-}"
EXPORT_PATH="${STORAGE_NFS_EXPORT:-}"
# literal: emitted into a standalone script that can't see DEFAULT_NFS_OPTS
OPTS="${STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}"
EXPECTED_SOURCE="${STORAGE_EXPECTED_SOURCE:-${HOST}:${EXPORT_PATH}}"
EXPECTED_FSTYPE="${STORAGE_EXPECTED_FSTYPE:-nfs4}"
SENTINEL="${STORAGE_SENTINEL:-${MOUNTPOINT}/.mediastack-storage-ready}"

[[ -n "$MOUNTPOINT" && -n "$HOST" && -n "$EXPORT_PATH" ]] || exit 1

path_under_mountpoint() {
    python3 - "$1" "$2" <<'PY'
import os
import sys

path = os.path.abspath(os.path.normpath(sys.argv[1]))
mountpoint = os.path.abspath(os.path.normpath(sys.argv[2]))
try:
    ok = os.path.commonpath([path, mountpoint]) == mountpoint and path != mountpoint
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

mount_matches() {
    local live_source live_fstype
    live_source="$(findmnt -rn -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)"
    live_fstype="$(findmnt -rn -M "$MOUNTPOINT" -o FSTYPE 2>/dev/null || true)"
    [[ -n "$live_source" && "$live_source" == "$EXPECTED_SOURCE" ]] || return 1
    case "$EXPECTED_FSTYPE:$live_fstype" in
        nfs4:nfs|nfs4:nfs4|nfs:nfs|nfs:nfs4) return 0 ;;
        *) [[ "$live_fstype" == "$EXPECTED_FSTYPE" ]] ;;
    esac
}

if ! path_under_mountpoint "$SENTINEL" "$MOUNTPOINT"; then
    echo "sentinel is outside mountpoint: $SENTINEL" >&2
    exit 1
fi

refuse() {
    # The watchdog discards helper output, so the audit trail has to be the
    # system log; stderr stays for an operator running the helper by hand.
    echo "$1" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t mediastack-storage-helper -p daemon.warning "$1"
    fi
}

is_nfs_fstype() {
    case "$1" in
        nfs | nfs4) return 0 ;;
        *) return 1 ;;
    esac
}

fstab_owned_by_other() {
    # An fstab entry for this target is an admin-owned mount unless it names
    # the source setup recorded. Never detach a mount the host owns.
    local entry seen=false
    while read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$entry" == "$EXPECTED_SOURCE" ]]; then
            return 1
        fi
        seen=true
    done < <(findmnt --fstab -rn -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)
    $seen
}

mount_is_responsive() {
    timeout 5 stat -f -c '%T' "$MOUNTPOINT" >/dev/null 2>&1
}

detach_unexpected_mount() {
    local src="$1" fstype="$2"

    # Only NFS is ever detached here: anything else at the mountpoint is an
    # admin's own filesystem, not a NAS mount this helper is repairing.
    if ! is_nfs_fstype "$fstype"; then
        refuse "refusing to unmount ${MOUNTPOINT}: found ${src:-unknown} (${fstype:-unknown}), expected ${EXPECTED_SOURCE} (${EXPECTED_FSTYPE})"
        return 1
    fi
    if fstab_owned_by_other; then
        refuse "refusing to unmount ${MOUNTPOINT}: /etc/fstab owns this target with a source other than ${EXPECTED_SOURCE}"
        return 1
    fi

    # Plain umount is the busy check: fuser/lsof are not guaranteed present on
    # a minimal host, findmnt and umount are. Lazy detach stays available only
    # for the case it existed for - a mount that no longer answers, which
    # plain umount cannot clear.
    if timeout 20 umount "$MOUNTPOINT" >/dev/null 2>&1; then
        return 0
    fi
    if mount_is_responsive; then
        refuse "refusing to lazy-unmount ${MOUNTPOINT}: ${src:-unknown} is live and in use"
        return 1
    fi
    if ! umount -l "$MOUNTPOINT" >/dev/null 2>&1; then
        refuse "could not detach unresponsive mount at ${MOUNTPOINT}: ${src:-unknown}"
        return 1
    fi
}

if ! mount_matches && findmnt -rn -M "$MOUNTPOINT" >/dev/null 2>&1; then
    detach_unexpected_mount \
        "$(findmnt -rn -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)" \
        "$(findmnt -rn -M "$MOUNTPOINT" -o FSTYPE 2>/dev/null || true)" || exit 1
fi

mkdir -p "$MOUNTPOINT"
if ! mount_matches; then
    mount -t nfs4 -o "$OPTS" "${HOST}:${EXPORT_PATH}" "$MOUNTPOINT" \
        || mount -t nfs -o "$OPTS" "${HOST}:${EXPORT_PATH}" "$MOUNTPOINT"
fi

mount_matches
test -e "$SENTINEL"
EOF
}

storage_watchdog_unit_content() {
    local install_user="$1" install_group="$2" script="$3"
    cat <<EOF
[Unit]
Description=MediaStack NAS storage watchdog
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=$install_user
Group=$install_group
WorkingDirectory=$SCRIPT_DIR
ExecStart=$script
Restart=always
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
}

storage_watchdog_sudoers_content() {
    local install_user="$1" helper="$2"
    printf '%s ALL=(root) NOPASSWD: %s repair\n' "$install_user" "$helper"
}

storage_pause_watchdog_for_install() {
    command -v systemctl >/dev/null 2>&1 || return 0

    # Only announce the pause when the watchdog is actually running; a stale or
    # never-installed unit is torn down quietly (the reason for this probe).
    local state
    state="$(sudo systemctl is-active mediastack-storage-watchdog.service 2>/dev/null)" || true
    case "$state" in
        active | activating | reloading | deactivating)
            storage_log_info "Pausing NAS storage watchdog during Stage 1 install..."
            ;;
    esac

    # Defensively stop and disable even when it looks inactive: a leftover unit
    # from a prior NAS install must not fire while setup churns services.
    sudo systemctl stop mediastack-storage-watchdog.service >/dev/null 2>&1 || true
    sudo systemctl disable mediastack-storage-watchdog.service >/dev/null 2>&1 || true

    # Verify it is genuinely inactive. Fail closed if it is still active OR its
    # state cannot be verified (empty/error) — never continue on an unknown state.
    local rc=0
    state="$(sudo systemctl is-active mediastack-storage-watchdog.service 2>/dev/null)" || rc=$?
    case "$state" in
        inactive | failed | unknown) return 0 ;;
        active | activating | reloading | deactivating)
            storage_log_err "NAS storage watchdog is still active; refusing to continue while setup may stop/start protected services."
            return 1
            ;;
        *)
            storage_log_err "Could not verify NAS storage watchdog inactive state (systemctl exit ${rc}); refusing to continue."
            return 1
            ;;
    esac
}

storage_install_watchdog() {
    storage_is_nas || return 0
    if ! storage_watchdog_enabled; then
        # Disabled by config: tear down any unit left from a prior enabled run
        # (stop+disable is fail-safe when nothing is installed) and skip install.
        storage_pause_watchdog_for_install || true
        storage_log_info "NAS storage watchdog disabled by configuration; not installing."
        return 0
    fi
    local script="$SCRIPT_DIR/scripts/storage-watchdog.sh"
    local unit="$MEDIASTACK_STORAGE_WATCHDOG_UNIT"
    local libexec_dir="$MEDIASTACK_STORAGE_LIBEXEC_DIR"
    local helper="$libexec_dir/storage-mount-helper"
    local config_dir="/etc/mediastack"
    local config_file="$config_dir/storage.env"
    local sudoers_file="$MEDIASTACK_STORAGE_WATCHDOG_SUDOERS"
    local install_user install_group

    if [[ ! -x "$script" ]]; then
        storage_log_warn "Storage watchdog script missing or not executable: $script"
        return 0
    fi

    install_user="$(id -un)"
    install_group="$(id -gn)"

    storage_log_info "Installing NAS storage watchdog..."
    sudo install -d -o root -g root -m 0755 "$libexec_dir" "$config_dir"
    storage_mount_helper_content | sudo tee "$helper" >/dev/null
    sudo chown root:root "$helper"
    sudo chmod 0755 "$helper"
    storage_root_config_content | sudo tee "$config_file" >/dev/null
    sudo chown root:root "$config_file"
    sudo chmod 0600 "$config_file"
    storage_watchdog_sudoers_content "$install_user" "$helper" | sudo tee "$sudoers_file" >/dev/null
    sudo chown root:root "$sudoers_file"
    sudo chmod 0440 "$sudoers_file"
    if command -v visudo >/dev/null 2>&1; then
        sudo visudo -cf "$sudoers_file" >/dev/null
    fi
    storage_watchdog_unit_content "$install_user" "$install_group" "$script" | sudo tee "$unit" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable mediastack-storage-watchdog.service >/dev/null
    sudo systemctl restart mediastack-storage-watchdog.service >/dev/null
    storage_log_ok "NAS storage watchdog enabled"
}

# Tear down the watchdog host artefacts this module owns (unit, sudoers, libexec),
# called from the uninstall path so the teardown lives beside the installer above.
# Mirror of the old inline block in hardening.sh: unit stop/disable/rm guarded on
# presence, sudoers/libexec removed unconditionally. Does NOT daemon-reload — the
# caller keeps its single trailing reload so the systemctl sequence is unchanged.
# Returns non-zero if any removal fails (mirrors the old failed=1 accounting).
# ponytail: blind rm, no sha-guard — all MediaStack-generated, no admin-editable content.
storage_uninstall_watchdog() {
    local rc=0
    if sudo test -f "$MEDIASTACK_STORAGE_WATCHDOG_UNIT"; then
        sudo systemctl stop mediastack-storage-watchdog.service 2>/dev/null || rc=1
        sudo systemctl disable mediastack-storage-watchdog.service 2>/dev/null || rc=1
        sudo rm -f "$MEDIASTACK_STORAGE_WATCHDOG_UNIT" || rc=1
    fi
    sudo rm -f "$MEDIASTACK_STORAGE_WATCHDOG_SUDOERS" || rc=1
    sudo rm -rf "$MEDIASTACK_STORAGE_LIBEXEC_DIR" || rc=1
    return "$rc"
}
