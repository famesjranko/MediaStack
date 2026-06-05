#!/usr/bin/env bash
# tests/unit/profile-args.sh
#
# Contract tests for the shared docker-compose profile-arg builder
# (scripts/lib/profiles.sh::_build_profile_args). The installer and the day-2
# launcher now share this one builder, so this is the single place the
# profile-selection logic is exercised in isolation. Output order is fixed:
# subtitles, autoheal, proxy, remote.

set -uo pipefail

UNIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$UNIT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="profile-args"
scenario_begin "$CURRENT_SCENARIO"

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

source "$REPO_ROOT/scripts/lib/profiles.sh"

set +e
set +u

# Write a .env fixture from KEY=VALUE line arguments; echo its path. Each
# fixture gets a unique file (mktemp) so a path captured early stays valid even
# after later fixtures are written — `$(mkenv ...)` runs in a subshell, so a
# shared parent-side counter would not advance here.
mkenv() {
    local f
    f=$(mktemp "$TMP_ROOT/env.XXXXXX")
    printf '%s\n' "$@" > "$f"
    printf '%s' "$f"
}

# Run the builder against a .env fixture and join the flags into one string.
profiles_for() {
    local arr=()
    _build_profile_args arr "$1"
    echo "${arr[*]}"
}

# A minimal but otherwise-unrelated .env body, so each case isolates one knob.
# autoheal defaults ON, so the baseline output is "--profile autoheal".

# 1. Minimal .env (no relevant keys) -> autoheal default on.
f=$(mkenv "TZ=Etc/UTC" "PUID=1000")
assert_eq "--profile autoheal" "$(profiles_for "$f")" "minimal .env yields autoheal only (default on)"

# 2. AUTOHEAL_ENABLED=false -> no profiles at all.
f=$(mkenv "AUTOHEAL_ENABLED=false")
assert_eq "" "$(profiles_for "$f")" "AUTOHEAL_ENABLED=false disables autoheal"

# 3. BAZARR_ENABLED=true -> subtitles (+ autoheal default).
f=$(mkenv "BAZARR_ENABLED=true")
assert_eq "--profile subtitles --profile autoheal" "$(profiles_for "$f")" "BAZARR_ENABLED=true adds subtitles"

# 4-5. DOMAIN sentinel (unquoted + single-quoted) -> no proxy.
f=$(mkenv "DOMAIN=example.com")
assert_eq "--profile autoheal" "$(profiles_for "$f")" "DOMAIN=example.com is the LAN sentinel (no proxy)"
f=$(mkenv "DOMAIN='example.com'")
assert_eq "--profile autoheal" "$(profiles_for "$f")" "DOMAIN='example.com' single-quoted sentinel (no proxy)"

# 6. Real DOMAIN -> proxy.
f=$(mkenv "DOMAIN=gate.test")
assert_eq "--profile autoheal --profile proxy" "$(profiles_for "$f")" "real DOMAIN adds proxy"

# 7. Empty single-quoted WG password -> no remote (matches env_gen LAN-only write).
f=$(mkenv "WG_INIT_PASSWORD=''")
assert_eq "--profile autoheal" "$(profiles_for "$f")" "empty WG_INIT_PASSWORD leaves remote inactive"

# 8-11. WG password present in every quoting style -> remote. Case 9 is the
# P0 bug repro: the old stack.sh grep matched ONLY single-quoted values, so a
# double-quoted WG password silently dropped --profile remote.
f=$(mkenv "WG_INIT_PASSWORD='secret'")
assert_eq "--profile autoheal --profile remote" "$(profiles_for "$f")" "single-quoted WG password adds remote"
f=$(mkenv 'WG_INIT_PASSWORD="secret"')
assert_eq "--profile autoheal --profile remote" "$(profiles_for "$f")" "double-quoted WG password adds remote (P0 grep-drift repro)"
f=$(mkenv "WG_INIT_PASSWORD=plain")
assert_eq "--profile autoheal --profile remote" "$(profiles_for "$f")" "unquoted WG password adds remote"
f=$(mkenv "WG_INIT_PASSWORD='p@ss=w0rd=x'")
assert_eq "--profile autoheal --profile remote" "$(profiles_for "$f")" "WG password containing '=' parses (split on first =)"

# 12. All knobs on -> full ordered set.
allon=$(mkenv "BAZARR_ENABLED=true" "AUTOHEAL_ENABLED=true" "DOMAIN=gate.test" "WG_INIT_PASSWORD='x'")
assert_eq "--profile subtitles --profile autoheal --profile proxy --profile remote" "$(profiles_for "$allon")" "all knobs on yields full ordered set"

# 13. Missing .env file -> defaults (autoheal only).
assert_eq "--profile autoheal" "$(profiles_for "$TMP_ROOT/does-not-exist")" "missing .env falls back to defaults"

# 14. Comments and blank lines are ignored.
f=$(mkenv "# a comment" "" "WG_INIT_PASSWORD='y'" "# trailing")
assert_eq "--profile autoheal --profile remote" "$(profiles_for "$f")" "comments and blanks are skipped"

# 15. Partial key names must NOT match (exact-key guard).
f=$(mkenv "BAZARR_ENABLEDX=true" "XAUTOHEAL_ENABLED=false")
assert_eq "--profile autoheal" "$(profiles_for "$f")" "non-exact key names do not match"

# set -e safety: the installer sources and calls this under `set -euo pipefail`.
# Force a full re-source (unset the include guard) inside a strict subshell so
# both the file-scope guard line and the function run under set -e.
strict_out=$( set -euo pipefail
              unset _MS_PROFILES_SH_LOADED
              source "$REPO_ROOT/scripts/lib/profiles.sh"
              a=(); _build_profile_args a "$allon"; echo "${a[*]}" )
strict_rc=$?
assert_eq "0" "$strict_rc" "builder runs cleanly under set -euo pipefail (rc 0)"
assert_eq "--profile subtitles --profile autoheal --profile proxy --profile remote" "$strict_out" "builder output is correct under strict mode"

scenario_end "$CURRENT_SCENARIO"
summary
