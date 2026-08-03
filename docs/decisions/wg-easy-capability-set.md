# wg-easy runs with four added capabilities, not `privileged`

## Context

The `wireguard` service in `docker-compose.yml` runs wg-easy v15 on the
`mediastack` bridge. A WireGuard endpoint needs kernel-level privilege that an
unprivileged container does not have: it creates a `wg0` interface, programs
routes, and — because wg-easy enforces per-client `firewallIps` server-side —
writes packet-filter rules of its own.

The container also mounts the repository's `config/wireguard/` directory, which
`setup.sh` creates owned by the installing user (`PUID:PGID`, typically
`1000:1000`) rather than by root, so the operator can read and back up peer
configuration without `sudo`.

Nothing else in the stack asks for elevated capabilities except fail2ban, which
takes `NET_ADMIN` + `NET_RAW` to write its own ban chains. Granting more than
wg-easy needs would put the widest privilege in the stack on the one service
that is reachable from the internet.

## Decision

The service declares `cap_drop: [ALL]` and then adds exactly four capabilities:

| Capability | What it is for |
|---|---|
| `NET_ADMIN` | Create and configure the `wg0` interface, set its addresses, routes and `fwmark`. Without it wg-easy cannot bring the tunnel up at all. |
| `NET_RAW` | Program the packet-filter rules that enforce each peer's `firewallIps`. The access-tier model is server-enforced, not advisory, so this is what makes a Streaming-tier peer actually unable to reach Sonarr. |
| `SYS_MODULE` | Load the host's `wireguard` kernel module when it is not already loaded. Paired with the read-only `/lib/modules` mount; on a host where the module is built in or preloaded, nothing uses this. |
| `DAC_OVERRIDE` | Let container-root write `wg0.conf` and `wg-easy.db` into the user-owned `config/wireguard/`. |

`security_opt` keeps the default seccomp and `no-new-privileges` profile shared
by every service in the file.

## Rejected alternatives

- **`privileged: true`.** The shortest path and what much WireGuard documentation
  suggests. Rejected: it grants every capability plus device access to the one
  container with a port forwarded from the internet, and it removes the ability
  to notice that the required set grew.
- **Chown `config/wireguard/` to root and drop `DAC_OVERRIDE`.** Rejected: the
  operator would need `sudo` to read or back up their own peer configuration,
  and the install path is deliberately non-root. `DAC_OVERRIDE` is the narrower
  of the two.
- **Require the host to preload the `wireguard` module and drop `SYS_MODULE`.**
  Rejected for now: it converts a container-internal detail into a documented
  host prerequisite for every user, on a project whose premise is that the
  installer handles host setup. See the reopen condition.
- **`linuxserver/wireguard` instead of wg-easy.** Rejected on the product axis
  (peer management by hand-edited config files, no web UI), recorded in
  `docs/project/stack.md`; it does not need a smaller capability set.

## Consequences

- The capability set is a contract, not an implementation detail:
  `tests/scenarios/wireguard.sh` asserts `cap_add` is exactly these four and
  `cap_drop` is `ALL`, so an upstream image that starts wanting a fifth fails
  the preflight rather than silently acquiring it.
- A host whose kernel has no `wireguard` module and no headers still fails; the
  capability lets wg-easy load a module that exists, not build one.
- Shrinking the set later is a compose edit plus a scenario edit — both visible
  in one diff.

## Reopen condition

Reopen when either is true:

- The Debian floor recorded in `docs/project/stack.md` guarantees the
  `wireguard` module is built in or autoloaded on a stock install. Then drop
  `SYS_MODULE` and the `/lib/modules` mount, and re-run
  `./tests/run.sh wireguard` to prove the tunnel still comes up.
- wg-easy gains a documented rootless or reduced-capability mode. Then re-derive
  the minimum set against that documentation rather than trimming by experiment.

## Enforcement

`tests/scenarios/wireguard.sh` — the compose-contract block asserts the exact
`cap_add` list and `cap_drop: ALL` before it exercises the API. A capability
added to or removed from `docker-compose.yml` without updating that assertion
fails the `wireguard` scenario.
