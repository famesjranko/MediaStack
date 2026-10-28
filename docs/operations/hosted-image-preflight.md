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

Each scenario tests the same proposed combination: selected candidate digests
plus accepted companion digests. All required scenarios must pass with a
nonempty assertion population and no failed or skipped assertions. If one
candidate fails, the selected combination is not published. Narrow the selection
and rerun to test a smaller combination. Passing evidence from the failed
combination cannot authorize the smaller combination.

The pipeline has four boundaries:

1. A read-only planner freezes the source SHA, candidate snapshot, full effective
   service set, fixture-image digests, architecture and scenario run IDs. Its
   canonical plan hash is passed through job outputs, independently of image-job
   artifacts.
2. Disposable hosted Ubuntu VMs run privileged DinD with read-only repository
   permissions. At most two scenarios run concurrently. Image execution receives
   no publishing token or live credentials. Each scenario has a 70-minute process
   deadline inside an 85-minute job deadline.
3. A read-only verifier checks the original plan hash and validates result data,
   exact-digest receipts, source/run identity, architecture, actual companion and
   fixture references, image inspections, pass/skip counts and resource fields.
   It writes a selective lock only after every required result qualifies.
4. A separate publisher runs only on the default branch. It revalidates the
   original artifacts using trusted source code, refuses an advanced default
   branch, and opens an ordinary PR. It never runs candidate images, executes
   artifact code, pushes to `main`, or merges. Its write token exists only in
   this job. GitHub creates the PR-triggered CI run in an approval-required
   state. A maintainer must approve that run before the PR gate can pass.

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

Check for an existing open digest PR before another publishing trial. Current
manual runs create separate branches; they do not replace or deduplicate open
proposals. Scheduled publication needs an explicit policy for this case.

Artifacts are retained for 14 days:

- `preflight-plan`: the immutable candidate snapshot and complete JSON plan.
- `result-<scenario>`: sanitized assertion/service logs, selected Docker event
  fields, image IDs/digests/platforms, exact receipts and `result.json`.
- `preflight-accepted`: the proposed lock, combined receipts and PR description.

The result records elapsed seconds and disk growth before DinD cleanup. Disk
growth is an end-of-run measurement, not peak usage. Raw `.env`, databases,
service configuration and container environment dumps are never exported.
Logs mask the fixture password, credential assignments and long generated values.
Missing or malformed artifacts prevent publication. A job killed before it can
write evidence also prevents publication; the disposable VM provides cleanup.

These are functional drift tests of trusted upstream images. Privileged DinD
is not a security sandbox for a malicious image. A runner escape could corrupt
its evidence or write Actions caches used by other runs, despite a read-only
repository token. Python tool versions are pinned, but their shared CI caches
are not independently hash-verified by this repository. Review this boundary
before enabling unattended image tests.

On a feature branch, use `publish=false` to measure the proposed workflow. The
publisher cannot run there. Review cold time/disk results and the artifact logs
before enabling recurring image acceptance. Scheduled acceptance is deliberately
absent until the measurements, independent permissions/test review, hosted
failure proof and open-proposal policy are complete. The existing scheduled
alert remains active.

GitHub must permit the repository's workflow token to create pull requests.
The [repository Actions setting](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository)
is **Allow GitHub Actions to create and approve pull requests**. Keep default
workflow permissions read-only; the publisher requests its own job permissions.
The workflow never approves or merges a PR. At the first measurement, the
repository reported `can_approve_pull_request_reviews: false`. This was enabled
separately for the default-branch publisher trial. Publication failures
remain visible in the publisher job. The candidate tests do not gain write
permissions to work around a repository restriction.

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
These measurements cover one candidate combination. Scheduled publication has
the additional gates described above.

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
