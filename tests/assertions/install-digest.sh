# Assertion: per-service install-digest recording.
# record_install (scripts/image_drift.py --record-install, wired into the real
# installer at stage1.sh) writes the digest each service came up running to
# config/state/image-install.tsv, giving day-2 "Revert to installed image" a
# channel-independent target. Only services with a resolvable local repo digest
# are recorded; undigestable ones are skipped.
#
# This scenario brings the stack up via `docker compose up -d` (inline in
# run_scenario, ~line 84), not the installer's perform_install, so the recorder
# hook never fires on its own. Invoke the same command here against the live
# stack — the real-docker E2E coverage the mocked unit test can't give. Safe as
# the last assertion: record_install overwrites (idempotent) and nothing
# downstream reads the file it writes.
assert_install_digest_recorded() {
    local file="config/state/image-install.tsv"
    local rows sha rec_err
    if ! rec_err=$(dind_exec "python3 scripts/image_drift.py --compose docker-compose.yml --record-install $file" 2>&1); then
        fail "install: image-install.tsv recorded" "recorder exited non-zero: $(echo "$rec_err" | tail -3 | tr '\n' ' ')"
        return
    fi
    rows=$(dind_exec "grep -vc '^#' $file 2>/dev/null || echo 0" | tr -d '[:space:]')
    if [[ "${rows:-0}" -ge 1 ]]; then
        pass "install: image-install.tsv recorded ($rows service digests)"
    else
        fail "install: image-install.tsv recorded" \
            "recorder ran but resolved no digests — check RepoDigests on the running images (save|load-sideloaded images can lack them)"
        return
    fi
    sha=$(dind_exec "grep -c 'sha256:' $file 2>/dev/null || echo 0" | tr -d '[:space:]')
    if [[ "${sha:-0}" == "$rows" ]]; then
        pass "install: every recorded row carries a sha256 digest"
    else
        fail "install: every recorded row carries a sha256 digest" "rows=$rows sha256=$sha"
    fi
}
