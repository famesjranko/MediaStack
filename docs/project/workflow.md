# Branch And PR Workflow — MediaStack

This document is authoritative for branch topology, naming, and how changes
land. The release procedure lives in [release.md](release.md); contribution
process and etiquette live in [../../CONTRIBUTING.md](../../CONTRIBUTING.md).

## Topology

`main` is the only permanent branch: default, integration, and release branch
in one. Every other branch is short-lived, exists to become exactly one pull
request, and is deleted on merge.

| Branch | Purpose | Lands via |
|---|---|---|
| `main` | The supported product; every commit on it passed the full PR gate | — |
| `<type>/<slug>` | One change: fix, feature, docs, test, or chore | Squash-merge PR into `main` |
| `release/x.y.z` | Version pin for a release ([release.md](release.md) gate 1) | Squash-merge PR into `main` |

`<type>` is one of `feat`, `fix`, `docs`, `test`, `chore`, `refactor`.
`<slug>` is a short kebab-case description
(e.g. `fix/ddns-verify-fail-fast-race`).

## How a change lands

1. Branch from current `main`.
2. Commit freely on the branch — the branch history is working state and will
   be squashed away.
3. Open a PR into `main` (template applies; anything beyond a small obvious
   fix should trace to an issue — see CONTRIBUTING.md).
4. Wait for every required check, then **squash-merge**. The squash commit
   takes the PR title as its subject and the PR body as its message, so both
   are written to survive as permanent history.
5. The branch is deleted automatically on merge.

## Protection

The `main` ruleset enforces, with no bypass for anyone including admins:

- Changes land only through a pull request, squash-merge only.
- Linear history: no merge commits, no force pushes, no branch deletion.
- All required status checks green, on a branch current with `main`
  (the CI job names are the required contexts — see the note at the top of
  `.github/workflows/ci.yml` before renaming one).

There are no review-count requirements: the repository is maintained solo, and
the gate is CI plus the maintainer's own review of every PR before merging.

## Rules of thumb

- One PR, one concern. A cleanup discovered mid-change gets its own branch.
- Between a release PR's merge and its tag, merge nothing else
  ([release.md](release.md)).
- Never push directly to `main`; the ruleset refuses it either way.
- Push tags by name only, never `git push --tags`.
