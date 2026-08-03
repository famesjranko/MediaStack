#!/usr/bin/env bash
# tests/unit/upgrades-manifest.sh
#
# Keeps docs/operations/upgrades.md honest against the live docker-compose.yml. Pure bash +
# python3 — no DinD, no Docker, no network. Run directly: ./tests/unit/upgrades-manifest.sh
#
# Checks:
#   - presence: every compose service has a manifest row (no missing/stale/duplicate)
#   - policy<->tag: each row's strict pin-policy token matches the live tag
#   - preflight validity: each preflight token resolves to a real oracle
#   - lock<->manifest: accepted image records keep the same preflight confidence tier
#   - scenario coverage: a `scenario:X` row's service is actually started by X,
#     checked against the explicit SCENARIO_COVERAGE map below (scenario ->
#     profiles/services it launches) — catches a row claiming a scenario that
#     never launches the service (the bazarr class)
#   - README Stable-baseline badge is regenerated from the current lock (catches
#     a lock-restamping commit that forgot the image-updates.md step 9 badge
#     regen — see scripts/image-drift.py --check-readme-badges)
# docker-compose.yml stays the single source of truth for tags; this guard makes
# the manifest's policy claims self-checking.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="upgrades-manifest"
echo -e "${CYAN}${BOLD}▶ scenario: upgrades-manifest${NC}"

results=$(
    python3 - <<'PYEOF'
import os, re, sys, yaml

REPO = os.environ["REPO_ROOT"]
out = []

# 1. Live compose services + resolved tags.
with open(os.path.join(REPO, "docker-compose.yml")) as f:
    compose = yaml.safe_load(f) or {}
services = compose.get("services") or {}

def tag_of(image):
    # Tag = substring after the last ':' that follows the last '/', so
    # registry:5000/name:tag parses correctly. An untagged image returns "" and
    # matches no policy token, so the guard flags it — explicit tags are required.
    name = (image or "").rsplit("/", 1)[-1]
    return name.rsplit(":", 1)[-1] if ":" in name else ""

svc_tag = {s: tag_of((v or {}).get("image", "")) for s, v in services.items()}

# 2. Parse the manifest table between the markers (only that table).
with open(os.path.join(REPO, "docs/operations/upgrades.md")) as f:
    text = f.read()
m = re.search(
    r"<!--\s*upgrades-manifest:start\s*-->(.*?)<!--\s*upgrades-manifest:end\s*-->",
    text, re.S)
rows = {}
dups = set()
if not m:
    out.append(("FAIL", "manifest markers present in docs/operations/upgrades.md"))
else:
    out.append(("PASS", "manifest markers present in docs/operations/upgrades.md"))
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 5:
            continue
        svc = cells[0]
        if svc in ("Service", "") or set(svc) <= set("-: "):
            continue  # header or separator row
        if svc in rows:
            dups.add(svc)  # duplicate rows would otherwise be masked (last-write-wins)
        rows[svc] = {"policy": cells[1], "preflight": cells[3]}

# 3. Parse the stable lock's preflight records. The lock is the Stable-channel
# record, while the manifest is the preflight SSOT used to generate commands;
# accepting different confidence tiers between them makes the record misleading.
lock_rows = {}
lock_dups = set()
lock_path = os.path.join(REPO, "docs/operations/image-digests.lock")
with open(lock_path) as f:
    for raw in f:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        cells = line.split("\t")
        if cells[0] == "service":
            continue
        if len(cells) != 5:
            out.append(("FAIL", "stable lock rows have five columns :: " + line))
            continue
        svc = cells[0]
        if svc in lock_rows:
            lock_dups.add(svc)
        lock_rows[svc] = cells[4]

# 3b. Fail closed: every check below is a set difference, and three empty sets
# differ in no way — a compose or table parse failure would pass them all.
populations = [("compose services", services), ("manifest rows", rows), ("stable lock rows", lock_rows)]
empty = [label for label, pop in populations if not pop]
out.append(("FAIL", "parsed populations are non-empty :: empty=" + ",".join(empty))
           if empty else ("PASS", "parsed populations are non-empty"))
if empty:
    for status, msg in out:
        print(f"{status}\t{msg}")
    sys.exit(0)

# 4. Presence (and no stale rows).
missing = sorted(s for s in services if s not in rows)
extra = sorted(s for s in rows if s not in services)
out.append(("FAIL", "every compose service has a manifest row :: missing=" + ",".join(missing))
           if missing else ("PASS", "every compose service has a manifest row"))
out.append(("FAIL", "no stale manifest rows :: extra=" + ",".join(extra))
           if extra else ("PASS", "no stale manifest rows"))
out.append(("FAIL", "no duplicate manifest rows :: dup=" + ",".join(sorted(dups)))
           if dups else ("PASS", "no duplicate manifest rows"))

# 5. Policy <-> live tag.
def policy_ok(policy, tag):
    if policy == "latest":
        return tag == "latest"
    if policy == "exact-patch":
        return re.fullmatch(r"\d+\.\d+\.\d+", tag) is not None
    if policy.startswith("major:"):
        return tag == policy.split(":", 1)[1]
    if policy.startswith("variant:"):
        return tag == policy.split(":", 1)[1]
    return False

pol_bad = [f"{s}(policy={rows[s]['policy']},tag={svc_tag[s]})"
           for s in services if s in rows and not policy_ok(rows[s]["policy"], svc_tag[s])]
out.append(("FAIL", "pin policy matches live compose tag :: " + " ".join(pol_bad))
           if pol_bad else ("PASS", "pin policy matches live compose tag"))

# 6. Preflight token validity.
def preflight_ok(pf):
    if pf in ("compose-only", "manual"):
        return True
    if pf.startswith("scenario:"):
        return os.path.isfile(os.path.join(REPO, "tests/scenarios", pf.split(":", 1)[1] + ".sh"))
    if pf.startswith("unit:"):
        return os.path.isfile(os.path.join(REPO, pf.split(":", 1)[1]))
    return False

pf_bad = [f"{s}(preflight={rows[s]['preflight']})"
          for s in services if s in rows and not preflight_ok(rows[s]["preflight"])]
out.append(("FAIL", "preflight token resolves to a real oracle :: " + " ".join(pf_bad))
           if pf_bad else ("PASS", "preflight token resolves to a real oracle"))

# 7. The Stable lock must cover exactly the manifest services and retain its
# preflight token. The lock is not allowed to silently retain an obsolete tier.
lock_missing = sorted(s for s in rows if s not in lock_rows)
lock_extra = sorted(s for s in lock_rows if s not in rows)
out.append(("FAIL", "every manifest service has a stable lock row :: missing=" + ",".join(lock_missing))
           if lock_missing else ("PASS", "every manifest service has a stable lock row"))
out.append(("FAIL", "no stale stable lock rows :: extra=" + ",".join(lock_extra))
           if lock_extra else ("PASS", "no stale stable lock rows"))
out.append(("FAIL", "no duplicate stable lock rows :: dup=" + ",".join(sorted(lock_dups)))
           if lock_dups else ("PASS", "no duplicate stable lock rows"))
lock_pf_bad = [f"{s}(lock={lock_rows[s]},manifest={rows[s]['preflight']})"
               for s in rows if s in lock_rows and lock_rows[s] != rows[s]["preflight"]]
out.append(("FAIL", "stable lock preflight matches manifest :: " + " ".join(lock_pf_bad))
           if lock_pf_bad else ("PASS", "stable lock preflight matches manifest"))

# 8. scenario:<name> rows must actually START the service — a row can't claim a
#    scenario that never launches it (the bazarr coverage-overstatement class).
def svc_profiles(s):
    p = (services.get(s) or {}).get("profiles")
    return set(p) if p else {"default"}

# Coverage is declared explicitly per preflight scenario rather than parsed out
# of scenario shell — regex-parsing arbitrary scenarios proved fragile (sibling
# name collisions, comment/log string literals, redirect/flag forms). Update this
# map when a scenario changes what it launches; an unknown scenario covers
# nothing, forcing a deliberate entry rather than a silent pass.
SCENARIO_COVERAGE = {
    # scenario -> compose profiles it brings up (override reaches via the patched
    # compose) and/or services it launches standalone (docker run + ms_test_image)
    "fresh-install":  {"profiles": {"default", "proxy", "autoheal"}},
    "autoheal":       {"services": {"autoheal"}},
    "bazarr":         {"services": {"bazarr"}},
    "unpackerr":      {"services": {"unpackerr"}},
    "npm-heal":       {"services": {"npm"}},
    "wireguard":      {"services": {"wireguard"}},
    "fail2ban-drift": {"services": {"fail2ban"}},
    "ddns-seed":      {"services": {"ddns-updater"}},
    "ddns-verify":    {"services": {"ddns-updater"}},
    # ddns-offline exercises the verify degrade path; not a preflight oracle for
    # any lock row (so never consulted here), but listed so scenario_starts below
    # does not reject it as an unknown scenario.
    "ddns-offline":   {"services": {"ddns-updater"}},
}

def scenario_starts(svc, scen):
    cov = SCENARIO_COVERAGE.get(scen)
    if cov is None:
        return False  # unknown preflight scenario: add an entry above (don't pass silently)
    if svc in cov.get("services", set()):
        return True
    return bool(svc_profiles(svc) & cov.get("profiles", set()))

cov_bad = [f"{s}(scenario={rows[s]['preflight'].split(':',1)[1]},profiles={sorted(svc_profiles(s))})"
           for s in services
           if s in rows and rows[s]["preflight"].startswith("scenario:")
           and not scenario_starts(s, rows[s]["preflight"].split(":", 1)[1])]
out.append(("FAIL", "scenario actually starts the service :: " + " ".join(cov_bad))
           if cov_bad else ("PASS", "scenario actually starts the service"))

for status, msg in out:
    print(f"{status}\t{msg}")
PYEOF
)
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "upgrades-manifest checker ran" "python3 exited $rc"
    summary
    exit 1
fi

while IFS=$'\t' read -r status msg; do
    [[ -z "$status" ]] && continue
    name="${msg%% :: *}"
    if [[ "$msg" == *" :: "* ]]; then detail="${msg#* :: }"; else detail=""; fi
    case "$status" in
        PASS) pass "$name" ;;
        FAIL) fail "$name" "$detail" ;;
        *) fail "unexpected checker line" "$status $msg" ;;
    esac
done <<<"$results"

# README Stable-baseline badge must reflect the current lock. Pure local file
# read, no network — safe to run on every PR, not just at accept-time.
badge_out=$(python3 "$REPO_ROOT/scripts/image-drift.py" \
    --previous "$REPO_ROOT/docs/operations/image-digests.lock" \
    --check-readme-badges "$REPO_ROOT/README.md" 2>&1)
if [[ $? -eq 0 ]]; then
    pass "README Stable-baseline badge is current"
else
    fail "README Stable-baseline badge is current" "$badge_out"
fi

summary
