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
# shellcheck disable=SC2034 # consumed by storage/mount.sh and storage/watchdog.sh, sourced below
DEFAULT_NFS_OPTS="vers=4.2,proto=tcp,rw,hard,timeo=600,retrans=2,nosuid,nodev,noexec"

# Watchdog host-artefact paths this module owns. Single source of truth so
# storage_install_watchdog and storage_uninstall_watchdog can never drift (the
# teardown was formerly re-typed in hardening.sh). Plain assignment — re-source safe.
# shellcheck disable=SC2034 # consumed by storage/watchdog.sh, sourced below
MEDIASTACK_STORAGE_WATCHDOG_UNIT="/etc/systemd/system/mediastack-storage-watchdog.service"
# shellcheck disable=SC2034 # consumed by storage/watchdog.sh, sourced below
MEDIASTACK_STORAGE_LIBEXEC_DIR="/usr/local/libexec/mediastack"
# shellcheck disable=SC2034 # consumed by storage/watchdog.sh, sourced below
MEDIASTACK_STORAGE_WATCHDOG_SUDOERS="/etc/sudoers.d/mediastack-storage-watchdog"

# Topic modules, split out of this file for size: mode/predicates + mount-
# identity checks, NFS mount/repair/probe, env+preflight orchestration, and
# watchdog artefact install/uninstall. Kept in this one place so every
# sourcer (setup.sh, the launcher, and the unit/scenario tests) gets the
# full storage.sh surface from a single source.
# shellcheck source=storage/core.sh
source "$_STORAGE_LIB_DIR/storage/core.sh"
# shellcheck source=storage/mount.sh
source "$_STORAGE_LIB_DIR/storage/mount.sh"
# shellcheck source=storage/preflight.sh
source "$_STORAGE_LIB_DIR/storage/preflight.sh"
# shellcheck source=storage/watchdog.sh
source "$_STORAGE_LIB_DIR/storage/watchdog.sh"
