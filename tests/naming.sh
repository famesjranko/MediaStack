#!/usr/bin/env bash
# Filename-casing gate: tracked *.sh basenames must be kebab-case, tracked
# *.py basenames must be snake_case (docs/conventions.md "Identifier and
# file naming"). tests/shell-naming.allowlist is a shrink-only ratchet of the
# offenders that predate this gate — mirrors tests/shell-line-cap.sh's
# allowlist semantics but with no per-file value to track, so it is a plain
# path list: an entry may only be removed, never added, and a listed path
# that is no longer tracked or now conforms is a stale entry that fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOWLIST="$REPO_ROOT/tests/shell-naming.allowlist"
SH_PATTERN='^[a-z0-9]+(-[a-z0-9]+)*\.sh$'
PY_PATTERN='^[a-z0-9_]+\.py$'

die() {
    printf 'naming: %s\n' "$1" >&2
    exit 2
}

tracked_file_list=$(mktemp) || die "cannot create tracked-file list"
base_allowlist=$(mktemp) || die "cannot create base allowlist"
trap 'rm -f "$tracked_file_list" "$base_allowlist"' EXIT

base_ref=""
if base_ref=$(git -C "$REPO_ROOT" rev-parse HEAD^ 2>/dev/null); then
    :
else
    base_ref=HEAD
fi

if ! git -C "$REPO_ROOT" ls-files -z '*.sh' '*.py' >"$tracked_file_list"; then
    die "tracked file discovery failed"
fi

tracked_files=()
mapfile -d '' -t tracked_files <"$tracked_file_list"
((${#tracked_files[@]} > 0)) || die "tracked population is empty"

declare -A offending=()
for file in "${tracked_files[@]}"; do
    base="$(basename "$file")"
    case "$file" in
        *.sh)
            [[ "$base" =~ $SH_PATTERN ]] || offending["$file"]=1
            ;;
        *.py)
            [[ "$base" =~ $PY_PATTERN ]] || offending["$file"]=1
            ;;
    esac
done

declare -A tracked_set=()
for file in "${tracked_files[@]}"; do
    tracked_set["$file"]=1
done

base_allowlist_exists=false
if git -C "$REPO_ROOT" cat-file -e "$base_ref:tests/shell-naming.allowlist" 2>/dev/null; then
    base_allowlist_exists=true
    git -C "$REPO_ROOT" show "$base_ref:tests/shell-naming.allowlist" >"$base_allowlist" \
        || die "cannot read base allowlist"
fi

declare -A base_allowed=()
while IFS= read -r file || [[ -n "$file" ]]; do
    [[ -z "$file" ]] && continue
    base_allowed["$file"]=1
done <"$base_allowlist"

declare -A allowed=()
if [[ -e "$ALLOWLIST" ]]; then
    [[ -r "$ALLOWLIST" ]] || die "allowlist is unreadable: $ALLOWLIST"
    while IFS= read -r file || [[ -n "$file" ]]; do
        [[ -z "$file" ]] && continue
        [[ -z "${allowed["$file"]+present}" ]] \
            || die "duplicate allowlist entry: $file"
        [[ -n "${tracked_set["$file"]+tracked}" ]] \
            || die "stale allowlist entry (file is not tracked): $file"
        [[ -n "${offending["$file"]+offending}" ]] \
            || die "stale allowlist entry (file now conforms): $file"
        if [[ "$base_allowlist_exists" == true && -z "${base_allowed["$file"]+baseline}" ]]; then
            die "new allowlist entry is not permitted: $file"
        fi
        allowed["$file"]=1
    done <"$ALLOWLIST"
fi

fail=0
for file in "${!offending[@]}"; do
    [[ -n "${allowed["$file"]+allowlisted}" ]] && continue
    printf 'naming: %s does not match the required casing for its extension — see docs/conventions.md "Identifier and file naming"\n' "$file" >&2
    fail=1
done

((fail == 0)) || exit 1

# -----------------------------------------------------------------------------
# Declared function-prefix gate: a module under scripts/ (or the root
# `mediastack` dispatcher) opts in by putting a
# `<prefix>_*` token on its `# Owns:` line (first 5 lines) — see
# docs/conventions.md "Identifier and file naming". Once declared, every
# function def in that file must start with a declared prefix, allowing one
# optional leading `_` for a file-private helper; `main` is the entry-point
# exemption. Fails closed: zero declaring files proves nothing.
# -----------------------------------------------------------------------------
TOKEN_PATTERN='[a-z][a-z0-9_]*_\*'
DEF_PATTERN='^_?[a-z0-9_]+[[:space:]]*\(\)'

prefix_files_list=$(mktemp) || die "cannot create prefix-file list"
trap 'rm -f "$tracked_file_list" "$base_allowlist" "$prefix_files_list"' EXIT
git -C "$REPO_ROOT" ls-files -z 'scripts/*.sh' 'mediastack' >"$prefix_files_list" \
    || die "prefix-population discovery failed"

declared_files=()
mapfile -d '' -t declared_candidates <"$prefix_files_list"

prefix_fail=0
for file in "${declared_candidates[@]}"; do
    tokens=$(sed -n '1,5p' "$REPO_ROOT/$file" | grep '^# Owns:' | grep -oE "$TOKEN_PATTERN" | sort -u)
    [[ -n "$tokens" ]] || continue
    declared_files+=("$file")
    pattern=$(sed 's/_\*$//' <<<"$tokens" | paste -sd '|' -)
    while IFS=: read -r lineno defline; do
        name="${defline%%(*}"
        name="${name%%[[:space:]]*}"
        name="${name#_}"
        [[ "$name" == "main" ]] && continue
        if ! [[ "$name" =~ ^($pattern)_ ]]; then
            printf 'naming: %s:%s: %s() does not match declared prefix(es) [%s] — see docs/conventions.md "Identifier and file naming"\n' \
                "$file" "$lineno" "$name" "$(tr '\n' ' ' <<<"$tokens")" >&2
            prefix_fail=1
        fi
    done < <(grep -nE "$DEF_PATTERN" "$REPO_ROOT/$file")
done

if ((${#declared_files[@]} == 0)); then
    die "no prefix-population file declares a function prefix — empty population"
fi

((prefix_fail == 0)) || exit 1

# -----------------------------------------------------------------------------
# Service-module shape gate: every scripts/services/<svc>/main.sh defines
# configure_<svc>() — the entry point scripts/configure.sh calls. A directory
# hyphen maps to an underscore in the function name (ddns-updater ->
# configure_ddns_updater). See docs/project/structure.md "Adding a New Service".
# Fails closed: an empty service population proves nothing.
# -----------------------------------------------------------------------------
service_mains_list=$(mktemp) || die "cannot create service-module list"
trap 'rm -f "$tracked_file_list" "$base_allowlist" "$prefix_files_list" "$service_mains_list"' EXIT
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
        printf 'naming: %s does not define %s() — every service module must define its configurator; see docs/project/structure.md "Adding a New Service"\n' \
            "$file" "$entry" >&2
        shape_fail=1
    fi
done

((shape_fail == 0)) || exit 1

# -----------------------------------------------------------------------------
# Import-direction gate over docs/project/structure.md "Dependency Direction":
# a service module may not source another service's files, and nothing under
# scripts/setup/ may source a peer top-level scripts/setup/*.sh module. Only
# the sanctioned seams below are exempt; each is documented in structure.md,
# and a listed seam that no longer exists is a stale entry that fails.
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
trap 'rm -f "$tracked_file_list" "$base_allowlist" "$prefix_files_list" "$service_mains_list" "$import_files_list"' EXIT
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
        elif [[ "$target" == scripts/setup/*.sh && "$target" != */*/*/* && "$file" != "$target" ]]; then
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
        printf 'naming: %s: %s (%s) — see docs/project/structure.md "Dependency Direction"\n' \
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

printf 'naming: %s tracked shell/python files checked (%s allowlisted); %s scripts/*.sh files checked for declared function prefixes; %s service modules checked for their configurator; %s import edges checked\n' \
    "${#tracked_files[@]}" "${#allowed[@]}" "${#declared_files[@]}" "${#service_mains[@]}" "$edge_count"
