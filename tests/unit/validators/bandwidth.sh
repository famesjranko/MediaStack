# Owns: MB/s speed-limit validator tests.
# Sources: tests/unit/validators.sh setup and scripts/lib/validators/bandwidth.sh.

# ---------------------------------------------------------------------------
# MB/s speed-limit validator (qBittorrent DL/UL). Distinct from the Mbps
# validators: same grammar, unit-correct "MB/s" copy. 0 = unlimited.
# ---------------------------------------------------------------------------
for ok in "0" "5" "1.5" "100" "0.5"; do
    reset_warn
    validate_mb_per_sec "$ok"
    rc=$?
    assert_eq "0" "$rc" "validate_mb_per_sec: accepts '$ok'"
    assert_eq "0" "$WARN_COUNT" "validate_mb_per_sec: '$ok' emits no warn"
done

for bad in "" "abc" "1.2.3" "5mb" "-1" "1," "1 "; do
    reset_warn
    validate_mb_per_sec "$bad"
    rc=$?
    assert_eq "1" "$rc" "validate_mb_per_sec: rejects '$bad'"
    assert_eq "1" "$WARN_COUNT" "validate_mb_per_sec: '$bad' warns once"
done

reset_warn
validate_mb_per_sec "x"
rc=$?
assert_contains "$LAST_WARN" "MB/s" "validate_mb_per_sec: warn copy says MB/s (not Mbps)"
