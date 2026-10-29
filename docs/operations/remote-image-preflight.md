# Remote image preflight

Use this operator-run check for an NPM digest that needs public WAN evidence.
It installs the accepted stack, seeds user state, upgrades NPM through the real
`scripts/update.sh`, and tests the candidate from the public internet.
It then deletes the disposable VM. It publishes a local receipt only after
deletion is verified. It does not change the accepted digest lock.

Read [the hosted gate](hosted-image-preflight.md),
[the compatibility matrix](image-compatibility.md), and
[local image acceptance](upgrades.md) first.

For an agent-run check, load the portable
[remote-image-preflight skill](../../skills/remote-image-preflight/SKILL.md).
It adds target, cost and cleanup guardrails to this runbook. The repository keeps
this public workflow under `skills/`; private runtime skill directories stay out
of the published tree.

## Coverage

The current command supports **NPM only**:

```bash
tests/gcp-vm/run-candidate.sh npm --plan /path/to/plan.json \
  --plan-hash WEEKLY_PLAN_HASH --output .tmp/npm-evidence
```

The application-state oracle uses `--settings-only` on the remote guest. It
seeds and compares users, credentials, integrations and settings. Media history,
watch state and torrent resume fixtures remain exclusive to the DinD upgrade
proof. A snapshot records its scope; a check with a different scope fails.

It proves:

- The real setup installs the accepted Stable lock and enables remote access.
- Stored application credentials and representative user records survive.
- NPM proxy IDs, forwarding rules, certificate IDs, certificate and private-key
  fingerprints, credentials, and a deliberate
  user proxy survive before reconfiguration can repair missing state.
- Reconfiguration preserves that state.
- Both managed certificates renew through NPM against Let's Encrypt staging.
  Their leaf fingerprints change, while their database IDs stay the same.
- Public DNS points to the VM. Public HTTPS serves Jellyfin and Seerr with the
  exact renewed certificates. WAN connections to the canonical admin ports fail.

The baseline uses the same synthetic local tracker as the DinD migration tests.
The harness registers it in Jackett, Sonarr and Radarr before saving user state.
This populates the shared migration oracle when the installer's optional public
indexers are disabled. The tracker uses a digest-pinned helper image on the
stack network, publishes no host port and makes no public tracker calls.

NPM's hosted acceptance requires fresh setup, local migration and renewal with
Pebble. This remote proof adds public DNS, staging ACME and WAN firewall evidence.
Remote receipts do not enter the hosted publisher or replace the local scenarios.

Local WireGuard scenarios cover stored peer migration and an existing IPv4
client's handshake and tunnel traffic. Public WAN access remains a separate
proof. DDNS candidate pushes and fail2ban candidate host bans also need separate
proofs.
This check uses their accepted images as companions; it does not approve them.
NAS checks need a disposable lab guest and the TrueNAS test appliance. GPU checks
need a disposable guest with the P600. Those commands are not implemented yet.
FlareSolverr stays held because there is no deterministic challenge-solving
oracle.

## One-time setup

Use a Linux x86-64 operator host with Python 3, git, gcloud, `getent`, and network
access to the GCP VM. Authenticate gcloud with the intended account. The harness
passes the project on every cloud call and does not change the active project.

Configure a dedicated disposable target in the gitignored `tests/.env.gcp`.
Copy [the example](../../tests/.env.gcp.example) if needed. Set `PROJECT_ID`,
`ZONE`, `INSTANCE`, `MACHINE_TYPE`, `BOOT_DISK_SIZE`, `DOMAIN`, `NPM_ADMIN_EMAIL`,
and `DDNS_PASSWORD`. Set `GCP_EXPECT_TARGET` to exactly
`PROJECT_ID/ZONE/INSTANCE`. Use an unused instance name. The harness refuses to
replace an existing VM.

Use a dedicated test DNS name and Dynu credentials with the narrowest available
scope. Enable its `jellyfin` and `seerr` subdomains. The check pushes the new VM
address to those names. **DNS records remain pointed at that address after the
VM is deleted.** Never use a daily server's names or credentials.

The project needs the existing `mediastack-public` firewall tag rules described
in the [GCP harness prerequisites](../../tests/gcp-vm/README.md#prerequisites-one-time).
Allow public TCP 80, 443 and 6881, plus SSH from the operator host. Do not open
the admin ports. This harness creates no firewall rule or service-account key.
The VM has no attached service account and no OAuth scopes.

`NPM_LE_SERVER` must be the staging endpoint, or absent:

```text
https://acme-staging-v02.api.letsencrypt.org/directory
```

An empty value is refused. Staging certificates are untrusted. The public probe
checks the exact leaf certificate instead of trusting a successful TLS request
alone. Staging has [generous rate limits](https://letsencrypt.org/docs/staging-environment/),
not unlimited issuance. Never substitute the production endpoint.

## Frozen inputs and offline validation

Download the `preflight-plan` artifact from the weekly run:

```bash
gh run download RUN_ID --repo famesjranko/MediaStack \
  --name preflight-plan --dir /path/to/weekly-plan
```

Use a clean checkout at the artifact's source SHA. Read the plan hash in the
planner's GitHub step summary. New plans include every resolved digest, including
held services, in their hash. A changed hash, source, baseline, tag, or repository
is refused before the harness contacts GCP.

Validate locally first:

```bash
tests/gcp-vm/run-candidate.sh npm --plan /path/to/weekly-plan/plan.json \
  --plan-hash WEEKLY_PLAN_HASH --preflight
```

This command makes no cloud, SSH, registry, or live endpoint call. Without a local
credential file it validates the example target. It does not prove authentication,
quota, DNS control, network reachability, or current prices.

For an older weekly artifact, or an explicit frozen TSV, use:

```bash
tests/gcp-vm/run-candidate.sh npm --snapshot /path/to/current.tsv --preflight
tests/gcp-vm/run-candidate.sh npm --snapshot /path/to/current.tsv \
  --output .tmp/npm-evidence
```

An explicit snapshot must contain every service in the accepted lock. Only NPM
changes during the run. All companions use accepted digests. Review the snapshot's
origin yourself; an explicit TSV has no independent weekly plan-hash binding.
The remote plan records the full snapshot and has its own SHA-256 hash.

## Run, cost and cleanup

Before a live run, state the account, exact target and expected cost. Check current
Compute Engine prices for the configured zone, machine and disk. The default is
an `e2-medium` with a 30 GB standard boot disk. Budget approximately 15–30 minutes;
this is an estimate, not a measured candidate-run result. VM time, disk time and
network traffic are billable. A failed run can take longer.

Commit source changes before running. The harness sends `git archive HEAD` to
the VM. It sends only the selected remote inputs over SSH stdin. It does not copy
the operator's environment, git credentials or untracked files.

Run the command from [Coverage](#coverage). Select a new output directory each
time. Existing output directories are refused. The log prints the last stage
reached. Each cloud command and remote operation has a deadline.
Each public HTTPS request has a 30-second total deadline. This includes the
connection, TLS handshake, response headers and response body. A server that
keeps sending small amounts of data cannot extend the deadline.

Cleanup runs on success, failure, SIGINT and SIGTERM. It waits for pending cloud
creation before it verifies the VM's run
ownership label, deletes it, and lists the target again to prove absence. An
unacknowledged creation or unverified deletion blocks publication. A two-hour Compute Engine DELETE deadline
is a backstop for SIGKILL, lost power or a disconnected operator host. No local
trap can guarantee immediate cleanup in those cases.

Confirm that the log says `Verified: disposable VM deleted`. If it instead says
`Cleanup NOT verified`, inspect the exact target immediately:

```bash
gcloud --project=PROJECT_ID compute instances list \
  --filter='name=INSTANCE' --format='table(name,zone,status)'
```

Do not treat an authentication or API error as proof of absence. The boot disk is
created with automatic deletion. No static address or additional disk is created.

## Evidence and failures

A successful output directory contains `plan.json`, `current.tsv`, `run.log`,
`summary.md`, and `receipts.tsv`. The remote v3 receipt adds `plan_hash` between
`arch` and `recorded_at_utc` in the existing tab-separated format. Hosted v2
receipts stay unchanged. The remote harness verifies the receipt's `plan_hash`
against the reviewed plan before publication. Local acceptance requires the
three local scenario receipts; operator-run WAN evidence remains separate.

A failed or interrupted run publishes no receipt. Pending receipts are removed.
The failure names the operation that failed or reached its deadline. Common
causes are a missing digest, failed setup, lost NPM state, failed renewal,
stale DNS, unavailable public HTTPS, or a reachable admin port. Do not bypass a
failed check. Correct the cause and run again on a new target.

The local log contains harness stage labels and results. Raw setup output,
HTTP bodies, Docker events and private diagnostics stay on the guest and disappear
with it. Do not retrieve or publish those files: they can contain credentials.
Keep the reduced evidence outside tracked paths. Review it before attaching it
to a PR. Remote evidence is operator testimony, not a hosted attestation.

For a digest update, first collect the required local receipts from
`fresh-install`, `npm-upgrade` and `npm-renewal` at this source commit. The remote
receipt alone cannot authorize the update. Keep the local receipts in
`.tmp/npm-local-receipts.tsv`, then accept only the tested NPM row:

```bash
python3 scripts/image_drift.py \
  --previous docs/operations/image-digests.lock \
  --current-file .tmp/npm-evidence/current.tsv \
  --write-current docs/operations/image-digests.lock --accept-services npm \
  --preflight-receipt .tmp/npm-local-receipts.tsv
```

The harness checks the remote receipt's digest, source, scenario, architecture,
run and remote plan hash before it publishes evidence. The local acceptance gate
checks the required local receipts at the same source commit. Other lock rows
are preserved. Open a normal PR with both sets of evidence attached
or linked. State which checks used local fixtures and which used public WAN.
Never merge automatically.
