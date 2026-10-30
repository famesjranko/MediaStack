---
name: remote-image-preflight
description: Run MediaStack's operator-only NPM candidate check on a disposable GCP VM and prepare public WAN evidence. WireGuard, NAS and GPU checks are not implemented yet.
---

Read `docs/operations/remote-image-preflight.md` in the MediaStack checkout.
Follow its script and evidence flow; do not improvise
infrastructure or replace the upgrade with a fresh candidate install.

Before a live run, establish the gcloud account and exact
`GCP_EXPECT_TARGET`. State the configured machine, disk, expected duration and
current estimated cost. Get authorization for that target and cost if the user
has not already provided it. Use the available `gcp` skill for cloud discovery
and permissions when applicable. A code implementation request alone does not
authorize spending money or using live DNS credentials.

Run `tests/gcp-vm/run-candidate.sh npm --preflight` with the frozen input options
from the runbook first. Never print credentials, the process environment, raw
remote logs or HTTP bodies. Use dedicated test DNS and staging ACME only.

After the run, verify deletion from the log and cloud state. Report an unverified
deletion immediately, with the exact target. Do not accept a digest without the
receipt and reviewed remote plan hash. NPM also needs the required local scenario
receipts; a remote receipt does not replace them. Link the sanitized evidence in
a normal PR and report failures and untested surfaces explicitly. Keep held services held.
