# Contributing

Thanks for taking the time to improve MediaStack. The main thing to keep in
mind is the turnkey single-box goal: one guided setup, minimal manual config
editing, and safe re-runs. Every contribution is credited to its author.

## Start here

For anything beyond a small, obvious fix, it's worth opening an issue first to
talk through the approach before you spend time on code. It saves you rework and
helps keep changes in step with the turnkey goal. Bug reports and feature
requests each have a template, so pick whichever fits when you open the issue.
Small things like typos and one-line corrections can go straight to a pull
request.

Create a short-lived feature branch and open a pull request into `main` for
every change. `main` is the protected integration and release branch as well as
the repository's only long-lived branch.

## Running the checks

The default check runs the same coverage as the full pull-request gate:

```
./tests/check.sh
```

It includes formatting, lint, type, secret, compose, host-unit, and image-free
wizard checks serially; CI spreads that coverage across parallel jobs. It needs
Docker and `uv`. Without Docker, you can still run relevant individual
pure-bash units directly, but that is not the complete PR gate:

```
./tests/unit/gpu-branching.sh
```

`tests/README.md` documents the full test surface. The DinD end-to-end battery
is optional for most changes, and the live-host proofs (real DNS, Let's Encrypt,
WAN firewall) are explicit operator-run checks and never run in CI.

## Pull request checklist

Before opening a pull request:

1. Run `bash -n` on changed shell scripts.
2. Run `./tests/check.sh` (or clearly state which narrower checks you could run).
3. Confirm compose still validates; the default check renders it with `.env.example`.
4. Update docs when commands, service behavior, config keys, or test surfaces change.

Public tracker/indexer changes must stay opt-in and must not make legal
assumptions for users. NVIDIA driver patching must also remain opt-in.

Please don't commit `.env`, live service config under `config/<service>/`, or
the generated NVIDIA patch/download trees.

## Contribution licensing

By submitting a pull request, patch, issue comment, documentation change, or
other contribution to MediaStack, you agree that your contribution is provided
under the same licence as the project: the PolyForm Noncommercial License 1.0.0.

You confirm that you have the right to submit the contribution and that it does
not intentionally include code, documentation, assets, secrets, generated output,
or third-party material that would prevent MediaStack from being distributed
under the PolyForm Noncommercial License 1.0.0.

MediaStack is source-available for non-commercial use. Commercial use requires
prior written permission from the licensor.

If your contribution includes third-party material, clearly identify it in the
pull request and include its licence and source.
