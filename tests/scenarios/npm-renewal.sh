# Real NPM + Pebble regression for #167. No public ACME or WAN credentials.

run_scenario() {
    dind_exec "docker compose down -v --remove-orphans >/dev/null 2>&1 || true"
    pebble_down
    dind_exec "rm -rf config/npm"
    dind_exec "cp .env.example .env"
    create_config_dirs_in_dind
    npm_acme_override
    # Given the installing user owns NPM's directories before its first start.
    dind_exec "chown -R 1000:1000 config/npm"

    if ! dind_exec "docker compose -f docker-compose.yml -f docker-compose.acme-test.yml --profile proxy up -d npm"; then
        fail "NPM renewal fixture starts"
        return 1
    fi
    wait_healthy npm 120 || return 1
    pebble_up && pebble_setup_dns || return 1

    # Given two HTTPS proxy hosts have independently issued Pebble certificates.
    if ! dind_exec "python3 tests/fixtures/npm_renewal.py seed"; then
        fail "NPM serves both initial certificates with correct SNI"
        return 1
    fi
    pass "NPM serves both initial certificates with correct SNI"

    # When each certificate renews through the real API.
    # Then fresh TLS connections serve that exact new leaf without a test reload.
    if dind_exec "python3 tests/fixtures/npm_renewal.py manual"; then
        pass "API renewal deploys both new certificates to HTTPS"
    else
        fail "API renewal deploys both new certificates to HTTPS"
        return 1
    fi

    # When the real scheduled renewal callback finds both certificates due.
    # Then both renewed leaves reach HTTPS without a test reload.
    if dind_exec "python3 tests/fixtures/npm_renewal.py scheduled"; then
        pass "scheduled renewal deploys both new certificates to HTTPS"
    else
        fail "scheduled renewal deploys both new certificates to HTTPS"
        return 1
    fi
}
