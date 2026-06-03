# Maintainer Image Updates

How maintainers handle upstream image movement without running DinD in GitHub Actions.

MediaStack keeps readable image tags in `docker-compose.yml` and records the exact digests last
accepted by maintainers in `docs/operations/image-digests.lock`. The setup wizard defaults users to the
**Stable** image channel, which generates `docker-compose.override.yml` with
`image: tag@sha256:digest` references from that lock file. Users can opt into **Latest** to follow
upstream tags directly.

## When CI Alerts

The `Image Drift Alert` workflow resolves every compose image tag to its current remote digest and
compares it with `docs/operations/image-digests.lock`. It does not pull layers, start containers, or run DinD.

When it fails:

1. Open the workflow summary and note every changed service.
2. Read the service rows in `docs/operations/upgrades.md`.
3. Freeze the digest snapshot that will be tested:

   ```bash
   mkdir -p .tmp
   python3 scripts/image-drift.py --snapshot-current .tmp/image-digests.current.tsv
   python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv
   ```

4. Run the exact local preflight shown by that snapshot summary. For scenario-backed services, the
   command uses `MS_TEST_IMAGE_OVERRIDES` with the new digest, for example:

   ```bash
   MS_TEST_IMAGE_OVERRIDES="jellyfin=jellyfin/jellyfin:latest@sha256:<digest>" ./tests/run.sh fresh-install
   ```

5. For `compose-only` services, validate compose and review the upstream changelog if the service is
   security-sensitive.
6. For `manual` services, start the relevant profile locally and verify the UI/configurator path by
   hand.
7. If any preflight fails, leave `docs/operations/image-digests.lock` unchanged and fix the integration before
   accepting the digest.
8. If every affected service passes, accept the same snapshot that was tested:

   ```bash
   python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current
   ```

9. Regenerate the README Stable image badges from the accepted lock:

   ```bash
   python3 scripts/image-drift.py --write-readme-badges README.md
   ```

10. Inspect the lock-file diff. Only rows for changed images should get new digests and timestamps,
   unless this is the first validation restamp.
11. Commit the lock-file update with any required code/docs fixes. Stable-channel users receive the
   new tested digests after updating the repo and running `./scripts/update.sh`.

For the first validation pass, run the relevant DinD battery against the bootstrap lock and
then restamp every row:

```bash
mkdir -p .tmp
python3 scripts/image-drift.py --snapshot-current .tmp/image-digests.current.tsv
python3 scripts/image-drift.py --current-file .tmp/image-digests.current.tsv --write-current docs/operations/image-digests.lock --accept-current --restamp-all
```

## Stable vs Latest

The wizard exposes two user-facing modes:

| Mode | User behavior | Maintainer burden | Tradeoff |
|---|---|---|---|
| Stable | Users install and update to the digests accepted in this repo. | Higher. Every upstream image update needs local preflight before restamping the lock. | Predictable installs and support baseline. |
| Latest | Users pull current upstream tags with `./scripts/update.sh`. | Lower. CI still alerts maintainers, but users can outrun the tested record. | Faster updates, more risk from upstream image changes. |

Stable is the default because MediaStack targets non-technical users. Latest is still useful
for advanced operators who intentionally want upstream movement before the maintainer workflow has
accepted it.

## User-Facing Updates

For the default CLI-managed install, `./scripts/update.sh` is the supported update path. In Stable,
it regenerates the compose override from `docs/operations/image-digests.lock` and pulls those accepted digests.
In Latest, it omits image overrides and pulls the upstream tags from `docker-compose.yml`.

Portainer is useful for visibility, restart actions, logs, and manual troubleshooting, but it is not
the source of truth for a stack that MediaStack created with Docker Compose from this repository.

Portainer can show image update indicators and can pull/redeploy Portainer-managed stacks. If a user
deploys MediaStack through Portainer instead of `setup.sh`, they should use Portainer's stack update
flow consistently. Mixing Portainer container recreation with this repo's compose-managed setup can
leave the live containers different from `docker-compose.yml`.
