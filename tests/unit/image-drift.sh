#!/usr/bin/env bash
# Unit test - scripts/image-drift.py snapshot and accept flow.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="image-drift"
scenario_begin "$CURRENT_SCENARIO"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat >"$TMP_DIR/previous.tsv" <<'EOF'
# MediaStack tested image digest record v1
# Update only after the matching local DinD preflight has passed.
service	image	digest	tested_at_utc	preflight
jellyfin	jellyfin/jellyfin:latest	sha256:1111111111111111111111111111111111111111111111111111111111111111	2026-01-01T00:00:00Z	scenario:fresh-install
EOF

cat >"$TMP_DIR/current.tsv" <<'EOF'
# MediaStack tested image digest record v1
# Update only after the matching local DinD preflight has passed.
service	image	digest	tested_at_utc	preflight
jellyfin	jellyfin/jellyfin:latest	sha256:2222222222222222222222222222222222222222222222222222222222222222		scenario:fresh-install
EOF

cat >"$TMP_DIR/upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| jellyfin | latest | stable | scenario:fresh-install | test |
<!-- upgrades-manifest:end -->
EOF

badges=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --readme-badges 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift README badges render exits zero"
assert_contains "$badges" "Stable image baseline: 1 pinned digests" "image-drift README badge includes lock row count"
assert_contains "$badges" "docs/operations/day-2.md" "image-drift README badge links to user-facing update guidance"
if [[ "$(grep -c '^\[!\[' <<<"$badges")" == "1" ]]; then
    pass "image-drift README badge block contains one generated badge"
else
    fail "image-drift README badge block contains one generated badge" "expected=1"
fi

cat >"$TMP_DIR/README.md" <<'EOF'
# Example

<!-- stable-image-badges:start -->
stale badges
<!-- stable-image-badges:end -->
EOF

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --write-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?
readme_text=$(cat "$TMP_DIR/README.md")

assert_eq "0" "$rc" "image-drift README badge write exits zero"
assert_contains "$output" "updated" "image-drift README badge write reports update"
assert_contains "$readme_text" "Stable image baseline: 1 pinned digests" "image-drift README badge write replaces marked block"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --check-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift README badge check exits zero when current"
assert_contains "$output" "current" "image-drift README badge check reports current"

sed -i 's/1%20pinned/2%20pinned/' "$TMP_DIR/README.md"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --check-readme-badges "$TMP_DIR/README.md" 2>&1)
rc=$?

assert_eq "1" "$rc" "image-drift README badge check fails when stale"
assert_contains "$output" "out of date" "image-drift README badge check explains stale block"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --current-file "$TMP_DIR/current.tsv" \
    --snapshot-current "$TMP_DIR/snapshot.tsv" 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift snapshot exits zero with current-file"
assert_contains "$output" "snapshot written" "image-drift snapshot reports output path"
if grep -q 'sha256:2222222222222222222222222222222222222222222222222222222222222222' "$TMP_DIR/snapshot.tsv"; then
    pass "image-drift snapshot writes exact current digest"
else
    fail "image-drift snapshot writes exact current digest"
fi

accepted="$TMP_DIR/accepted.tsv"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --current-file "$TMP_DIR/snapshot.tsv" \
    --write-current "$accepted" \
    --accept-current \
    --no-verify-preflight \
    --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?

assert_eq "0" "$rc" "image-drift accept exits zero with current-file"
assert_contains "$output" "Image drift accepted" "image-drift accept reports accepted baseline"
if grep -q $'jellyfin\tjellyfin/jellyfin:latest\tsha256:2222222222222222222222222222222222222222222222222222222222222222\t2026-06-01T00:00:00Z\tscenario:fresh-install' "$accepted"; then
    pass "image-drift accept writes exact preflighted snapshot"
else
    fail "image-drift accept writes exact preflighted snapshot"
fi

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/previous.tsv" \
    --upgrades "$TMP_DIR/upgrades.md" \
    --write-current "$TMP_DIR/unsafe.tsv" \
    --accept-current 2>&1)
rc=$?

assert_eq "1" "$rc" "image-drift accept rejects live re-resolution"
assert_contains "$output" "--accept-current requires --current-file" "image-drift accept explains current-file requirement"

# --- selective accept (--accept-services) -----------------------------------
# Fixture: a baseline with DISTINCT old timestamps (so preservation is provable),
# plus three candidate snapshots — a matched-set digest drift, an added service,
# and a removed service. printf keeps the literal tabs honest.
SHA_A="sha256:$(printf 'a%.0s' {1..64})" # sonarr previous
SHA_B="sha256:$(printf 'b%.0s' {1..64})" # radarr previous
SHA_C="sha256:$(printf 'c%.0s' {1..64})" # sonarr current (drifted)
SHA_D="sha256:$(printf 'd%.0s' {1..64})" # radarr current (drifted)
SHA_E="sha256:$(printf 'e%.0s' {1..64})" # jackett (unchanged)
SHA_G="sha256:$(printf 'g%.0s' {1..64})" # homepage (added)

{
    printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n'
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t2020-01-01T00:00:00Z\tscenario:fresh-install\n' "$SHA_A"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\t2020-02-02T00:00:00Z\tscenario:fresh-install\n' "$SHA_B"
    printf 'jackett\tlinuxserver/jackett:latest\t%s\t2020-03-03T00:00:00Z\tscenario:fresh-install\n' "$SHA_E"
} >"$TMP_DIR/sel-previous.tsv"

{
    printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n'
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_C"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_D"
    printf 'jackett\tlinuxserver/jackett:latest\t%s\t\tscenario:fresh-install\n' "$SHA_E"
} >"$TMP_DIR/sel-matched.tsv"

{
    cat "$TMP_DIR/sel-matched.tsv"
    printf 'homepage\tghcr.io/gethomepage/homepage:latest\t%s\t\tscenario:fresh-install\n' "$SHA_G"
} >"$TMP_DIR/sel-added.tsv"

{
    printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n'
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_C"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\t\tscenario:fresh-install\n' "$SHA_D"
} >"$TMP_DIR/sel-removed.tsv"

cat >"$TMP_DIR/sel-upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| sonarr | latest | stable | scenario:fresh-install | x |
| radarr | latest | stable | scenario:fresh-install | x |
| jackett | latest | stable | scenario:fresh-install | x |
<!-- upgrades-manifest:end -->
EOF

sel_base=(--previous "$TMP_DIR/sel-previous.tsv" --upgrades "$TMP_DIR/sel-upgrades.md")

# Selective accept of one drifted service writes that row and preserves the rest.
merged="$TMP_DIR/sel-merged.tsv"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$merged" \
    --no-verify-preflight \
    --accept-services sonarr --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift selective accept exits zero"
assert_contains "$output" "Selectively accepted drifted services: sonarr" "image-drift selective accept reports the accepted service"
assert_contains "$output" "Drifted services left pending: radarr" "image-drift selective accept reports the pending drift"

exp_sonarr=$(printf 'sonarr\tlinuxserver/sonarr:latest\t%s\t2026-06-01T00:00:00Z\tscenario:fresh-install' "$SHA_C")
if grep -qF "$exp_sonarr" "$merged"; then
    pass "image-drift selective accept writes the selected drifted digest + fresh timestamp"
else
    fail "image-drift selective accept writes the selected drifted digest + fresh timestamp"
fi
exp_radarr=$(printf 'radarr\tlinuxserver/radarr:latest\t%s\t2020-02-02T00:00:00Z\tscenario:fresh-install' "$SHA_B")
if grep -qF "$exp_radarr" "$merged"; then
    pass "image-drift selective accept preserves the unselected drifted row and its old timestamp"
else
    fail "image-drift selective accept preserves the unselected drifted row and its old timestamp"
fi
if grep -qF "$SHA_D" "$merged"; then
    fail "image-drift selective accept excludes the unaccepted drifted digest"
else
    pass "image-drift selective accept excludes the unaccepted drifted digest"
fi
exp_jackett=$(printf 'jackett\tlinuxserver/jackett:latest\t%s\t2020-03-03T00:00:00Z\tscenario:fresh-install' "$SHA_E")
if grep -qF "$exp_jackett" "$merged"; then
    pass "image-drift selective accept preserves the unchanged row verbatim"
else
    fail "image-drift selective accept preserves the unchanged row verbatim"
fi

# Multiple services, comma-separated: both accepted, the unchanged row preserved.
merged2="$TMP_DIR/sel-merged2.tsv"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$merged2" \
    --no-verify-preflight \
    --accept-services sonarr,radarr --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift selective multi-accept exits zero"
exp_radarr_new=$(printf 'radarr\tlinuxserver/radarr:latest\t%s\t2026-06-01T00:00:00Z\tscenario:fresh-install' "$SHA_D")
if grep -qF "$exp_radarr_new" "$merged2" && grep -qF "$exp_jackett" "$merged2"; then
    pass "image-drift selective multi-accept updates both selected rows, preserves the rest"
else
    fail "image-drift selective multi-accept updates both selected rows, preserves the rest"
fi

# A snapshot that adds a service is refused (structural change needs --accept-current).
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-added.tsv" --write-current "$TMP_DIR/sel-x.tsv" \
    --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept refuses an added service"
assert_contains "$output" "added: homepage" "image-drift selective accept names the added service"
assert_contains "$output" "--accept-current" "image-drift selective accept points added services at full accept"

# A snapshot that removes a service is refused too.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-removed.tsv" --write-current "$TMP_DIR/sel-x.tsv" \
    --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept refuses a removed service"
assert_contains "$output" "removed: jackett" "image-drift selective accept names the removed service"

# Invalid selectors fail clearly.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/sel-x.tsv" \
    --accept-services bogus 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept rejects an unknown service"
assert_contains "$output" "unknown service 'bogus'" "image-drift selective accept explains the unknown service"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/sel-x.tsv" \
    --accept-services sonarr,sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept rejects a duplicate selector"
assert_contains "$output" "duplicate service" "image-drift selective accept explains the duplicate"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/sel-x.tsv" \
    --accept-services jackett 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept rejects a non-drifted service"
assert_contains "$output" "has not drifted" "image-drift selective accept explains the non-drifted selector"

# Arg guards: mutual exclusion is reported before the current-file requirement.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --accept-services sonarr --accept-current 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept is mutually exclusive with full accept"
assert_contains "$output" "mutually exclusive" "image-drift selective accept explains the mutual exclusion first"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --write-current "$TMP_DIR/sel-x.tsv" --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept requires a frozen current-file"
assert_contains "$output" "requires --current-file" "image-drift selective accept explains the current-file requirement"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift selective accept requires a write-current destination"
assert_contains "$output" "requires --write-current" "image-drift selective accept explains the write-current requirement"

# The drift summary offers a copy-paste selective-accept command for the drifted
# services, but only when no service was added or removed.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" 2>&1)
rc=$?
assert_eq "2" "$rc" "image-drift summary exits 2 on unaccepted drift"
assert_contains "$output" "--accept-services sonarr,radarr" "image-drift summary offers a selective-accept command"
assert_contains "$output" "--write-readme-badges README.md" "image-drift summary closes with the README badge regen step"

output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-added.tsv" 2>&1)
if printf '%s' "$output" | grep -qF -- "--accept-services"; then
    fail "image-drift summary omits the selective command when the service set changed"
else
    pass "image-drift summary omits the selective command when the service set changed"
fi

# The badge-regen closing step only makes sense when there was drift to accept;
# the no-drift early return must stay a plain one-liner.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-previous.tsv" 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift summary exits zero when nothing drifted"
assert_contains "$output" "No compose image digest changes detected" "image-drift summary reports no drift"
if printf '%s' "$output" | grep -qF -- "--write-readme-badges"; then
    fail "image-drift summary omits the badge regen step when nothing drifted"
else
    pass "image-drift summary omits the badge regen step when nothing drifted"
fi

# --record-install writes the local install-digest set, and read_policy tolerates
# a digest-pin value (normalized to the 'pinned' token by the status formatters). Run
# in-process with the docker readers monkeypatched - the real docker path is exercised
# end-to-end by the DinD fresh-install scenario.
rec_out=$(
    python3 - "$REPO_ROOT" "$TMP_DIR" <<'PY' 2>&1
import sys, pathlib, importlib.util
repo, tmp = sys.argv[1], pathlib.Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("idrift", f"{repo}/scripts/image-drift.py")
m = importlib.util.module_from_spec(spec)
sys.modules["idrift"] = m
spec.loader.exec_module(m)

# read_policy accepts stable/latest AND a <image>@sha256 pin.
pol = tmp / "policy.tsv"
pol.write_text("# h\nsonarr\tlatest\nradarr\tlscr.io/x/radarr:latest@sha256:" + "a" * 64 + "\n")
p = m.read_policy(pol)
print("POLICY_OK" if p.get("sonarr") == "latest" and m._is_pin(p.get("radarr", "")) else "POLICY_BAD")

# record_install writes service<TAB>image<TAB>digest for each running service (skips
# services with no resolvable local digest).
m.load_compose_images = lambda _p: [("sonarr", "lscr.io/x/sonarr:latest"),
                                     ("radarr", "lscr.io/x/radarr:latest"),
                                     ("ghost", "lscr.io/x/ghost:latest")]
m.container_image_id = lambda s: None if s == "ghost" else "img-" + s
m.image_repo_digest = lambda i, img: "sha256:" + "b" * 64
out = tmp / "image-install.tsv"
m.record_install(pathlib.Path("docker-compose.yml"), out)
rows = [l for l in out.read_text().splitlines() if l and not l.startswith("#")]
ok = (len(rows) == 2
      and all(len(r.split("\t")) == 3 for r in rows)
      and rows[0].startswith("sonarr\tlscr.io/x/sonarr:latest\tsha256:")
      and not any(r.startswith("ghost") for r in rows))
print("RECORD_OK" if ok else "RECORD_BAD:" + repr(rows))
PY
)
assert_contains "$rec_out" "POLICY_OK" "image-drift read_policy accepts a digest pin value"
assert_contains "$rec_out" "RECORD_OK" "image-drift --record-install writes the service/image/digest set, skipping undigestable services"

# --- preflight-receipt accept gate ------------------------------------------
# image-drift.py refuses to accept a drifted digest into the lock unless
# tests/run.sh recorded a passing preflight for that exact image@digest under the
# service's manifest scenario. Reuses the selective-accept baseline above
# (sonarr SHA_A->SHA_C, radarr SHA_B->SHA_D, both scenario:fresh-install).
gate_receipt="$TMP_DIR/receipt.tsv"

# (a) No receipt -> selective accept is refused, naming the service + run command,
# and the lock is never written.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-x.tsv" \
    --preflight-receipt "$TMP_DIR/no-such-receipt.tsv" \
    --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift accept gate refuses a digest with no preflight receipt"
assert_contains "$output" "no passing local preflight receipt" "image-drift accept gate explains the missing receipt"
assert_contains "$output" "./tests/run.sh fresh-install" "image-drift accept gate prints the preflight command to run"
if [[ -f "$TMP_DIR/gate-x.tsv" ]]; then
    fail "image-drift accept gate leaves the lock unwritten when blocked" "gate-x.tsv exists"
else
    pass "image-drift accept gate leaves the lock unwritten when blocked"
fi

# (b) A matching receipt (image, digest, scenario) unblocks the accept.
printf 'sonarr\tlinuxserver/sonarr:latest\t%s\tfresh-install\n' "$SHA_C" >"$gate_receipt"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-ok.tsv" \
    --preflight-receipt "$gate_receipt" \
    --accept-services sonarr --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift accept gate passes with a matching receipt"
assert_contains "$output" "Selectively accepted drifted services: sonarr" "image-drift accept gate writes the accepted row when vouched"

# (c) A receipt for the right digest but the wrong scenario does not vouch.
printf 'sonarr\tlinuxserver/sonarr:latest\t%s\tsmoke\n' "$SHA_C" >"$gate_receipt"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-x2.tsv" \
    --preflight-receipt "$gate_receipt" \
    --accept-services sonarr 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift accept gate rejects a receipt from the wrong scenario"
assert_contains "$output" "no passing local preflight receipt" "image-drift accept gate ignores a wrong-scenario receipt"

# (d) --no-verify-preflight bypasses the gate with a loud warning.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-bypass.tsv" \
    --preflight-receipt "$TMP_DIR/no-such-receipt.tsv" --no-verify-preflight \
    --accept-services sonarr 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift accept gate is bypassable with --no-verify-preflight"
assert_contains "$output" "no-verify-preflight" "image-drift accept gate warns loudly when bypassed"

# (e) accept-current is gated the same way; only drifted rows need a receipt.
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-ac.tsv" \
    --preflight-receipt "$TMP_DIR/no-such-receipt.tsv" \
    --accept-current 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift accept-current gate refuses untested drift"
assert_contains "$output" "sonarr" "image-drift accept-current gate names an unproven drifted service"
if [[ -f "$TMP_DIR/gate-ac.tsv" ]]; then
    fail "image-drift accept-current gate leaves the lock unwritten when blocked" "gate-ac.tsv exists"
else
    pass "image-drift accept-current gate leaves the lock unwritten when blocked"
fi

{
    printf 'sonarr\tlinuxserver/sonarr:latest\t%s\tfresh-install\n' "$SHA_C"
    printf 'radarr\tlinuxserver/radarr:latest\t%s\tfresh-install\n' "$SHA_D"
} >"$gate_receipt"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/gate-ac-ok.tsv" \
    --preflight-receipt "$gate_receipt" \
    --accept-current --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift accept-current gate passes when every drifted row is vouched"
assert_contains "$output" "Image drift accepted" "image-drift accept-current gate writes the baseline when vouched"

# (f) A non-scenario preflight tier (compose-only/manual) has no automated receipt,
# so the gate warns but does not block.
cat >"$TMP_DIR/nonscn-previous.tsv" <<EOF
service	image	digest	tested_at_utc	preflight
demo	example/demo:latest	$SHA_A	2020-01-01T00:00:00Z	compose-only
EOF
cat >"$TMP_DIR/nonscn-current.tsv" <<EOF
service	image	digest	tested_at_utc	preflight
demo	example/demo:latest	$SHA_C		compose-only
EOF
cat >"$TMP_DIR/nonscn-upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| demo | latest | stable | compose-only | x |
<!-- upgrades-manifest:end -->
EOF
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/nonscn-previous.tsv" --upgrades "$TMP_DIR/nonscn-upgrades.md" \
    --current-file "$TMP_DIR/nonscn-current.tsv" --write-current "$TMP_DIR/nonscn-ok.tsv" \
    --preflight-receipt "$TMP_DIR/no-such-receipt.tsv" \
    --accept-services demo --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift accept gate allows a compose-only tier without a receipt"
assert_contains "$output" "no automated" "image-drift accept gate warns that a non-scenario tier is unverified"

# (g) An added service whose preflight token is empty (absent from the upgrades
# manifest) is NOT a recognized non-scenario tier, so the gate blocks fail-closed
# instead of warning it through — an unmanifested service cannot slip an untested
# digest into the lock via --accept-current.
cat >"$TMP_DIR/orphan-previous.tsv" <<EOF
service	image	digest	tested_at_utc	preflight
sonarr	linuxserver/sonarr:latest	$SHA_A	2020-01-01T00:00:00Z	scenario:fresh-install
EOF
cat >"$TMP_DIR/orphan-current.tsv" <<EOF
service	image	digest	tested_at_utc	preflight
sonarr	linuxserver/sonarr:latest	$SHA_A	2020-01-01T00:00:00Z	scenario:fresh-install
orphan	example/orphan:latest	$SHA_C
EOF
cat >"$TMP_DIR/orphan-upgrades.md" <<'EOF'
<!-- upgrades-manifest:start -->
| Service | Pin policy | API stability | Preflight | Touchpoint |
|---|---|---|---|---|
| sonarr | latest | stable | scenario:fresh-install | x |
<!-- upgrades-manifest:end -->
EOF
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/orphan-previous.tsv" --upgrades "$TMP_DIR/orphan-upgrades.md" \
    --current-file "$TMP_DIR/orphan-current.tsv" --write-current "$TMP_DIR/orphan-out.tsv" \
    --preflight-receipt "$TMP_DIR/no-such-receipt.tsv" \
    --accept-current --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift accept gate blocks an added service with no recognized preflight tier"
assert_contains "$output" "not a recognized oracle" "image-drift accept gate names the unrecognized preflight tier"
if [[ -f "$TMP_DIR/orphan-out.tsv" ]]; then
    fail "image-drift accept gate leaves the lock unwritten for an unmanifested service" "orphan-out.tsv exists"
else
    pass "image-drift accept gate leaves the lock unwritten for an unmanifested service"
fi

# (h) With no previous baseline there is nothing to gate against; recording the
# fresh baseline warns that the digests are unverified unless --no-verify-preflight
# vouches for them by hand.
printf 'service\timage\tdigest\ttested_at_utc\tpreflight\n' >"$TMP_DIR/empty-previous.tsv"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/empty-previous.tsv" --upgrades "$TMP_DIR/orphan-upgrades.md" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/bootstrap.tsv" \
    --accept-current --tested-at 2026-06-01T00:00:00Z 2>&1)
rc=$?
assert_eq "0" "$rc" "image-drift records a fresh baseline when no previous lock exists"
assert_contains "$output" "no prior lock to gate against" "image-drift warns a fresh baseline is unverified by the gate"
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$TMP_DIR/empty-previous.tsv" --upgrades "$TMP_DIR/orphan-upgrades.md" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/bootstrap2.tsv" \
    --accept-current --no-verify-preflight --tested-at 2026-06-01T00:00:00Z 2>&1)
if echo "$output" | grep -qF "no prior lock to gate against"; then
    fail "image-drift bootstrap warning suppressed by --no-verify-preflight" "warning still printed"
else
    pass "image-drift bootstrap warning suppressed by --no-verify-preflight"
fi

# (i) --write-current with drift present but NO accept flag is an output destination,
# not an accept — it must refuse rather than smuggle a drifted digest into the lock
# past the receipt gate, and leave the lock unwritten. (sel-matched drifts sonarr and
# radarr off sel-previous.)
output=$(python3 "$REPO_ROOT/scripts/image-drift.py" "${sel_base[@]}" \
    --current-file "$TMP_DIR/sel-matched.tsv" --write-current "$TMP_DIR/nowrite.tsv" 2>&1)
rc=$?
assert_eq "1" "$rc" "image-drift --write-current with drift and no accept flag is refused"
assert_contains "$output" "without an accept flag" "image-drift --write-current names the missing accept flag"
if [[ -f "$TMP_DIR/nowrite.tsv" ]]; then
    fail "image-drift --write-current leaves the lock unwritten when refusing drift" "nowrite.tsv exists"
else
    pass "image-drift --write-current leaves the lock unwritten when refusing drift"
fi

scenario_end "$CURRENT_SCENARIO"
summary
