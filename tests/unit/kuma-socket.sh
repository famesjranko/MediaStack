#!/usr/bin/env bash
# Kuma sends info before it installs the login listener on a new connection.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"
scenario_begin kuma-socket
if python3 -I - "$REPO_ROOT" <<'PY'; then
import json
import pathlib
import shutil
import subprocess
import sys
import unittest

root = pathlib.Path(sys.argv.pop())
program = (root / "tests/fixtures/kuma_socket.js").read_text()
runner = [shutil.which("node"), "-"] if shutil.which("node") else [
    "docker", "run", "--rm", "-i", "--network", "none", "node:22-slim", "node", "-"
]
HARNESS = r'''
const vm = require('node:vm');
const {EventEmitter} = require('node:events');
const incoming = new EventEmitter();
const scenario = SCENARIO;
const events = [], errors = [];
let ready = false, started = false, status = 0, snapshot = null, finish;
const done = new Promise(resolve => finish = resolve);
const fixture = {id: 3, name: 'MediaStack migration fixture', type: 'push', pushToken: 'fixture-token'};
const socket = {
    once(name, callback) { incoming.once(name, callback); },
    connect() {
        if (started) return;
        started = true;
        queueMicrotask(() => {
            incoming.emit('connect');
            const initialize = () => {
                if (scenario === 'missing-info') return;
                incoming.emit('info', {version: 'fixture'});
                ready = true;
            };
            // Kuma awaits sendInfo before registering its login handler.
            if (scenario === 'immediate-info') initialize();
            else setImmediate(initialize);
        });
    },
    timeout() { return this; },
    emit(name, ...args) {
        events.push(name);
        const ack = args.pop();
        if (!ready) {
            errors.push('request arrived before handlers');
            queueMicrotask(() => ack(new Error('unacknowledged request')));
            return;
        }
        queueMicrotask(() => {
            if (name === 'getMonitorList') incoming.emit('monitorList', {3: fixture});
            ack(null, {ok: !(scenario === 'rejected-login' && name === 'login'), data: []});
        });
    },
    disconnect() { finish(); }
};
const sandbox = {
    require(name) {
        if (name === 'fs') return {readFileSync: () => JSON.stringify({username: 'fixture', password: 'fixture-password'})};
        if (name === 'socket.io-client') return {io: (url, options) => {
            if (options.autoConnect !== false) socket.connect();
            return socket;
        }};
        if (name === 'crypto') return require(name);
        throw new Error(name);
    },
    process: {argv: ['node', 'snapshot'], set exitCode(code) { status = code; }, exit(code) { status = code; finish(); }},
    console: {log(line) { snapshot = JSON.parse(line); }, error(line) { errors.push(line); }},
    fetch: async () => ({ok: true, json: async () => ({})}),
    AbortSignal,
    setTimeout(callback, delay) { return setTimeout(callback, delay / 100); },
    clearTimeout
};
vm.runInNewContext(PROGRAM, sandbox);
done.then(() => console.log(JSON.stringify({status, events, errors, snapshot})));
'''


class KumaSocket(unittest.TestCase):
    def run_case(self, scenario):
        script = HARNESS.replace("SCENARIO", json.dumps(scenario)).replace("PROGRAM", json.dumps(program))
        result = subprocess.run(runner, input=script, text=True, capture_output=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_login_waits_for_initial_server_info(self):
        # Given Kuma initializes its request handlers after the transport connects.
        for scenario in ("delayed-info", "immediate-info"):
            with self.subTest(scenario=scenario):
                # When the real migration client collects a snapshot.
                result = self.run_case(scenario)

                # Then it authenticates once after readiness and collects state.
                self.assertEqual(result["status"], 0, result)
                self.assertEqual(result["events"].count("login"), 1, result)
                self.assertIsNotNone(result["snapshot"], result)
                self.assertEqual(result["errors"], [])

    def test_missing_server_info_fails_without_login(self):
        # Given the transport connects but Kuma never announces readiness.
        # When the real migration client reaches its bounded event deadline.
        result = self.run_case("missing-info")

        # Then it fails without authenticating or publishing state.
        self.assertEqual(result["status"], 1, result)
        self.assertEqual(result["events"], [], result)
        self.assertIsNone(result["snapshot"])

    def test_rejected_login_cannot_publish_state(self):
        # Given a ready Kuma server rejects the saved credentials.
        # When the real migration client attempts authentication.
        result = self.run_case("rejected-login")

        # Then it fails after one login and does not collect or publish state.
        self.assertEqual(result["status"], 1, result)
        self.assertEqual(result["events"], ["login"], result)
        self.assertEqual(result["errors"], ["Kuma request failed: login"], result)
        self.assertIsNone(result["snapshot"])


unittest.main(verbosity=2)
PY
    pass 'Kuma migration waits for server readiness and rejects failed authentication'
else
    fail 'Kuma migration waits for server readiness and rejects failed authentication'
fi
summary
