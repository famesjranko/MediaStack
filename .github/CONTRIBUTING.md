# Contributing

Thanks for improving MediaStack. Keep changes focused on the turnkey
single-box goal: one guided setup, minimal manual config editing, and safe
re-runs.

Before opening a pull request:

1. Run `bash -n` on changed shell scripts.
2. Run relevant unit tests under `tests/unit/`.
3. Validate compose with a generated `.env`.
4. Update docs when commands, service behavior, config keys, or test surfaces change.

Public tracker/indexer changes must stay opt-in and must not make legal
assumptions for users. NVIDIA driver patching must also remain opt-in.

Do not commit `.env`, `tests/.env.gcp`, service runtime config, private plans,
local agent state, or generated NVIDIA patch/download trees.
