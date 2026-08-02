#!/usr/bin/env python3
"""Repository publication-safety scanner.

Usage:
    python3 tests/lib/repo_guard.py <root>
    python3 tests/lib/repo_guard.py --list-rules

Findings print as "<RULE-ID>\t<path>\t<detail>" and exit 1; a clean tree exits
0. Any internal problem — missing root, non-repository root, unreadable file,
empty population, empty pattern list — prints "GUARD-ERROR\t<path>\t<detail>"
and exits 2, so the guard never passes by accident.

Findings never carry matched text. A secret rule reports the file, the rule,
the pattern NAME and the line number, never the value.

Scope: the tree as it stands now — the index and the working tree. Git history
is not read; blob-level history scanning is a separate, later concern with its
own gate.
"""

import fnmatch
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError as exc:  # fail closed: no YAML rule can run without it
    sys.stdout.write(f"GUARD-ERROR\t-\tpyyaml unavailable: {exc}\n")
    raise SystemExit(2) from exc


class GuardError(Exception):
    """Raised for any condition that must fail the guard rather than pass it."""

    def __init__(self, path, detail):
        super().__init__(detail)
        self.path = path
        self.detail = detail


# ---------------------------------------------------------------------------
# Rule inputs
# ---------------------------------------------------------------------------

# Ported verbatim from the "Secret and private-file guard" step in
# .github/workflows/ci.yml. Do not narrow either of these.
CI_FORBIDDEN_TRACKED = (
    r"(^|/)(\.env($|\.)|\.envrc|tests/\.env\.gcp|private(/|$)|docs/plans(/|$)"
    r"|\.planning(/|$)|\.tmp(/|$)|CONTEXT\.md$|tests/.*-plan\.md$)"
)
CI_PATH_ALLOWLIST = r"(^|/)(\.env\.example|\.env\.gcp\.example|\.env\.lan-host\.example)$"
CI_CONTENT_ALLOWLIST = (
    r"^(\.env\.example|tests/\.env\.gcp\.example|tests/\.env\.lan-host\.example)$"
)

# Generated host artifacts that must never be tracked. Mirrors .gitignore; a
# tracked hit means an ignore rule was lost or a file was force-added.
HOST_ARTIFACTS = [
    r"^config\.yml$",
    r"^docker-compose\.override\.yml$",
    r"^\.setup-result$",
    r"^\.nvidia-finalize-pending$",
    r"^\.nvidia-nvenc-unpatched$",
    r"^\.nvidia-(patch|tmp)/",
    r"^backups/",
    r"^config/(jellyfin|sonarr|radarr|seerr|unpackerr|homepage|jackett"
    r"|qbittorrent|fail2ban|npm|state|wireguard|ddns-updater|bazarr"
    r"|uptime-kuma|beszel)/",
    r"^tests/\.dind-state$",
    r"^tests/\.image-override-applied$",
    r"^tests/\.image-preflight-passed\.tsv$",
    r"(^|/)__pycache__/",
    r"\.pyc$",
]

# Secret-bearing file classes. Structural: keyed on file class, not on a list
# of known-bad values, so an unknown credential file is still caught.
SECRET_FILE_GLOBS = [
    "*.pem",
    "*.key",
    "*.p12",
    "*.pfx",
    "*.jks",
    "*.keystore",
    "*.kdbx",
    "*.ovpn",
    "*.kubeconfig",
    "*.gpg",
    "*.asc",
    "*.ppk",
    "id_rsa*",
    "id_dsa*",
    "id_ecdsa*",
    "id_ed25519*",
    "*secring*",
    ".netrc",
    ".npmrc",
    ".pypirc",
    ".htpasswd",
    "authorized_keys",
    "*service-account*.json",
    "*service_account*.json",
    "*credentials*.json",
    "*client_secret*.json",
]

# Credential grammar. The first eight are ported verbatim from the ci.yml rg
# invocation; the rest widen coverage without replacing any of them.
SECRET_PATTERNS = [
    ("private-key-header", r"-----BEGIN (RSA|OPENSSH|EC|DSA)? ?PRIVATE KEY-----"),
    ("google-api-key", r"AIza[0-9A-Za-z_-]{35}"),
    ("google-oauth-token", r"ya29\.[0-9A-Za-z_-]+"),
    ("aws-access-key-id", r"AKIA[0-9A-Z]{16}"),
    ("github-token", r"gh[pousr]_[0-9A-Za-z_]{36,}"),
    ("slack-token", r"xox[baprs]-[0-9A-Za-z-]+"),
    ("client-secret-assignment", r"client_secret\s*[:=]\s*[\"']?[^\"'\s]+"),
    ("private-key-assignment", r"private_key\s*[:=]\s*[\"']?[^\"'\s]+"),
    ("private-key-header-generic", r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"),
    ("aws-session-key-id", r"ASIA[0-9A-Z]{16}"),
    ("gitlab-token", r"glpat-[0-9A-Za-z_-]{20,}"),
    ("azure-account-key", r"AccountKey=[A-Za-z0-9+/=]{40,}"),
    ("sendgrid-key", r"SG\.[0-9A-Za-z_-]{20,}\.[0-9A-Za-z_-]{20,}"),
    ("dockerhub-token", r"dckr_pat_[0-9A-Za-z_-]{20,}"),
    ("npm-token", r"npm_[0-9A-Za-z]{36}"),
]

WORKTREE_RULE_PATTERNS = {
    "PRIVATE-DOC-DIR": [
        r"(^|/)docs/private/",
        r"(^|/)\.planning/",
        r"(^|/)docs/plans/",
    ],
    # Both slash-suffixed (directory) and bare (file/symlink-to-file) shapes:
    # os.walk only trailing-slashes entries it puts in dirnames.
    "ANALYZER-CACHE": [
        r"(^|/)\.ua/",
        r"(^|/)\.understand-anything/",
        r"(^|/)\.ua$",
        r"(^|/)\.understand-anything$",
    ],
    "KNOWLEDGE-GRAPH": [
        r"(^|/)knowledge[-_]graph",
        r"\.kg\.json$",
        r"(^|/)codebase-graph",
        r"(^|/)repo-map\.json$",
        r"(^|/)code-?graph\.(json|db|sqlite3?)$",
    ],
    "AGENT-PRIVATE-DIR": [
        r"(^|/)\.scratch/",
        r"^docs/agents/",
        r"^evidence/",
        r"(^|/)\.(cursor|windsurf|codex|gemini|aider|agents|continue)/",
        r"(^|/)\.aider\.",
        r"^\.claude/(skills|agents|commands|projects)/",
        r"^\.claude/settings\.local\.json$",
        r"^\.github/workflows-private/",
    ],
    "REAL-LOG": [
        r"\.log$",
        r"\.log\.[0-9]+$",
        r"(^|/)logs/",
    ],
}

REQUIRED_YAML_CONFIG = "config/examples/config.yml"
WORKFLOW_DIR = ".github/workflows"


# ---------------------------------------------------------------------------
# Populations
# ---------------------------------------------------------------------------


# Every rule input passes through here: a list that silently empties turns
# its rule into a loop that iterates zero times and always passes.
def require_nonempty(label, seq):
    if not seq:
        raise GuardError("-", f"empty rule input: {label}")
    return seq


def tracked_paths(root):
    try:
        proc = subprocess.run(
            ["git", "-C", root, "ls-files", "-z"],
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise GuardError("-", f"git unavailable: {exc}") from exc
    if proc.returncode != 0:
        raise GuardError("-", f"git ls-files failed: rc={proc.returncode}")
    names = [p for p in proc.stdout.decode("utf-8", "replace").split("\0") if p]
    return require_nonempty("tracked population", sorted(names))


def worktree_paths(root):
    """Every file and directory under root except .git — the index cannot see
    a gitignored .ua/, and that is exactly what the analyzer-cache rule must
    reject. Directories carry a trailing slash and are emitted without being
    entered, so a .ua symlinked to an external cache still matches.

    .git is pruned at every depth, not just the root: a live install clones
    nvidia-patch into the tree and its .git/logs/ is not a real log."""
    names: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root, onerror=_walk_error):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        rel = os.path.relpath(dirpath, root)
        prefix = "" if rel == "." else rel + "/"
        names.extend(prefix + d + "/" for d in dirnames)
        names.extend(prefix + f for f in filenames)
    return require_nonempty("worktree population", sorted(names))


# os.walk swallows errors by default, which would shrink the population.
def _walk_error(exc):
    raise GuardError(getattr(exc, "filename", "-") or "-", f"walk failed: {exc}")


def read_text(root, rel):
    try:
        with open(os.path.join(root, rel), "rb") as handle:
            return handle.read().decode("utf-8", "replace")
    except OSError as exc:
        raise GuardError(rel, f"unreadable: {exc.strerror}") from exc


# ---------------------------------------------------------------------------
# Rules
# ---------------------------------------------------------------------------


def rule_forbidden_tracked_path(ctx):
    forbidden = re.compile(CI_FORBIDDEN_TRACKED)
    allowed = re.compile(CI_PATH_ALLOWLIST)
    return [
        (p, "ported=ci-forbidden-path")
        for p in ctx["tracked"]
        if forbidden.search(p) and not allowed.search(p)
    ]


# Index-only on purpose: a live install legitimately carries these files
# untracked, so a worktree scan here would fire on every developer.
def rule_host_artifact(ctx):
    pats = [re.compile(p) for p in require_nonempty("HOST-ARTIFACTS", HOST_ARTIFACTS)]
    return [
        (p, "artifact=generated-host-file")
        for p in ctx["tracked"]
        if any(pat.search(p) for pat in pats)
    ]


# The same paths HOST-ARTIFACT rejects in the index are legitimate untracked
# runtime state in the worktree (service logs, TLS material, a nvidia-patch
# clone), so worktree rules that would otherwise fire on every live install
# skip them. Tracked, they are still a HOST-ARTIFACT finding — the exemption
# cannot widen without widening that rule too.
def live_runtime(path):
    pats = require_nonempty("HOST-ARTIFACTS", HOST_ARTIFACTS)
    return any(re.search(p, path) for p in pats)


# Worktree-scanned: an untracked private key can be git add-ed later, exactly
# the argument that puts .scratch/ on the worktree population.
def rule_secret_file(ctx):
    globs = require_nonempty("SECRET_FILE_GLOBS", SECRET_FILE_GLOBS)
    allowed = re.compile(CI_PATH_ALLOWLIST)
    out = []
    for path in ctx["worktree"]:
        if allowed.search(path) or live_runtime(path):
            continue
        base = os.path.basename(path.rstrip("/"))
        hit = next((g for g in globs if fnmatch.fnmatch(base, g)), None)
        if hit:
            out.append((path, f"class={hit}"))
    return out


# Reports the pattern name and line, never the match — a guard that echoes
# the secret into CI logs has made things worse. Uses ci.yml's content
# allowlist, which is anchored differently from its path allowlist.
# Index-only, unlike SECRET-FILE: reading every untracked byte on a live
# install is a cost question the file-class rule does not have.
def rule_secret_pattern(ctx):
    pats = [
        (name, re.compile(rx)) for name, rx in require_nonempty("SECRET_PATTERNS", SECRET_PATTERNS)
    ]
    allowed = re.compile(CI_CONTENT_ALLOWLIST)
    out = []
    for path in ctx["tracked"]:
        if allowed.search(path):
            continue
        for lineno, line in enumerate(read_text(ctx["root"], path).splitlines(), 1):
            for name, pat in pats:
                if pat.search(line):
                    out.append((path, f"pattern={name} line={lineno}"))
    return out


def _worktree_rule(rule_id, exempt=None):
    def check(ctx):
        pats = [re.compile(p) for p in require_nonempty(rule_id, WORKTREE_RULE_PATTERNS[rule_id])]
        return [
            (p, f"rule={rule_id.lower()}")
            for p in ctx["worktree"]
            if any(pat.search(p) for pat in pats) and not (exempt and exempt(p))
        ]

    return check


def _yaml_findings(ctx, paths, detail):
    out = []
    for rel in paths:
        try:
            yaml.safe_load(read_text(ctx["root"], rel))
        except yaml.YAMLError:
            out.append((rel, detail))
    return out


def rule_yaml_config(ctx):
    if REQUIRED_YAML_CONFIG not in ctx["tracked_set"]:
        return [(REQUIRED_YAML_CONFIG, "yaml=missing-config-template")]
    return _yaml_findings(ctx, [REQUIRED_YAML_CONFIG], "yaml=unparseable")


def rule_yaml_workflow(ctx):
    paths = sorted(
        p for p in ctx["tracked"] if p.startswith(WORKFLOW_DIR + "/") and p.endswith(".yml")
    )
    if not paths:
        return [(WORKFLOW_DIR, "yaml=no-workflow-files")]
    return _yaml_findings(ctx, paths, "yaml=unparseable")


RULES = [
    ("FORBIDDEN-TRACKED-PATH", rule_forbidden_tracked_path),
    ("HOST-ARTIFACT", rule_host_artifact),
    ("SECRET-FILE", rule_secret_file),
    ("SECRET-PATTERN", rule_secret_pattern),
    ("PRIVATE-DOC-DIR", _worktree_rule("PRIVATE-DOC-DIR")),
    ("ANALYZER-CACHE", _worktree_rule("ANALYZER-CACHE")),
    ("KNOWLEDGE-GRAPH", _worktree_rule("KNOWLEDGE-GRAPH")),
    ("AGENT-PRIVATE-DIR", _worktree_rule("AGENT-PRIVATE-DIR")),
    ("REAL-LOG", _worktree_rule("REAL-LOG", exempt=live_runtime)),
    ("YAML-CONFIG", rule_yaml_config),
    ("YAML-WORKFLOW", rule_yaml_workflow),
]


def scan(root):
    require_nonempty("rule registry", RULES)
    tracked = tracked_paths(root)
    ctx = {
        "root": root,
        "tracked": tracked,
        "tracked_set": set(tracked),
        "worktree": worktree_paths(root),
    }
    findings, executed = [], []
    for rule_id, check in RULES:
        for path, detail in check(ctx):
            findings.append((rule_id, path, detail))
        executed.append(rule_id)
    if executed != [rule_id for rule_id, _ in RULES]:
        raise GuardError("-", "rule registry did not execute in full")
    return findings


def main(argv):
    require_nonempty("rule registry", RULES)
    if len(argv) == 2 and argv[1] == "--list-rules":
        for rule_id, _ in RULES:
            print(rule_id)
        return 0
    if len(argv) != 2 or not argv[1]:
        sys.stdout.write("GUARD-ERROR\t-\tusage: repo_guard.py <root>\n")
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        sys.stdout.write(f"GUARD-ERROR\t{root}\tscan root is not a directory\n")
        return 2
    try:
        findings = scan(os.path.realpath(root))
    except GuardError as exc:
        sys.stdout.write(f"GUARD-ERROR\t{exc.path}\t{exc.detail}\n")
        return 2
    for rule_id, path, detail in findings:
        sys.stdout.write(f"{rule_id}\t{path}\t{detail}\n")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
