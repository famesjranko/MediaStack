# AGENTS.md

Entry point for anyone — person or tool — working on this repository without
prior context.

MediaStack is a turnkey single-box media server: one guided setup, no config
editing, safe re-runs. Bash and Python (stdlib plus distro PyYAML; no pip),
orchestrating Docker Compose. Every design choice serves zero-friction setup
and low maintenance.

## Rules for every change

- Code and compose files are authoritative; when a document disagrees with
  the tree, fix the document.
- Configuration belongs in `config.yml`, not in bash. `docker-compose.yml`
  says how services run; `.env` (generated) holds secrets and host values.
- Setup must stay safe to re-run: skip what is already configured, warn on
  drift, never auto-reconcile.
- `./mediastack` is the only user-facing entry point, for install and day-2
  alike; it drives `setup.sh` and the other scripts. Users never run those
  directly.
- Never commit `.env`, live service config under `config/<service>/`, or
  generated host artifacts. A publication guard enforces this — see the
  enforcement table in [docs/conventions.md](docs/conventions.md).

## Read before working on…

| Area | Read | Why |
|---|---|---|
| Anything (first visit) | [docs/conventions.md](docs/conventions.md) | What is enforced, what is deliberately not, file placement |
| Services / compose | [docs/project/stack.md](docs/project/stack.md), [docs/project/structure.md](docs/project/structure.md) | Runtime model; where a new service's files go |
| `setup.sh` | [docs/setup/setup-flow.md](docs/setup/setup-flow.md) | Phase ordering that re-run safety depends on |
| Service configurators | [docs/setup/configure-flow.md](docs/setup/configure-flow.md) | Per-service wiring; skip/warn semantics |
| `config.yml` / `.env` keys | [docs/setup/configuration-schema.md](docs/setup/configuration-schema.md) | Full key reference; adding a key touches both |
| Storage paths | [docs/setup/storage.md](docs/setup/storage.md) | Local/NAS/manual modes constrain path handling |
| Image tags | [docs/operations/upgrades.md](docs/operations/upgrades.md) | Pin policy and the bump preflight |
| Tests themselves | [tests/README.md](tests/README.md) | Scenario layout, DinD battery, what runs where |
| A pull request | [CONTRIBUTING.md](CONTRIBUTING.md) | Process expectations |
| Anything else | [docs/README.md](docs/README.md) | Full doc index |

## Test before claiming done

| You changed | Run | Why |
|---|---|---|
| Nothing yet (first run on this machine) | `./tests/check.sh install` | Fetches the pinned dev tools (ShellCheck, shfmt, gitleaks) into the local cache — the fast tier then needs no Docker |
| Any shell | `./tests/check.sh fast` | ShellCheck, shfmt, ruff, mypy, secrets — no containers |
| Any Python | `./tests/check.sh ruff && ./tests/check.sh mypy` | Lint/format and types, isolated stages |
| Compose / config templates | `./tests/check.sh` | Adds compose render + unit + wizard scenarios |
| Setup/wizard flows | `./tests/check.sh` | Wizard scenarios run image-free here |
| Anything, before a PR | `./tests/check.sh` | Same coverage as the CI gate |
| Container behaviour | `./tests/check.sh full` | Complete DinD battery — slow, needs Docker |

Single-stage selectors (lint, shfmt, ruff, mypy, secrets, unit, wizard) are
documented in the usage header of [tests/check.sh](tests/check.sh).

## Build

There is no build step. The deliverables are the scripts and compose files
themselves. `./mediastack` is the user-facing entry point for install and
day-2 management; it drives `setup.sh` and the other scripts — users never
run those directly. Both are exercised by the test tiers above, not run
during development.
