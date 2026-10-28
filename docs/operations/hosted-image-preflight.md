# Manual hosted image preflight

The `Image Drift Alert` workflow has an optional image preflight. The weekly
schedule still runs the lightweight alert only. Expensive image tests and digest
publication require a manual dispatch. The ordinary PR gate stays independent.

Run a measurement without publication:

```bash
gh workflow run image-drift.yml --ref main \
  -f preflight=true -f services=sonarr -f publish=false
```

After reviewing the workflow permissions and results, prepare a digest PR:

```bash
gh workflow run image-drift.yml --ref main \
  -f preflight=true -f services=sonarr,radarr -f publish=true
```

An empty `services` input selects changed images that have sufficient automated
coverage. The planner holds Bazarr, Beszel hub, Portainer, Uptime Kuma, NPM,
WireGuard and FlareSolverr for separate operator review. Their specific gaps are
listed in the [compatibility matrix](image-compatibility.md). Explicit selection
does not bypass a hold. Image tag/repository changes and service additions or
removals require a separately reviewed baseline change.

## Isolate, then combine

One run narrows the selection automatically:

1. **Phase 1.** Each selected candidate runs alone. Its jobs use that candidate
   digest plus the accepted digests of all other services. Each candidate runs
   every scenario that the manifest requires for it.
2. **Selection.** A read-only job reads the phase-1 results as data. A candidate
   passes only when all of its phase-1 jobs qualify. The job freezes a phase-2
   plan for the candidates that passed and records the failed candidates. The
   phase-2 plan hash goes through job outputs, like the phase-1 plan hash.
3. **Phase 2.** The candidates that passed run together through the union of
   their required scenarios. Only phase-2 evidence can authorize this
   combination. Phase-1 evidence never authorizes a different combination.

When exactly one candidate passes phase 1, its phase-1 jobs already tested the
exact combination: that candidate plus the accepted companions. Phase 2 does not
run. The phase-2 plan records this as `authority: phase-1`, and the verifier
accepts phase-1 evidence only for a single-candidate combination. When no
candidate passes, the plan records `authority: none` and nothing is published.

A qualifying job has a nonempty assertion population, no failed or skipped
assertions, complete disk measurements and sufficient
[disk headroom](#runner-disk). If phase 2 fails, the run publishes nothing. The
status report names the failure.

Phase 1 runs one job for each candidate and required scenario. A data-owning
service requires three scenarios. A selection of five data-owning candidates
therefore runs fifteen phase-1 jobs, two at a time. Select fewer services to
shorten a run.

## Contract gate

Passing scenarios do not prove that each API call of MediaStack still works. A
JSON helper can return a default value when a field has a new name. The contract
gate closes this gap. `tests/contracts/*.yml` lists each API call, the statuses
that it accepts and the response fields (`reads`) that MediaStack uses. See
[tests/contracts/README.md](../../tests/contracts/README.md).

Capture:

1. `fresh-install`, `upgrade-path` and `install-e2e` are the traced scenarios.
   They set `MS_CONTRACT_TRACE` only on the commands that start product code.
   Assertion requests are not traced.
2. In DinD, a `curl` wrapper writes a trace of each product request.
3. At scenario end, `tests/contracts/observe.py` runs in DinD. It connects each
   request to its inventory entry, and to the candidate image or to another
   image, through the container start events. It writes `contracts.json` to the
   job artifact. This file holds counts, statuses and the names of the reads
   seen. It holds no values, headers or bodies.
4. The raw traces stay in DinD and are deleted there.

Verdict (`tests/preflight/contracts.py`):

- Each traced job must upload its own `contracts.json`, for its scenario, run
  and candidates, with the inventory of the tested source. It must trace at
  least one request and parse all of them.
- For each candidate, the gate uses all of its traced jobs together. Each entry
  must have a call on the candidate digest with an accepted status. Each
  declared read must appear in an accepted response. No call to the candidate
  can be outside the inventory.
- An entry with `unexercised` (`gpu`, `remote-profile`, `launcher-menu`, `nas`,
  `held-profile` or `accepted-image-only`) is exempt. `accepted-image-only`
  means that the required scenarios make the call only while the service runs
  its accepted image, never the candidate. Examples are the installer's
  `GET /Users` in `install-e2e` and the system-status check after a Revert. An exempt entry that has a call on the candidate
  is reported as stale. It does not fail.
- A contract failure is an image failure. It is never undecided. In phase 1, it
  removes the candidate from the combination. In phase 2, final verification
  refuses the combination and nothing is published.

Failure messages name the exact entry:

| Message | Meaning |
|---|---|
| `sonarr quality-profile-list: not exercised on candidate (seen 404×2 in fresh-install)` | No call had an accepted status on the candidate. The message shows what was seen. |
| `sonarr quality-profile-list: missing reads items[].quality.id` | No accepted response had that field with a value. |
| `sonarr GET /api/v3/system/status: unlisted call (upgrade-path)` | MediaStack called a route that the inventory does not list. |
| `p1-sonarr.fresh-install: contracts.json is missing or unreadable` | The traced job uploaded no usable evidence. |
| `p1-sonarr.fresh-install: contract trace inactive: no product request was traced` | The wrapper recorded nothing. |
| `p1-sonarr.fresh-install: contract trace has 3 unparsed requests` | A local request has no known target or no request line. |
| `p1-sonarr.fresh-install: contract inventory fingerprint does not match the tested source` | The evidence comes from another inventory. |

A candidate without entries, for example socket-proxy, passes the gate. The
digest PR body and the status report say that its acceptance rests on its
scenarios. Both also list the exempt entries and the stale exemptions.

## Boundaries

The pipeline has these boundaries:

1. A read-only planner freezes the source SHA, candidate snapshot, accepted
   companions, fixture-image digests, architecture and job run IDs. Its
   canonical plan hash is passed through job outputs, independently of image-job
   artifacts.
2. Disposable hosted Ubuntu VMs run privileged DinD with read-only repository
   permissions, in phase 1 and in phase 2. At most two jobs of a phase run
   concurrently. Image execution receives no publishing token or live
   credentials. Each job has a 70-minute process deadline inside an 85-minute job
   deadline.
3. The read-only selection job and the read-only verifier check each plan hash
   and validate result data, exact-digest receipts, source/run identity,
   architecture, actual companion and fixture references, image inspections,
   pass/skip counts, resource fields and disk headroom. The verifier recomputes the selection
   from the phase-1 results and refuses a stale or different phase-2 plan. It
   writes a selective lock only after every authorizing result qualifies.
4. A separate publisher runs only on the default branch. It revalidates the
   original artifacts using trusted source code, refuses an advanced default
   branch, and maintains one rolling PR. It never runs candidate images, executes
   artifact code, pushes to `main`, or merges. Its write token exists only in
   this job. GitHub creates the PR-triggered CI run in an approval-required
   state. A maintainer must approve that run before the PR gate can pass.
5. A separate status job has only `issues: write`. It runs no image and no
   artifact code. It posts the run status, also when the planner fails.

Every job declares its own permissions. No job inherits a workflow-level
permission.

## Re-run a preflight

Use **Re-run all jobs** only. A partial re-run (**Re-run failed jobs** or one
job) reuses the plan outputs of the earlier attempt. GitHub does not document
which attempt's artifact a re-run job downloads, and `upload-artifact` does not
overwrite an artifact name that already exists. Each job
refuses a plan from another attempt of the same run, with the message
`partial re-runs are not supported, use Re-run all jobs`.

## Approve the PR's CI run

Open the generated PR and select **Approve workflows to run** in its merge box.
Review the diff before approval. This starts CI; it does not approve or merge
the PR. A manually dispatched CI run can pass on the same commit without
satisfying the ruleset. See [GitHub's token behavior](https://docs.github.com/en/actions/concepts/security/github_token#when-github_token-triggers-workflow-runs)
and [required-check event restrictions](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks#checks-from-some-workflow-jobs-are-not-evaluated).

A maintainer can also approve the pending PR run through the API, after checking
its event, source commit and associated PR:

```bash
gh api --method POST repos/OWNER/REPO/actions/runs/RUN_ID/approve
```

## Open-proposal policy

With `publish=true`, the publisher keeps one open digest PR. The PR head is the branch
`chore/tested-images`, and the PR has the label `tested-digests`. A newer
accepted run replaces the proposal: the newest run's tested combination is the
only proposal. A failed phase 2 accepts nothing. A run refuses a candidate when
the candidate fails phase 1, or when final verification of its combination does
not succeed. The publisher makes one decision per run:

| This run | Branch `chore/tested-images` and its PR | Action |
|---|---|---|
| Any result | PR not opened by `github-actions[bot]`, more than one open PR, PR head differs from the branch, or the branch has other commits | Refuse and fail. Change nothing. |
| Any result | Branch exists, no open PR, and the last PR with that head was closed without merging | Refuse and fail. Delete the branch to enable publication again. |
| Accepted a combination | No branch, a branch from a merged PR, or a publisher branch with no PR | Rebuild the branch from the default branch, push it with a lease, and open the PR. |
| Accepted a combination | Publisher-owned PR, different lock | Rebuild the branch from the default branch, force-update it with a lease, and refresh the PR body. |
| Accepted a combination | Publisher-owned PR, same lock | Keep the branch. Refresh the PR body so that it cites this run. Test timestamps are ignored. |
| Accepted nothing; refused an exact digest that the PR proposes | Publisher-owned PR | Comment on the PR with the run link, close it, and delete the branch with a lease. The next accepted run opens a new PR. |
| Accepted nothing; refused none of the PR's digests | Publisher-owned PR | Do nothing. The PR's evidence is the source and run that its description cites, not this run. |
| Accepted nothing | No PR | Do nothing. |

A publisher-owned branch has exactly one commit on top of the default branch.
That commit has the publisher's author, committer and message, and it changes
only the digest record and the README badges. Any other shape causes a refusal.
To recover, close the PR and delete the branch after review. If you close the
PR and keep the branch, the publisher refuses until you delete the branch. The
repository squash-merges and deletes merged branches, so the publisher reads the
closed PR list to find out whether a remaining branch was merged. Every push and
deletion uses a lease on the branch head that the publisher read. A concurrent
change makes the push fail. The repository ruleset protects only `main`, so it
permits this force-update.

## Status report

The status job posts one comment for each preflight run on the open
`image-drift` issue. The comment names the ref of the run. A run on a ref other
than the default branch is marked as a trial run. The comment gives one state
for each drifted service:

- proposed in PR #N;
- failed in phase 1 or phase 2, with links to the run and its artifacts. A
  [contract](#contract-gate) failure also names each failed entry;
- undecided because the disk headroom was exhausted in phase 1 or phase 2.
  The comment names each such job with its peak disk growth and the free bytes
  at the peak. The cause is not determined: the runner or the image can fill
  the disk;
- failed final verification, when the image jobs passed but the verifier
  refused the evidence. A phase-2 contract failure names each failed entry;
- held, with the reason from the compatibility hold list;
- not selected.

The comment also lists the phase-1 contract coverage limits: exempt entries,
stale exemptions and candidates without contract entries.

When the planner fails, for example on a registry outage, an invalid `services`
input or a lock that differs from compose, the comment says so and links the
run. When the status job cannot validate the plan, it posts the same kind of
notice. When no `image-drift` issue is open, the report is written to the step summary
only. The weekly alert keeps ownership of the issue body.

## Artifacts and limits

Artifacts are retained for 14 days:

- `preflight-plan`: the immutable candidate snapshot and the phase-1 JSON plan.
- `preflight-selection`: the phase-2 JSON plan, with the passed and failed
  candidates, the authorizing evidence and the phase-1 contract report.
- `result-<job>`: sanitized assertion/service logs, selected Docker event
  fields (bare actions only, so that no exec command line is exported),
  image IDs/digests/platforms, exact receipts, `result.json` and, for traced
  scenarios, `contracts.json`. Phase-1
  jobs are named `p1-<service>.<scenario>`. Phase-2 jobs are named
  `p2-<scenario>`.
- `preflight-accepted`: the proposed lock, combined receipts and PR description.

The result records elapsed seconds and the disk measurements in
[Runner disk](#runner-disk). Raw `.env`, databases, service configuration and
container environment dumps are never exported.
Logs mask the fixture password, credential assignments and long generated values.
Missing or malformed artifacts prevent publication. A job killed before it can
write evidence also prevents publication; the disposable VM provides cleanup.

These are functional drift tests of trusted upstream images. Privileged DinD
is not a security sandbox for a malicious image. A runner escape could corrupt
its evidence or write Actions cache entries, despite a read-only repository
token. A forged cache entry can overwrite any workspace file when a later job
restores it, including the scripts that verify tool hashes. For this reason, no
workflow in this repository restores an Actions cache, and each CI job fetches
and verifies its pinned tools. `tests/unit/workflow-caches.sh` enforces this.
Corrupted evidence can still reach a proposed PR. The maintainer review of that
PR remains the final gate.

On a feature branch, use `publish=false` to measure the proposed workflow. The
publisher cannot run there. Review cold time/disk results and the artifact logs
before enabling recurring image acceptance. Scheduled acceptance is deliberately
absent until the measurements, independent permissions/test review and hosted
failure proof are complete. The existing scheduled alert remains active.

GitHub must permit the repository's workflow token to create pull requests.
The [repository Actions setting](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
is **Allow GitHub Actions to create and approve pull requests**. Keep default
workflow permissions read-only; the publisher requests its own job permissions.
The workflow never approves or merges a PR. At the first measurement, the
repository reported `can_approve_pull_request_reviews: false`. This was enabled
separately for the default-branch publisher trial. Publication failures
remain visible in the publisher job. The candidate tests do not gain write
permissions to work around a repository restriction.

## Runner disk

A cold scenario can fill most of the free disk of a hosted runner. GitHub
documents about 14 GB of free SSD space for these runners. A full disk must not
authorize a candidate, and it must not be recorded as an image failure. Each
image job runs on its own VM, so the disk need of a job does not change with the
number of candidates.

Before DinD starts, each image job runs `tests/preflight/free-runner-disk.sh`.
The script removes preinstalled toolchains that MediaStack does not use: the
Android SDK, .NET, GHC and GHCup, the CodeQL bundle and Swift. It also removes
all preinstalled Docker images. The job keeps docker, python3, git, curl and
apt. The step summary records the free bytes on the filesystem of the Docker
data root before and after the cleanup. The script refuses to run unless both
`GITHUB_ACTIONS=true` and `RUNNER_ENVIRONMENT=github-hosted` are set, because
self-hosted runners also set `GITHUB_ACTIONS`. A cleanup failure does not stop
the job: the scenario still runs, and the headroom rule below judges the disk.

During the scenario, the runner reads the free space of the Docker data root
filesystem every 2 seconds. DinD keeps its inner Docker data in a volume under
this root. `result.json` records these fields:

| Field | Meaning |
|---|---|
| `disk_free_start_bytes` | Free bytes when the scenario starts, after the cleanup |
| `disk_peak_growth_bytes` | The largest growth that a sample saw |
| `disk_growth_bytes` | Growth at the end of the run, before DinD is removed |
| `disk_samples` | The number of samples |
| `disk_error` | Null, or the reason that the sampler could not measure the run |
| `runner_error` | Null, or the headroom failure below |

Samples are 2 seconds apart, so a shorter spike can stay unseen. If the sampler
cannot measure the whole run, it writes `disk_error` and no numbers. The
selection job and the verifier refuse a result that has a `disk_error`, that
lacks a disk field or `runner_error`, that has no sample, or whose peak growth
is less than its end-of-run growth.

If the free space at the peak is less than 2 GiB, the job fails with
`undecided: disk headroom exhausted`, followed by the peak growth, the free
bytes at the peak and the minimum, and `cause not determined`. The runner or the
image can cause this; for example, a new image release can write much more
data. The peak growth stays visible so that such an image can be found. This
rule applies also when the scenario failed, because a full disk can cause the
scenario failure. The runner removes DinD before it writes `result.json`, so
that it can write the result after the disk was full. The selection job and the
verifier recompute the rule from the numbers in each result, and do not trust
`runner_error`. Such a job decides nothing:

- Its candidate does not pass, and it is not recorded as failed.
- The selection plan records it under `runner_failed`, with the measurement.
- The status report marks the candidate as undecided. For a failed phase 2, the
  status job reads the phase-2 results as data to find this case.
- The publisher does not close an open PR because of it. For a failed phase 2,
  the publisher reads the phase-2 results as data, with the same rule as the
  status job. A candidate stays refused if any of its jobs failed for another
  reason, or if a result is missing or malformed.
- An image failure in another job of the same candidate takes precedence: the
  candidate is failed.

## First cold hosted measurement

[Run 40524452417](https://github.com/famesjranko/MediaStack/actions/runs/40524452417)
tested a qBittorrent candidate on source `eaf53943d82fb7c54492bf6e8f12b4673f100264`
on 2026-10-27. Both image jobs and the separate verifier passed. Publication was
disabled; the verifier produced a selective lock artifact for review.

| Scenario | Passed | Failed/skipped | Seconds | Disk growth (bytes) |
|---|---:|---:|---:|---:|
| fresh-install | 240 | 0/0 | 286 | 12,220,076,032 |
| upgrade-path | 326 | 0/0 | 397 | 12,523,839,488 |

These are end-of-run measurements for one candidate combination on hosted
Ubuntu 24.04. They do not establish peak disk use or a general runtime bound.
Scheduled publication has the additional gates described above.

## Default-branch publisher trial

[Run 40611106158](https://github.com/famesjranko/MediaStack/actions/runs/40611106158)
tested qBittorrent on source `0c05f639e4e5e55d2207d508e48bf48e28d33f93`
and opened [PR #139](https://github.com/famesjranko/MediaStack/pull/139) on
2026-10-28. Fresh-install passed 240 assertions in 287 seconds; upgrade-path
passed 326 in 341 seconds. Both had zero failures or skips. The complete artifact
set passed the pinned secret scan. Only qBittorrent's lock row changed.

The trial exposed the CI handoff defect: its manually dispatched CI passed all
seven jobs but did not satisfy the PR ruleset. The PR-triggered run was waiting
for approval. The operator approval step above replaces that redundant dispatch.

## Isolation trial

[Run 40645429539](https://github.com/famesjranko/MediaStack/actions/runs/40645429539)
ran on 2026-10-28, before the disk cleanup and the peak measurement existed. It
ran 9 image jobs, and the complete run took 30 minutes.

| Measurement | Value |
|---|---|
| Image jobs | 9 |
| Failed/skipped assertions | 0/0 in every job |
| Seconds per job | 249 to 352 |
| End-of-run disk growth per job | 10.9 GB to 13.1 GB |
| Largest end-of-run growth | `upgrade-path`: 13,055,971,328 bytes |
| Other scenarios, largest growth | `fresh-install`: 12.5 GB; `install-e2e`: 11.1 GB |

The largest end-of-run growth is close to the documented 14 GB of free space,
and the peak can be larger. This trial is the reason for the
[runner disk](#runner-disk) cleanup and headroom rule. Before scheduled
acceptance is enabled, a hosted run must measure the peak and the space that the
cleanup frees.
