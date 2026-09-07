# Release Workflow — MediaStack

This document is authoritative for versioning policy and for preparing,
tagging, and verifying a MediaStack release. Branch topology and ordinary
change flow live in [workflow.md](workflow.md); release-note writing rules
live at the top of [CHANGELOG.md](../../CHANGELOG.md).

A release is a verified point in `main`'s history: there is no build artifact
and no publish step. The install path stays `git clone` + `./mediastack`; the
tag and GitHub Release exist so an operator can name what they run
(`./mediastack --version`) and read what changed before updating.

The flow is manual with three gates. Automating gates 1 and 3 is deliberately
deferred until the manual shape has held for two or three releases.

## Versioning policy (0.x)

- **Semantic Versioning, pre-1.0.** `0.MINOR.PATCH`, tagged `vX.Y.Z`.
- **A patch (`0.x.Y`) never changes behaviour on an existing install.** Fixes
  only: a re-run of `./mediastack`, an update action, or a configured service
  behaves as already documented, just correctly. A Stable baseline refresh
  alone (drift accepted, no script changes) may ship as a patch.
- **A minor (`0.X.0`) may change behaviour, including breaking it**, provided
  the break is a `### Breaking Changes` entry in the changelog with the
  migration step inline. New services, wizard-flow changes, and compose
  changes are minors.
- **1.0.0** when the wizard surface, `config.yml` schema, and day-2 menu are
  stable enough that a break would demand a major — not before.

## Version state

- `VERSION` carries the **last released** version (`0.0.0-dev` before the
  first release). `./mediastack --version` prints it plus the current commit.
- The **next** version follows from `[Unreleased]` in the changelog: any
  `### Breaking Changes` entry rules out a patch under the 0.x policy.
- Read the truly released version off the releases, not the tree:
  `gh release list --limit 1`.

## Preconditions (all of them, before gate 1)

- [ ] `[Unreleased]` holds every operator-visible change that is merged, and
      nothing that is not.
- [ ] **No open image-drift issue.** The Stable baseline in
      [operations/image-digests.lock](../operations/image-digests.lock) has
      passed its DinD preflights against current upstream
      ([operations/upgrades.md](../operations/upgrades.md)). A release never
      ships an untested baseline.
- [ ] `./tests/check.sh` green on `main` (the full CI-equivalent gate).
- [ ] `./tests/check.sh secrets-history` clean — the tag publishes history.
- [ ] Anything no check can run has its evidence written down (GPU and
      live-host behaviour come from the `tests/lan-host/` and `tests/gcp-vm/`
      harnesses, which never gate a merge).

## Gate 1 — prepare

On a branch `release/X.Y.Z` from current `main`:

1. Pin the changelog: retitle `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
   and open a fresh empty `## [Unreleased]` above it.
2. Write `X.Y.Z` into `VERSION`.
3. `./tests/check.sh fast`, commit as `release: vX.Y.Z`, push the branch.

## Gate 2 — merge

Open the `release/X.Y.Z` → `main` PR, wait for every required check,
**squash**-merge, and **record the squash SHA**. Merge nothing else between
gate 2 and gate 3 — the tag must land on exactly that SHA.

## Gate 3 — tag and release

```bash
V=X.Y.Z
git fetch origin && git checkout main && git pull --ff-only
git rev-parse --short HEAD          # must be the recorded squash SHA
git tag -a "v$V" -m "MediaStack v$V" <squash-sha>
git push origin "v$V"               # by name — NEVER `git push --tags`
                                    # (local working tags must not publish)
awk -v v="## [$V]" 'index($0,v)==1{f=1;next} /^## \[/{f=0} f' CHANGELOG.md \
  > "/tmp/notes-$V.md"
[[ -s "/tmp/notes-$V.md" ]] || { echo "no changelog section for $V" >&2; exit 1; }
gh release create "v$V" --title "MediaStack v$V" --notes-file "/tmp/notes-$V.md"
```

The empty-file guard matters: a heading that does not match (wrong date
separator, stray space) would otherwise publish a release with empty notes.

## Verify

- [ ] `gh release view vX.Y.Z` shows the changelog section's body verbatim
      (the `## [X.Y.Z]` heading itself is deliberately dropped).
- [ ] `git clone` at the tag + `./mediastack --version` prints
      `MediaStack X.Y.Z (<sha>)`. (A tarball install has no `.git`, so the
      sha is omitted there — that is expected.)
- [ ] The `[Unreleased]` section on `main` is empty and ready.

## If a release is wrong

Do not delete or move a published tag. Fix forward: land the fix on `main`
and cut the next patch. A tag that must be warned about gets a note prepended
to its GitHub Release body.
