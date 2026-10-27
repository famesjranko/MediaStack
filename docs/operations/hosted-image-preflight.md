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
   this job. It dispatches the independent CI workflow because PR events created
   with `GITHUB_TOKEN` do not start another workflow automatically.

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

On a feature branch, use `publish=false` to measure the proposed workflow. The
publisher cannot run there. Review cold time/disk results and the artifact logs
before enabling recurring image acceptance. Scheduled acceptance is deliberately
absent until both that measurement and an independent permissions/test review
are complete. The existing scheduled alert remains active.

GitHub must permit the repository's workflow token to create pull requests.
Publication failures remain visible in the publisher job. The candidate tests do
not gain write permissions to work around a repository restriction.
