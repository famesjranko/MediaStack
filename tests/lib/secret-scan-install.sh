# tests/lib/secret-scan-install.sh
# Owns: fetching, sha256-verifying and caching the pinned gitleaks binary -
# fetch/sha256_of/verify_sha256/install_scanner/require_scanner.
# Sources: die(), pin(), and the GITLEAKS/VERSION/CONFIG/BINARY_SHA256/
# INSTALL_TMP variables set by the caller before this file is sourced.

fetch() {
    curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$1" "$2" \
        || die "download failed: $2"
}

sha256_of() {
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1) || die "sha256sum failed: $1"
    printf '%s\n' "$got"
}

verify_sha256() {
    [ "$(sha256_of "$1")" = "$2" ] || die "sha256 mismatch for $(basename "$1")"
}

install_scanner() {
    local url checksums_url want want_checksums dir tmp asset published

    if [ -x "$GITLEAKS" ] && [ "$(sha256_of "$GITLEAKS")" = "$BINARY_SHA256" ]; then
        printf 'gitleaks %s (cached, sha256 verified)\n' "$VERSION"
        return 0
    fi

    url="$(pin url)" || exit 2
    checksums_url="$(pin checksums_url)" || exit 2
    want="$(pin sha256)" || exit 2
    want_checksums="$(pin checksums_sha256)" || exit 2

    dir="$TOOL_CACHE/gitleaks-$VERSION"
    tmp=$(mktemp -d) || die "mktemp failed"
    INSTALL_TMP="$tmp"
    trap cleanup EXIT
    asset="$tmp/${url##*/}"

    fetch "$asset" "$url"
    fetch "$tmp/checksums.txt" "$checksums_url"
    verify_sha256 "$tmp/checksums.txt" "$want_checksums"
    verify_sha256 "$asset" "$want"

    # Cross-check the pin against upstream's own manifest: agreeing with a
    # checksum we recorded ourselves only proves the download was not corrupted.
    published=$(awk -v name="$(basename "$asset")" '$2 == name { print $1 }' "$tmp/checksums.txt")
    [ "$published" = "$want" ] || die "tools.toml sha256 disagrees with published checksums"

    mkdir -p "$dir" || die "cannot create $dir"
    tar -xzf "$asset" -C "$dir" gitleaks || die "extract failed"
    rm -rf "$tmp"

    verify_sha256 "$GITLEAKS" "$BINARY_SHA256"
    [ "$("$GITLEAKS" version 2>/dev/null)" = "$VERSION" ] \
        || die "installed binary does not report $VERSION"
    printf 'gitleaks %s installed at %s\n' "$VERSION" "$GITLEAKS"
}

# The cached binary is re-hashed on every run: a version string is self-reported
# and a three-line shell script can print one.
require_scanner() {
    [ -x "$GITLEAKS" ] || die "scanner not installed - run: $0 install"
    [ "$(sha256_of "$GITLEAKS")" = "$BINARY_SHA256" ] \
        || die "cached scanner sha256 does not match tools.toml - run: $0 install"
    [ "$("$GITLEAKS" version 2>/dev/null)" = "$VERSION" ] \
        || die "cached scanner is not $VERSION - run: $0 install"
    [ -r "$CONFIG" ] || die "unreadable scanner config: $CONFIG"
}
