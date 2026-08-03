# =============================================================================
# MediaStack Setup - Storage modes, NAS guards, and watchdog install
# =============================================================================
# Sourced by setup.sh and selected scripts. Sources common.sh itself:
# storage_env_set delegates to its _env_write_kv, and
# common.sh is side-effect-free at source time so the watchdog stays safe.

# No include guard of its own: this file is safe to re-source (plain function/
# var definitions — the unit suite relies on re-sourcing to restore stubs);
# common.sh guards itself, so the source below is a no-op after the first.
_STORAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$_STORAGE_LIB_DIR/../lib/common.sh"

# Canonical NFS mount options — the recommended default seeded when the user
# hasn't supplied custom opts. Owned here (the storage/NFS module) and consumed
# by the wizard's Stage 1 collection too, since setup.sh sources storage.sh
# before the wizard. The watchdog mount-helper heredoc (see
# storage_mount_helper_content) keeps its own literal: that heredoc is emitted
# into a standalone script that only sources storage.env and never sees this.
DEFAULT_NFS_OPTS="vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"

# Watchdog host-artefact paths this module owns. Single source of truth so
# storage_install_watchdog and storage_uninstall_watchdog can never drift (the
# teardown was formerly re-typed in hardening.sh). Plain assignment — re-source safe.
MEDIASTACK_STORAGE_WATCHDOG_UNIT="/etc/systemd/system/mediastack-storage-watchdog.service"
MEDIASTACK_STORAGE_LIBEXEC_DIR="/usr/local/libexec/mediastack"
MEDIASTACK_STORAGE_WATCHDOG_SUDOERS="/etc/sudoers.d/mediastack-storage-watchdog"

storage_mode() {
    printf '%s\n' "${STORAGE_MODE:-local}"
}

storage_is_nas() {
    [[ "$(storage_mode)" == "nas" ]]
}

storage_is_manual() {
    [[ "${STORAGE_APP_WIRING:-managed}" == "manual" ]]
}

storage_data_services() {
    printf '%s\n' unpackerr qbittorrent sonarr radarr seerr jellyfin
    if [[ "${BAZARR_ENABLED:-false}" == "true" ]]; then
        printf '%s\n' bazarr
    fi
}

storage_log_info() { if declare -F log_info >/dev/null; then log_info "$*"; else echo "INFO: $*"; fi; }
storage_log_ok() { if declare -F log_ok >/dev/null; then log_ok "$*"; else echo "OK: $*"; fi; }
storage_log_warn() { if declare -F log_warn >/dev/null; then log_warn "$*"; else echo "WARN: $*"; fi; }
storage_log_err() { if declare -F log_error >/dev/null; then log_error "$*"; else echo "ERROR: $*"; fi; }
storage_log_skip() { if declare -F log_skip >/dev/null; then log_skip "$*"; else echo "SKIP: $*"; fi; }

storage_expected_source() {
    if [[ -n "${STORAGE_EXPECTED_SOURCE:-}" ]]; then
        printf '%s\n' "$STORAGE_EXPECTED_SOURCE"
    elif [[ -n "${STORAGE_NFS_HOST:-}" && -n "${STORAGE_NFS_EXPORT:-}" ]]; then
        printf '%s:%s\n' "$STORAGE_NFS_HOST" "$STORAGE_NFS_EXPORT"
    fi
}

storage_expected_fstype() {
    printf '%s\n' "${STORAGE_EXPECTED_FSTYPE:-nfs4}"
}

storage_sentinel_path() {
    printf '%s\n' "${STORAGE_SENTINEL:-${DATA_DIR:-/data}/.mediastack-storage-ready}"
}

storage_mountpoint() {
    printf '%s\n' "${STORAGE_MOUNTPOINT:-${DATA_DIR:-/data}}"
}

storage_path_is_under_mountpoint() {
    local path="$1" mountpoint="$2"
    python3 - "$path" "$mountpoint" <<'PY'
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

storage_sentinel_is_under_mountpoint() {
    storage_path_is_under_mountpoint "$(storage_sentinel_path)" "$(storage_mountpoint)"
}

storage_findmnt_source() {
    findmnt -rn -M "$(storage_mountpoint)" -o SOURCE 2>/dev/null || true
}

storage_findmnt_fstype() {
    findmnt -rn -M "$(storage_mountpoint)" -o FSTYPE 2>/dev/null || true
}

storage_mount_matches() {
    local want_source want_fstype live_source live_fstype
    want_source="$(storage_expected_source)"
    want_fstype="$(storage_expected_fstype)"
    live_source="$(storage_findmnt_source)"
    live_fstype="$(storage_findmnt_fstype)"

    [[ -n "$live_source" && -n "$want_source" ]] || return 1
    [[ "$live_source" == "$want_source" ]] || return 1
    case "$want_fstype:$live_fstype" in
        nfs4:nfs | nfs4:nfs4 | nfs:nfs | nfs:nfs4) return 0 ;;
        *) [[ "$live_fstype" == "$want_fstype" ]] ;;
    esac
}

storage_sentinel_ok() {
    local sentinel
    sentinel="$(storage_sentinel_path)"
    storage_sentinel_is_under_mountpoint || return 1
    timeout 5 test -e "$sentinel" >/dev/null 2>&1
}

storage_nas_ok() {
    storage_is_nas || return 0
    storage_mount_matches && storage_sentinel_ok
}

# The mount watchdog/guard is opt-out per NAS install. Absent = enabled, so
# existing installs (no STORAGE_WATCHDOG key) keep their watchdog.
storage_watchdog_enabled() {
    [[ "${STORAGE_WATCHDOG:-true}" != "false" ]]
}

storage_mountpoint_has_mount() {
    findmnt -rn -M "$(storage_mountpoint)" >/dev/null 2>&1
}

storage_repair_mismatched_mount() {
    local mountpoint live_source live_fstype expected_source

    storage_mount_matches && return 0
    storage_mountpoint_has_mount || return 0

    mountpoint="$(storage_mountpoint)"
    live_source="$(storage_findmnt_source)"
    live_fstype="$(storage_findmnt_fstype)"
    expected_source="$(storage_expected_source)"

    storage_log_warn "A different filesystem is mounted at ${mountpoint}: ${live_source:-unknown} (${live_fstype:-unknown}); expected ${expected_source:-unknown}."
    if declare -F ui_confirm >/dev/null; then
        if ! ui_confirm "Detach the existing mount and mount the selected NAS here?" "yes"; then
            storage_log_warn "Keeping existing mount at ${mountpoint}; NAS mount was not changed."
            return 1
        fi
    fi

    storage_log_info "Detaching existing mount at ${mountpoint} before mounting selected NAS..."
    if ! sudo umount -l "$mountpoint"; then
        storage_log_err "Could not detach existing mount at ${mountpoint}."
        return 1
    fi
}

storage_mount_nfs() {
    local mountpoint
    mountpoint="$(storage_mountpoint)"
    local host="${STORAGE_NFS_HOST:-}"
    local export_path="${STORAGE_NFS_EXPORT:-}"
    local opts="${STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}"

    if [[ -z "$host" || -z "$export_path" ]]; then
        storage_log_err "NAS storage selected but NFS host/export is missing."
        return 1
    fi

    if storage_mount_matches; then
        return 0
    fi

    storage_repair_mismatched_mount || return 1

    sudo mkdir -p "$mountpoint" || return 1
    storage_log_info "Mounting NFS storage ${host}:${export_path} at ${mountpoint}..."
    if sudo mount -t nfs4 -o "$opts" "${host}:${export_path}" "$mountpoint"; then
        storage_log_ok "NFS mount active at ${mountpoint}"
        return 0
    fi

    storage_log_warn "NFSv4 mount failed; retrying with generic nfs type."
    sudo mount -t nfs -o "$opts" "${host}:${export_path}" "$mountpoint"
}

storage_ensure_nfs_common() {
    if command -v mount.nfs >/dev/null 2>&1 || command -v mount.nfs4 >/dev/null 2>&1; then
        return 0
    fi
    storage_log_info "Installing nfs-common for NAS storage..."
    sudo apt-get update -qq >/dev/null 2>&1 || true
    ui_spin "Installing nfs-common..." sudo apt-get install -y -qq nfs-common
}

# TCP reachability probe. Reuses the codebase nc idiom (network.sh) with a
# /dev/tcp fallback so it works without netcat installed.
storage_host_port_open() {
    local host="$1" port="$2"
    if command -v nc >/dev/null 2>&1; then
        nc -z -w5 "$host" "$port" >/dev/null 2>&1 && return 0
        return 1
    fi
    timeout 5 bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
}

# Turn the user's real mount options into fail-fast probe options: a bad target
# must error out, not hang. Strip hard/soft/timeo/retrans, force soft + short
# timeout so an unreachable export fails in ~10s instead of retrying forever.
storage_probe_opts() {
    local opts="${1:-vers=4.2,proto=tcp,rw}"
    local cleaned
    cleaned=$(printf '%s' "$opts" \
        | tr ',' '\n' \
        | grep -viE '^(hard|soft|timeo=.*|retrans=.*)$' \
        | paste -sd, -)
    printf '%s' "${cleaned:+${cleaned},}soft,timeo=50,retrans=2"
}

# Non-destructive NAS verification for the wizard. Mounts the export to a
# THROWAWAY temp dir (never the real mountpoint), runs discrete checks with one
# line each, classifies the share, then unmounts. Because it never touches the
# real mountpoint, no mismatch/detach can ever happen. Sets _STORAGE_PROBE_CLASS
# on success. Returns 0 only if reachable + mountable + readable + writable.
storage_probe_nas() {
    local host="${STORAGE_NFS_HOST:-}"
    local export_path="${STORAGE_NFS_EXPORT:-}"
    local opts probe_opts tmp rc=0
    opts="${STORAGE_NFS_OPTS:-$DEFAULT_NFS_OPTS}"
    _STORAGE_PROBE_CLASS=""

    if [[ -z "$host" || -z "$export_path" ]]; then
        storage_log_err "NAS storage selected but NFS host/export is missing."
        return 1
    fi

    # 1. NAS reachable (NFSv4 port 2049; fall back to rpcbind 111 for v3).
    if storage_host_port_open "$host" 2049 || storage_host_port_open "$host" 111; then
        storage_log_ok "NAS reachable ($host)"
    else
        storage_log_err "NAS not reachable at ${host}:2049 (host down or firewalled)."
        return 1
    fi

    if ! tmp=$(mktemp -d 2>/dev/null); then
        storage_log_err "Could not create a temporary directory to test the NAS mount."
        return 1
    fi

    # 2. Export mountable — temp mount with fail-fast opts, never the real mountpoint.
    probe_opts="$(storage_probe_opts "$opts")"
    if ui_spin "Testing NFS export ${host}:${export_path}..." \
        sudo mount -t nfs4 -o "$probe_opts" "${host}:${export_path}" "$tmp" \
        || sudo mount -t nfs -o "$probe_opts" "${host}:${export_path}" "$tmp" >/dev/null 2>&1; then
        storage_log_ok "NFS export available (${export_path})"
    else
        storage_log_err "NFS export not found or not permitted for this host (${host}:${export_path})."
        rmdir "$tmp" 2>/dev/null || true
        return 1
    fi

    # 3. Readable.
    if ls "$tmp" >/dev/null 2>&1; then
        storage_log_ok "Share is readable"
    else
        storage_log_err "Share mounted but is not readable."
        rc=1
    fi

    # 4. Writable — tested as the install user (not sudo), mirroring how
    #    MediaStack actually creates directories and the sentinel. Catches
    #    read-only exports and root-squash that would block managed writes.
    if [[ $rc -eq 0 ]]; then
        if touch "$tmp/.mediastack-probe" >/dev/null 2>&1; then
            rm -f "$tmp/.mediastack-probe" 2>/dev/null || true
            storage_log_ok "Share is writable"
        else
            storage_log_err "Share is read-only for this host (check the NFS export's rw option + squash)."
            rc=1
        fi
    fi

    # 5. Classify while still mounted, then always unmount + clean up the temp dir.
    if [[ $rc -eq 0 ]]; then
        _STORAGE_PROBE_CLASS="$(storage_classify_data_root "$tmp")"
    fi
    sudo umount -l "$tmp" >/dev/null 2>&1 || true
    rmdir "$tmp" 2>/dev/null || true
    return "$rc"
}

storage_env_set() {
    local key="$1" value="$2" env_file="${SCRIPT_DIR:-$(pwd)}/.env"
    [[ -f "$env_file" ]] || return 0
    # One blessed .env writer (common.sh) — atomic, mode-preserving, quoted.
    _env_write_kv "$env_file" "$key" "$value" >/dev/null || return 1
}

storage_classify_data_root() {
    local data_dir="${1:-${DATA_DIR:-/data}}"
    if [[ ! -d "$data_dir" ]]; then
        printf '%s\n' missing
        return 0
    fi
    if [[ -e "$data_dir/media" && ! -d "$data_dir/media" ]]; then
        printf '%s\n' conflict:media
        return 0
    fi
    if [[ -e "$data_dir/torrents" && ! -d "$data_dir/torrents" ]]; then
        printf '%s\n' conflict:torrents
        return 0
    fi
    if find "$data_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        if [[ -d "$data_dir/media" && -d "$data_dir/torrents" ]]; then
            printf '%s\n' mediastack
        else
            printf '%s\n' nonempty
        fi
    else
        printf '%s\n' empty
    fi
}

storage_preflight_nas() {
    storage_is_nas || return 0

    storage_ensure_nfs_common

    storage_mount_nfs || return 1

    local source fstype sentinel
    source="$(storage_findmnt_source)"
    fstype="$(storage_findmnt_fstype)"
    storage_env_set STORAGE_EXPECTED_SOURCE "$source" || return 1
    storage_env_set STORAGE_EXPECTED_FSTYPE "$fstype" || return 1
    export STORAGE_EXPECTED_SOURCE="$source"
    export STORAGE_EXPECTED_FSTYPE="$fstype"

    sentinel="$(storage_sentinel_path)"
    if ! storage_sentinel_is_under_mountpoint; then
        storage_log_err "NAS sentinel must be inside the NAS mountpoint (${sentinel} is outside $(storage_mountpoint))."
        return 1
    fi
    if [[ ! -e "$sentinel" ]]; then
        storage_log_info "Creating NAS sentinel: $sentinel"
        if ! mkdir -p "$(dirname "$sentinel")" 2>/dev/null || ! touch "$sentinel" 2>/dev/null; then
            storage_log_err "Could not create NAS sentinel at $sentinel."
            return 1
        fi
    fi

    if ! storage_nas_ok; then
        storage_log_err "NAS storage check failed: mount identity or sentinel did not verify."
        return 1
    fi

    storage_log_ok "NAS storage verified (${source}, ${fstype}, sentinel=${sentinel})"
}

storage_guard_before_start() {
    storage_is_nas || return 0
    storage_watchdog_enabled || return 0
    if storage_nas_ok; then
        return 0
    fi
    storage_log_err "Refusing to start MediaStack: NAS storage is not mounted and verified."
    storage_log_err "Expected: source=$(storage_expected_source), sentinel=$(storage_sentinel_path)"
    return 1
}

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

mountpoint="${STORAGE_MOUNTPOINT:-}"
host="${STORAGE_NFS_HOST:-}"
export_path="${STORAGE_NFS_EXPORT:-}"
# literal: emitted into a standalone script that can't see DEFAULT_NFS_OPTS
opts="${STORAGE_NFS_OPTS:-vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec}"
expected_source="${STORAGE_EXPECTED_SOURCE:-${host}:${export_path}}"
expected_fstype="${STORAGE_EXPECTED_FSTYPE:-nfs4}"
sentinel="${STORAGE_SENTINEL:-${mountpoint}/.mediastack-storage-ready}"

[[ -n "$mountpoint" && -n "$host" && -n "$export_path" ]] || exit 1

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
    live_source="$(findmnt -rn -M "$mountpoint" -o SOURCE 2>/dev/null || true)"
    live_fstype="$(findmnt -rn -M "$mountpoint" -o FSTYPE 2>/dev/null || true)"
    [[ -n "$live_source" && "$live_source" == "$expected_source" ]] || return 1
    case "$expected_fstype:$live_fstype" in
        nfs4:nfs|nfs4:nfs4|nfs:nfs|nfs:nfs4) return 0 ;;
        *) [[ "$live_fstype" == "$expected_fstype" ]] ;;
    esac
}

if ! path_under_mountpoint "$sentinel" "$mountpoint"; then
    echo "sentinel is outside mountpoint: $sentinel" >&2
    exit 1
fi

if ! mount_matches && findmnt -rn -M "$mountpoint" >/dev/null 2>&1; then
    umount -l "$mountpoint" >/dev/null 2>&1 || true
fi

mkdir -p "$mountpoint"
if ! mount_matches; then
    mount -t nfs4 -o "$opts" "${host}:${export_path}" "$mountpoint" \
        || mount -t nfs -o "$opts" "${host}:${export_path}" "$mountpoint"
fi

mount_matches
test -e "$sentinel"
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
