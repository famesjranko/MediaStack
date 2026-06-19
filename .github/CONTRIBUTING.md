# Contributing

Thanks for improving MediaStack. Keep changes focused on the turnkey
single-box goal: one guided setup, minimal manual config editing, and safe
re-runs.

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

## Pull request checklist

Before opening a pull request:

1. Run `bash -n` on changed shell scripts.
2. Run relevant unit tests under `tests/unit/`.
3. Validate compose with a generated `.env`.
4. Update docs when commands, service behavior, config keys, or test surfaces change.

Public tracker/indexer changes must stay opt-in and must not make legal
assumptions for users. NVIDIA driver patching must also remain opt-in.

Do not commit `.env`, `tests/.env.gcp`, service runtime config, private plans,
local agent state, or generated NVIDIA patch/download trees.
