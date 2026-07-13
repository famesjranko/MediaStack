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

## Running the checks

The whole host test tier runs in one shot, and is the exact gate CI runs on
every pull request:

```
./tests/unit.sh    # shell syntax, shellcheck, py_compile, compose render, and every tests/unit/*.sh
```

`tests/unit.sh` needs the Docker CLI (for the compose render and the pinned
shellcheck image). Without Docker, you can still run the individual pure-bash
unit tests directly:

```
./tests/unit/gpu-branching.sh
```

`tests/README.md` documents the full test surface. The DinD end-to-end battery
is optional for most changes, and the live-host proofs (real DNS, Let's Encrypt,
WAN firewall) are maintainer-only.

## Pull request checklist

Before opening a pull request:

1. Run `bash -n` on changed shell scripts.
2. Run `./tests/unit.sh` (or the relevant `tests/unit/*.sh` if you cannot run Docker).
3. Confirm compose still validates; `./tests/unit.sh` renders it with a generated `.env`.
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
prior written permission from Andrew Mcdonald.

If your contribution includes third-party material, clearly identify it in the
pull request and include its licence and source.
