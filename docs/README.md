# MediaStack Docs

MediaStack is a turnkey single-box media server. These docs explain the public
installation, runtime, test, and maintenance surface.

## Design

| Doc | One-line hook |
|-----|---------------|
| [design/architecture.md](design/architecture.md) | Services, dependency graph, bridge network, security layer, and media layout. |
| [decisions/README.md](decisions/README.md) | Decision records: the reasoning the code and tests do not carry, with rejected alternatives and reopen conditions. |

## Setup

| Doc | One-line hook |
|-----|---------------|
| [setup/setup-flow.md](setup/setup-flow.md) | `setup.sh` phase by phase, including recovery and hardware transcoding. |
| [setup/storage.md](setup/storage.md) | Local, managed NFS/NAS, and manual storage modes. |
| [setup/configure-flow.md](setup/configure-flow.md) | `scripts/configure.sh` service wiring and idempotency patterns. |
| [setup/configuration-schema.md](setup/configuration-schema.md) | `config.yml`, `.env.example`, and tracked seed config reference. |

## Operations

| Doc | One-line hook |
|-----|---------------|
| [operations/day-2.md](operations/day-2.md) | Day-2 updates, recovery, and troubleshooting. |
| [operations/upgrades.md](operations/upgrades.md) | Image pin policy and candidate-image preflight workflow. |
| [operations/image-updates.md](operations/image-updates.md) | What to do when the image drift alert fires. |
| [operations/image-digests.lock](operations/image-digests.lock) | Stable-channel image digest record. |

## Testing And Reference

| Doc | One-line hook |
|-----|---------------|
| [../tests/README.md](../tests/README.md) | DinD, unit, and scenario test surfaces (live-host proof is maintainer-only). |
| [reference/quality-bounds.md](reference/quality-bounds.md) | Quality profile bounds and tuning reference. |

## Project

| Doc | One-line hook |
|-----|---------------|
| [project/stack.md](project/stack.md) | Runtime, services, commands, and host dependencies. |
| [project/structure.md](project/structure.md) | Directory tree, placement rules, and service-add workflow. |
| [conventions.md](conventions.md) | Gate commands, placement, what is enforced, and what is not. |

## Reading Order

1. [design/architecture.md](design/architecture.md)
2. [setup/setup-flow.md](setup/setup-flow.md)
3. [setup/storage.md](setup/storage.md)
4. [setup/configure-flow.md](setup/configure-flow.md)
5. [setup/configuration-schema.md](setup/configuration-schema.md)
6. [../tests/README.md](../tests/README.md)
7. [operations/day-2.md](operations/day-2.md)
8. [operations/upgrades.md](operations/upgrades.md)
9. [project/stack.md](project/stack.md)
10. [project/structure.md](project/structure.md)

Code and compose files are authoritative. When docs disagree with code, update
the docs.
