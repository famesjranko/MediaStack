#!/usr/bin/env bash
# Exercise the live install's local-indexer preparation without cloud or Docker.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin gcp-prepare-state
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = pathlib.Path(sys.argv.pop())
sys.path.insert(0, str(ROOT / "tests"))
import remote_image_preflight as run


class Baseline(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        for name in ("tests/gcp-vm", "tests/fixtures/torznab", "scripts", "bin"):
            (self.root / name).mkdir(parents=True)
        for name in ("tests/gcp-vm/prepare-state.sh", "tests/fixtures/torznab/mstest.yml",
                     "tests/fixtures/torznab/server.py"):
            shutil.copyfile(ROOT / name, self.root / name)
        (self.root / "config.yml").write_text("indexers: []\nkeep: configured-value\n")
        self.write("bin/docker", '''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ['TRACE'], 'a') as f: f.write(json.dumps(args) + '\\n')
fault = os.environ['FAULT']
if args[0] == 'run' and fault == 'start': sys.exit(66)
if args[0] == 'exec' and fault == 'tracker': sys.exit(66)
if args[0] == 'inspect': print('unhealthy' if fault == 'jackett' else 'healthy')
''')
        self.write("bin/sleep", "#!/bin/sh\nexit 0\n")
        self.write("scripts/configure.sh", '''#!/usr/bin/env python3
import json, os, pathlib, sys, yaml
assert yaml.safe_load(pathlib.Path('config.yml').read_text())['indexers'] == [{'id':'mstest','type':'general'}]
assert pathlib.Path('config/jackett/cardigann/definitions/mstest.yml').is_file()
with open(os.environ['TRACE'], 'a') as f: f.write(json.dumps(['configure', *sys.argv[1:]]) + '\\n')
''')

    def write(self, name, content):
        path = self.root / name
        path.write_text(content)
        path.chmod(0o755)

    def prepare(self, fault=""):
        env = dict(os.environ, PATH=str(self.root / "bin") + ":" + os.environ["PATH"],
                   TRACE=str(self.root / "trace"), FAULT=fault)
        return subprocess.run(["bash", "tests/gcp-vm/prepare-state.sh"], cwd=self.root,
                              env=env, capture_output=True, timeout=20)

    def test_real_install_populates_optional_indexer_before_saving_baseline(self):
        # Given an ordinary install with public indexers left disabled.
        def remote_step(gcp, label, script, *args, **kwargs):
            if "bash tests/gcp-vm/prepare-state.sh" in script:
                result = self.prepare()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if "upgrade_state.py save" in script:
                # The existing migration oracle refuses an empty indexer population.
                config = yaml.safe_load((self.root / "config.yml").read_text())
                self.assertTrue(config["indexers"], "baseline has no configured indexer")
            return b""

        # When the real orchestration prepares and saves its accepted baseline.
        with patch.object(run, "remote_step", remote_step):
            run.install(None, {"DOMAIN":"fixture.test", "NPM_ADMIN_EMAIL":"admin@fixture.test",
                               "DDNS_PASSWORD":"fixture-private-password"})

        # Then it configures a local pinned fixture and preserves unrelated settings.
        config = yaml.safe_load((self.root / "config.yml").read_text())
        self.assertEqual(config, {"indexers":[{"id":"mstest","type":"general"}],
                                  "keep":"configured-value"})
        commands = [json.loads(line) for line in (self.root / "trace").read_text().splitlines()]
        launch = commands[0]
        self.assertEqual(launch[:6], ["run", "-d", "--name", "torznab-fixture", "--network", "mediastack"])
        self.assertTrue(any(arg.startswith("python:3.12-alpine@sha256:") for arg in launch))
        self.assertFalse(set(launch) & {"-p", "--publish", "--publish-all", "-P"})
        self.assertLess(commands.index(["restart", "jackett"]),
                        commands.index(["configure", "--only", "jackett,sonarr,radarr"]))

    def test_unavailable_fixture_or_jackett_stops_before_configuration(self):
        for fault in ("start", "tracker", "jackett"):
            with self.subTest(fault=fault):
                # Given a failed fixture start or a service that never becomes ready.
                (self.root / "trace").unlink(missing_ok=True)

                # When the real baseline preparation attempts to configure it.
                result = self.prepare(fault)

                # Then it fails before calling the service configurators.
                self.assertNotEqual(result.returncode, 0)
                commands = [json.loads(line) for line in (self.root / "trace").read_text().splitlines()]
                self.assertFalse(any(command[0] == "configure" for command in commands))


unittest.main(argv=["gcp-prepare-state"], verbosity=2)
PY
    pass 'live migration baseline prepares its optional indexer fixture'
else
    fail 'live migration baseline prepares its optional indexer fixture'
fi
summary
