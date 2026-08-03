# Admin ports bind on all interfaces and are confined by the host firewall

## Context

MediaStack publishes several administrative UIs on the host: NPM admin (81),
wg-easy admin (51821), DDNS Updater (8000), Uptime Kuma (3001), Portainer
(9000), and the *arr / download UIs. None of them should ever be reachable from
the internet, and several of them are reachable with a password that the
installer also uses elsewhere.

Docker publishes a port by inserting rules ahead of the host's own firewall, so
a UFW `deny` alone does not cover a published container port. Two mechanisms are
therefore available: bind the port to `127.0.0.1` in `docker-compose.yml`, or
filter it in the `DOCKER-USER` chain that Docker leaves for exactly this
purpose.

## Decision

Publish admin ports on all interfaces, and confine them with a MediaStack-owned
iptables chain installed by host hardening.

`setup_ufw_docker_rules` in `scripts/setup/hardening.sh` writes a
`MEDIASTACK-DOCKER-RESTRICT` chain into `/etc/ufw/after.rules`, jumped to from
`DOCKER-USER`. The chain `RETURN`s traffic from `127.0.0.0/8`, `10.0.0.0/8`,
`172.16.0.0/12` and `192.168.0.0/16`, then `DROP`s the admin-port list —
including 81 and 51821 — for every other source, and `RETURN`s the rest so 80,
443 and the torrent port pass through.

The chain is installed when `UFW_ENABLED=true`, which is the Stage 1 wizard's
default and its recommendation. A user who declines the firewall keeps the
published ports and gets convention only: the router must not forward them.
`docs/design/architecture.md` states both branches rather than the stronger one.

## Rejected alternatives

- **Bind admin ports to `127.0.0.1` in `docker-compose.yml`.** The strongest
  option and the one a security reviewer expects. Rejected because it breaks the
  product: these UIs are meant to be opened from a laptop or phone on the LAN,
  and a `127.0.0.1` binding makes them reachable only by SSH tunnel from the box
  itself — for the explicitly non-technical target user, that is the same as
  removing the feature. It also breaks the VPN access tiers, whose whole design
  is a remote peer reaching a chosen subset of these ports.
- **Bind to the detected LAN IP instead of `0.0.0.0`.** Rejected: the binding
  would be baked into a generated compose overlay at install time and would
  silently stop serving after a DHCP change, a NIC swap, or a move between
  networks — a failure that presents as "the dashboard is gone" with no error.
- **Make hardening mandatory rather than opt-in.** Rejected: hardening also
  turns on default-deny inbound and unattended upgrades, which can lock a user
  out of their own SSH session on an unusual network. The opt-out stays, and the
  cost of taking it is stated where the exposure is described.
- **Rely on the router not forwarding the ports.** Rejected as the *only*
  mechanism — that is the state this decision replaced. It is still the fallback
  when the user declines the firewall, which is why the fallback is documented
  as a convention and not as a control.

## Consequences

- The guarantee is conditional. Any security claim about admin ports has to name
  the condition, and `docs/design/architecture.md` does.
- The protection is host state, not repository state: it can be lost by a
  `ufw reset`, by Docker rewriting `DOCKER-USER`, or by another tool flushing the
  chain. The day-2 *Health & security* menu therefore checks that the chain is
  still present and jumped to, and that check exists because losing it is silent.
- The admin-port list lives in two places that must agree: the multiport rules in
  `hardening.sh` and the host-port table in `docs/design/architecture.md`. A new
  admin service needs an entry in both.

## Reopen condition

Reopen when any is true:

- A per-service, LAN-scoped binding becomes expressible in compose without
  hardcoding a host IP (for example, a Docker network mode that resolves the LAN
  interface at start). Then bind directly and keep the chain as defence in depth.
- The published admin-port set grows past what the `-m multiport` rules can
  express (15 ports each, a kernel limit already noted in `hardening.sh`, which
  splits the current 16 ports across two rules). Needing a third rule means the
  admin surface has roughly doubled, which is the moment to re-derive the model
  rather than append to it.
- Any admin UI gains an authentication story strong enough to stand alone on the
  internet, at which point the question becomes which ports still need the chain.

## Enforcement

Partial, and deliberately named as such:

- `tests/unit/hardening.sh` proves `setup_ufw_docker_rules` writes the chain and
  the `DOCKER-USER` jump into the after.rules text, and that
  `setup_ufw_docker_dedup_hook` injects an after.init block carrying the
  `iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT` trim. Both are
  assertions over emitted text: nothing runs the trim against a doubled jump, so
  "exactly once" is written, not observed.
- `tests/scenarios/smoke.sh` fails if the rendered `proxy` profile binds *any*
  port to `127.0.0.1`, which pins the published-on-all-interfaces half of the
  decision. It is a whole-profile assertion, not a port-81 one: a deliberate
  loopback binding on some other service would fail it too.
- The day-2 *Health & security* check reports a missing or flushed chain on a
  live host.

Two gaps, both listed under "Not enforced" in `docs/conventions.md`:

- Nothing checks that the multiport list in `hardening.sh` still covers every
  admin port published by `docker-compose.yml`. Adding an admin service without
  adding its port leaves that port exposed on a hardened host.
- Nothing observes the uninstall teardown. `tests/unit/uninstall-system-cleanup.sh`
  drives `_uninstall_ufw`, but its `sudo` stub returns non-zero for every
  `iptables` call, so the delete/flush/delete-chain block in `hardening.sh` is
  never exercised.
