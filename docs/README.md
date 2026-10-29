# MediaStack Docs

MediaStack is a turnkey single-box media server. These docs have two groups.
Find your group first.

## Use MediaStack

For people who install and run a MediaStack server.

| Doc | Who it is for |
|-----|---------------|
| [../README.md](../README.md) | Anyone. Start here for an overview and the quick start. |
| [guide/install.md](guide/install.md) | A person who installs MediaStack for the first time. |
| [guide/using-the-menu.md](guide/using-the-menu.md) | An owner who runs the server with the `./mediastack` menu. |
| [guide/remote-access.md](guide/remote-access.md) | An owner who wants to reach the server from outside the home network. |
| [guide/troubleshooting.md](guide/troubleshooting.md) | An owner whose server does not work as expected. |

## Work on MediaStack

For people who change the code, compose files, tests, or docs.

| Doc | One-line hook |
|-----|---------------|
| [conventions.md](conventions.md) | Gate commands, file placement, what is enforced, and what is not. |
| [design/architecture.md](design/architecture.md) | Services, dependency graph, bridge network, security layer, and media layout. |
| [decisions/README.md](decisions/README.md) | Decision records: reasoning the code does not carry, with rejected options. |
| [project/stack.md](project/stack.md) | Runtime, services, commands, and host dependencies. |
| [project/structure.md](project/structure.md) | Directory tree, placement rules, and service-add workflow. |
| [project/workflow.md](project/workflow.md) | Branch topology, naming, and squash-merge rules. |
| [project/release.md](project/release.md) | The 0.x version policy and release gates. |
| [setup/setup-flow.md](setup/setup-flow.md) | `setup.sh` phase by phase, with recovery and hardware transcoding. |
| [setup/storage.md](setup/storage.md) | Local, managed NFS/NAS, and manual storage modes. |
| [setup/configure-flow.md](setup/configure-flow.md) | `scripts/configure.sh` service wiring and idempotency patterns. |
| [setup/configuration-schema.md](setup/configuration-schema.md) | `config.yml`, `.env.example`, and tracked seed config reference. |
| [setup/quality-bounds.md](setup/quality-bounds.md) | Quality profile bounds and tuning reference. |
| [operations/day-2.md](operations/day-2.md) | Day-2 internals: how the launcher and repair scripts work. |
| [operations/upgrades.md](operations/upgrades.md) | Image pin policy, bump preflight, and the image-drift workflow. |
| [operations/remote-image-preflight.md](operations/remote-image-preflight.md) | Operator-run NPM upgrade, staging renewal, public HTTPS, and receipt-gated acceptance. |
| [../tests/README.md](../tests/README.md) | DinD, unit, GCP VM, and LAN hardware test surfaces. |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | Pull request process and expectations. |

## Reading Order For Contributors

1. [conventions.md](conventions.md)
2. [design/architecture.md](design/architecture.md)
3. [project/structure.md](project/structure.md)
4. [setup/setup-flow.md](setup/setup-flow.md)
5. [../tests/README.md](../tests/README.md)

Code and compose files are authoritative. When docs disagree with code, update
the docs.

Image validation: [compatibility evidence](operations/image-compatibility.md) and
[hosted preflight](operations/hosted-image-preflight.md).
