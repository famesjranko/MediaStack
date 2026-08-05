#!/usr/bin/env bash
# Structure gate: service-module shape and import-direction — split out of
# tests/naming.sh, which now owns filename casing and declared function
# prefixes only. See docs/project/structure.md "Adding a New Service" and
# "Dependency Direction".

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
    printf 'structure: %s\n' "$1" >&2
    exit 2
}

# -----------------------------------------------------------------------------
# Service-module shape gate: every scripts/services/<svc>/main.sh defines
# configure_<svc>() — the entry point scripts/configure.sh calls. A directory
# hyphen maps to an underscore in the function name (ddns-updater ->
# configure_ddns_updater). See docs/project/structure.md "Adding a New Service".
# Fails closed: an empty service population proves nothing.
# -----------------------------------------------------------------------------
service_mains_list=$(mktemp) || die "cannot create service-module list"
trap 'rm -f "$service_mains_list"' EXIT
git -C "$REPO_ROOT" ls-files -z 'scripts/services/*/main.sh' >"$service_mains_list" \
    || die "service-module discovery failed"

service_mains=()
mapfile -d '' -t service_mains <"$service_mains_list"
((${#service_mains[@]} > 0)) || die "no scripts/services/*/main.sh found — empty population"

shape_fail=0
for file in "${service_mains[@]}"; do
    svc="$(basename "$(dirname "$file")")"
    entry="configure_${svc//-/_}"
    if ! grep -qE "^${entry}[[:space:]]*\(\)" "$REPO_ROOT/$file"; then
        printf 'structure: %s does not define %s() — every service module must define its configurator; see docs/project/structure.md "Adding a New Service"\n' \
            "$file" "$entry" >&2
        shape_fail=1
    fi
done

((shape_fail == 0)) || exit 1

# -----------------------------------------------------------------------------
# Import-direction gate over docs/project/structure.md "Dependency Direction":
# a service module may not source another service's files or any setup
# module (the phase trees stay apart; shared logic belongs in lib/), and a
# module under scripts/setup/ may not source a peer top-level
# scripts/setup/*.sh module. Only the sanctioned seams below are exempt; each is documented in
# structure.md, and a listed seam that no longer exists is a stale entry that
# fails.
#
# `source` arguments are resolved by expanding the `$(cd "$(dirname
# "${BASH_SOURCE[0]}")…" && pwd)` directory variables the modules use; an
# argument that resolves to no *.sh path (a runtime `.env`, a variable this
# gate cannot resolve) is not an import edge and is skipped.
# -----------------------------------------------------------------------------
SANCTIONED_SEAMS=(
    # hardening.sh dispatches host-artefact teardown to the modules that own it.
    'scripts/setup/hardening.sh -> scripts/setup/gpu.sh'
    'scripts/setup/hardening.sh -> scripts/setup/storage.sh'
    'scripts/setup/hardening.sh -> scripts/setup/fail2ban.sh'
    # env-write.sh is a size split of env-gen.sh, not an independent module.
    'scripts/setup/env-gen.sh -> scripts/setup/env-write.sh'
)

# repo-relative dir of $1 joined with $2, with any `..` resolved
_join_path() {
    realpath -m --relative-to="$REPO_ROOT" "$REPO_ROOT/$1/$2"
}

# Prints `<file> -> <target>` for every source line whose argument resolves.
_import_edges() {
    local file="$1" dir line var arg target base suffix
    dir="$(dirname "$file")"
    local -A dirvars=([SCRIPT_DIR]=.)
    while IFS= read -r line; do
        var="${line%%=*}"
        case "$line" in
            *'BASH_SOURCE[0]'*)
                dirvars["$var"]="$dir$(sed -n 's/.*BASH_SOURCE\[0\]}")\([^"]*\)".*/\1/p' <<<"$line")"
                ;;
            *)
                # a directory variable derived from another one
                read -r base suffix < <(sed -n \
                    's/.*cd "\${\?\([A-Za-z_][A-Za-z0-9_]*\)}\?\/\?\([^"]*\)".*/\1 \2/p' <<<"$line")
                [[ -n "${dirvars["$base"]+set}" ]] || continue
                dirvars["$var"]=$(_join_path "${dirvars["$base"]}" "$suffix")
                ;;
        esac
    done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*="\$\(cd ".*&& pwd\)"' "$REPO_ROOT/$file")

    while IFS= read -r arg; do
        [[ "$arg" == *.sh ]] || continue
        [[ "$arg" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/(.*)$ ]] || continue
        var="${BASH_REMATCH[1]}"
        [[ -n "${dirvars["$var"]+set}" ]] || continue
        target=$(_join_path "${dirvars["$var"]}" "${BASH_REMATCH[2]}")
        printf '%s -> %s\n' "$file" "$target"
    done < <(grep -oE '^[[:space:]]*(source|\.)[[:space:]]+"[^"]+"' "$REPO_ROOT/$file" \
        | sed 's/.*"\(.*\)"/\1/')
}

import_files_list=$(mktemp) || die "cannot create import-population list"
trap 'rm -f "$service_mains_list" "$import_files_list"' EXIT
git -C "$REPO_ROOT" ls-files -z 'scripts/services/*.sh' 'scripts/setup/*.sh' >"$import_files_list" \
    || die "import-population discovery failed"

import_files=()
mapfile -d '' -t import_files <"$import_files_list"
((${#import_files[@]} > 0)) || die "no service or setup module found — empty import population"

declare -A seam_seen=()
import_fail=0
edge_count=0
for file in "${import_files[@]}"; do
    while IFS= read -r edge; do
        [[ -n "$edge" ]] || continue
        edge_count=$((edge_count + 1))
        target="${edge#* -> }"
        reason=""
        if [[ "$file" == scripts/services/* && "$target" == scripts/services/* ]]; then
            src_svc="${file#scripts/services/}"
            dst_svc="${target#scripts/services/}"
            [[ "${src_svc%%/*}" == "${dst_svc%%/*}" ]] \
                || reason="a service module may not source another service"
        elif [[ "$file" == scripts/services/* && "$target" == scripts/setup/* ]]; then
            reason="a service module may not source a setup module — shared logic belongs in lib/"
        elif [[ "$file" == scripts/setup/* && "$target" == scripts/setup/*.sh && "$target" != */*/*/* && "$file" != "$target" ]]; then
            reason="a setup module may not source a peer scripts/setup module"
        fi
        [[ -n "$reason" ]] || continue
        for seam in "${SANCTIONED_SEAMS[@]}"; do
            if [[ "$edge" == "$seam" ]]; then
                seam_seen["$seam"]=1
                reason=""
                break
            fi
        done
        [[ -n "$reason" ]] || continue
        printf 'structure: %s: %s (%s) — see docs/project/structure.md "Dependency Direction"\n' \
            "$file" "$edge" "$reason" >&2
        import_fail=1
    done < <(_import_edges "$file")
done

((edge_count > 0)) || die "no import edge resolved — empty import-edge population"

for seam in "${SANCTIONED_SEAMS[@]}"; do
    [[ -n "${seam_seen["$seam"]+seen}" ]] \
        || die "stale sanctioned seam (that import no longer exists): $seam"
done

((import_fail == 0)) || exit 1

printf 'structure: %s service modules checked for their configurator; %s import edges checked\n' \
    "${#service_mains[@]}" "$edge_count"
