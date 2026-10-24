#!/usr/bin/env bash
# Owns: restore points for per-service image updates - a snapshot of a service's
#   MediaStack-managed config dir taken before its image moves, the restore on
#   Revert, and the post-revert "is it up and can MediaStack still log in" check.
# Sources: launcher globals (SCRIPT_DIR, ui_log, _service_is_running), common.sh
#   helpers (curl_header_stdin, api_get_key, service_local_url) and, lazily,
#   scripts/services/qbittorrent/main.sh for the shared qBittorrent login.
#
# Why: an image update can let the newer version rewrite its config in a form the
# older image cannot read (qBittorrent 5.3 -> 5.2 drops the WebUI password and logs
# a temporary one). Reverting only the image then leaves the service broken.
#
# Layout, next to config/state/image-policy.tsv (the pin state):
#   config/state/restore-points/<svc>.tar.gz             config/<svc> before the update
#   config/state/restore-points/<svc>.pre-revert.tar.gz  config/<svc> just before a restore
#   config/state/restore-points.tsv                      service<TAB>UTC time<TAB>archive
# Only config/<svc> is archived, never the media or download paths, and a dir over
# _MU_RESTORE_MAX_KB is skipped so one update cannot fill the config disk.

_MU_RESTORE_MAX_KB=262144

_restore_dir() { printf '%s\n' "$SCRIPT_DIR/config/state/restore-points"; }
_restore_index() { printf '%s\n' "$SCRIPT_DIR/config/state/restore-points.tsv"; }

# $1 service, $2 slot: "point" (default) or "pre-revert".
_restore_archive() {
    local slot="${2:-point}"
    if [[ "$slot" == "point" ]]; then
        printf '%s/%s.tar.gz\n' "$(_restore_dir)" "$1"
    else
        printf '%s/%s.%s.tar.gz\n' "$(_restore_dir)" "$1" "$slot"
    fi
}

_restore_index_clear() {
    local file tmp
    file="$(_restore_index)"
    [[ -f "$file" ]] || return 0
    tmp=$(mktemp)
    awk -F '\t' -v s="$1" '$1 != s' "$file" >"$tmp"
    mv "$tmp" "$file"
}

_restore_index_set() {
    _restore_index_clear "$1"
    printf '%s\t%s\t%s\n' "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$(_restore_archive "$1")")" \
        >>"$(_restore_index)"
}

_restore_point_exists() {
    [[ -f "$(_restore_archive "$1")" ]] \
        && awk -F '\t' -v s="$1" '$1 == s { found = 1 } END { exit !found }' "$(_restore_index)" 2>/dev/null
}

_discard_restore_point() {
    rm -f "$(_restore_archive "$1")" "$(_restore_archive "$1" pre-revert)"
    _restore_index_clear "$1"
}

# Archive config/<svc> into the slot. Returns 0 saved, 2 nothing to save (no config
# dir), 1 failed (reason logged). The archive holds secrets (API keys, password
# hashes), so it is created owner-only.
_snapshot_config() {
    local svc="$1" slot="${2:-point}" cfg="$SCRIPT_DIR/config/$1" arc kb part
    [[ -d "$cfg" ]] || return 2
    # A database copied while its service runs can be torn mid-write, and Revert
    # would then restore a corrupt one. Callers stop the service first.
    if _service_is_running "$svc"; then
        ui_log warn "${svc}: not copying config/${svc} while ${svc} runs (a database could be copied mid-write)."
        return 1
    fi
    kb=$(du -sk "$cfg" 2>/dev/null | cut -f1)
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        ui_log warn "${svc}: could not measure config/${svc}."
        return 1
    fi
    if ((kb > _MU_RESTORE_MAX_KB)); then
        ui_log warn "${svc}: config/${svc} is $((kb / 1024)) MiB, over the $((_MU_RESTORE_MAX_KB / 1024)) MiB limit for a restore point."
        return 1
    fi
    arc="$(_restore_archive "$svc" "$slot")"
    part="${arc}.part"
    if ! (
        umask 077
        mkdir -p "$(_restore_dir)"
        tar -czf "$part" -C "$SCRIPT_DIR/config" "$svc"
    ) 2>/dev/null; then
        rm -f "$part"
        ui_log warn "${svc}: could not archive config/${svc} (unreadable files?)."
        return 1
    fi
    mv "$part" "$arc"
}

# Take the restore point for an image update. The previous point (if any) belongs
# to an older image move, so it goes first - a stale point must never be restored.
_take_restore_point() {
    local svc="$1" rc=0
    _discard_restore_point "$svc"
    _snapshot_config "$svc" || rc=$?
    case "$rc" in
        0)
            _restore_index_set "$svc"
            ui_log info "${svc}: saved a restore point of config/${svc} (Revert puts it back with the old image)."
            ;;
        2) ;;
        *) ui_log warn "${svc}: no restore point saved - Revert will not be able to restore its config." ;;
    esac
    return 0
}

# Replace config/<svc> with the archive. The caller stops the service first.
# The archive is unpacked beside the live dir and swapped in whole, so files the
# newer version created (a SQLite -wal/-shm next to the restored .db) cannot
# survive. The old dir is deleted only after the swap succeeded.
_restore_config() {
    local svc="$1" arc cfg stage
    cfg="$SCRIPT_DIR/config/$svc"
    _service_is_running "$svc" && return 1
    arc="$(_restore_archive "$svc" "${2:-point}")"
    [[ -f "$arc" ]] || return 1
    stage="$(mktemp -d "${cfg}.restore.XXXXXX")" || return 1
    if ! tar -xzf "$arc" -C "$stage" --no-same-owner 2>/dev/null || [[ ! -d "$stage/$svc" ]]; then
        rm -rf "$stage"
        return 1
    fi
    if [[ -d "$cfg" ]] && ! mv "$cfg" "$stage/aside"; then
        rm -rf "$stage"
        return 1
    fi
    if ! mv "$stage/$svc" "$cfg"; then
        [[ -d "$stage/aside" ]] && mv "$stage/aside" "$cfg"
        rm -rf "$stage"
        return 1
    fi
    rm -rf "$stage"
}

# Pre-start hooks for _recreate_service. It runs them with the old container
# stopped and the new one not yet started, so config copies are consistent.
# Update: take the restore point (a failure only warns; the update goes on).
_restore_hook_snapshot() { _take_restore_point "$1"; }

# qBittorrent 5.3 stores its whitelist in [WebUI], which 5.2 does not read.
# The target image has already been pulled when this hook runs, while the point
# still holds the old config, so inspect its actual metadata before the swap.
_warn_qbt_restore_layout_incompatible() {
    local svc="$1" arc layout target_ref version
    [[ "$svc" == qbittorrent ]] || return 0
    arc="$(_restore_archive "$svc")"
    declare -F qbt_config_has_webui_whitelist >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../services/qbittorrent/main.sh"
    layout=$(mktemp) || return 0
    if ! tar -xzOf "$arc" qbittorrent/qBittorrent/qBittorrent.conf >"$layout" 2>/dev/null \
        || ! qbt_config_has_webui_whitelist "$layout"; then
        rm -f "$layout"
        return 0
    fi
    rm -f "$layout"
    target_ref="$(_install_image_ref "$svc")"
    if ! version=$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$target_ref" 2>/dev/null); then
        ui_log warn "${svc}: the restore point has the newer [WebUI] whitelist layout, but it could not be checked against the target image."
        return 0
    fi
    case "$version" in
        5.2.*)
            ui_log warn "${svc}: the restore point has the newer [WebUI] whitelist layout, but qBittorrent 5.2.x cannot read it."
            ui_log warn "Its auth whitelist will not take effect, so Sonarr and Radarr get 403. Update qBittorrent again to recover."
            ;;
        5.[3-9].* | 5.[1-9][0-9].* | [6-9].* | [1-9][0-9].*) ;;
        *)
            ui_log warn "${svc}: the restore point has the newer [WebUI] whitelist layout, but it could not be checked against the target image."
            ;;
    esac
}

# Revert: keep a safety copy of the newer config, then put the old config back.
_restore_hook_point() {
    rm -f "$(_restore_archive "$1" pre-revert)"
    ui_log info "${1}: saving a safety copy of its current config..."
    if ! _snapshot_config "$1" pre-revert; then
        ui_log error "${1}: could not save a safety copy of the current config; its config was not changed."
        return 1
    fi
    _warn_qbt_restore_layout_incompatible "$1"
    ui_log info "${1}: restoring its config from the restore point..."
    _restore_config "$1" point
}
# Failed revert: put the newer config back (nothing to do if the safety copy was never made).
_restore_hook_pre_revert() {
    [[ -f "$(_restore_archive "$1" pre-revert)" ]] || return 0
    ui_log info "${1}: putting its previous config back..."
    _restore_config "$1" pre-revert
}

# Wait for a running, non-unhealthy container. Stricter than _wait_service_running,
# which treats a slow start as fine: a revert must prove the service came back.
_verify_service_up() {
    local svc="$1" i health
    for ((i = 0; i < 30; i++)); do
        if _service_is_running "$svc"; then
            health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$svc" 2>/dev/null || echo "")
            [[ -z "$health" || "$health" == "healthy" ]] && return 0
            [[ "$health" == "unhealthy" ]] && return 1
        fi
        sleep 2
    done
    return 1
}

# Can MediaStack still log in to the service? Returns 0 yes, 1 no, 2 not checkable
# here (credential missing), 3 MediaStack does not log in to this service.
# A few spaced tries only: qBittorrent bans the client after repeated bad logins.
_service_login_check() {
    local svc="$1" url key attempt jar body rc=1
    case "$svc" in
        qbittorrent)
            [[ -n "${JELLYFIN_ADMIN_PASSWORD:-}" ]] || return 2
            declare -F _qbt_login_shared >/dev/null || source "$SCRIPT_DIR/scripts/services/qbittorrent/main.sh"
            url="$(service_local_url qbittorrent)"
            jar=$(mktemp)
            for attempt in 1 2 3 4; do
                _qbt_login_shared "$jar" "$url" && {
                    rc=0
                    break
                }
                sleep 3
            done
            rm -f "$jar"
            return "$rc"
            ;;
        sonarr | radarr)
            key="$(api_get_key "$SCRIPT_DIR/config/$svc/config.xml")"
            [[ -n "$key" ]] || return 2
            url="$(service_local_url "$svc")/api/v3/system/status"
            for attempt in 1 2 3 4; do
                curl_header_stdin "X-Api-Key" "$key" -sf -o /dev/null "$url" && return 0
                sleep 3
            done
            return 1
            ;;
        jellyfin)
            [[ -n "${JELLYFIN_ADMIN_PASSWORD:-}" ]] || return 2
            declare -F wait_for_jellyfin_auth >/dev/null || source "$SCRIPT_DIR/scripts/lib/http.sh"
            body=$(JF_USER="${JELLYFIN_ADMIN_USER:-admin}" JF_PW="$JELLYFIN_ADMIN_PASSWORD" python3 -c '
import json, os
print(json.dumps({"Username": os.environ["JF_USER"], "Pw": os.environ["JF_PW"]}))')
            # It polls while Jellyfin's auth backend warms up, and stops early on a refused login.
            wait_for_jellyfin_auth "$(service_local_url jellyfin)" \
                'MediaBrowser Client="MediaStack", Device="launcher", DeviceId="mediastack-revert", Version="1"' \
                "$body" 30 >/dev/null
            return $(($? == 0 ? 0 : 1))
            ;;
        *) return 3 ;;
    esac
}

# After a revert: the service must be up and, where MediaStack logs in to it, the
# login must still work. Failure is reported in full - this is the check that the
# image-only revert lacked. A service that is stopped was only staged: skip.
_verify_reverted_service() {
    local svc="$1" rc=0
    _service_is_running "$svc" || return 0
    if ! _verify_service_up "$svc"; then
        ui_log error "${svc}: reverted, but it did not come back healthy. Check: docker logs ${svc}"
        return 1
    fi
    _service_login_check "$svc" || rc=$?
    case "$rc" in
        0) ui_log ok "${svc}: back up and MediaStack can still log in." ;;
        1)
            ui_log error "${svc}: reverted and running, but MediaStack can no longer log in to it."
            ui_log error "Its config may not match the older image. Update ${svc} again to move it forward."
            return 1
            ;;
        2) ui_log warn "${svc}: back up, but the login could not be checked (credentials not available)." ;;
    esac
    return 0
}

# Revert a service to the image it was installed with, together with the config it
# had then. No restore point means the config may be newer than the image, so ask.
# Any failure after the config swap puts the previous config back before returning.
_reset_service_to_default() {
    local svc="$1" install_ref prior has_point=0 point_hook="" undo_hook=""
    install_ref="$(_install_image_ref "$svc")"
    prior="$(_service_policy_raw "$svc")"
    if _restore_point_exists "$svc"; then
        has_point=1
    elif [[ -d "$SCRIPT_DIR/config/$svc" ]]; then
        ui_log warn "${svc}: no restore point for its config. The config may already be newer than the installed image,"
        ui_log warn "and an older version can fail to read it (qBittorrent, for one, can lose its WebUI password)."
        ui_confirm "Revert the ${svc} image anyway, without restoring its config?" no || {
            ui_log info "Left ${svc} unchanged."
            return 1
        }
    fi
    if ((has_point)); then
        point_hook=_restore_hook_point
        undo_hook=_restore_hook_pre_revert
    fi
    if [[ -z "$install_ref" ]]; then
        ui_log warn "${svc}: no recorded install digest; clearing its override instead."
        _clear_service_policy "$svc"
    else
        _set_service_policy "$svc" "$install_ref"
    fi
    ui_log info "${svc}: reverting to the image it was installed with..."
    _regenerate_override || {
        ui_log error "Could not regenerate compose override."
        return 1
    }
    storage_guard_before_start || return 1
    if _recreate_service "$svc" "${svc} reverted to its installed image." "$point_hook" "${point_hook:+swapped}"; then
        if _verify_reverted_service "$svc"; then
            _discard_restore_point "$svc"
            return 0
        fi
        ((has_point)) && ui_log error "${svc}: the restore point and a copy of the newer config are kept in $(_restore_dir)."
        return 1
    fi
    # Recreate failed. A digest pin can point at an unfetchable image (and a restored
    # config no longer matches the image it came from): restore the prior override and
    # config, then bring the service back up (onto its previous cached image when that
    # pull also fails, else its prior tracking-tag image).
    if [[ -n "$install_ref" ]] || ((has_point)); then
        ui_log warn "${svc}: revert failed (the installed image may no longer be available); restoring its previous image and config."
        _restore_service_policy_row "$svc" "$prior"
        _regenerate_override || {
            ui_log error "Could not regenerate compose override."
            return 1
        }
        # The first attempt stopped a running service and its `up -d` failed: it is
        # still down, so bring it back up rather than report it as staged.
        local resume=""
        ((${_MU_STOPPED_HERE:-0})) && resume=resume
        _recreate_service "$svc" "${svc} restored to its previous image." "$undo_hook" "$resume" || return 1
    fi
    return 1
}
