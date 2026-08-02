#!/usr/bin/env bash
# tests/unit/docs.sh
#
# Contract suite for the public control surface: the legal, security, intake,
# docs-index, routing and contribution files a public repository is judged on.
# They have no other guard — nothing else notices a deleted SECURITY.md, an
# issue-template chooser that stopped routing security reports privately, a
# second CONTRIBUTING.md competing with the canonical one, or a router pointing
# at a document that no longer exists.
#
# Parses YAML the same way tests/lib/repo_guard.py does (yaml.safe_load) so
# "does this parse" has exactly one definition across the repo. Fails closed on
# every population it derives: a presence check over an empty list passes
# vacuously and asserts nothing.
#
# Pure bash + python3 — no Docker, no network.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"
CURRENT_SCENARIO="docs"
scenario_begin "$CURRENT_SCENARIO"

# Overridable so a fixture copy can be mutated and probed without touching the
# real tree.
DOCS_ROOT="${MS_TEST_DOCS_ROOT:-$REPO_ROOT}"
export DOCS_ROOT

results=$(
    python3 - <<'PYEOF'
import json
import os
import pathlib
import re
import sys

try:
    import yaml
except ImportError as exc:
    print(f"FAIL\tPyYAML importable :: {exc}")
    sys.exit(0)

root = pathlib.Path(os.environ["DOCS_ROOT"])

out = []

def report(status, name, detail=""):
    # One line per assertion: a multi-line detail (a YAML parser error) would
    # otherwise reach the bash reader as unlabelled lines.
    line = f"{status}\t{name}"
    if detail:
        line += " :: " + " ".join(str(detail).split())
    out.append(line)

# The control surface, declared rather than derived: there is no rule that
# generates it, so the list is the contract and every entry is asserted below.
CONTROL_FILES = [
    "LICENSE",
    "CONTRIBUTING.md",
    "README.md",
    "AGENTS.md",
    "docs/README.md",
    "docs/conventions.md",
    "docs/decisions/README.md",
    ".github/SECURITY.md",
]
CONTROL_DIRS = [".github/ISSUE_TEMPLATE"]

# A markdown control file's relative links are checked; LICENSE is not markdown.
# The routers are the reason this matters most: a route is worthless if it
# resolves to nothing, and nothing else in the repo reads them.
LINK_SOURCES = [
    "CONTRIBUTING.md",
    "README.md",
    "AGENTS.md",
    "docs/README.md",
    "docs/conventions.md",
    "docs/decisions/README.md",
    ".github/SECURITY.md",
    "tests/README.md",
]

# GitHub-hosted routes that a contact link may use to reach a private report,
# mapped to the file in this repository that backs them. Keyed on the URL path
# tail so an org or repo rename does not break the assertion.
SECURITY_ROUTES = {
    "security/policy": ".github/SECURITY.md",
    "security/advisories/new": ".github/SECURITY.md",
}

SECURITY_WORDS = ("security", "vulnerabilit", "credential")

if not CONTROL_FILES or not CONTROL_DIRS or not LINK_SOURCES:
    report("FAIL", "control-file population is non-empty", "declared list is empty")
    for line in out:
        print(line)
    sys.exit(0)
report("PASS", "control-file population is non-empty", f"{len(CONTROL_FILES) + len(CONTROL_DIRS)} entries")
report("PASS", "link-source population is non-empty", f"{len(LINK_SOURCES)} file(s)")

for rel in CONTROL_FILES:
    if (root / rel).is_file():
        report("PASS", f"control file exists: {rel}")
    else:
        report("FAIL", f"control file exists: {rel}", "missing or not a regular file")

for rel in CONTROL_DIRS:
    if (root / rel).is_dir():
        report("PASS", f"control directory exists: {rel}")
    else:
        report("FAIL", f"control directory exists: {rel}", "missing or not a directory")

# --- issue templates parse ---------------------------------------------------

template_dir = root / ".github/ISSUE_TEMPLATE"
templates = sorted(p for p in template_dir.iterdir() if p.is_file()) if template_dir.is_dir() else []

if templates:
    report("PASS", "issue-template population is non-empty", f"{len(templates)} file(s)")
else:
    report("FAIL", "issue-template population is non-empty", f"no files under {template_dir}")

FRONT_MATTER_RE = re.compile(r"\A---\n(.*?)\n---\s*(\n|\Z)", re.S)

def template_yaml(path):
    """The YAML a template carries: the whole file for .yml/.yaml, the front
    matter for a markdown template. Raises on anything that is not YAML."""
    text = path.read_text(encoding="utf-8")
    if path.suffix in (".yml", ".yaml"):
        return yaml.safe_load(text)
    m = FRONT_MATTER_RE.match(text)
    if not m:
        raise ValueError("no YAML front matter")
    return yaml.safe_load(m.group(1))

for path in templates:
    rel = path.relative_to(root)
    name = f"issue template parses as YAML: {rel}"
    try:
        parsed = template_yaml(path)
    except Exception as exc:
        report("FAIL", name, f"{type(exc).__name__}: {exc}")
        continue
    if isinstance(parsed, dict) and parsed:
        report("PASS", name)
    else:
        report("FAIL", name, f"expected a non-empty mapping, got {type(parsed).__name__}")

# --- chooser routes security reports privately -------------------------------

chooser_path = template_dir / "config.yml"
chooser = None
if chooser_path.is_file():
    try:
        chooser = yaml.safe_load(chooser_path.read_text(encoding="utf-8"))
    except Exception as exc:
        report("FAIL", "chooser config.yml parses", f"{type(exc).__name__}: {exc}")
else:
    report("FAIL", "chooser config.yml parses", f"missing {chooser_path}")

links = chooser.get("contact_links") or [] if isinstance(chooser, dict) else []
links = [link for link in links if isinstance(link, dict)]

route_name = "chooser routes security reports to a private channel"
if not SECURITY_ROUTES:
    report("FAIL", route_name, "no security routes declared")
elif not links:
    report("FAIL", route_name, "chooser declares no contact_links")
else:
    security_links = [
        link
        for link in links
        if any(word in f"{link.get('name', '')} {link.get('about', '')}".lower() for word in SECURITY_WORDS)
    ]
    if not security_links:
        report("FAIL", route_name, "no contact link mentions security")
    else:
        for link in security_links:
            url = str(link.get("url", ""))
            label = str(link.get("name", "?"))
            tail = next((r for r in SECURITY_ROUTES if url.rstrip("/").endswith(r)), None)
            if tail is None:
                report("FAIL", f"{route_name}: {label}", f"url is not a known private route: {url or '(none)'}")
            elif (root / SECURITY_ROUTES[tail]).is_file():
                report("PASS", f"{route_name}: {label}", f"{tail} -> {SECURITY_ROUTES[tail]}")
            else:
                report("FAIL", f"{route_name}: {label}", f"{tail} routes to missing {SECURITY_ROUTES[tail]}")

# --- relative links in the control files resolve -----------------------------
# Scoped to the control set by decision, not by accident: a tree-wide link check
# is a separate piece of work with its own false-positive surface.

LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
links_checked = 0

for rel in LINK_SOURCES:
    path = root / rel
    if not path.is_file():
        continue
    for target in LINK_RE.findall(path.read_text(encoding="utf-8")):
        if re.match(r"\A(?:[a-z][a-z0-9+.-]*:|//|#)", target):
            continue
        clean = target.split("#", 1)[0].split("?", 1)[0]
        if not clean:
            continue
        links_checked += 1
        resolved = (path.parent / clean).resolve()
        name = f"relative link resolves: {rel} -> {target}"
        if resolved.exists():
            report("PASS", name)
        else:
            report("FAIL", name, f"no such path: {resolved}")

if links_checked:
    report("PASS", "control-file link population is non-empty", f"{links_checked} link(s)")
else:
    report("FAIL", "control-file link population is non-empty", "no relative links found in the control files")

# --- decision records carry every required section ---------------------------
# A record missing "Rejected alternatives" or "Reopen condition" is the failure
# mode this guards: it reads as a decision record while recording only the
# outcome.

DECISION_SECTIONS = [
    "Context",
    "Decision",
    "Rejected alternatives",
    "Consequences",
    "Reopen condition",
    "Enforcement",
]
HEADING_RE = re.compile(r"^##\s+(.+?)\s*$", re.M)

decisions_dir = root / "docs/decisions"
records = (
    sorted(p for p in decisions_dir.glob("*.md") if p.name != "README.md")
    if decisions_dir.is_dir()
    else []
)

if records and DECISION_SECTIONS:
    report("PASS", "decision-record population is non-empty", f"{len(records)} record(s)")
else:
    report("FAIL", "decision-record population is non-empty", f"no *.md under {decisions_dir}")

index_text = (decisions_dir / "README.md").read_text(encoding="utf-8") if (decisions_dir / "README.md").is_file() else ""

for path in records:
    rel = path.relative_to(root)
    headings = set(HEADING_RE.findall(path.read_text(encoding="utf-8")))
    missing = [s for s in DECISION_SECTIONS if s not in headings]
    name = f"decision record has every required section: {rel}"
    if missing:
        report("FAIL", name, "missing: " + ", ".join(missing))
    else:
        report("PASS", name)

    name = f"decision record is listed in the index: {rel}"
    if f"({path.name})" in index_text:
        report("PASS", name)
    else:
        report("FAIL", name, "no link to it in docs/decisions/README.md")

# --- exactly one contribution guide ------------------------------------------

SKIP_DIRS = {".git", "node_modules"}
found = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
    if "CONTRIBUTING.md" in filenames:
        found.append(str(pathlib.Path(dirpath).relative_to(root) / "CONTRIBUTING.md"))

name = "exactly one CONTRIBUTING.md in the tree"
if found == ["CONTRIBUTING.md"]:
    report("PASS", name, "CONTRIBUTING.md")
else:
    report("FAIL", name, f"found {sorted(found) or 'none'}, expected only the repository root")

for line in out:
    print(line)
PYEOF
)
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "docs checker ran" "python3 exited $rc"
    summary
    exit 1
fi

while IFS=$'\t' read -r status rest; do
    [[ -z "$status" ]] && continue
    name="${rest%% :: *}"
    if [[ "$rest" == *" :: "* ]]; then detail="${rest#* :: }"; else detail=""; fi
    case "$status" in
        PASS) pass "$name" ;;
        FAIL) fail "$name" "$detail" ;;
        *) fail "unexpected checker line" "$status $rest" ;;
    esac
done <<<"$results"

scenario_end "$CURRENT_SCENARIO"
summary
