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
    # --first-only: a stacked mountpoint prints one line per layer, and only
    # the topmost one is what anything reading $MOUNTPOINT actually sees.
    live_source="$(findmnt -rn --first-only -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)"
    live_fstype="$(findmnt -rn --first-only -M "$MOUNTPOINT" -o FSTYPE 2>/dev/null || true)"
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

fstab_blocks_detach() {
    # An fstab entry for this target is an admin-owned mount unless it names
    # the source setup recorded. A lookup that fails outright is not the same
    # as "no entry": it fails closed, like every other guard here.
    local entries rc=0 entry
    entries="$(findmnt --fstab -rn -M "$MOUNTPOINT" -o SOURCE 2>/dev/null)" || rc=$?
    if ((rc > 1)); then
        refuse "refusing to unmount ${MOUNTPOINT}: /etc/fstab lookup failed (findmnt exit ${rc})"
        return 0
    fi
    while read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$entry" != "$EXPECTED_SOURCE" ]]; then
            refuse "refusing to unmount ${MOUNTPOINT}: /etc/fstab owns this target with a source other than ${EXPECTED_SOURCE}"
            return 0
        fi
    done <<<"$entries"
    return 1
}

mount_is_responsive() {
    # -k so a hard-mount stat that ignores SIGTERM still gets reaped; the whole
    # detach has to finish inside the watchdog's 30s cap on this helper.
    timeout -k 5 5 stat -f -c '%T' "$MOUNTPOINT" >/dev/null 2>&1
}

detach_unexpected_mount() {
    local src="$1" fstype="$2"

    # Without timeout every step below would exit 127 and the helper would
    # degrade into the unconditional lazy detach this guard replaced.
    if ! command -v timeout >/dev/null 2>&1; then
        refuse "timeout(1) unavailable; not detaching ${MOUNTPOINT}"
        return 1
    fi

    # Only NFS is ever detached here: anything else at the mountpoint is an
    # admin's own filesystem, not a NAS mount this helper is repairing.
    if ! is_nfs_fstype "$fstype"; then
        refuse "refusing to unmount ${MOUNTPOINT}: found ${src:-unknown} (${fstype:-unknown}), expected ${EXPECTED_SOURCE} (${EXPECTED_FSTYPE})"
        return 1
    fi
    if fstab_blocks_detach; then
        return 1
    fi

    # Responsiveness decides which unmount is legitimate, and it has to be
    # asked first: a plain umount of a dead NFS mount blocks in D-state until
    # the caller kills the helper, so the lazy path would never be reached.
    if ! mount_is_responsive; then
        # Exactly what lazy detach exists for - a mount that no longer answers
        # and that plain umount cannot clear.
        if ! umount -l "$MOUNTPOINT" >/dev/null 2>&1; then
            refuse "could not lazy-detach unresponsive mount at ${MOUNTPOINT}: ${src:-unknown}"
            return 1
        fi
        return 0
    fi

    # The mount answers, so plain umount is the busy check: fuser/lsof are not
    # guaranteed present on a minimal host, findmnt and umount are.
    if timeout -k 5 10 umount "$MOUNTPOINT" >/dev/null 2>&1; then
        return 0
    fi
    refuse "refusing to lazy-unmount ${MOUNTPOINT}: ${src:-unknown} is live and in use"
    return 1
}

if ! mount_matches && findmnt -rn --first-only -M "$MOUNTPOINT" >/dev/null 2>&1; then
    detach_unexpected_mount \
        "$(findmnt -rn --first-only -M "$MOUNTPOINT" -o SOURCE 2>/dev/null || true)" \
        "$(findmnt -rn --first-only -M "$MOUNTPOINT" -o FSTYPE 2>/dev/null || true)" || exit 1
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

    # The watchdog is only useful if its sudoers rule parses, so validate before
    # anything is written. A directory-service login name (DOMAIN\user,
    # user@REALM) is not a plain sudoers user token and would install a rule
    # sudo never honours, leaving auto-repair silently dead; so would an
    # unvalidated file on a host with no visudo. Skip the watchdog in both
    # cases - setup carries on, the user is told.
    if [[ ! "$install_user" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        storage_log_warn "User name '${install_user}' cannot be expressed as a sudoers rule; NAS storage watchdog not installed."
        return 0
    fi
    if ! command -v visudo >/dev/null 2>&1; then
        storage_log_warn "visudo is unavailable, so the watchdog sudoers rule cannot be validated; NAS storage watchdog not installed."
        return 0
    fi
    # Staged inside the root-owned config dir, not $TMPDIR: what visudo accepts
    # must be the same bytes `install` copies, with no window where an unrelated
    # user could swap the file in between.
    sudo install -d -o root -g root -m 0755 "$config_dir"
    local sudoers_tmp
    sudoers_tmp="$(sudo mktemp -p "$config_dir" .storage-watchdog-sudoers.XXXXXX)" || return 1
    # shellcheck disable=SC2064 # expand sudoers_tmp now: the trap must not depend on the local surviving
    # The trap is cleared again on every exit path below: a bash RETURN trap set
    # in a function also fires on every later `source` in the same shell, which
    # would replay this sudo rm (and possibly a sudo prompt) for the rest of setup.
    trap "sudo rm -f '$sudoers_tmp'" RETURN
    storage_watchdog_sudoers_content "$install_user" "$helper" | sudo tee "$sudoers_tmp" >/dev/null
    if ! sudo visudo -cf "$sudoers_tmp" >/dev/null 2>&1; then
        sudo rm -f "$sudoers_tmp"
        trap - RETURN
        storage_log_warn "Generated watchdog sudoers rule failed validation; NAS storage watchdog not installed."
        return 0
    fi

    storage_log_info "Installing NAS storage watchdog..."
    sudo install -d -o root -g root -m 0755 "$libexec_dir" "$config_dir"
    storage_mount_helper_content | sudo tee "$helper" >/dev/null
    sudo chown root:root "$helper"
    sudo chmod 0755 "$helper"
    storage_root_config_content | sudo tee "$config_file" >/dev/null
    sudo chown root:root "$config_file"
    sudo chmod 0600 "$config_file"
    sudo install -o root -g root -m 0440 "$sudoers_tmp" "$sudoers_file"
    sudo rm -f "$sudoers_tmp"
    trap - RETURN
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
