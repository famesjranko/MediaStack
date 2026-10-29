#!/usr/bin/env bash
# Frozen inputs, GCP ownership/cleanup, receipt binding and public HTTPS refusal.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin remote-preflight
if python3 -I - "$REPO_ROOT" <<'PY'; then
import contextlib
import copy
import io
import json
import os
import pathlib
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(sys.argv.pop())
sys.path.insert(0, str(ROOT / "tests"))
import remote_image_preflight as run
from preflight.model import HELD, build_plan, drift, fingerprint, rows
from remote_preflight.gcp import Gcp, command
from remote_preflight.inputs import STAGING, frozen_inputs, target_config

SOURCE = "a" * 40
RUN_ID = "run-20261029T120000Z-12345678"
CONFIG = dict(PROJECT_ID="fixture-project", ZONE="us-central1-a", INSTANCE="candidate-test",
              MACHINE_TYPE="e2-medium", BOOT_DISK_SIZE="30GB", DOMAIN="fixture.test",
              NPM_ADMIN_EMAIL="admin@fixture.test", DDNS_PASSWORD="fixture-private-value")


def plan():
    return {"source": SOURCE, "architecture": "x86_64", "run_id": RUN_ID,
            "candidate": "jc21/nginx-proxy-manager:2@sha256:" + "1" * 64,
            "snapshot": {"npm": "jc21/nginx-proxy-manager:2@sha256:" + "1" * 64}}


def receipt(p, binding_hash, **changes):
    image, digest = p["candidate"].split("@")
    row = dict(service="npm", image=image, digest=digest, scenario="remote-gcp",
               source=p["source"], run_id=p["run_id"], arch="x86_64", plan_hash=binding_hash,
               recorded="2026-10-29T12:00:00Z")
    row.update(changes)
    return ("\t".join(row.values()) + "\n").encode()


class FrozenInputs(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.folder = pathlib.Path(self.tmp.name)
        self.baseline = rows(ROOT / "docs/operations/image-digests.lock")
        self.current = dict(self.baseline)
        npm = self.baseline["npm"]
        self.current["npm"] = drift.ImageDigest("npm", npm.image, "sha256:" + "1" * 64)
        self.snapshot = self.folder / "current.tsv"
        drift.write_tsv(self.snapshot, list(self.current.values()))

    def test_held_digest_is_frozen_in_weekly_plan(self):
        # Given a drifted held NPM image and no automatic selection.
        hosted = build_plan(self.baseline, self.current, [], SOURCE, "99-1", {})
        path = self.folder / "plan.json"
        path.write_text(json.dumps(hosted))

        # When the exact hashed weekly plan is consumed at its source.
        with patch("remote_preflight.inputs.source_sha", return_value=SOURCE):
            result = frozen_inputs(None, path, fingerprint(hosted))

        # Then NPM stays held and its frozen digest is available for remote proof.
        self.assertIn("npm", HELD)
        self.assertNotIn("npm", hosted["selected"])
        self.assertEqual(result["candidate"], hosted["snapshot"]["npm"])
        self.assertEqual(result["weekly_plan_hash"], fingerprint(hosted))

    def test_tampered_or_stale_weekly_plan_is_rejected(self):
        # Given a hashed weekly plan whose source or held digest is later changed.
        original = build_plan(self.baseline, self.current, [], SOURCE, "99-1", {})
        for field in ("source", "snapshot"):
            with self.subTest(field):
                hosted = copy.deepcopy(original)
                if field == "source":
                    hosted[field] = "b" * 40
                else:
                    hosted[field]["npm"] = "example/wrong@sha256:" + "2" * 64
                path = self.folder / "plan.json"
                path.write_text(json.dumps(hosted))

                # When the original plan hash is supplied.
                # Then neither modified plan can start a remote run.
                with patch("remote_preflight.inputs.source_sha", return_value=SOURCE):
                    with self.assertRaisesRegex(ValueError, "hash or source"):
                        frozen_inputs(None, path, fingerprint(original))

    def test_snapshot_rejects_bad_digest_population_and_tag_change(self):
        for fault in ("unchanged", "missing", "duplicate", "digest", "tag"):
            with self.subTest(fault):
                # Given an explicit snapshot with one invalid acceptance input.
                values = dict(self.current)
                npm = values["npm"]
                if fault == "unchanged": values["npm"] = self.baseline["npm"]
                if fault == "missing": values.pop("sonarr")
                if fault == "digest": values["npm"] = drift.ImageDigest("npm", npm.image, "bad")
                if fault == "tag": values["npm"] = drift.ImageDigest("npm", "example/npm:3", npm.digest)
                population = list(values.values())
                if fault == "duplicate": population.append(npm)
                drift.write_tsv(self.snapshot, population)

                # When it is validated without resolving a live tag.
                # Then the invalid snapshot cannot authorize a cloud operation.
                with self.assertRaises(ValueError):
                    frozen_inputs(self.snapshot, None, None)

    def test_self_consistent_weekly_plan_from_another_source_is_rejected(self):
        # Given an intact weekly plan whose hash is valid but source is another commit.
        hosted = build_plan(self.baseline, self.current, [], "b" * 40, "99-1", {})
        path = self.folder / "plan.json"
        path.write_text(json.dumps(hosted))

        # When its correct hash is supplied from the current checkout.
        # Then source identity independently blocks the remote run.
        with patch("remote_preflight.inputs.source_sha", return_value=SOURCE):
            with self.assertRaisesRegex(ValueError, "hash or source"):
                frozen_inputs(None, path, fingerprint(hosted))

    def test_target_and_staging_guards(self):
        # Given a target whose expected name or ACME server differs.
        base = dict(CONFIG, GCP_EXPECT_TARGET="fixture-project/us-central1-a/candidate-test")
        for change in ({"GCP_EXPECT_TARGET": "wrong"}, {"NPM_LE_SERVER": ""},
                       {"NPM_LE_SERVER": "https://acme-v02.api.letsencrypt.org/directory"}):
            with self.subTest(change), patch.dict(os.environ, dict(base, **change), clear=True):
                # When offline target validation runs.
                # Then it refuses before any cloud operation.
                with self.assertRaises(ValueError): target_config()


    def test_offline_command_never_contacts_cloud_or_prints_credentials(self):
        # Given a frozen candidate and a gcloud stub that records any attempted call.
        env_file = self.folder / "inputs"
        values = dict(CONFIG, GCP_EXPECT_TARGET="fixture-project/us-central1-a/candidate-test",
                      NPM_LE_SERVER=STAGING)
        env_file.write_text("\n".join(f"{k}={shlex.quote(v)}" for k, v in values.items()))
        binary = self.folder / "gcloud"
        marker = self.folder / "cloud-called"
        binary.write_text(f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\nexit 66\n")
        binary.chmod(0o755)
        env = dict(os.environ, GCP_ENV_FILE=str(env_file), PATH=str(self.folder) + ":" + os.environ["PATH"])

        # When the real public command validates the snapshot offline.
        result = subprocess.run([str(ROOT / "tests/gcp-vm/run-candidate.sh"), "npm", "--snapshot",
                                 str(self.snapshot), "--preflight"], env=env, capture_output=True)

        # Then it succeeds without cloud calls, runtime artifacts, or credential output.
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertNotIn(CONFIG["DDNS_PASSWORD"].encode(), result.stdout + result.stderr)


class ReceiptBinding(unittest.TestCase):
    def test_exact_remote_receipt_qualifies_and_each_binding_is_required(self):
        # Given a remote v3 receipt and the reviewed plan that produced it.
        p, ph = plan(), "e" * 64
        with tempfile.TemporaryDirectory() as folder:
            output = pathlib.Path(folder)
            run.verify_receipt(receipt(p, ph), p, ph, output)
            row = drift.ImageDigest("npm", *p["candidate"].split("@"))
            policy = drift.ReceiptPolicy(SOURCE, frozenset([RUN_ID]), "x86_64", ph)

            # When each provenance field is independently changed.
            for field in ("service", "image", "digest", "scenario", "source", "run_id", "arch", "plan_hash"):
                with self.subTest(field):
                    # Then no mismatched receipt qualifies.
                    with self.assertRaises(ValueError):
                        run.verify_receipt(receipt(p, ph, **{field: "wrong"}), p, ph, output)
            run.verify_receipt(receipt(p, ph), p, ph, output)
            parsed = drift.read_pass_receipts(output / "pending-receipts.tsv")
            self.assertIsNone(drift._receipt_failure(parsed["npm"], row, "remote-gcp", policy))
            self.assertIn("requires --receipt-plan-hash", drift._receipt_failure(
                parsed["npm"], row, "remote-gcp", drift.ReceiptPolicy(SOURCE)))

    def test_local_selective_accept_requires_remote_evidence_and_preserves_other_rows(self):
        # Given a two-service lock and a drifted NPM snapshot.
        with tempfile.TemporaryDirectory() as folder:
            out = pathlib.Path(folder)
            fields = "service\timage\tdigest\ttested_at_utc\tpreflight\n"
            old = "npm\tjc21/nginx-proxy-manager:2\tsha256:" + "0" * 64 + "\told\tscenario:remote-gcp\n"
            other = "sonarr\texample/sonarr:1\tsha256:" + "3" * 64 + "\told\tcompose-only\n"
            (out / "lock").write_text(fields + old + other)
            new = old.replace("0" * 64, "1" * 64)
            (out / "current").write_text(fields + new + other)
            (out / "upgrades.md").write_text("<!-- upgrades-manifest:start -->\n"
                "| Service | Pin policy | API stability | Preflight | Touchpoint |\n"
                "|---|---|---|---|---|\n| npm | major:2 | stable | scenario:remote-gcp | x |\n"
                "| sonarr | latest | stable | compose-only | x |\n<!-- upgrades-manifest:end -->\n")
            ph = "e" * 64
            (out / "receipts").write_bytes(receipt(plan(), ph))
            argv = [sys.executable, str(ROOT / "scripts/image_drift.py"), "--previous", str(out / "lock"),
                    "--current-file", str(out / "current"), "--upgrades", str(out / "upgrades.md"),
                    "--write-current", str(out / "accepted"), "--accept-services", "npm",
                    "--receipt-source", SOURCE, "--receipt-run-id", RUN_ID,
                    "--preflight-receipt", str(out / "receipts")]

            # When acceptance omits the reviewed hash, then supplies it.
            blocked = subprocess.run(argv, capture_output=True)
            accepted = subprocess.run(argv + ["--receipt-plan-hash", ph], capture_output=True)

            # Then only the bound evidence updates NPM and the other row stays byte-identical.
            self.assertEqual(blocked.returncode, 1, blocked.stderr)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertIn(other, (out / "accepted").read_text())
            self.assertIn("1" * 64, (out / "accepted").read_text())


class FakeCloud:
    def __init__(self, fault=""):
        self.vm = None
        self.pending = None
        self.operation_reads = 0
        self.calls = []
        self.fault = fault

    def __call__(self, argv, data=None, timeout=120):
        self.calls.append(argv)
        if argv[0] == "git" and "archive" in argv: return b"fixture archive"
        if argv[0] != "gcloud" or "--project=fixture-project" not in argv:
            raise AssertionError("every cloud operation needs an explicit project")
        if "operations" in argv:
            self.operation_reads += 1
            if self.pending:
                if self.operation_reads == 1: return b'[{"status":"RUNNING"}]'
                self.vm, self.pending = self.pending, None
            return b'[]'
        if "list" in argv: return json.dumps([self.vm] if self.vm else []).encode()
        if "create" in argv:
            label = next(a.split("=", 2)[2] for a in argv if a.startswith("--labels="))
            self.vm = {"zone": "zones/us-central1-a", "labels": {"mediastack-preflight": label}}
            if self.fault == "delayed-create":
                self.pending, self.vm = self.vm, None
                raise RuntimeError("create response lost before VM became visible")
            if self.fault == "create": raise RuntimeError("create response lost")
            return b""
        if "delete" in argv:
            if self.fault != "cleanup": self.vm = None
            return b""
        if "ssh" in argv:
            if self.fault == "interrupt": raise KeyboardInterrupt()
            if self.fault == "candidate" and any("uname -m" in a for a in argv):
                raise RuntimeError("candidate failed")
            return b""
        raise AssertionError(argv)


class Cleanup(unittest.TestCase):
    def setUp(self):
        self.handlers = {sig: signal.getsignal(sig) for sig in (signal.SIGINT, signal.SIGTERM)}
        self.addCleanup(lambda: [signal.signal(sig, value) for sig, value in self.handlers.items()])

    def test_existing_target_is_never_deleted(self):
        # Given a pre-existing VM that this run does not own.
        cloud = FakeCloud()
        cloud.vm = {"zone": "zones/us-central1-a", "labels": {}}
        gcp = Gcp(CONFIG, RUN_ID, lambda message: None)

        # When creation is refused and cleanup runs.
        with patch("remote_preflight.gcp.command", cloud):
            with self.assertRaisesRegex(ValueError, "already exists"): gcp.create()
            gcp.cleanup()

        # Then no delete was sent for the existing target.
        self.assertFalse(any("delete" in argv for argv in cloud.calls))
        self.assertIsNotNone(cloud.vm)

    def test_pending_cloud_create_settles_before_deletion_is_verified(self):
        # Given a lost create response while the cloud operation still runs.
        cloud = FakeCloud("delayed-create")
        gcp = Gcp(CONFIG, RUN_ID, lambda message: None)

        # When cleanup runs before the instance is visible in the VM list.
        with patch("remote_preflight.gcp.command", cloud), patch("remote_preflight.gcp.time.sleep"):
            with self.assertRaises(RuntimeError): gcp.create()
            gcp.cleanup()

        # Then it waits for cloud creation to settle and deletes the resulting VM.
        self.assertIsNone(cloud.pending)
        self.assertIsNone(cloud.vm)
        self.assertTrue(any("delete" in argv for argv in cloud.calls))

    def test_foreign_ownership_after_a_raced_create_is_never_deleted(self):
        # Given a create attempt whose named target now belongs to another run.
        cloud = FakeCloud()
        gcp = Gcp(CONFIG, RUN_ID, lambda message: None)
        with patch("remote_preflight.gcp.command", cloud):
            gcp.create()
            cloud.vm["labels"] = {"mediastack-preflight": "another-run"}

            # When cleanup checks the target's ownership label.
            # Then it refuses deletion even though this run attempted creation.
            with self.assertRaisesRegex(RuntimeError, "ownership label"):
                gcp.cleanup()
        self.assertIsNotNone(cloud.vm)
        self.assertFalse(any("delete" in argv for argv in cloud.calls))

    def test_success_failure_interrupt_and_lost_create_response(self):
        for fault in ("", "candidate", "interrupt", "create", "cleanup", "wan", "wan-timeout", "receipt"):
            with self.subTest(fault), tempfile.TemporaryDirectory() as folder:
                # Given a disposable cloud transport with one injected failure.
                cloud = FakeCloud(fault)
                out = pathlib.Path(folder) / "result"
                p = plan()
                expected = TimeoutError if fault == "wan-timeout" else (ValueError, RuntimeError, KeyboardInterrupt)
                def candidate(gcp, actual, ph):
                    if fault == "wan": raise ValueError("no candidate HTTPS")
                    if fault == "wan-timeout": raise TimeoutError("public HTTPS deadline expired")
                    return receipt(actual, ph, **({"digest": "bad"} if fault == "receipt" else {}))
                patches = [patch("remote_preflight.gcp.command", cloud),
                           patch.object(run, "clean_source"), patch.object(run, "install"),
                           patch.object(run, "candidate", candidate)]

                # When the real orchestration and cleanup run.
                with contextlib.ExitStack() as stack, contextlib.redirect_stdout(io.StringIO()):
                    for item in patches: stack.enter_context(item)
                    if fault:
                        with self.assertRaises(expected):
                            run.execute(p, CONFIG, out)
                    else:
                        run.execute(p, CONFIG, out)

                # Then only a complete run with verified deletion publishes a receipt.
                self.assertEqual((out / "receipts.tsv").exists(), not bool(fault))
                self.assertFalse((out / "pending-receipts.tsv").exists())
                self.assertEqual(cloud.vm is None, fault != "cleanup")
                self.assertTrue(any("delete" in argv for argv in cloud.calls))
                create = next(argv for argv in cloud.calls if "create" in argv)
                self.assertIn("--no-service-account", create)
                self.assertIn("--instance-termination-action=DELETE", create)

    def test_child_output_never_reaches_error_message(self):
        # Given a failing candidate command that prints a credential to both streams.
        secret = "private-value-never-log-this"

        # When the real process boundary reports its failure.
        with self.assertRaises(RuntimeError) as caught:
            command([sys.executable, "-c", "import sys; print(sys.argv[1]); print(sys.argv[1], file=sys.stderr); sys.exit(1)", secret])

        # Then the exception contains only the exit code.
        self.assertNotIn(secret, str(caught.exception))
        self.assertIn("exit 1", str(caught.exception))

    def test_wan_failure_stops_real_candidate_orchestration_before_receipts(self):
        # Given successful guest commands but a failed public WAN proof.
        gcp = Gcp(CONFIG, RUN_ID, lambda message: None)
        state = {"hosts": []}
        calls = []
        def ssh(script, data=None, timeout=120):
            calls.append(script)
            if "ms-npm-after.json" in script: return json.dumps(state).encode()
            return b""
        instances = [{"networkInterfaces": [{"accessConfigs": [{"natIP": "192.0.2.42"}]}]}]

        # When the real candidate orchestration reaches the public check.
        with patch.object(gcp, "ssh", side_effect=ssh), patch.object(gcp, "instances", return_value=instances):
            with patch.object(run.wan, "check", side_effect=ValueError("candidate serves no HTTPS")) as probe:
                with self.assertRaisesRegex(ValueError, "no HTTPS"):
                    run.candidate(gcp, plan(), "e" * 64)

        # Then it propagates the failure and never retrieves acceptance receipts.
        probe.assert_called_once_with("fixture.test", "192.0.2.42", state)
        self.assertFalse(any("ms-remote-receipts.tsv" in script for script in calls))


unittest.main(argv=["remote-preflight"], verbosity=2)
PY
    pass 'remote candidate inputs, ownership, cleanup and receipt contracts'
else
    fail 'remote candidate inputs, ownership, cleanup and receipt contracts'
fi
summary
