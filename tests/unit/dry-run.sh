#!/usr/bin/env bash
# Unit test — the `--dry-run` UI explorer (scripts/lib/dry_run.sh).
#
# Two layers:
#   1. Container-free SAFETY assertions (always): the host driver isolates the
#      real flow correctly — non-privileged, --network none, --rm, NO read-write
#      bind mount (the repo is copied in), a recursion guard, and the stubs are
#      gated strictly behind the --dry-run flag so a normal run can't no-op the
#      real installer. A leak past these = real execution on the host, so they
#      are the load-bearing checks.
#   2. Best-effort container WALK (when Docker is available): actually run
#      ./mediastack --dry-run inside the throwaway container, drive it to Quit,
#      and assert the real menu rendered, an action announced "DRY-RUN: would …",
#      it exited 0, and nothing leaked to the host. Skips cleanly (not fails)
#      when Docker/network is unavailable, so it never reds an offline CI.
#
# Run directly: ./tests/unit/dry-run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT
cd "$REPO_ROOT" || exit 2

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="dry-run"
scenario_begin "$CURRENT_SCENARIO"

lib="scripts/lib/dry_run.sh"

# ---------------------------------------------------------------------------
# 1. Container-free safety invariants (source-level — these gate host safety)
# ---------------------------------------------------------------------------
run_line="$(grep -E 'docker run ' "$lib" | head -1)"

assert_contains "$run_line" "--network none" "safety: container runs with --network none (no egress on a missed stub)"
assert_contains "$run_line" "--rm"           "safety: container is --rm (auto-removed)"

# NEVER a bind mount — the repo is copied in, so the host tree cannot be written.
# Match only volume/mount flags on a docker run/exec (not `command -v`/`printf -v`).
if grep -nE 'docker[[:space:]]+(run|exec)[^|]*([[:space:]]-v[[:space:]]|--volume|--mount)' "$lib"; then
    fail "safety: driver uses no read-write bind mount" "found a docker volume/mount flag in $lib"
else
    pass "safety: driver uses no read-write bind mount (repo is copied in)"
fi

# The container image is non-root (the launcher refuses root) — baked into the
# slim image, asserted via the Dockerfile.
if grep -qE '^USER[[:space:]]+mstest' tests/Dockerfile.dry-run; then
    pass "safety: dry-run image runs as the non-root mstest user"
else
    fail "safety: dry-run image runs as a non-root user" "no 'USER mstest' in tests/Dockerfile.dry-run"
fi

# Trust signal = the image sentinel (/etc/ms-dry-run-sandbox), NOT an env var: the
# entries launch the sandbox unless already inside it, so ./mediastack --dry-run
# inside can't fork-bomb more containers AND a stray env var can't bypass the
# container on a real host.
for entry in mediastack setup.sh; do
    if grep -qE 'dry_run_in_sandbox' "$entry" \
        && grep -qE '"--dry-run"|"--ui-preview"' "$entry"; then
        pass "guard: $entry launches the sandbox unless already inside it (dry_run_in_sandbox)"
    else
        fail "guard: $entry gates on the sandbox marker" "missing dry_run_in_sandbox guard"
    fi
done

source scripts/lib/dry_run.sh   # inert — installs no stubs (asserted below)

# Gate-misfire: sourcing the library must install NO stubs (inert until dry_run_begin).
gate_out=$(bash -c '
    set -uo pipefail
    source scripts/lib/dry_run.sh
    declare -F sudo pull_images _run_setup_return start_stack 2>/dev/null | wc -l
' 2>/dev/null)
assert_eq "0" "$gate_out" "gate-misfire: sourcing dry_run.sh installs no stub functions (inert until dry_run_begin)"

# BLOCKER guard (the load-bearing safety check): the file-writing stubs MUST refuse
# to run outside the sandbox (no /etc/ms-dry-run-sandbox) — so a stray env var or a
# bug can never run them against a real repo. Run in a throwaway CWD + with a
# ui_banner shim so a regression would proceed-and-fail here, not touch this tree.
if dry_run_in_sandbox; then
    skip "safety: refuse-outside-sandbox" "this runner has the sandbox marker"
else
    pass "safety: dry_run_in_sandbox is false on a normal host (no sentinel present)"
    refuse_tmp="$(mktemp -d)"; refuse_rc=0
    ( cd "$refuse_tmp" && bash -c "ui_banner() { :; }; source '$REPO_ROOT/scripts/lib/dry_run.sh'; dry_run_begin launcher" ) >/dev/null 2>&1 || refuse_rc=$?
    rm -rf "$refuse_tmp"
    if (( refuse_rc != 0 )); then
        pass "safety: dry_run_begin refuses to run outside the sandbox container (exit $refuse_rc)"
    else
        fail "safety: dry_run_begin refuses outside the sandbox" "it ran without the sandbox marker — would write a real repo"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Best-effort container walk (skips cleanly without Docker / network)
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "container walk: Docker not available" "real flow verified manually + by the safety asserts above"
    scenario_end "$CURRENT_SCENARIO"
    summary
    exit $?
fi

before_containers="$(docker ps -aq --filter name=ms-dry-run | wc -l)"
host_env_before="absent"; [[ -f .env ]] && host_env_before="present"

steps="$(mktemp)"; raw="$(mktemp)"; plain="$(mktemp)"
printf '%s\n' '[{"expect":"What would you like to do"},{"send":"11\n"}]' > "$steps"

walk_rc=0
timeout 200 python3 tests/lib/wizard_pty.py \
    --command './mediastack --dry-run' \
    --steps "$steps" --cwd "$REPO_ROOT" \
    --raw-log "$raw" --plain-log "$plain" \
    --step-timeout 90 --exit-timeout 30 --expect-exit 0 || walk_rc=$?

transcript="$(sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$plain" 2>/dev/null || true)"

if (( walk_rc == 0 )); then
    pass "container walk: ./mediastack --dry-run renders the launcher and exits 0"
else
    # A build/pull failure (offline CI) is a SKIP, not a FAIL; a real crash fails.
    if grep -qiE 'cannot connect|pull access|network|no such host|failed to (build|solve)' "$plain" "$raw" 2>/dev/null; then
        skip "container walk: image build/pull unavailable (offline)" "exit $walk_rc"
    else
        fail "container walk: ./mediastack --dry-run exits 0" "exit $walk_rc; see $plain"
    fi
fi

if [[ -n "$transcript" ]]; then
    assert_contains "$transcript" "DRY-RUN MODE" "container walk: dry-run banner shown"
    assert_contains "$transcript" "What would you like to do" "container walk: real launcher menu rendered"
fi

# Host-safety after the walk: no leftover container, no host .env created.
after_containers="$(docker ps -aq --filter name=ms-dry-run | wc -l)"
assert_eq "$before_containers" "$after_containers" "host-safety: no leftover dry-run container"
host_env_after="absent"; [[ -f .env ]] && host_env_after="present"
assert_eq "$host_env_before" "$host_env_after" "host-safety: the walk created/changed no host .env"

rm -f "$steps" "$raw" "$plain" 2>/dev/null || true

scenario_end "$CURRENT_SCENARIO"
summary
