# Owns: Stage 1 install-plan rendering and confirmation choice.
# Sources: Docker Compose, wizard UI, `SCRIPT_DIR`/`AUTOHEAL_ENABLED`, and `_WIZ_*` state.

_stage1_confirm() {
    ui_section 10 10 "Confirm install plan"

    # _stage1_preflight_nas_choice exports DATA_DIR/STORAGE_* (so the NAS mount
    # helper sees them) and restores them to their pre-preflight values — which are
    # EMPTY on a fresh install — without dropping the export attribute, so they
    # linger in the environment. docker compose gives the process environment
    # precedence over --env-file, so a leaked empty DATA_DIR turns the compose bind
    # "${DATA_DIR}:/data" into ":/data" ("invalid spec: :/data") and the config
    # below reports zero services -> the misleading "Cannot enumerate services"
    # abort. Drop them here so the install plan reflects .env.example; the real
    # install re-derives them from the _WIZ_* values when it writes and sources .env.
    unset DATA_DIR STORAGE_MODE STORAGE_MOUNTPOINT STORAGE_NFS_HOST STORAGE_NFS_EXPORT \
        STORAGE_NFS_OPTS STORAGE_SENTINEL STORAGE_EXPECTED_SOURCE STORAGE_EXPECTED_FSTYPE

    local -a compose_args=(--env-file "$SCRIPT_DIR/.env.example")
    if [[ "${_WIZ_BAZARR_ENABLED:-false}" == "true" ]]; then
        compose_args+=(--profile subtitles)
    fi
    if [[ "${AUTOHEAL_ENABLED:-true}" != "false" ]]; then
        compose_args+=(--profile autoheal)
    fi

    local services_raw service_count image_count
    services_raw=$(docker compose "${compose_args[@]}" config --services 2>/dev/null || true)
    if [[ -z "$services_raw" ]]; then
        # Removed the hardcoded fallback list — it omitted unpackerr
        # and flaresolverr (both default-profile services per docs/project/stack.md), so
        # users hit the fallback would have seen an inaccurate plan, clicked
        # Install, and gotten more services than promised. A non-technical
        # audience needs trustworthy commit screens; better to fail loudly
        # than guess.
        log_error "Cannot enumerate services for install plan. Is docker-compose.yml present and is the Docker daemon reachable?"
        exit 1
    fi
    service_count=$(printf '%s\n' "$services_raw" | awk 'NF {count++} END {print count + 0}')
    image_count=$(docker compose "${compose_args[@]}" config --images 2>/dev/null | awk 'NF {count++} END {print count + 0}')

    ui_box "Core Media Server: Install Plan" \
        "$(ui_kv 'Services' "${service_count:-0} core containers")" \
        "$(ui_kv 'Images' "${image_count:-0}")" \
        "$(ui_kv 'Image channel' "${_WIZ_IMAGE_CHANNEL:-stable}")" \
        "$(ui_kv 'Storage' "${_WIZ_STORAGE_MODE:-local} at ${_WIZ_DATA_DIR:-/data} (${_WIZ_STORAGE_APP_WIRING:-managed} app wiring)")" \
        "$(ui_kv 'Indexer preset' "$([[ "${_WIZ_PUBLIC_INDEXERS_ENABLED:-false}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Firewall' "$([[ "${_WIZ_UFW_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Hardening' "$([[ "${_WIZ_HARDENING_ENABLED:-true}" == "true" ]] && echo enabled || echo disabled)")" \
        "$(ui_kv 'Time' '5-7 minutes on first run')" \
        "$(ui_kv 'Access' 'no public access - LAN only')" \
        "$(ui_kv 'Result' 'Working media server on your LAN')"

    _STAGE1_CONFIRM_ACTION=$(ui_choose "Proceed with Stage 1 installation?" \
        "Install" \
        "Back" \
        "Abort")
}
