# =============================================================================
# Shared nvidia-patch pinning and verification helpers
# =============================================================================
# Sourced by setup GPU helpers and scripts/nvidia-repatch.sh. This file keeps
# the reviewed upstream commit in one place so no caller executes moving
# nvidia-patch code as root.

NVIDIA_PATCH_REPO_URL="https://github.com/keylase/nvidia-patch.git"
NVIDIA_PATCH_REPO_COMMIT="0e665c46a87ba99b41a07169fa3acf6162739648"

_nvidia_patch_log() {
    local level="$1"
    local message="$2"
    local fn="log_${level}"
    local tag

    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn" "$message"
        return
    fi

    case "$level" in
        ok) tag="OK" ;;
        warn) tag="WARN" ;;
        error) tag="ERROR" ;;
        *) tag="INFO" ;;
    esac
    printf '[%s] %s\n' "$tag" "$message" >&2
}

nvidia_patch_expected_commit() {
    printf '%s\n' "$NVIDIA_PATCH_REPO_COMMIT"
}

nvidia_patch_readme_url() {
    printf 'https://raw.githubusercontent.com/keylase/nvidia-patch/%s/README.md\n' \
        "$NVIDIA_PATCH_REPO_COMMIT"
}

nvidia_patch_clean_tree() {
    local patch_dir="$1"
    local status

    [[ -d "$patch_dir/.git" ]] || return 1
    status=$(git -C "$patch_dir" status --porcelain --untracked-files=all 2>/dev/null) || return 1
    [[ -z "$status" ]]
}

_nvidia_patch_origin_ok() {
    local patch_dir="$1"
    local origin

    origin=$(git -C "$patch_dir" remote get-url origin 2>/dev/null || true)
    case "$origin" in
        "$NVIDIA_PATCH_REPO_URL"|"https://github.com/keylase/nvidia-patch")
            return 0
            ;;
    esac

    _nvidia_patch_log warn "Refusing nvidia-patch tree with unexpected origin: ${origin:-none}"
    return 1
}

nvidia_patch_prepare_repo() {
    local patch_dir="$1"
    local parent head

    if [[ -z "$patch_dir" ]]; then
        _nvidia_patch_log warn "No nvidia-patch directory supplied"
        return 1
    fi

    if [[ -e "$patch_dir" && ! -d "$patch_dir/.git" ]]; then
        _nvidia_patch_log warn "Refusing non-git nvidia-patch path: $patch_dir"
        return 1
    fi

    if [[ -d "$patch_dir/.git" ]]; then
        _nvidia_patch_origin_ok "$patch_dir" || return 1
        if ! nvidia_patch_clean_tree "$patch_dir"; then
            _nvidia_patch_log warn "Refusing dirty nvidia-patch tree at $patch_dir"
            _nvidia_patch_log warn "Remove local changes or delete .nvidia-patch, then retry."
            return 1
        fi
    else
        parent=$(dirname "$patch_dir")
        mkdir -p "$parent" || return 1
        _nvidia_patch_log info "Cloning nvidia-patch at reviewed commit ${NVIDIA_PATCH_REPO_COMMIT:0:12}..."
        if ! git clone -q --no-checkout "$NVIDIA_PATCH_REPO_URL" "$patch_dir"; then
            _nvidia_patch_log warn "nvidia-patch clone failed"
            return 1
        fi
    fi

    if ! git -C "$patch_dir" cat-file -e "${NVIDIA_PATCH_REPO_COMMIT}^{commit}" 2>/dev/null; then
        _nvidia_patch_log info "Fetching reviewed nvidia-patch commit ${NVIDIA_PATCH_REPO_COMMIT:0:12}..."
        if ! git -C "$patch_dir" fetch -q origin; then
            _nvidia_patch_log warn "Could not fetch reviewed nvidia-patch commit ${NVIDIA_PATCH_REPO_COMMIT}"
            return 1
        fi
    fi

    if ! git -C "$patch_dir" checkout -q --detach "$NVIDIA_PATCH_REPO_COMMIT"; then
        _nvidia_patch_log warn "Could not check out reviewed nvidia-patch commit ${NVIDIA_PATCH_REPO_COMMIT}"
        return 1
    fi

    if ! nvidia_patch_clean_tree "$patch_dir"; then
        _nvidia_patch_log warn "nvidia-patch tree became dirty after checkout"
        return 1
    fi

    head=$(git -C "$patch_dir" rev-parse HEAD 2>/dev/null) || return 1
    if [[ "$head" != "$NVIDIA_PATCH_REPO_COMMIT" ]]; then
        _nvidia_patch_log warn "nvidia-patch HEAD is $head, expected $NVIDIA_PATCH_REPO_COMMIT"
        return 1
    fi

    if ! git -C "$patch_dir" ls-tree -r --name-only "$NVIDIA_PATCH_REPO_COMMIT" -- patch.sh \
        | grep -Fxq "patch.sh"; then
        _nvidia_patch_log warn "Reviewed nvidia-patch commit does not contain patch.sh"
        return 1
    fi

    _nvidia_patch_log info "nvidia-patch verified at ${NVIDIA_PATCH_REPO_COMMIT:0:12}"
    return 0
}

nvidia_patch_export_run_tree() {
    local patch_dir="$1"
    local head run_dir

    head=$(git -C "$patch_dir" rev-parse HEAD 2>/dev/null) || return 1
    if [[ "$head" != "$NVIDIA_PATCH_REPO_COMMIT" ]]; then
        _nvidia_patch_log warn "Refusing to export unverified nvidia-patch HEAD $head"
        return 1
    fi

    if ! nvidia_patch_clean_tree "$patch_dir"; then
        _nvidia_patch_log warn "Refusing to export dirty nvidia-patch tree"
        return 1
    fi

    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/mediastack-nvidia-patch.XXXXXX") || return 1
    chmod 700 "$run_dir" || {
        rm -rf "$run_dir"
        return 1
    }

    if ! git -C "$patch_dir" archive --format=tar "$NVIDIA_PATCH_REPO_COMMIT" | tar -x -C "$run_dir"; then
        rm -rf "$run_dir"
        _nvidia_patch_log warn "Could not export reviewed nvidia-patch tree"
        return 1
    fi

    if [[ ! -f "$run_dir/patch.sh" ]]; then
        rm -rf "$run_dir"
        _nvidia_patch_log warn "Exported nvidia-patch tree is missing patch.sh"
        return 1
    fi

    printf '%s\n' "$run_dir"
}
