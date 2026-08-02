# Decision records

Design decisions whose reasoning is not already carried by the code, the tests,
or a reference document. A decision that `docker-compose.yml`, a scenario
assertion, or a section of `docs/design/architecture.md` already explains in
full belongs there and not here — this directory exists for the cases where the
tree shows *what* without anywhere showing *why*, and where getting it wrong
later would be expensive.

Records are named by slug, not numbered. There is no series to be complete
about: adding one is a judgement that a specific rationale gap exists.

Every record carries the same six sections, in this order, and
`tests/unit/docs.sh` fails if one is missing:

`## Context` · `## Decision` · `## Rejected alternatives` · `## Consequences` ·
`## Reopen condition` · `## Enforcement`

`## Enforcement` names the test, guard, or check that holds the decision in
place — or says plainly which part of it nothing enforces.

| Record | Decision |
|---|---|
| [admin-port-exposure.md](admin-port-exposure.md) | Admin ports bind on all interfaces and are confined by a MediaStack-owned `DOCKER-USER` chain, installed only when host hardening is accepted. |
| [wg-easy-capability-set.md](wg-easy-capability-set.md) | The VPN container drops all capabilities and adds exactly four, rather than running privileged. |

The table is checked: `tests/unit/docs.sh` fails if a record is missing from it
or if a row names a file that does not exist.
