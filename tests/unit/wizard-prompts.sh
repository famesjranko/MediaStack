#!/usr/bin/env bash
# =============================================================================
# Unit test — shared wizard prompt SSOT (tests/lib/wizard_prompts.json)
# =============================================================================
# The DinD wizard-ui-* scenarios and the maintainer-private bare-metal harness build their
# PTY steps from ONE prompt definition file via tests/lib/wizard_steps_build.py. This guards
# that single source of truth:
#   - the JSON is well-formed and every regex compiles (the flavor wizard_pty.py uses)
#   - the builder renders SSOT names, @timeout, ENTER and NONE correctly, and rejects bad names
#   - no scenario that BUILDS from the SSOT has drifted back to an inline prompt regex
#   - every prompt name a scenario passes to the builder is defined in the SSOT, with even
#     NAME/SEND parity
# so a wizard prompt change is made in one place with no silent drift.
#
# NOTE: this does NOT verify the regexes still match the LIVE wizard text — that guard is the
# DinD wizard-ui-* CI job (.github/workflows/pr-checks.yml), whose PTY run times out (exit 124)
# if a prompt drifts from the product. This test + that job together cover drift.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="wizard-prompts"
scenario_begin "$CURRENT_SCENARIO"

SSOT="$REPO_ROOT/tests/lib/wizard_prompts.json"
BUILD="$REPO_ROOT/tests/lib/wizard_steps_build.py"

# 1. SSOT parses + every value is a valid Python regex.
if out=$(python3 - "$SSOT" <<'PY'
import json, re, sys
p = json.load(open(sys.argv[1]))["prompts"]
assert isinstance(p, dict) and p, "prompts must be a non-empty object"
for k, v in p.items():
    re.compile(v)
print(len(p))
PY
); then
    pass "wizard-prompts: SSOT parses, $out regexes compile"
else
    fail "wizard-prompts: SSOT invalid or a regex does not compile"
fi

# 2. Builder renders the SSOT name, @timeout, ENTER, and NONE forms correctly.
built=$(python3 "$BUILD" transcode_offer 1 stage2_https_not_ready@30 ENTER stage1_admin_username NONE)
if BUILT="$built" python3 - "$SSOT" <<'PY'
import json, os, sys
steps = json.loads(os.environ["BUILT"])
P = json.load(open(sys.argv[1]))["prompts"]
expected = [
    {"expect": P["transcode_offer"]}, {"send": "1\n"},
    {"expect": P["stage2_https_not_ready"], "timeout": 30}, {"send": "\n"},
    {"expect": P["stage1_admin_username"]},
]
assert steps == expected, f"{steps!r} != {expected!r}"
PY
then
    pass "wizard-prompts: builder renders SSOT name / @timeout / ENTER / NONE"
else
    fail "wizard-prompts: builder did not render the expected steps-JSON"
fi

# 2b. Builder rejects an unknown prompt name (fail-loud, not a silent empty step).
if python3 "$BUILD" no_such_prompt 1 >/dev/null 2>&1; then
    fail "wizard-prompts: builder accepted an unknown prompt name"
else
    pass "wizard-prompts: builder rejects an unknown prompt name"
fi

# 3. Self-scoping: any wizard-ui scenario that BUILDS from the SSOT must not also inline a
#    prompt regex. (Scenarios that don't call the builder — e.g. recovery, manage-updates, and
#    the deliberately-dynamic nas-existing-share — are not checked.)
reinlined=""
for f in "$REPO_ROOT"/tests/scenarios/wizard-ui-*.sh; do
    if grep -qE 'wizard_(stage[123]|build)_steps ' "$f" && grep -qE '"expect"[[:space:]]*:' "$f"; then
        reinlined="$reinlined $(basename "$f")"
    fi
done
if [ -z "$reinlined" ]; then
    pass "wizard-prompts: no SSOT-building scenario inlines a prompt regex"
else
    fail "wizard-prompts: scenario(s) build from the SSOT yet still inline a regex:$reinlined"
fi

# 4. Every prompt name passed to the builder is defined in the SSOT, with even NAME/SEND parity.
if out=$(python3 - "$SSOT" "$REPO_ROOT"/tests/scenarios/wizard-ui-*.sh <<'PY'
import json, re, sys, os
ssot = set(json.load(open(sys.argv[1]))["prompts"])
problems = []
for path in sys.argv[2:]:
    base = os.path.basename(path)
    text = open(path).read().replace("\\\n", " ")   # join bash line-continuations
    for line in text.splitlines():
        line = line.strip()
        m = re.match(r'wizard_(?:stage[123]|build)_steps\s+(.+)', line)
        if not m:
            continue
        toks = m.group(1).split()
        rest = toks[1:]                              # drop the steps-path arg
        if len(rest) % 2 != 0:
            problems.append(f"{base}: odd NAME/SEND parity"); continue
        for name in rest[0::2]:
            base_name = re.sub(r'@\d+$', '', name)
            if base_name.startswith("literal:"):
                continue
            if base_name not in ssot:
                problems.append(f"{base}:{name}")
if problems:
    print("; ".join(problems)); sys.exit(1)
print("all scenario prompt names defined, even parity")
PY
); then
    pass "wizard-prompts: $out"
else
    fail "wizard-prompts: $out"
fi

# 5. Lib-reachability: any scenario that CALLS a builder function must source a lib that DEFINES
#    it, else it dies at runtime ("command not found" -> PTY FileNotFoundError) while checks 1-4
#    still pass. (A self-contained scenario can be masked in a full run by an earlier scenario
#    sourcing the lib into the shared shell — this catches it deterministically.)
if out=$(python3 - "$REPO_ROOT"/tests/scenarios/wizard-ui-*.sh <<'PY'
import re, sys, os
DEFN = {
    "wizard_stage1_steps": ("wizard_stage1_common.sh",),
    "wizard_stage2_steps": ("wizard_stage2_common.sh",),
    "wizard_stage3_steps": ("wizard_stage3_common.sh",),
    "wizard_build_steps":  ("wizard_steps_common.sh", "wizard_stage1_common.sh",
                            "wizard_stage2_common.sh", "wizard_stage3_common.sh"),
}
problems = []
for path in sys.argv[1:]:
    base = os.path.basename(path)
    text = open(path).read()
    sources = set(re.findall(r'source\s+tests/lib/(\S+)', text))
    for fn, libs in DEFN.items():
        if re.search(rf'(?m)^\s*{fn}\s', text):          # a call (def only lives in the libs)
            if not any(lib in sources for lib in libs):
                problems.append(f"{base}: calls {fn} but sources none of {libs}")
if problems:
    print("; ".join(problems)); sys.exit(1)
print("all builder-calling scenarios source a defining lib")
PY
); then
    pass "wizard-prompts: $out"
else
    fail "wizard-prompts: $out"
fi

scenario_end "$CURRENT_SCENARIO"
summary
