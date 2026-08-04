# tests/scenarios/api-matrix.sh — DinD API-matrix test layer.
#
# Once the API-bearing services are up, drive their configuration APIs DIRECTLY
# (reusing the product renderers) through a matrix of states and assert each one
# lands live — amortizing a single bring-up across many in-place API tests.
# Unlike the configure.sh path (idempotent, warn-on-drift), this mutates the
# live API across states, so it can prove the full parameter space.
#
# Modules live under tests/api-matrix/<service>.sh and are sourced + called here:
#   - quality        Sonarr/Radarr quality profiles (resolution x size cells,
#                    in-place PUT-rename) — the render->API contract.
#   - quality-rename Day-2 "change quality profile": seed cell A, change to
#                    cell B with QP_RENAME_FROM, assert in-place rename (same id,
#                    new scores, no orphan) through the PRODUCT configurators.
#   - qbittorrent Config-driven setup plus the surgical day-2 speed-limit action.
#   - jackett     Indexer enable/skip + FlareSolverr-URL/admin-password
#                 set-once cycles, re-run idempotency — the deterministic,
#                 local part of configure_jackett. Live Torznab/Cloudflare
#                 reachability stays wizard-presets.sh's job.
#   - jellyfin    Library config match/drift/absent branches plus the exact
#                 Sonarr/Radarr->Jellyfin notification wiring, including
#                 idempotent re-run. Encoding/streaming/networking/server-name
#                 stay fresh-install's job (already covered at their default).
#   - seerr       Sonarr/Radarr->Seerr connection wiring (host, port, quality
#                 profile, root dir, season folders / minimum availability),
#                 including idempotent re-run. Runs after jellyfin (which
#                 already created the SSO admin this module's login needs —
#                 the same ordering configure.sh itself uses); library
#                 sync/quotas/trustProxy stay covered at their default point
#                 by fresh-install's assert_seerr_configured.
# Each new day-2 action that mutates a service API still gets a module here.
#
# Wall-time budget: ~9-13 min (Sonarr, Radarr, qBittorrent, Jackett, Jellyfin,
# and Seerr are brought up; Jackett's FlareSolverr-config-set restart adds
# ~20-30s once, Jellyfin's first-run wizard plus its one networking-triggered
# container recreate adds ~60-90s once, and configure_seerr's own
# auth/library-sync polling adds a few minutes on top).
#
# Convention: every module drives one stateful, dependent sequence —
# each step's preconditions assume the previous one landed. On a precondition
# miss, a module does `fail "...";skip "<dropped block>" "<why>";return` (or
# `continue` inside a per-item loop) rather than falling through into
# assertions whose target state was never reached. The `skip()` call is ONE
# call per cascade site, not one per dropped assertion — exact downstream
# counts are loop/state-dependent (e.g. the per-app, per-cell loops below) and
# enumerating them individually would drift out of sync as modules evolve.
# Treat the first `[FAIL]` in a module's output as the signal that everything
# named in the paired `[SKIP]` line was not run, not as a precise inventory of
# what was skipped.

source tests/api-matrix/bringup.sh
source tests/api-matrix/quality.sh
source tests/api-matrix/quality-rename.sh
source tests/api-matrix/qbittorrent.sh
source tests/api-matrix/jackett.sh
source tests/api-matrix/jellyfin.sh
source tests/api-matrix/seerr.sh

run_scenario() {
    # ------------------------------------------------------------------
    # 0-2. Prep, bring-up, and API keys — shared with contract-drift.sh
    # (tests/api-matrix/bringup.sh), so this scenario and the drift replayer
    # never grow two bring-up implementations.
    # ------------------------------------------------------------------
    api_matrix_bring_up || return 1
    local sonarr_key="$API_MATRIX_SONARR_KEY" radarr_key="$API_MATRIX_RADARR_KEY"

    # ------------------------------------------------------------------
    # 3. Module test-1: quality profiles (Sonarr + Radarr)
    # ------------------------------------------------------------------
    [[ -n "$sonarr_key" ]] && matrix_quality sonarr "http://localhost:8989/api/v3" "$sonarr_key"
    [[ -n "$radarr_key" ]] && matrix_quality radarr "http://localhost:7878/api/v3" "$radarr_key"

    # ------------------------------------------------------------------
    # 4. Module test-2: day-2 in-place rename through the product path
    # ------------------------------------------------------------------
    [[ -n "$sonarr_key" ]] && matrix_quality_rename sonarr "http://localhost:8989/api/v3" "$sonarr_key"
    [[ -n "$radarr_key" ]] && matrix_quality_rename radarr "http://localhost:7878/api/v3" "$radarr_key"

    # ------------------------------------------------------------------
    # 5. Module test-3: qBittorrent setup + surgical day-2 speed limits
    # ------------------------------------------------------------------
    matrix_qbittorrent matrix-admin ApiMatrixQbtPassword123

    # ------------------------------------------------------------------
    # 6. Module test-4: Jackett indexer enable/skip + server-state cycles
    # ------------------------------------------------------------------
    # Deliberately reuses the qBittorrent module's shared admin password —
    # Jackett's admin password is the same JELLYFIN_ADMIN_PASSWORD value.
    matrix_jackett ApiMatrixQbtPassword123

    # ------------------------------------------------------------------
    # 7. Module test-5: Jellyfin library config + Sonarr/Radarr notifications
    # ------------------------------------------------------------------
    if [[ -n "$sonarr_key" && -n "$radarr_key" ]]; then
        matrix_jellyfin "$sonarr_key" "http://localhost:8989/api/v3" "$radarr_key" "http://localhost:7878/api/v3"
    fi

    # ------------------------------------------------------------------
    # 8. Module test-6: Sonarr/Radarr -> Seerr connection wiring
    # ------------------------------------------------------------------
    if [[ -n "$sonarr_key" && -n "$radarr_key" ]]; then
        matrix_seerr "$sonarr_key" "http://localhost:8989/api/v3" "$radarr_key" "http://localhost:7878/api/v3" \
            matrix-admin ApiMatrixQbtPassword123
    fi
}
