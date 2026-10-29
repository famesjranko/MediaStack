# Bazarr's subtitles profile is absent from fresh-install. Start it on the
# accepted lock, then seed user state before upgrade-path installs candidates.
upgrade_bazarr_prepare() {
    env_set BAZARR_ENABLED true
    local log=/tmp/ms-upgrade-bazarr.log
    if ! dind_exec 'docker compose --profile subtitles up -d bazarr' >"$log" 2>&1 \
        || ! wait_healthy bazarr 180; then
        fail 'upgrade-path starts accepted Bazarr'
        tail -30 "$log"
        return 1
    fi
    if ! dind_exec "MS_CONTRACT_TRACE=${CONTRACT_TRACE_DIR:-} UI_ASCII=1 ./scripts/configure.sh --only bazarr" >"$log" 2>&1; then
        fail 'upgrade-path configures accepted Bazarr'
        return 1
    fi
    wait_healthy bazarr 180 || return 1
    # Seed with the writers stopped. Retain the normal sync intervals; no
    # external provider or metadata lookup is needed for the local records.
    dind_exec 'docker compose stop bazarr sonarr radarr && python3 -I tests/fixtures/bazarr_media.py && python3 -I tests/fixtures/bazarr_state.py seed && docker compose --profile subtitles up -d bazarr' >>"$log" 2>&1 \
        && wait_healthy bazarr 180 \
        && dind_exec 'python3 -I tests/fixtures/bazarr_state.py save && python3 -I tests/fixtures/bazarr_state.py prove-history-loss' || {
        fail 'upgrade-path records accepted Bazarr subtitle state'
        tail -30 "$log"
        return 1
    }
    pass 'upgrade-path records accepted Bazarr subtitle history, user profiles and credentials'
    pass 'upgrade-path rejects lost Bazarr movie history and verifies its restoration'
}

upgrade_bazarr_check() {
    dind_exec 'python3 -I tests/fixtures/bazarr_state.py check'
}
