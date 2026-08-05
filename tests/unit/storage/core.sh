# Owns: storage_classify_data_root, storage_nas_ok, storage_watchdog_enabled,
# storage_guard_before_start. Sourced by tests/unit/storage.sh; inherits its
# preamble (TMP_DIR, source of storage.sh/stack.sh/stage1.sh/env-gen.sh, assert lib).

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

assert_eq "empty" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: empty root"

mkdir -p "$TMP_DIR/media/movies" "$TMP_DIR/torrents/tv"
assert_eq "mediastack" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: existing MediaStack layout"

rm -rf "${TMP_DIR:?}"/*
mkdir -p "$TMP_DIR/Photos"
assert_eq "nonempty" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: unrelated non-empty root"

rm -rf "${TMP_DIR:?}"/*
touch "$TMP_DIR/media"
assert_eq "conflict:media" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: media file conflict"

rm -rf "${TMP_DIR:?}"/*
touch "$TMP_DIR/torrents"
assert_eq "conflict:torrents" "$(storage_classify_data_root "$TMP_DIR")" "storage classify: torrents file conflict"

# shellcheck disable=SC2034 # consumed by storage_mountpoint in storage/core.sh, sourced below
DATA_DIR="$TMP_DIR"
# shellcheck disable=SC2034 # consumed by storage_mode in storage/core.sh, sourced below
STORAGE_MODE=nas
# shellcheck disable=SC2034 # consumed by storage_mountpoint in storage/core.sh, sourced below
STORAGE_MOUNTPOINT="$TMP_DIR"
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
# shellcheck disable=SC2034 # consumed by storage_expected_fstype in storage/core.sh, sourced below
STORAGE_EXPECTED_FSTYPE="nfs4"
STORAGE_SENTINEL="$TMP_DIR/.mediastack-storage-ready"
touch "$STORAGE_SENTINEL"

findmnt() {
    case "$*" in
        *"-o SOURCE"*) echo "192.0.2.10:/exports/mediastack-fixture" ;;
        *"-o FSTYPE"*) echo "nfs" ;;
        *) return 0 ;;
    esac
}

if storage_nas_ok; then
    pass "storage_nas_ok: accepts expected source and nfs/nfs4 compatibility"
else
    fail "storage_nas_ok: accepts expected source and nfs/nfs4 compatibility"
fi

STORAGE_EXPECTED_SOURCE="192.0.2.11:/exports/other"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects wrong source"
else
    pass "storage_nas_ok: rejects wrong source"
fi

STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
rm -f "$STORAGE_SENTINEL"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects missing sentinel"
else
    pass "storage_nas_ok: rejects missing sentinel"
fi

STORAGE_SENTINEL="$TMP_DIR-outside-sentinel"
touch "$STORAGE_SENTINEL"
if storage_nas_ok; then
    fail "storage_nas_ok: rejects sentinel outside mountpoint"
else
    pass "storage_nas_ok: rejects sentinel outside mountpoint"
fi

# --- STORAGE_WATCHDOG opt-out gate (findmnt still stubbed; sentinel is outside
# the mountpoint from the block above, so storage_nas_ok fails here) ---
# shellcheck disable=SC2034 # consumed by storage_expected_source in storage/core.sh, sourced below
STORAGE_EXPECTED_SOURCE="192.0.2.10:/exports/mediastack-fixture"
unset STORAGE_WATCHDOG
if storage_watchdog_enabled; then
    pass "storage_watchdog_enabled: absent flag defaults to enabled"
else
    fail "storage_watchdog_enabled: absent flag defaults to enabled"
fi

STORAGE_WATCHDOG=false
if storage_watchdog_enabled; then
    fail "storage_watchdog_enabled: false disables"
else
    pass "storage_watchdog_enabled: false disables"
fi

if storage_guard_before_start 2>/dev/null; then
    pass "storage_guard_before_start: watchdog off -> allows start despite failing nas_ok"
else
    fail "storage_guard_before_start: watchdog off -> allows start despite failing nas_ok"
fi

# shellcheck disable=SC2034 # consumed by storage_watchdog_enabled in storage/core.sh, sourced below
STORAGE_WATCHDOG=true
if storage_guard_before_start 2>/dev/null; then
    fail "storage_guard_before_start: watchdog on -> refuses start when nas_ok fails"
else
    pass "storage_guard_before_start: watchdog on -> refuses start when nas_ok fails"
fi
unset STORAGE_WATCHDOG

unset -f findmnt
