# Conventions

How work lands in this repository: the commands that gate it, where files go,
what is mechanically enforced, and what is not.

Every rule below either names the thing that enforces it or is listed under
[Not enforced](#not-enforced). A rule with neither reads as a gate without
being one, so treat an unmarked rule as a bug in this document.

## Commands

`tests/check.sh` is the one command surface over every gate. Its own usage
header is the source of truth for the tier and single-stage selector names —
read [`../tests/check.sh`](../tests/check.sh) rather than a list copied here.

```
./tests/check.sh fast       # static tier; no DinD or service containers
./tests/check.sh            # default tier: the same coverage as the PR gate
./tests/check.sh <selector> # exactly one stage
```

The fast tier runs pinned ShellCheck from a native install at the exact pinned
version or from the verified local cache (`./tests/check.sh install`, one-time
per machine), falling back to Docker when neither is present. It does not
start DinD or product service containers, but
the whole-tree ShellCheck sweep can still take several minutes. Use a
single-stage or touched-file command from `tests/README.md` for quick feedback.

CI's required-status-check names are the job names in
[`../.github/workflows/ci.yml`](../.github/workflows/ci.yml); the full test
surface is described in [`../tests/README.md`](../tests/README.md).

Pinned developer tools (gitleaks, shfmt, mypy, ruff) are declared with exact
versions and integrity material in [`../tools.toml`](../tools.toml). Each entry
records the invocation that actually runs it; a pin nothing invokes is a pin
that proves nothing.

## Placement

[`project/structure.md`](project/structure.md) is the placement contract: the
directory tree, the allowed dependency directions, and the steps for adding a
service, bumping a service version, or extending the shared registries.
[`project/stack.md`](project/stack.md) covers the runtime, the service list and
the command quick reference.

One placement rule is machine-checked: nothing private, host-specific, or secret
may be tracked. `tests/lib/repo_guard.py` is the guard;
[`../tests/unit/repository-safety.sh`](../tests/unit/repository-safety.sh) proves it
against one clean and one targeted bad fixture per rule.

### Shell structure

Every tracked shell file (`*.sh` and the `mediastack` launcher) is capped at 500 lines. The fast-tier line-cap gate
uses `tests/shell-line-cap.allowlist` for today's existing offenders. An
allowlist entry is `<path>\t<line-count>`. Recorded counts may only shrink (or
the entry may be removed), and the file may not grow past its recorded count;
an entry for a missing file or a file now at or under the cap is stale and fails
the gate. Remove entries as files are brought under the cap.

The source-to-unit naming rule is that a unit suite names the source module it
covers, in one of three shapes: `tests/unit/<name>.sh` (the source basename),
`tests/unit/<area>-<name>.sh` where the basename alone is ambiguous (e.g.
`launcher-ddns.sh`, `stage2-ddns.sh`), or a mirrored directory
`tests/unit/<area>/<name>.sh` (e.g. `tests/unit/gpu/`, `tests/unit/hardening/`).
Submodules split out of a covered module (e.g. `scripts/services/npm/*.sh`,
`scripts/lib/arr/*.sh`) may stay covered by that module's existing suite rather
than gaining one file each. Service modules use one fixed shape:
`scripts/services/<name>/main.sh` is required, with `render/` and `templates/`
optional for Python renderers and static templates.

Every new shell module under `scripts/` starts with this two-line header
contract immediately after its shebang (or as its first two lines when it has
no shebang). Two exemptions: `scripts/services/<name>/main.sh` keeps the
numbered banner shape its peers use, and test files under `tests/` carry no
header contract:

```bash
# Owns: <the responsibility this file owns>.
# Sources: <the files, functions, or environment it depends on>.
```

## Enforcement

| Rule | Enforced by | CI context |
|---|---|---|
| Tracked shell passes shellcheck at `warning` | `./tests/check.sh lint` → `tests/lint.sh` | `lint-shellcheck` |
| Tracked shell file is at or under 500 lines, with an allowlist ratchet for existing offenders | `./tests/check.sh line-cap` → `tests/shell-line-cap.sh` (also in `fast`) | `lint-shellcheck` |
| Tracked shell is shfmt-clean | `./tests/check.sh shfmt` → `tests/format.sh check` | `format-shfmt` |
| Python passes ruff lint and format check | `./tests/check.sh ruff` | `lint-ruff` |
| Python type-checks under the pinned mypy | `./tests/check.sh mypy` | `type-mypy` |
| API endpoint literals and contract entries match | `./tests/check.sh contracts` (also part of `fast`) | — |
| No secret in the tree | `./tests/check.sh secrets` → `tests/secret-scan.sh`, reconciled against `tests/secret-scan.expected` | `secret-scan` |
| No secret in reachable history | `./tests/check.sh secrets-history` — run before a push that publishes new history, not in any tier | — |
| Shell parses, Python byte-compiles, compose renders across profiles | `./tests/check.sh unit` → `tests/unit.sh` tiers 1, 3, 5 | `unit-host` |
| Every `tests/unit/*.sh` suite passes | `tests/unit.sh` tier 6 | `unit-host` |
| `tests/lint.sh` sweeps shellcheck exactly once over the whole file list | `tests/unit/lint-sweep.sh` | `unit-host` |
| Wizard PTY behaviour | `./tests/check.sh wizard` → `tests/ci-scenarios.sh` + `tests/run.sh` | `wizard-ui` |
| No private, host, or credential artifact is tracked | `tests/unit/repository-safety.sh` over `tests/lib/repo_guard.py` | `unit-host` |
| Control files exist and their relative links resolve | `tests/unit/docs.sh` | `unit-host` |
| Exactly one `CONTRIBUTING.md` in the tree | `tests/unit/docs.sh` | `unit-host` |
| Issue templates parse and route security reports privately | `tests/unit/docs.sh` | `unit-host` |
| Every decision record carries all six required sections and is listed in the decisions index | `tests/unit/docs.sh` | `unit-host` |
| `docs/operations/upgrades.md` matches the live `docker-compose.yml` tags | `tests/unit/upgrades-manifest.sh` | `unit-host` |

The DinD battery (`./tests/check.sh full`, `tests/battery.sh`) runs no CI
context by design — see the CI boundary in
[`../tests/README.md`](../tests/README.md). It is a local gate only.

Every derived population in these suites fails closed: a check over an empty
list is an assertion that proves nothing, so an empty population is a failure
rather than a pass.

## Suppressions

Keep repo-wide ShellCheck suppressions in `.shellcheckrc`, not scattered inline
through individual files. The file explains each currently suppressed code;
the runner accepts a native ShellCheck only when it matches the pinned version,
then a sha256-verified cached pin (`./tests/lint.sh install`), and otherwise
uses the pinned container — the same engine version on every rung.

## Contributing

[`../CONTRIBUTING.md`](../CONTRIBUTING.md) is the contributor entry point:
issue-first for anything beyond an obvious fix, the pull-request checklist, the
opt-in rules for tracker/indexer and NVIDIA driver behaviour, and the
contribution-licensing terms. Read it before opening a pull request; this file
covers the mechanics it points at.

Documentation follows the code. Code and compose files are authoritative — when
a doc disagrees with the tree, fix the doc.

## Agent tooling

[`../AGENTS.md`](../AGENTS.md) is the routing entry point for anyone, human or
automated, arriving without context.


## Not enforced

These are conventions, judgement calls, or documented workflows that no test,
lint rule, or CI job checks. Follow them; do not mistake them for gates.

- **Unit-test naming.** The 1:1 source-to-`tests/unit/<name>.sh` basename rule
  is a convention; no checker currently verifies the correspondence.
- **Service-module shape.** The required `main.sh` with optional `render/` and
  `templates/` layout is a convention; no checker currently verifies it.
- **New-file header contract.** The two-line `Owns`/`Sources` header is a
  convention; no checker currently verifies it.

- **The "Adding a New Service" checklist** in `project/structure.md`. Nothing
  verifies that the tree section, the `config.yml` section, or the
  `scripts/configure.sh` loop entry were updated alongside a new service.
- **The dependency-direction rules** in `project/structure.md` (no cross-service
  imports, no cross-module `scripts/setup/*` imports). No import graph is
  computed; a violation lints clean.
- **The "Bumping a Service Version" preflight.** `tests/unit/upgrades-manifest.sh`
  checks that the manifest's claims are internally consistent with compose and
  the digest lock. It cannot tell whether the preflight scenario was actually
  run before the tag changed.
- **The `project/structure.md` tree, the `project/stack.md` service table and
  host-dependency list, and the documented container/configurator counts.**
  Nothing derives any of them from `docker-compose.yml` or `scripts/`, so a
  service added or removed leaves every one of them stale and green.
- **Prose claims with no single mechanical source** — the wall-clock scenario
  budgets, the CI summary in `project/stack.md`, the per-service "what gets
  configured" table in `README.md`. Judgement, re-read when the thing changes.
- **The evolution triggers** in `project/structure.md` (service `main.sh` over
  200 lines, features touching 2+ services, new shared *arr patterns). Advisory
  thresholds with no measurement.
- **Relative links outside the control-file set.** `tests/unit/docs.sh` checks
  links in `README.md`, `CONTRIBUTING.md`, `docs/README.md`,
  `.github/SECURITY.md`, `AGENTS.md` and this file. Links in every
  other document, and anchor fragments everywhere, are unchecked.
- **The reading order and index in `docs/README.md`.** The links are checked;
  that the index still lists every document is not.
- **The CI workflow's own shape.** Nothing checks that every `check.sh`
  selector is run by some job, that a job declares `timeout-minutes`, or that
  branch protection's required contexts still match the job names in
  `.github/workflows/ci.yml`. Read the workflow when you change a gate.
- **README menu screenshot freshness.** The PNGs under `docs/assets/` are
  manually refreshed snapshots. This repository has no capture generator or
  freshness gate, so review them when launcher menus change.
- **The admin-port list in `scripts/setup/hardening/firewall.sh`.** Nothing checks that
  the `MEDIASTACK-DOCKER-RESTRICT` multiport rules still cover every admin port
  published by `docker-compose.yml`. A new admin service whose port is not added
  there is exposed on a hardened host and lints clean. See
  [`decisions/admin-port-exposure.md`](decisions/admin-port-exposure.md).
- **The uninstall teardown of `MEDIASTACK-DOCKER-RESTRICT`.**
  `tests/unit/uninstall-system-cleanup.sh` drives `_uninstall_ufw`, but its `sudo`
  stub fails every `iptables` call, so the delete/flush/delete-chain block in
  `scripts/setup/hardening/firewall.sh` is never observed. Deleting that block leaves every
  host unit suite green while an uninstalled or firewall-disabled host keeps a
  live chain DROPping 16 ports.
- **Lint suppressions.** Nothing inventories the inline `# shellcheck disable=`,
  `# noqa` and `# type: ignore` directives or the tool-wide disable lists, so a
  new one lands unreviewed unless a reader notices it in the diff.
- **Whether a decision record is still true.** Its shape and its index entry are
  checked; that its reopen condition has not already fired is not.
- **Commit-message shape.** No convention is imposed and none is checked.
- **This document.** Its existence and links are checked; whether a row in the
  enforcement table still describes what the named suite does is not. Re-read it
  when you change a gate.
