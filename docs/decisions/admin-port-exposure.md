# Admin ports bind on all interfaces and are confined by an admin-port filter

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

The rule list lives once, in `scripts/setup/hardening/admin-filter.sh`. The
`MEDIASTACK-DOCKER-RESTRICT` chain, jumped to from `DOCKER-USER`, `RETURN`s
traffic from `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and
Tailscale's `100.64.0.0/10`, then `DROP`s the admin-port list — including 81 and
51821 over TCP and Jellyfin's discovery responder on 7359/udp — for every other
source, and `RETURN`s the rest so 80, 443, the torrent port and the WireGuard
port pass through. The IPv6 mirror `RETURN`s `::1/128`, `fc00::/7`, `fe80::/10`
and Tailscale's `fd7a:115c:a1e0::/48`.

The chain does not depend on UFW. It filters only traffic that Docker forwards
into containers, so it cannot lock out the host's own SSH session. The reason
this record gives for letting a user decline hardening (default-deny inbound can
lock out SSH) does not apply to it. `ADMIN_PORT_FILTER` (default `true`, absent
reads as `true`) is its own choice.

There is one install path, used whether UFW is on or off.
`setup_admin_filter_unit` in `scripts/setup/hardening/admin-filter.sh` installs
a self-contained apply script, a systemd oneshot
(`mediastack-admin-filter.service`) that runs before `docker.service`, and a
`docker.service` drop-in. All three are recorded in the ownership ledger and
carry a marker, so uninstall and the opt-out remove only files that are still
MediaStack's. The script loads the chain with `iptables-restore --noflush`,
creates `DOCKER-USER` when Docker has not yet, inserts the jump at position 1,
repairs a jump that sits behind Docker's `RETURN`, and checks every rule with
`-C`. UFW toggles touch only UFW; they never touch the chain.

**Why the `/etc/ufw/after.rules` block was dropped.** Earlier versions wrote the
chain into `after.rules` and `after6.rules` when UFW was on. Three defects of
that path were reproduced with real `iptables` in a throwaway user+net
namespace:

1. `ufw reload` appends `-A DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT` behind
   Docker's own `-j RETURN`. On a running Docker the chain never ran.
2. The v4 block did not declare `DOCKER-USER`, so `iptables-restore` failed when
   UFW loaded before Docker created the chain.
3. Declaring a chain that already exists under `--noflush` flushes it.

With the systemd path needed anyway for hosts without UFW, one mechanism is
simpler than two.

**Migration.** A host set up by an earlier version holds the MediaStack block in
both files. On every setup run and on the day-2 UFW and filter toggles,
`setup_admin_filter` installs the unit path first and re-runs the apply script
to confirm the chain verifies. Only then does it strip the block between
`# MEDIASTACK-DOCKER-RULES` and `# END MEDIASTACK-DOCKER-RULES` from each file,
together with the one blank line the old writer put before it. Every other byte
stays. A begin marker without an end marker is not touched, and setup fails.
UFW is not reloaded, so the live chain is never dropped. If the unit path fails
to install or verify, the blocks stay and hardening returns non-zero. The
block was never ledgered, so it is found by its markers, which also lets the
opt-out and the best-effort uninstall (no ledger) remove it.

Failure is loud and closed. The drop-in gives `docker.service` `Requires=` and
`After=` on the oneshot. `systemd.unit(5)` states that when a required unit
"fails to activate, and an ordering dependency After= on the failing unit is
set, this unit will not be started". If the filter cannot be applied, Docker
does not start, so no port is published. The oneshot has no `Condition*` line:
the same page says a failed condition does not fail the start job of a unit that
`Requires=` it. After applying, the script checks every rule with
`iptables -C` / `ip6tables -C` and exits non-zero if the jump or any rule is
missing. It also fails when `iptables` and `ip6tables` use different backends
(nf_tables versus legacy). The drop-in re-runs the check as an `ExecStartPost`
of `docker.service`, which additionally requires `FORWARD` to reach
`DOCKER-USER`; that catches a Docker that uses a different firewall backend.

The chain covers an address family only where the kernel has it: the script
skips `ip6tables` when the kernel has no IPv6.

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
  out of their own SSH session on an unusual network. UFW stays optional. The
  admin-port filter was split out of it because it carries no lockout risk.
- **Keep a second, UFW-path mechanism in `after.rules`.** This was the design
  until this change. Rejected for the three defects above.
- **Tie the chain to UFW, and call a declined firewall "convention only".**
  This was the earlier decision. Rejected: it left every admin port reachable
  from any source a router forwards for a user who declined an unrelated SSH
  risk. The chain now has its own opt-out instead.
- **Warn when UFW is off and install nothing.** Rejected: a warning that does
  not close the exposure is the same failure, reported.
- **Start Docker even if the filter failed to apply.** Rejected: a quiet failure
  is the exposure this record exists to prevent. See the trade-off below.
- **Rely on the router not forwarding the ports.** Rejected as the *only*
  mechanism — that is the state this decision replaced.

## Consequences

- The guarantee holds unless the user sets `ADMIN_PORT_FILTER=false`. Any
  security claim about admin ports has to name that condition, and
  `docs/design/architecture.md` does.
- **Fail-closed trade-off.** A filter that cannot be applied stops Docker: the stack does not start until the cause is fixed or the user
  turns the filter off. This is deliberate. The cost is an outage that presents
  as "Docker will not start"; `systemctl status mediastack-admin-filter` and the
  day-2 *Health & security* menu name the cause. The chance of it is small:
  the script needs only `iptables`, and it is applied before Docker starts. One
  window remains: if the post-start `ExecStartPost` check fails on a Docker that
  uses another firewall backend, Docker has already started containers, and
  systemd then stops it.
- **Opt-out.** The Stage 1 security section offers it when the firewall is
  declined, and the day-2 *Features & settings* menu toggles it at any time.
  Turning it off removes the unit, the drop-in, the chain and any legacy
  `after.rules` block through the ledger, leaves Docker able to start, and
  makes ports 81, 51821, 8000, 3001, 9000, the *arr and download UIs and
  7359/udp reachable from any source a router forwards. The main menu does not warn for a deliberate opt-out; the Health
  menu reports it as the user's choice.
- **wg-easy runs with `INSECURE=true`.** The wg-easy admin UI is served over
  plain HTTP on the LAN, and wg-easy refuses to log in over HTTP unless this is
  set. That is acceptable only because 51821 is confined to private sources by
  this chain. It is one more reason the chain must not depend on a firewall the
  user can decline.
- The protection is host state, not repository state: it can be lost by a
  another tool flushing the chain or inserting a rule ahead of the jump, or a
  jump that ends up behind Docker's own trailing `RETURN`. `ufw reset` and
  `ufw reload` no longer reach it. Docker itself does
  not flush `DOCKER-USER` (the moby source says the daemon "does not delete or
  modify any pre-existing rules" there, v26 through v28). The day-2 *Health &
  security* menu checks the chain, the jump, the jump's position, the unit and
  the drop-in, with UFW on or off. `./mediastack` also prints a warning
  under the banner while the filter is wanted but not active.
- Docker 28 and later can run with an nftables firewall backend, which has no
  `DOCKER-USER` chain. The post-start check fails there, which stops Docker
  until the user switches backend or turns the filter off.
- The admin-port list lives in two places that must agree: the rule data in
  `hardening/admin-filter.sh` (rendered for both families and both paths) and
  the host-port table in `docs/design/architecture.md`. A new admin service
  needs an entry in both.

## Reopen condition

Reopen when any is true:

- A per-service, LAN-scoped binding becomes expressible in compose without
  hardcoding a host IP (for example, a Docker network mode that resolves the LAN
  interface at start). Then bind directly and keep the chain as defence in depth.
- The published admin-port set grows past what the `-m multiport` rules can
  express (15 ports each, a kernel limit noted in `hardening/admin-filter.sh`, which
  splits the current 16 TCP ports across two rules; the single UDP port has a
  rule of its own). Needing a third TCP rule means the admin surface has roughly
  doubled, which is the moment to re-derive the model rather than append to it.
- Any admin UI gains an authentication story strong enough to stand alone on the
  internet, at which point the question becomes which ports still need the chain.

## Enforcement

Partial, and deliberately named as such:

- `tests/unit/hardening/admin-filter.sh` proves the rules are rendered once for
  both families (Tailscale ranges included), that with UFW on or off the unit,
  the drop-in (`Requires=`, `After=`, `ExecStartPost`) and the ledger entries are
  written and nothing reaches `after.rules` or `after6.rules`, and that the opt-out
  writes none. It proves the migration: with legacy blocks and the user's own text
  around them, the chain is applied before the first rewrite, only the blocks go
  (the files end byte-identical to the user's text), a failed install or verify
  leaves them and fails hardening, and an unterminated block is never cut. A
  regression case models `ufw reload`, `enable` and `disable` loading the after
  files into a stateful fake `iptables` after Docker's `RETURN` is in place: one
  jump stays at position 1 and the chain stays populated.
  `tests/unit/hardening/admin-filter-script.sh` runs the generated apply script
  against the same fake: it exits non-zero when the load fails, when a rule or
  the jump is missing afterwards, and on a backend mismatch, and a re-run leaves
  one jump. Two cases run against the real `iptables` in a throwaway user+net
  namespace (the script alone, and the script followed by ufw-style loads of
  the after files) and skip where the host forbids it.
- `tests/unit/hardening/firewall.sh` proves `setup_ufw` neither writes
  `after.rules`/`after6.rules`, nor reloads UFW, nor reads `DOCKER-USER`.
  `tests/unit/hardening/firewall-dedup.sh` proves `setup_ufw` no longer writes
  `after.init`, and that the migration removes the old dedup hook: a file
  MediaStack created goes, the stock sample comes back byte for byte with its
  mode, and a custom or unterminated file is left alone. The hook ran
  `iptables -D DOCKER-USER -j MEDIASTACK-DOCKER-RESTRICT`, and `-D` deletes the
  first match, which is the unit's position-1 jump.
- `tests/scenarios/smoke.sh` fails if the rendered `proxy` profile binds *any*
  port to `127.0.0.1`, which pins the published-on-all-interfaces half of the
  decision. It is a whole-profile assertion, not a port-81 one: a deliberate
  loopback binding on some other service would fail it too.
- `tests/unit/health-check.sh` drives the port-lock verdicts with UFW on and
  off: missing chain, empty chain, missing jump, jump behind a `RETURN`, a missing
  drop-in, a missing or failed or inactive unit, the opt-out shown as the user's
  choice, and the `./mediastack` warning line (shown when the filter is wanted
  and inactive, absent after an opt-out).
- `tests/unit/uninstall-admin-filter.sh` proves uninstall and the opt-out remove
  the unit, the drop-in, the chain and legacy `after.rules` blocks (with or
  without a ledger) through the ledger, reload systemd before the unit stops so
  Docker keeps running, leave a file without the marker alone, and return
  non-zero when a removal fails. It also proves the UFW teardown leaves the
  chain and `after.rules` alone. `tests/unit/launcher-features.sh` proves the
  day-2 toggles converge the filter before they touch UFW, and that a failed
  filter install stops the UFW change. `tests/unit/uninstall-system-cleanup.sh`
  drives `_uninstall_ufw` with a `sudo` stub that fails every `iptables` call.

Not observed by any test, and left to a live host:

- That `docker.service` really refuses to start when the oneshot fails, and that
  a reboot applies the chain before Docker publishes a port. The ordering rests
  on the `systemd.unit(5)` text quoted above.
- That a real `ufw reload` or `ufw disable` leaves the chain alone on a running
  Docker. The tests model UFW's load of the after files; they do not run `ufw`.

One gap, listed under "Not enforced" in `docs/conventions.md`:

- Nothing checks that the port list in `hardening/admin-filter.sh` still covers
  every admin port published by `docker-compose.yml`. Adding an admin service
  without adding its port leaves that port exposed.
