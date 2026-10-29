#!/usr/bin/env bash
# Execute the guest script against isolated command fixtures; never touch a host daemon.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin gcp-candidate-host
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(sys.argv.pop())
REF = "jc21/nginx-proxy-manager:2@sha256:" + "1" * 64


class Guest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        for name in ("tests/gcp-vm", "tests/lib", "tests/fixtures", "scripts", "docs/operations", "bin"):
            (self.root / name).mkdir(parents=True)
        # Only relocate guest /tmp artifacts. The command and receipt logic stay intact.
        script = (ROOT / "tests/gcp-vm/candidate-host.sh").read_text()
        (self.root / "tests/gcp-vm/candidate-host.sh").write_text(script.replace("/tmp/", str(self.root) + "/"))
        shutil.copyfile(ROOT / "tests/lib/receipts.sh", self.root / "tests/lib/receipts.sh")
        (self.root / "docs/operations/image-digests.lock").write_text(
            "service\timage\tdigest\ttested_at_utc\tpreflight\n"
            "npm\tjc21/nginx-proxy-manager:2\tsha256:" + "0" * 64 + "\told\tscenario:remote-gcp\n")
        self.write("scripts/update.sh", '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path.cwd()
with open(os.environ['TRACE'], 'a') as f: f.write('update\\n')
if os.environ['FAULT'] == 'update': sys.exit(66)
if os.environ['REF'].split('@')[1] not in (root / 'docs/operations/image-digests.lock').read_text(): sys.exit(67)
if os.environ['FAULT'] != 'no-start':
    with open(os.environ['RECEIPTS_EVENTS'], 'a') as f:
        for action in ('create', 'start'):
            f.write(json.dumps({'Type':'container', 'Action':action, 'Actor':{'ID':'fixture', 'Attributes':{'com.docker.compose.service':'npm', 'image':os.environ['REF']}}}) + '\\n')
''')
        self.write("scripts/configure.sh", '''#!/usr/bin/env python3
import os, sys
with open(os.environ['TRACE'], 'a') as f: f.write('configure ' + ' '.join(sys.argv[1:]) + '\\n')
sys.exit(66 if os.environ['FAULT'] == 'configure' else 0)
''')
        for file, label in (("upgrade_state.py", "application"), ("npm_state.py", "npm")):
            self.write("tests/fixtures/" + file, f'''import os, sys
with open(os.environ['TRACE'], 'a') as f: f.write('{label} ' + sys.argv[1] + '\\n')
sys.exit(66 if os.environ['FAULT'] == '{label}-' + sys.argv[1] else 0)
''')
        self.write("bin/docker", '''#!/usr/bin/env python3
import json, os, pathlib, sys, time
args = sys.argv[1:]
if args[0] == 'events': time.sleep(300)
elif args[:2] == ['volume', 'create']:
    with open(os.environ['RECEIPTS_EVENTS'], 'a') as f:
        f.write(json.dumps({'Type':'volume','Actor':{'ID':args[2]}}) + '\\n')
elif args[:2] == ['volume', 'rm']: pass
elif args[0] == 'inspect':
    if '.Config.Image' in args[2]: print('wrong' if os.environ['FAULT'] == 'wrong-image' else os.environ['REF'])
    else: print('healthy')
elif args[:2] == ['image', 'inspect']: print(json.dumps([os.environ['REF']]))
else: sys.exit(64)
''')

    def write(self, name, text):
        path = self.root / name
        path.write_text(text)
        path.chmod(0o755)

    def run_guest(self, fault):
        env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                   TRACE=str(self.root / "trace"), REF=REF, FAULT=fault,
                   RECEIPTS_EVENTS=str(self.root / "events"), RECEIPTS_PID=str(self.root / "pid"))
        return subprocess.run(["bash", str(self.root / "tests/gcp-vm/candidate-host.sh"), REF,
                               "a" * 40, "run-20261029T120000Z-12345678", "e" * 64],
                              env=env, capture_output=True, timeout=20)

    def test_real_guest_script_checks_before_repair_and_records_exact_candidate(self):
        # Given accepted state and command fixtures in an isolated guest directory.
        # When the real guest script upgrades to the frozen candidate.
        result = self.run_guest("")

        # Then migration is checked before repair and only complete proof earns a receipt.
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.root / "trace").read_text().splitlines(), ["update", "application check",
                         "npm check", "configure --only npm", "npm check", "npm renew"])
        lines = (self.root / "ms-remote-receipts.tsv").read_text().splitlines()
        rows = [line.split("\t") for line in lines if not line.startswith("#")]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:8], ["npm", *REF.split("@"), "remote-gcp", "a" * 40,
                         "run-20261029T120000Z-12345678", os.uname().machine, "e" * 64])

    def test_failed_checks_or_unobserved_candidate_never_write_a_receipt(self):
        for fault in ("update", "application-check", "npm-check", "configure", "npm-renew", "wrong-image", "no-start"):
            with self.subTest(fault):
                # Given one required guest check fails or the candidate never started.
                receipt = self.root / "ms-remote-receipts.tsv"
                receipt.unlink(missing_ok=True)

                # When the real guest script attempts the candidate proof.
                result = self.run_guest(fault)

                # Then it fails and cannot leave an acceptance receipt.
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(receipt.exists())


unittest.main(argv=["gcp-candidate-host"], verbosity=2)
PY
    pass 'guest orchestration refuses incomplete upgrade evidence'
else
    fail 'guest orchestration refuses incomplete upgrade evidence'
fi
summary
